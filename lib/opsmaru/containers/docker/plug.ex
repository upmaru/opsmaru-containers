if Code.ensure_loaded?(Plug.Conn) do
  defmodule Opsmaru.Containers.Docker.Plug do
    @moduledoc """
    Ordinary Docker Engine HTTP on a host-owned Plug adapter.

    Pass the host policy module as `:host`. The optional `:admission_timeout`
    and `:stream_timeout` bound local work in milliseconds. Use the raw handoff
    for Docker attach, upgraded requests and attached exec.
    """

    @behaviour Plug
    alias Opsmaru.Containers.Docker.{Admission, BindPolicy, HTTP}
    alias Opsmaru.Containers.Transport
    alias Opsmaru.Containers.Transport.Stream

    @chunk_bytes 65_536
    @max_checked_body 1_048_576
    @guarded_paths ["/containers/create", "/volumes/create", "/exec/{name:.*}/start"]

    @impl Plug
    def init(options) do
      %{
        host: Keyword.fetch!(options, :host),
        admission: timeout(options, :admission_timeout, 1_000),
        stream: timeout(options, :stream_timeout, 300_000)
      }
    end

    @impl Plug
    def call(conn, options) do
      deadline = now() + options.admission

      request = %{
        method: conn.method,
        path: conn.request_path,
        query: conn.query_string,
        peer: conn.remote_ip,
        host_peer: conn.private[:opsmaru_containers_peer]
      }

      with {:ok, admission} <- Admission.admit(options.host, request, deadline),
           :ok <- regular_request(conn, admission.route),
           {:ok, conn, body, framing} <- prepare_body(conn, options.host, admission, deadline) do
        relay(conn, admission, body, framing, now() + options.stream)
      else
        {:error, status, message} -> error(conn, status, message)
      end
    end

    defp regular_request(conn, route) do
      if Plug.Conn.get_req_header(conn, "upgrade") != [] or
           route["takeover"] in ["websocket", "h2c_upgrade"] or
           route["path"] == "/containers/{name:.*}/attach" do
        {:error, 501, "Docker stream requires the host's raw adapter"}
      else
        :ok
      end
    end

    defp prepare_body(conn, host, %{route: %{"path" => path}} = admission, deadline)
         when path in @guarded_paths do
      with {:ok, bytes, conn} <- read_checked_body(conn),
           :ok <- detached_exec(path, bytes),
           {:ok, bytes} <- BindPolicy.apply(host, admission, bytes, deadline) do
        {:ok, conn, bytes, {:length, byte_size(bytes)}}
      end
    end

    defp prepare_body(conn, _, _, _) do
      case request_framing(conn) do
        {:error, _, _} = failure -> failure
        framing -> {:ok, conn, :stream, framing}
      end
    end

    defp detached_exec("/exec/{name:.*}/start", bytes) do
      case Jason.decode(bytes, objects: :ordered_objects) do
        {:ok, %Jason.OrderedObject{values: fields}} -> require_detached(fields)
        _ -> {:error, 400, "Invalid Docker JSON request"}
      end
    end

    defp detached_exec(_, _), do: :ok

    defp require_detached(fields) do
      detach_fields = for {key, value} <- fields, String.downcase(key) == "detach", do: value

      if detach_fields == [true],
        do: :ok,
        else: {:error, 501, "Docker attached exec requires the host's raw adapter"}
    end

    defp read_checked_body(conn) do
      case Plug.Conn.read_body(conn, length: @max_checked_body, read_length: @chunk_bytes) do
        {:ok, body, conn} when byte_size(body) <= @max_checked_body -> {:ok, body, conn}
        {:more, _, _} -> {:error, 413, "Docker JSON request is too large"}
        _ -> {:error, 400, "Invalid Docker request body"}
      end
    end

    defp request_framing(conn) do
      lengths = Plug.Conn.get_req_header(conn, "content-length")
      transfer = Plug.Conn.get_req_header(conn, "transfer-encoding")

      case {lengths, transfer} do
        {[], []} when conn.method not in ["POST", "PUT", "PATCH"] -> :none
        {[], []} -> :chunked
        {[], ["chunked"]} -> :chunked
        {[length], []} -> length_header(length)
        _ -> {:error, 400, "Invalid Docker request framing"}
      end
    end

    defp length_header(value) do
      with true <- Regex.match?(~r/\A[0-9]{1,19}\z/, value),
           {length, ""} <- Integer.parse(value) do
        {:length, length}
      else
        _ -> {:error, 400, "Invalid Docker request framing"}
      end
    end

    defp relay(conn, admission, body, framing, deadline) do
      context = admission.context

      case Transport.dial(context.dialer, context.target, deadline) do
        {:ok, stream} ->
          try do
            exchange(conn, admission, stream, body, framing, deadline)
          after
            Stream.close(stream)
          end

        {:error, _} ->
          error(conn, 503, "Docker engine is not ready")
      end
    end

    defp exchange(conn, admission, stream, body, framing, deadline) do
      target = append_query(admission.path, conn.query_string)

      with :ok <- HTTP.send_head(stream, conn.method, target, conn.req_headers, framing, deadline),
           {:ok, conn} <- send_body(conn, stream, body, framing, deadline),
           {:ok, response} <- HTTP.receive_head(stream, conn.method, deadline) do
        respond(conn, response, admission)
      else
        _ -> error(conn, 502, "Docker engine connection failed")
      end
    end

    defp send_body(conn, _, _, :none, _), do: {:ok, conn}

    defp send_body(conn, stream, bytes, framing, deadline) when is_binary(bytes) do
      with :ok <- HTTP.send_chunk(stream, bytes, framing, deadline), do: {:ok, conn}
    end

    defp send_body(conn, stream, :stream, framing, deadline) do
      send_stream(conn, stream, framing, framing, deadline)
    end

    defp send_stream(conn, stream, framing, remaining, deadline) do
      with timeout when timeout > 0 <- deadline - now(),
           {status, bytes, conn} when status in [:ok, :more] <-
             Plug.Conn.read_body(conn,
               length: @chunk_bytes,
               read_length: @chunk_bytes,
               read_timeout: timeout
             ),
           {:ok, remaining} <- consume(remaining, bytes),
           :ok <- HTTP.send_chunk(stream, bytes, framing, deadline) do
        finish_stream(status, conn, stream, framing, remaining, deadline)
      end
    end

    defp finish_stream(:more, conn, stream, framing, remaining, deadline),
      do: send_stream(conn, stream, framing, remaining, deadline)

    defp finish_stream(:ok, conn, stream, framing, remaining, deadline)
         when remaining in [:chunked, {:length, 0}] do
      with :ok <- HTTP.finish(stream, framing, deadline), do: {:ok, conn}
    end

    defp finish_stream(_, _, _, _, _, _), do: {:error, :invalid_request_length}

    defp consume(:chunked, _bytes), do: {:ok, :chunked}

    defp consume({:length, remaining}, bytes) when byte_size(bytes) <= remaining,
      do: {:ok, {:length, remaining - byte_size(bytes)}}

    defp consume(_, _), do: {:error, :invalid_request_length}

    defp respond(conn, response, admission) do
      caps = admission.context.capabilities
      rewrite? = caps.maximum != admission.maximum or caps.minimum != admission.minimum
      version? = admission.route["path"] == "/version" and response.status == 200

      cond do
        response.mode in [:complete, {:length, 0}] ->
          conn
          |> response_headers(response, admission, true)
          |> Plug.Conn.send_resp(response.status, "")

        version? and rewrite? ->
          respond_version(conn, response, admission)

        true ->
          conn
          |> response_headers(response, admission, false)
          |> Plug.Conn.send_chunked(response.status)
          |> stream_response(response)
      end
    end

    defp respond_version(conn, response, admission) do
      with {:ok, body} <- HTTP.collect(response, @max_checked_body),
           {:ok, %{"ApiVersion" => _, "MinAPIVersion" => _} = version} <- Jason.decode(body) do
        body =
          version
          |> Map.merge(%{"ApiVersion" => admission.maximum, "MinAPIVersion" => admission.minimum})
          |> Jason.encode!()

        conn |> response_headers(response, admission, false) |> Plug.Conn.send_resp(200, body)
      else
        _ -> error(conn, 502, "Invalid Docker engine version response")
      end
    end

    defp response_headers(conn, response, admission, preserve_length?) do
      headers =
        response.headers
        |> HTTP.end_to_end()
        |> Enum.reject(fn {name, _} -> name == "content-length" and not preserve_length? end)
        |> Enum.map(fn
          {"api-version", _} -> {"api-version", admission.maximum}
          header -> header
        end)

      %{conn | resp_headers: headers ++ conn.resp_headers}
    end

    defp stream_response(conn, response) do
      case HTTP.next(response) do
        {:ok, bytes, response} ->
          case Plug.Conn.chunk(conn, bytes) do
            {:ok, conn} -> stream_response(conn, response)
            {:error, _} -> conn
          end

        :eof ->
          conn

        {:error, _} ->
          raise "Docker upstream response ended before completion"
      end
    end

    defp error(conn, status, message) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(%{message: message}))
    end

    defp append_query(path, ""), do: path
    defp append_query(path, raw_query), do: path <> "?" <> raw_query

    defp timeout(options, key, default) do
      case Keyword.get(options, key, default) do
        value when is_integer(value) and value in 1..3_600_000 -> value
        _ -> raise ArgumentError, "invalid Docker #{key}"
      end
    end

    defp now, do: System.monotonic_time(:millisecond)
  end
end
