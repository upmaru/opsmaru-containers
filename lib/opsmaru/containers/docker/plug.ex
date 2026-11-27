if Code.ensure_loaded?(Plug.Conn) do
  defmodule Opsmaru.Containers.Docker.Plug do
    @moduledoc """
    Ordinary Docker Engine HTTP on a host-owned Plug adapter.

    Pass the host policy module as `:host`. The optional `:admission_timeout`
    and `:stream_timeout` bound local work in milliseconds. Use the raw handoff
    for Docker attach, upgraded requests and attached exec.

    Set `conn.private[:opsmaru_containers_client]` to a separate host process
    that exits on client disconnect to cancel pending engine I/O.
    """

    @behaviour Plug
    alias Opsmaru.Containers.Docker.{
      Admission,
      BindPolicy,
      EngineRequest,
      EngineSelection,
      Exchange,
      HTTP,
      Routing
    }

    alias Opsmaru.Containers.Native.{Lifecycle, Listing, Wait}
    alias Opsmaru.Containers.Transport
    alias Opsmaru.Containers.Transport.Stream

    @chunk_bytes 65_536
    @max_checked_body 1_048_576
    @guarded_paths ["/containers/create", "/volumes/create", "/exec/{name:.*}/start"]
    @exchange_key {__MODULE__, :exchange}

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
      exchange =
        Exchange.start(%{
          adapter: :plug,
          host: options.host,
          method: conn.method,
          peer_address: conn.remote_ip
        })

      Process.put(@exchange_key, exchange)

      try do
        serve(conn, options)
      catch
        kind, reason ->
          # A crash that no path classified ends the exchange without
          # finishing it. Response writes record `:caller_closed` themselves,
          # and an earlier recorded reason still wins.
          interrupt_current_exchange(:killed)
          :erlang.raise(kind, reason, __STACKTRACE__)
      after
        exchange = Process.get(@exchange_key)
        Process.delete(@exchange_key)
        Exchange.finish(exchange)
      end
    end

    defp interrupt_current_exchange(reason) do
      exchange = current_exchange()

      if exchange,
        do: Process.put(@exchange_key, Exchange.interrupt(exchange, reason))
    end

    # A response write that raises or exits means the client went away.
    defp write_response(fun) do
      fun.()
    catch
      kind, reason ->
        interrupt_current_exchange(:caller_closed)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end

    defp serve(conn, options) do
      deadline = now() + options.admission

      request = %{
        method: conn.method,
        path: conn.request_path,
        query: conn.query_string,
        peer: conn.remote_ip,
        host_peer: conn.private[:opsmaru_containers_peer]
      }

      with {:ok, admission} <- Admission.admit(options.host, request, deadline),
           _ <- Exchange.admit_route(current_exchange(), admission.route, conn.request_path),
           :ok <- regular_request(conn, admission.route) do
        case Routing.route(admission, conn.query_string, deadline) do
          :nested ->
            nested(conn, options, request, admission, deadline)

          {:list, containers} ->
            native_list(conn, admission, containers, now() + options.stream)

          {:prune, containers} ->
            native_prune(conn, admission, containers, now() + options.stream)

          {:native, container} ->
            native(conn, admission, container, now() + options.stream)

          {:error, status, message} ->
            refuse(conn, status, message)
        end
      else
        {:error, status, message} -> refuse(conn, status, message)
      end
    end

    defp refuse(conn, status, message),
      do: error(conn, status, message, Exchange.refusal_reason(status, message))

    defp nested(conn, options, request, admission, deadline) do
      case prepare_body(conn, options.host, request, admission, deadline) do
        {:ok, conn, body, framing} ->
          relay(conn, admission, body, framing, now() + options.stream)

        {:native_create, conn, body} ->
          query = URI.decode_query(conn.query_string)
          deadline = now() + options.stream

          reply(
            conn,
            admission,
            Lifecycle.create(
              admission.context,
              options.host,
              query,
              body,
              admission.maximum,
              deadline
            )
          )

        {:error, status, message} ->
          refuse(conn, status, message)
      end
    end

    # The nested engine answers first, so its own validation and errors reach
    # the client unchanged. Native entries are merged into its answer.
    defp native_list(conn, admission, containers, deadline) do
      target = append_query(admission.path, conn.query_string)

      with {:ok, query} <- Listing.list_query(conn.query_string),
           {:ok, 200, nested} when is_list(nested) <- engine(admission, "GET", target, deadline),
           {:ok, native} <-
             Listing.entries(admission.context, containers, query, admission.maximum, deadline) do
        json(conn, admission, 200, Listing.merge(nested, native, query))
      else
        {:ok, status, body} -> json(conn, admission, status, body)
        {:error, status, message} -> refuse(conn, status, message)
        {:error, :engine} -> error(conn, 502, "Docker engine connection failed", :upstream_failed)
      end
    end

    defp native_prune(conn, admission, containers, deadline) do
      target = append_query(admission.path, conn.query_string)

      with {:ok, filters} <- Listing.prune_query(conn.query_string),
           {:ok, 200, %{} = nested} <- engine(admission, "POST", target, deadline),
           {:ok, deleted} <- Listing.prune(admission.context, containers, filters, deadline) do
        body = %{
          "ContainersDeleted" => (nested["ContainersDeleted"] || []) ++ deleted,
          "SpaceReclaimed" => nested["SpaceReclaimed"] || 0
        }

        json(conn, admission, 200, body)
      else
        {:ok, status, body} -> json(conn, admission, status, body)
        {:error, status, message} -> refuse(conn, status, message)
        {:error, :engine} -> error(conn, 502, "Docker engine connection failed", :upstream_failed)
      end
    end

    @native_routes %{
      "/containers/{name:.*}/start" => :start,
      "/containers/{name:.*}/stop" => :stop,
      "/containers/{name:.*}/kill" => :kill,
      "/containers/{name:.*}/restart" => :restart,
      "/containers/{name:.*}/pause" => :pause,
      "/containers/{name:.*}/unpause" => :unpause,
      "/containers/{name:.*}/rename" => :rename,
      "/containers/{name:.*}" => :remove,
      "/containers/{name:.*}/json" => :inspect,
      "/containers/{name:.*}/wait" => :wait
    }

    # A request for a container the native engine owns. Nothing reaches the
    # nested engine except name checks and image handoff reads.
    defp native(conn, admission, container, deadline) do
      query = URI.decode_query(conn.query_string)
      context = admission.context

      case Map.get(@native_routes, admission.route["path"]) do
        nil ->
          {:error, status, message} = Routing.unavailable(admission.route)
          refuse(conn, status, message)

        :wait ->
          native_wait(conn, admission, container, query, deadline)

        operation ->
          reply(
            conn,
            admission,
            lifecycle(operation, context, container, query, admission, deadline)
          )
      end
    end

    defp lifecycle(:start, context, container, _, _, deadline),
      do: Lifecycle.start(context, container, deadline)

    defp lifecycle(:stop, context, container, query, _, deadline),
      do: Lifecycle.stop(context, container, query, deadline)

    defp lifecycle(:kill, context, container, query, _, deadline),
      do: Lifecycle.kill(context, container, query, deadline)

    defp lifecycle(:restart, context, container, query, _, deadline),
      do: Lifecycle.restart(context, container, query, deadline)

    defp lifecycle(:pause, context, container, _, _, deadline),
      do: Lifecycle.pause(context, container, deadline)

    defp lifecycle(:unpause, context, container, _, _, deadline),
      do: Lifecycle.unpause(context, container, deadline)

    defp lifecycle(:rename, context, container, query, admission, deadline),
      do: Lifecycle.rename(context, container, query, admission.maximum, deadline)

    defp lifecycle(:remove, context, container, query, _, deadline),
      do: Lifecycle.remove(context, container, query, deadline)

    defp lifecycle(:inspect, context, container, _, _, deadline),
      do: Lifecycle.inspect(context, container, deadline)

    defp reply(conn, admission, {:ok, status, body}), do: json(conn, admission, status, body)

    defp reply(conn, admission, {:ok, status}) do
      Exchange.sent(current_exchange(), :sent)
      Exchange.commit(current_exchange(), status)
      conn = Plug.Conn.put_resp_header(conn, "api-version", admission.maximum)
      write_response(fn -> Plug.Conn.send_resp(conn, status, "") end)
    end

    defp reply(conn, _, {:error, status, message}), do: refuse(conn, status, message)

    # dockerd sends the status line before it waits, so a client sees the
    # wait begin. The result follows as the only body chunk. A client that
    # disconnects ends the wait with no answer and no removal.
    defp native_wait(conn, admission, container, query, deadline) do
      with {:ok, condition} <- Wait.condition(query["condition"]),
           {:ok, waiter} <- Wait.begin(admission.context, container, condition, deadline) do
        try do
          Exchange.sent(current_exchange(), :sent)
          Exchange.commit(current_exchange(), 200)

          conn =
            conn
            |> Plug.Conn.put_resp_content_type("application/json", nil)
            |> Plug.Conn.put_resp_header("api-version", admission.maximum)

          conn = write_response(fn -> Plug.Conn.send_chunked(conn, 200) end)

          with_client_monitor(conn, fn monitor ->
            case Wait.run(waiter, deadline, fn -> client_gone?(monitor) end) do
              {:ok, body} ->
                wait_chunk(conn, body)

              :cancelled ->
                Exchange.interrupt(current_exchange(), :caller_closed)
                conn

              {:error, _, message} ->
                wait_chunk(conn, %{"StatusCode" => -1, "Error" => %{"Message" => message}})
            end
          end)
        after
          Wait.close(waiter)
        end
      else
        {:error, status, message} -> refuse(conn, status, message)
      end
    end

    defp wait_chunk(conn, body) do
      encoded = Jason.encode!(body) <> "\n"

      case chunk(conn, encoded) do
        {:ok, conn} ->
          Exchange.response_bytes(current_exchange(), byte_size(encoded))
          conn

        {:error, _} ->
          Exchange.interrupt(current_exchange(), :caller_closed)
          conn
      end
    end

    defp client_gone?(nil), do: false

    defp client_gone?(monitor) do
      receive do
        {:DOWN, ^monitor, :process, _, _} -> true
      after
        0 -> false
      end
    end

    defp engine(admission, method, target, deadline) do
      Exchange.sent(current_exchange(), Exchange.dialed_outcome(method))
      body = if method == "POST", do: "", else: nil

      case EngineRequest.json(admission.context, method, target, body, deadline) do
        {:ok, _, _} = result -> result
        {:error, _} -> {:error, :engine}
      end
    end

    defp json(conn, admission, status, body) do
      Exchange.sent(current_exchange(), :sent)
      Exchange.commit(current_exchange(), status)
      encoded = Jason.encode!(body)
      Exchange.response_bytes(current_exchange(), byte_size(encoded))

      conn =
        conn
        |> Plug.Conn.put_resp_content_type("application/json", nil)
        |> Plug.Conn.put_resp_header("api-version", admission.maximum)

      write_response(fn -> Plug.Conn.send_resp(conn, status, encoded) end)
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

    defp prepare_body(conn, host, request, %{route: %{"path" => path}} = admission, deadline)
         when path in @guarded_paths do
      with {:ok, bytes, conn} <- read_checked_body(conn),
           _ <- Exchange.request_bytes(current_exchange(), byte_size(bytes)),
           :ok <- detached_exec(path, bytes) do
        checked_body(conn, host, request, admission, bytes, deadline)
      end
    end

    defp prepare_body(conn, _, _, _, _) do
      case request_framing(conn) do
        {:error, _, _} = failure -> failure
        framing -> {:ok, conn, :stream, framing}
      end
    end

    defp checked_body(conn, host, request, admission, bytes, deadline) do
      case engine_for(admission.route["path"], host, request, admission, bytes, deadline) do
        :native ->
          {:native_create, conn, bytes}

        :nested ->
          with {:ok, bytes} <- BindPolicy.apply(host, admission, bytes, deadline),
               do: {:ok, conn, bytes, {:length, byte_size(bytes)}}
      end
    end

    # A create the host routes to native is never sent to nested instead.
    defp engine_for("/containers/create", host, request, admission, bytes, deadline),
      do: EngineSelection.select(host, request, admission, bytes, deadline)

    defp engine_for(_, _, _, _, _, _), do: :nested

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
          Exchange.sent(current_exchange(), Exchange.dialed_outcome(conn.method))

          try do
            with_client_monitor(conn, fn monitor ->
              exchange(conn, admission, stream, body, framing, deadline, monitor)
            end)
          after
            Stream.close(stream)
          end

        {:error, _} ->
          error(conn, 503, "Docker engine is not ready", :engine_unavailable)
      end
    end

    defp with_client_monitor(conn, fun) do
      client = conn.private[:opsmaru_containers_client]
      monitor = if is_pid(client) and client != self(), do: Process.monitor(client)

      try do
        fun.(monitor)
      after
        if monitor, do: Process.demonitor(monitor, [:flush])
      end
    end

    defp exchange(conn, admission, stream, body, framing, deadline, monitor) do
      target = append_query(admission.path, conn.query_string)

      case HTTP.send_head(stream, conn.method, target, conn.req_headers, framing, deadline) do
        :ok ->
          conn
          |> request_body(stream, body, framing, deadline, monitor)
          |> respond_to_exchange(admission, monitor)

        {:error, _} ->
          error(conn, 502, "Docker engine connection failed", :upstream_failed)
      end
    end

    defp respond_to_exchange({conn, {:ok, response}}, admission, monitor),
      do: respond(conn, response, admission, monitor)

    defp respond_to_exchange({conn, {:error, _}}, _, _),
      do: error(conn, 502, "Docker engine connection failed", :upstream_failed)

    defp request_body(conn, stream, _, :none, deadline, monitor) do
      {conn,
       read_engine(monitor, deadline, fn -> HTTP.receive_head(stream, conn.method, deadline) end)}
    end

    defp request_body(conn, stream, body, framing, deadline, monitor) do
      with_task(fn -> HTTP.receive_head(stream, conn.method, deadline) end, fn reader ->
        upload = %{
          stream: stream,
          framing: framing,
          deadline: deadline,
          reader: reader.ref,
          monitor: monitor
        }

        case send_body(conn, body, upload) do
          {:ok, conn} -> {conn, await_head(upload)}
          {:response, result, conn} -> {conn, result}
          {:write_error, conn} -> {conn, await_head(upload)}
        end
      end)
    end

    defp send_body(conn, body, upload) when is_binary(body) do
      send_piece(conn, upload, fn ->
        HTTP.send_chunk(upload.stream, body, upload.framing, upload.deadline)
      end)
    end

    defp send_body(conn, :stream, upload), do: send_stream(conn, upload, upload.framing)

    defp send_stream(conn, upload, remaining) do
      case wait_for_io(upload.reader, nil, upload.monitor, 0) do
        {:response, result} -> {:response, result, close_after_response(conn)}
        :pending -> read_upload(conn, upload, remaining)
      end
    end

    defp read_upload(conn, upload, remaining) do
      with timeout when timeout > 0 <- upload.deadline - now(),
           {status, bytes, conn} when status in [:ok, :more] <-
             Plug.Conn.read_body(conn,
               length: @chunk_bytes,
               read_length: @chunk_bytes,
               read_timeout: timeout
             ) do
        forward_upload(conn, upload, remaining, status, bytes)
      else
        _ -> invalid_upload(conn, upload)
      end
    end

    defp forward_upload(conn, upload, remaining, status, bytes) do
      case consume(remaining, bytes) do
        {:ok, remaining} ->
          Exchange.request_bytes(current_exchange(), byte_size(bytes))

          sender = fn ->
            HTTP.send_chunk(upload.stream, bytes, upload.framing, upload.deadline)
          end

          with {:ok, conn} <- send_piece(conn, upload, sender, status == :more),
               do: finish_stream(status, conn, upload, remaining)

        {:error, _} ->
          invalid_upload(conn, upload)
      end
    end

    defp finish_stream(:more, conn, upload, remaining), do: send_stream(conn, upload, remaining)

    defp finish_stream(:ok, conn, _upload, {:length, 0}), do: {:ok, conn}

    defp finish_stream(:ok, conn, upload, :chunked) do
      send_piece(conn, upload, fn ->
        HTTP.finish(upload.stream, upload.framing, upload.deadline)
      end)
    end

    defp finish_stream(_, conn, upload, _), do: invalid_upload(conn, upload)

    defp invalid_upload(conn, upload) do
      conn = close_after_response(conn)

      case wait_for_io(upload.reader, nil, upload.monitor, 0) do
        {:response, result} ->
          {:response, result, conn}

        :pending ->
          Exchange.interrupt(current_exchange(), :invalid_request)
          {:response, {:error, :invalid_request_length}, conn}
      end
    end

    defp send_piece(conn, upload, fun, unread? \\ false) do
      case wait_for_io(upload.reader, nil, upload.monitor, 0) do
        {:response, result} ->
          {:response, result, early_connection(conn, unread?)}

        :pending ->
          with_task(fun, &await_write(conn, upload, &1.ref, unread?))
      end
    end

    defp await_write(conn, upload, writer, unread?) do
      case wait_for_io(upload.reader, writer, upload.monitor, remaining(upload.deadline)) do
        {:response, result} -> {:response, result, early_connection(conn, unread?)}
        {:sent, :ok} -> {:ok, conn}
        _ -> {:write_error, early_connection(conn, unread?)}
      end
    end

    defp await_head(upload), do: await_read(upload.reader, upload.monitor, upload.deadline)

    defp read_engine(nil, _, fun), do: fun.()

    defp read_engine(monitor, deadline, fun) do
      with_task(fun, fn reader -> await_read(reader.ref, monitor, deadline) end)
    end

    defp await_read(reader, monitor, deadline) do
      case wait_for_io(reader, nil, monitor, remaining(deadline)) do
        {:response, result} -> result
        :pending -> {:error, :deadline}
      end
    end

    defp wait_for_io(reader, writer, monitor, timeout) do
      receive do
        {^reader, result} -> {:response, result}
        {^writer, result} when is_reference(writer) -> {:sent, result}
        {:DOWN, ^monitor, :process, _, _} -> caller_closed()
      after
        timeout -> :pending
      end
    end

    defp caller_closed do
      Exchange.interrupt(current_exchange(), :caller_closed)
      exit(:shutdown)
    end

    defp with_task(fun, handle) do
      task = Task.async(fun)

      try do
        handle.(task)
      after
        Task.shutdown(task, :brutal_kill)
      end
    end

    defp early_connection(conn, true), do: close_after_response(conn)
    defp early_connection(conn, false), do: conn

    defp close_after_response(%{adapter: {adapter, _}} = conn) do
      if function_exported?(adapter, :get_http_protocol, 1) and
           Plug.Conn.get_http_protocol(conn) in [:"HTTP/1", :"HTTP/1.0", :"HTTP/1.1"] do
        Plug.Conn.put_resp_header(conn, "connection", "close")
      else
        conn
      end
    end

    defp remaining(deadline), do: max(0, deadline - now())

    defp consume(:chunked, _bytes), do: {:ok, :chunked}

    defp consume({:length, remaining}, bytes) when byte_size(bytes) <= remaining,
      do: {:ok, {:length, remaining - byte_size(bytes)}}

    defp consume(_, _), do: {:error, :invalid_request_length}

    defp respond(conn, response, admission, monitor) do
      Exchange.sent(current_exchange(), :sent)
      caps = admission.context.capabilities
      rewrite? = caps.maximum != admission.maximum or caps.minimum != admission.minimum
      version? = admission.route["path"] == "/version" and response.status == 200

      cond do
        response.mode in [:complete, {:length, 0}] ->
          Exchange.commit(current_exchange(), response.status)

          conn = response_headers(conn, response, admission, true)
          write_response(fn -> Plug.Conn.send_resp(conn, response.status, "") end)

        version? and rewrite? ->
          respond_version(conn, response, admission, monitor)

        true ->
          Exchange.commit(current_exchange(), response.status)

          conn = response_headers(conn, response, admission, false)

          fn -> Plug.Conn.send_chunked(conn, response.status) end
          |> write_response()
          |> stream_response(response, monitor)
      end
    end

    defp respond_version(conn, response, admission, monitor) do
      with {:ok, body} <-
             read_engine(monitor, response.deadline, fn ->
               HTTP.collect(response, @max_checked_body)
             end),
           {:ok, %{"ApiVersion" => _, "MinAPIVersion" => _} = version} <- Jason.decode(body) do
        body =
          version
          |> Map.merge(%{"ApiVersion" => admission.maximum, "MinAPIVersion" => admission.minimum})
          |> Jason.encode!()

        Exchange.commit(current_exchange(), 200)
        Exchange.response_bytes(current_exchange(), byte_size(body))
        conn = response_headers(conn, response, admission, false)
        write_response(fn -> Plug.Conn.send_resp(conn, 200, body) end)
      else
        _ -> error(conn, 502, "Invalid Docker engine version response", :upstream_failed)
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

    defp stream_response(conn, response, monitor) do
      case read_engine(monitor, response.deadline, fn -> HTTP.next(response) end) do
        {:ok, bytes, response} ->
          case chunk(conn, bytes) do
            {:ok, conn} ->
              Exchange.response_bytes(current_exchange(), byte_size(bytes))
              stream_response(conn, response, monitor)

            {:error, _} ->
              Exchange.interrupt(current_exchange(), :caller_closed)
              conn
          end

        :eof ->
          conn

        {:error, reason} ->
          Exchange.interrupt(
            current_exchange(),
            if(reason == :deadline, do: :deadline, else: :backend_closed)
          )

          raise "Docker upstream response ended before completion"
      end
    end

    defp chunk(conn, bytes), do: write_response(fn -> Plug.Conn.chunk(conn, bytes) end)

    defp error(conn, status, message, reason) do
      body = Jason.encode!(%{message: message})
      Exchange.commit(current_exchange(), status, reason)
      Exchange.response_bytes(current_exchange(), byte_size(body))

      conn = Plug.Conn.put_resp_content_type(conn, "application/json")
      write_response(fn -> Plug.Conn.send_resp(conn, status, body) end)
    end

    defp current_exchange, do: Process.get(@exchange_key)

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
