defmodule Opsmaru.Containers.Docker.Raw do
  @moduledoc """
  Docker HTTP/1.1 handoff for a host listener that owns the downstream stream.

  This module is the split raw entry point. `open/3` admits the request,
  dials the transport and completes the upstream handshake, then returns
  the response headers the host must send. `run/4` relays both streams once
  the host owns the frontend socket. `relay/4` is the single-call form:
  `open/3`, write the head, `run/4`.

  Ownership contract: `open/3` and `run/4` for one exchange MUST run in the
  same process. The calling process, the relay owner, must outlive the
  exchange. Adapters may tie resources to the dialing process (the exec
  bridge links an `Agent` and owns the Incus session), so moving a backend
  between processes is not supported.

  The request contains `:method`, `:path`, `:query`, `:headers` and `:body`
  with optional host peer metadata. Header names are lowercase. The listener
  must parse HTTP/1.1 framing before handing off and authenticate via
  the configured host callback.

  `open/3` options: `:admission_deadline`, `:deadline` (both absolute
  monotonic timestamps) and optionally `:exchange`. `run/4` options:
  `:deadline`, `:request_tail` and optionally `:exchange`. When `:exchange`
  is not passed, `open/3` starts an exchange internally (when a telemetry
  handler is attached) and stashes it in the calling process; `run/4`
  reads it back from there.
  """

  alias Opsmaru.Containers.Docker.{Admission, Exchange, HTTP, RawTunnel, Routing}
  alias Opsmaru.Containers.Transport
  alias Opsmaru.Containers.Transport.Stream

  @max_body 1_048_576
  @exchange_key {Opsmaru.Containers.Docker.Raw, :exchange}

  @doc """
  Admit and dial the nested engine, then complete the upstream handshake.

  Returns `{:upgrade, response, backend, tail}` where `response` carries the
  status, protocol and normalized headers `relay/4` would write, and
  `backend` plus `tail` are the already-dialed streams and the engine bytes
  read past its response head. The `backend` is returned unclosed: the
  caller owns it and delivers it to `run/4`. Any other result is
  `{:http, status, headers, body}` with the backend already closed.
  """
  @spec open(module(), map(), keyword()) ::
          {:upgrade, map(), Stream.t(), binary()}
          | {:http, pos_integer(), [{binary(), binary()}], binary()}
  def open(host, request, options) do
    exchange = Keyword.get(options, :exchange) || start_exchange(host, request)
    Process.put(@exchange_key, exchange)

    admission_deadline = Keyword.fetch!(options, :admission_deadline)
    deadline = Keyword.fetch!(options, :deadline)

    with {:ok, admission} <- Admission.admit(host, request, admission_deadline),
         :ok <- admit_exchange(exchange, request, admission),
         {:ok, protocol, framing} <- handshake(request, admission.route),
         :nested <- raw_route(admission, request.query, admission_deadline),
         {:ok, backend} <- dial(admission.context, deadline) do
      Exchange.sent(exchange, Exchange.dialed_outcome(request.method))

      exchange_phase(request, admission, backend, protocol, framing, deadline, exchange)
    else
      {:error, status, message} ->
        refuse(exchange, status, message, Exchange.refusal_reason(status, message))

      {:error, status, message, reason} ->
        refuse(exchange, status, message, reason)
    end
  end

  # Native attach is served in a later task: every other answer that is not
  # nested is refused here, with no Incus mutation.
  defp raw_route(admission, query, deadline) do
    case Routing.route(admission, query, deadline) do
      :nested -> :nested
      {:error, _, _} = error -> error
      _ -> Routing.unavailable(admission.route)
    end
  end

  defp refuse(exchange, status, message, reason) do
    body = Jason.encode!(%{message: message})
    Exchange.commit(exchange, status, reason)
    Exchange.response_bytes(exchange, byte_size(body))
    finish_exchange(exchange)
    {:http, status, [{"content-type", "application/json"}], body}
  end

  defp admit_exchange(exchange, request, admission) do
    Exchange.admit_route(exchange, admission.route, request.path)
    :ok
  end

  defp finish_exchange(exchange) do
    Process.delete(@exchange_key)
    Exchange.finish(exchange, :ended)
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
      {:error, _} -> {:error, 503, "Docker engine is not ready", :engine_unavailable}
    end
  end

  defp exchange_phase(request, admission, backend, protocol, framing, deadline, exchange) do
    case exchange(request, admission, backend, protocol, framing, deadline) do
      {:ok, %{mode: {:raw, _}} = response} ->
        # The engine accepted the upgrade: whatever happens from here, the
        # request was seen.
        Exchange.sent(exchange, :sent)
        Exchange.commit(exchange, response.status)

        {:upgrade, normalized_response(response, protocol, admission.maximum), backend,
         response.buffer}

      {:ok, response} ->
        finish_plain_response(response, backend, exchange)

      {:error, _reason} ->
        upstream_failed(backend, exchange)
    end
  rescue
    _ -> upstream_failed(backend, exchange)
  catch
    _, _ -> upstream_failed(backend, exchange)
  end

  defp upstream_failed(backend, exchange) do
    Stream.close(backend)
    {:http, _, _, body} = failure = upstream_failure()
    Exchange.commit(exchange, 502, :upstream_failed)
    Exchange.response_bytes(exchange, byte_size(body))
    finish_exchange(exchange)
    failure
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
  end

  defp send_body(_, _, :none, _), do: :ok

  defp send_body(stream, body, framing, deadline),
    do: HTTP.send_chunk(stream, body, framing, deadline)

  defp normalized_response(response, protocol, maximum) do
    headers =
      response.headers
      |> HTTP.end_to_end()
      |> Enum.map(fn
        {"api-version", _} -> {"api-version", maximum}
        header -> header
      end)
      |> Kernel.++(connection_headers(protocol))

    %{status: response.status, protocol: protocol, headers: headers}
  end

  defp connection_headers(nil), do: []
  defp connection_headers(protocol), do: [{"connection", "Upgrade"}, {"upgrade", protocol}]

  defp finish_plain_response(response, backend, exchange) do
    case HTTP.collect(response, @max_body) do
      {:ok, body} ->
        headers =
          Enum.reject(HTTP.end_to_end(response.headers), fn {name, _} ->
            name == "content-length"
          end)

        Stream.close(backend)
        Exchange.commit(exchange, response.status)
        Exchange.response_bytes(exchange, byte_size(body))
        finish_exchange(exchange)
        {:http, response.status, headers, body}

      _ ->
        upstream_failed(backend, exchange)
    end
  end

  defp upstream_failure do
    {:http, 502, [{"content-type", "application/json"}],
     Jason.encode!(%{message: "Docker engine connection failed"})}
  end

  defp start_exchange(host, request) do
    Exchange.start(%{
      adapter: :raw,
      host: host,
      method: Map.get(request, :method),
      peer_address: Map.get(request, :peer)
    })
  end

  @doc """
  Relay both streams once the host owns the frontend socket.

  Deliver the response tail to the frontend and the request tail to the
  backend, each exactly once and before later bytes, then relay both
  directions with independent write EOF. Writes no response head and always
  closes both streams.
  """
  @spec run(Stream.t(), Stream.t(), binary(), keyword()) ::
          :ok | {:error, :stream_failed | :deadline}
  def run(frontend, backend, response_tail, options) do
    deadline = Keyword.fetch!(options, :deadline)
    request_tail = Keyword.fetch!(options, :request_tail)

    exchange =
      case Keyword.get(options, :exchange) do
        nil -> Process.get(@exchange_key)
        handle -> handle
      end

    Process.delete(@exchange_key)

    result =
      RawTunnel.run(frontend, backend,
        deadline: deadline,
        request_tail: request_tail,
        response_tail: response_tail,
        exchange: exchange
      )

    case result do
      :ok ->
        Exchange.finish(exchange, :ended)

      {:error, reason} ->
        Exchange.interrupt(exchange, reason)
        Exchange.finish(exchange, :ended)
    end

    case result do
      {:error, :deadline} -> {:error, :deadline}
      {:error, _reason} -> {:error, :stream_failed}
      :ok -> :ok
    end
  end

  @doc """
  Forward a raw-capable request using separate admission and stream deadlines.

  The request contains `:method`, `:path`, `:query`, `:headers` and `:body`
  with optional host peer metadata. Header names are lowercase. The listener
  must parse HTTP/1.1 framing before handing off and authenticate via the
  configured host callback.
  """
  def relay(host, request, %Stream{} = frontend, options) do
    deadline = Keyword.fetch!(options, :deadline)
    request_tail = Keyword.fetch!(options, :request_tail)

    case open(host, request, Keyword.merge(options, deadline: deadline)) do
      {:upgrade, response, backend, tail} ->
        case send_head(frontend, HTTP.raw_head(response), deadline) do
          :ok ->
            result =
              run(frontend, backend, tail,
                deadline: deadline,
                request_tail: request_tail
              )

            {:relayed, result}

          _ ->
            # A failed, raising or exiting head write still closes both
            # streams; the engine already accepted the upgrade.
            close_stream(backend)
            close_stream(frontend)
            exchange = Process.get(@exchange_key)
            Process.delete(@exchange_key)
            Exchange.interrupt(exchange, :caller_closed)
            Exchange.finish(exchange, :ended)
            {:relayed, {:error, :stream_failed}}
        end

      {:http, status, headers, body} ->
        {:http, status, headers, body}
    end
  end

  defp send_head(frontend, head, deadline) do
    Stream.send(frontend, head, deadline)
  catch
    _, _ -> {:error, :caller_closed}
  end

  defp close_stream(stream) do
    Stream.close(stream)
  catch
    _, _ -> :ok
  end
end
