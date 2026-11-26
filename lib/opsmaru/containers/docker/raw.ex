defmodule Opsmaru.Containers.Docker.Raw do
  @moduledoc """
  Docker HTTP/1.1 handoff for a host listener that owns the downstream stream.

  The host passes the parsed request, its bounded body and any bytes already
  read after that body. After admission and an accepted engine handshake
  the relay writes the response and owns both streams. Otherwise the host
  retains its stream and can send the returned ordinary HTTP response.
  """

  alias Opsmaru.Containers.Docker.{Admission, HTTP, RawTunnel}
  alias Opsmaru.Containers.Transport
  alias Opsmaru.Containers.Transport.Stream

  @max_body 1_048_576

  @doc """
  Forward a raw-capable request using separate admission and stream deadlines.

  The request contains `:method`, `:path`, `:query`, `:headers` and `:body`
  with optional host peer metadata. Header names are lowercase. The listener
  must parse HTTP/1.1 framing before handing off and authenticate via the
  configured host callback.
  """
  def relay(host, request, %Stream{} = frontend, options) do
    admission_deadline = Keyword.fetch!(options, :admission_deadline)
    deadline = Keyword.fetch!(options, :deadline)
    request_tail = Keyword.fetch!(options, :request_tail)

    with {:ok, admission} <- Admission.admit(host, request, admission_deadline),
         {:ok, protocol, framing} <- handshake(request, admission.route),
         {:ok, backend} <- dial(admission.context, deadline) do
      response = exchange(request, admission, backend, protocol, framing, deadline)
      downstream(response, admission, frontend, backend, request_tail, deadline)
    else
      {:error, status, reason} ->
        {:http, status, [{"content-type", "application/json"}], Jason.encode!(%{message: reason})}
    end
  end

  defp handshake(%{body: body, headers: headers}, %{"takeover" => mode})
       when is_binary(body) and byte_size(body) <= @max_body and is_list(headers) do
    protocol = HTTP.upgrade_protocol(headers)
    upgrade? = Enum.any?(headers, fn {name, _} -> name == "upgrade" end)
    validate_protocol(mode, protocol, upgrade?, body)
  end

  defp handshake(_, _), do: invalid_handshake()

  defp validate_protocol("docker_stream", nil, false, body),
    do: {:ok, nil, {:length, byte_size(body)}}

  defp validate_protocol("docker_stream", "tcp", true, body),
    do: {:ok, "tcp", {:length, byte_size(body)}}

  defp validate_protocol("h2c_upgrade", "h2c", true, ""), do: {:ok, "h2c", :none}
  defp validate_protocol("websocket", "websocket", true, ""), do: {:ok, "websocket", :none}

  defp validate_protocol(_, _, _, _), do: invalid_handshake()

  defp invalid_handshake, do: {:error, 400, "Invalid Docker stream request"}

  defp dial(context, deadline) do
    case Transport.dial(context.dialer, context.target, deadline) do
      {:ok, stream} -> {:ok, stream}
      {:error, _} -> {:error, 503, "Docker engine is not ready"}
    end
  end

  defp exchange(request, admission, backend, protocol, framing, deadline) do
    target =
      if request.query == "", do: admission.path, else: admission.path <> "?" <> request.query

    mode = admission.route["takeover"]

    with :ok <-
           HTTP.send_head(
             backend,
             request.method,
             target,
             request.headers,
             framing,
             deadline,
             protocol
           ),
         :ok <- send_body(backend, request.body, framing, deadline) do
      HTTP.receive_head(backend, request.method, deadline, {mode, protocol})
    end
  rescue
    _ -> {:error, :engine_unavailable}
  catch
    _, _ -> {:error, :engine_unavailable}
  end

  defp send_body(_, _, :none, _), do: :ok

  defp send_body(stream, body, framing, deadline),
    do: HTTP.send_chunk(stream, body, framing, deadline)

  defp downstream(
         {:ok, %{mode: {:raw, _}} = response},
         admission,
         frontend,
         backend,
         request_tail,
         deadline
       ) do
    {:relayed,
     RawTunnel.run(frontend, backend,
       deadline: deadline,
       request_tail: request_tail,
       response_head: HTTP.raw_head(response, admission.maximum),
       response_tail: response.buffer
     )}
  end

  defp downstream({:ok, response}, _, _, backend, _, _) do
    case HTTP.collect(response, @max_body) do
      {:ok, body} ->
        headers =
          Enum.reject(HTTP.end_to_end(response.headers), fn {name, _} ->
            name == "content-length"
          end)

        {:http, response.status, headers, body}

      _ ->
        upstream_failure()
    end
  after
    Stream.close(backend)
  end

  defp downstream(_, _, _, backend, _, _) do
    Stream.close(backend)
    upstream_failure()
  end

  defp upstream_failure do
    {:http, 502, [{"content-type", "application/json"}],
     Jason.encode!(%{message: "Docker engine connection failed"})}
  end
end
