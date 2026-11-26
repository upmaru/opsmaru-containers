defmodule Opsmaru.Containers.Docker.Exchange do
  @moduledoc false
  # One Docker exchange: a `:start` event in the adapter process and exactly
  # one `:stop` event from an unlinked observer that monitors the process
  # owning the exchange.
  #
  # The observer exists before `:start` handlers run, so an owner killed
  # inside a start handler still gets its `:stop`. It emits `:stop` on the
  # first `finish/2` or on the owner's `:DOWN`, whichever arrives first, then
  # exits. Owners may be killed rather than asked to stop (deadlines, caller
  # loss), so code after a relay call is never relied on to report the end.
  #
  # Facts recorded from several processes (byte counts, status, interruption
  # reason, sent outcome) live in one `:atomics` array that the observer reads
  # when it emits. The parsed request is sent once by the owner.
  #
  # Without `:telemetry`, or with no handler attached to the `[:opsmaru_containers, :docker]`
  # prefix, `start/1` returns an inert handle: no process or array exists and
  # every other function is a no-op. Handlers for the events run in the
  # observer, never in a process that holds a backend socket.

  alias Opsmaru.Containers.Telemetry

  @prefix [:opsmaru_containers, :docker]
  @start [:opsmaru_containers, :docker, :exchange, :start]
  @request [:opsmaru_containers, :docker, :request]
  @stop [:opsmaru_containers, :docker, :exchange, :stop]

  @request_bytes 1
  @response_bytes 2
  @status 3
  @reason 4
  @outcome 5
  @committed 6

  @methods ~w(GET HEAD POST PUT DELETE)
  @modes [:http, :docker_stream, :h2c_upgrade, :websocket]
  @outcomes [:not_sent, :uncertain, :sent]
  @reasons [
    :invalid_request,
    :not_found,
    :denied,
    :unsupported,
    :version,
    :not_ready,
    :too_large,
    :engine_unavailable,
    :upstream_failed,
    :caller_closed,
    :backend_closed,
    :deadline,
    :handoff_timeout,
    :killed
  ]

  defstruct [:observer, :facts, metadata: nil]

  @type t :: %__MODULE__{observer: pid() | nil, facts: :atomics.atomics_ref() | nil}

  @doc false
  def inert, do: %__MODULE__{}

  @doc false
  def active?(%__MODULE__{observer: observer}), do: is_pid(observer)

  @doc false
  def reason_set, do: @reasons

  @doc false
  def outcomes, do: @outcomes

  # The start event records the facts known before admission: the adapter,
  # host policy module, method and peer address/port/certificate. Anything
  # the request will later decide (mode, route, path, api_version) is nil
  # here and merged in by `admit/2` once admission accepts the target.
  @doc false
  def start(fields) do
    if Telemetry.list_handlers(@prefix) == [] do
      inert()
    else
      begin(fields)
    end
  end

  defp begin(fields) do
    method = Map.get(fields, :method)

    metadata = %{
      telemetry_span_context: make_ref(),
      adapter: Map.get(fields, :adapter),
      host: Map.get(fields, :host),
      mode: nil,
      method: if(method in @methods, do: method),
      route: nil,
      path: nil,
      api_version: nil,
      peer_address: peer_address(Map.get(fields, :peer_address)),
      peer_port: peer_port(Map.get(fields, :peer_port)),
      peer_fingerprint: fingerprint(Map.get(fields, :certificate)),
      status: nil,
      outcome: nil,
      reason: nil
    }

    started = System.monotonic_time()
    facts = :atomics.new(6, signed: false)
    owner = self()
    observer = spawn(fn -> observe(owner, facts, metadata, started) end)

    Telemetry.execute(
      @start,
      %{system_time: System.system_time(), monotonic_time: started},
      metadata
    )

    %__MODULE__{observer: observer, facts: facts, metadata: metadata}
  end

  # Only an IP address tuple and a port number are reported; any other peer
  # term may carry host-private data.
  defp peer_address({a, b, c, d} = address)
       when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255,
       do: address

  defp peer_address({_, _, _, _, _, _, _, _} = address) do
    if Enum.all?(Tuple.to_list(address), &(is_integer(&1) and &1 in 0..65_535)),
      do: address
  end

  defp peer_address(_), do: nil

  defp peer_port(port) when is_integer(port) and port in 0..65_535, do: port
  defp peer_port(_), do: nil

  defp fingerprint(der) when is_binary(der),
    do: :crypto.hash(:sha256, der) |> Base.encode16(case: :lower)

  defp fingerprint(_), do: nil

  # Record the facts for a target admission accepted: the mode and template
  # path, the original encoded path (bounded) and the requested API version.
  @doc false
  def admit(nil, _), do: nil
  def admit(%__MODULE__{observer: nil} = exchange, _), do: exchange

  def admit(%__MODULE__{observer: observer} = exchange, facts) do
    mode = Map.get(facts, :mode)
    route = Map.get(facts, :route)
    path = Map.get(facts, :path)
    api_version = Map.get(facts, :api_version)

    facts = %{
      mode: if(mode in @modes, do: mode),
      route: if(is_binary(route) and byte_size(route) <= 1024, do: route),
      path: if(is_binary(path), do: bounded_path(path)),
      api_version: if(is_binary(api_version) and byte_size(api_version) <= 11, do: api_version)
    }

    send(observer, {:facts, facts})
    exchange
  end

  # Record an admitted route: its mode from the takeover, its template, the
  # accepted path and the `X.Y` version the path requests.
  @doc false
  def admit_route(exchange, route, path) do
    mode =
      case route["takeover"] do
        "docker_stream" -> :docker_stream
        "h2c_upgrade" -> :h2c_upgrade
        "websocket" -> :websocket
        _ -> :http
      end

    version =
      case Regex.run(~r/^\/v(\d+\.\d+)/, path) do
        [_, version] -> version
        _ -> nil
      end

    admit(exchange, %{mode: mode, route: route["path"], path: path, api_version: version})
  end

  # What the engine may have seen once a request is dialed: reads are
  # treated as seen, anything else as uncertain.
  @doc false
  def dialed_outcome(method) when method in ["GET", "HEAD"], do: :sent
  def dialed_outcome(_method), do: :uncertain

  # The reason for a Docker-shaped refusal from admission or body checks.
  @doc false
  def refusal_reason(400, message) do
    if String.contains?(message, "version"), do: :version, else: :invalid_request
  end

  def refusal_reason(413, _), do: :too_large
  def refusal_reason(403, _), do: :denied
  def refusal_reason(404, _), do: :not_found
  def refusal_reason(501, _), do: :unsupported
  def refusal_reason(503, _), do: :not_ready
  def refusal_reason(_, _), do: :invalid_request

  defp bounded_path(path) do
    if byte_size(path) > 8_192, do: binary_part(path, 0, 8_192), else: path
  end

  # Record the response head (or the refusal): status, optional reason and a
  # one-shot request event. At most one is emitted.
  @doc false
  def commit(handle, status, reason \\ nil)

  def commit(nil, _status, _reason), do: nil

  def commit(%__MODULE__{observer: nil} = exchange, _status, _reason), do: exchange

  def commit(%__MODULE__{observer: observer} = exchange, status, reason)
      when is_integer(status) and status in 100..999 do
    send(observer, {:commit, status, reason})
    exchange
  end

  def commit(exchange, _, _), do: exchange

  # Record what the engine may have seen once the upstream request is sent.
  @doc false
  def sent(nil, _outcome), do: nil

  def sent(%__MODULE__{observer: nil} = exchange, _), do: exchange

  def sent(%__MODULE__{facts: facts} = exchange, outcome) when outcome in @outcomes do
    :atomics.put(facts, @outcome, index(@outcomes, outcome))
    exchange
  end

  def sent(exchange, _outcome), do: exchange

  # Record why the exchange is being interrupted. The first recorded reason
  # wins.
  @doc false
  def interrupt(nil, _reason), do: nil

  def interrupt(%__MODULE__{observer: nil} = exchange, _), do: exchange

  def interrupt(%__MODULE__{facts: facts} = exchange, reason) when reason in @reasons do
    record_reason(facts, reason)
    exchange
  end

  def interrupt(exchange, _reason), do: exchange

  @doc false
  def request_bytes(nil, _bytes), do: nil

  def request_bytes(%__MODULE__{observer: nil} = exchange, _), do: exchange

  def request_bytes(%__MODULE__{facts: facts} = exchange, bytes)
      when is_integer(bytes) and bytes > 0 do
    :atomics.add(facts, @request_bytes, bytes)
    exchange
  end

  def request_bytes(exchange, _bytes), do: exchange

  @doc false
  def response_bytes(nil, _bytes), do: nil

  def response_bytes(%__MODULE__{observer: nil} = exchange, _), do: exchange

  def response_bytes(%__MODULE__{facts: facts} = exchange, bytes)
      when is_integer(bytes) and bytes > 0 do
    :atomics.add(facts, @response_bytes, bytes)
    exchange
  end

  def response_bytes(exchange, _bytes), do: exchange

  # End the exchange. `:ended` reports `outcome: :ok`, or the recorded
  # interruption if there is one. Only the first finish (or the owner's exit)
  # is reported.
  @doc false
  def finish(handle, declaration \\ :ended)

  def finish(nil, _declaration), do: nil

  def finish(%__MODULE__{observer: nil} = exchange, _), do: exchange

  def finish(%__MODULE__{observer: observer} = exchange, declaration)
      when declaration == :ended do
    send(observer, {:finish, declaration})
    exchange
  end

  # Move ownership to `owner`. Must be called by the current owner, so the
  # transfer is observed before that owner's own exit.
  @doc false
  def transfer(nil, _), do: nil
  def transfer(%__MODULE__{observer: nil} = exchange, _), do: exchange

  def transfer(%__MODULE__{observer: observer} = exchange, owner) when is_pid(owner) do
    send(observer, {:transfer, owner})
    exchange
  end

  def transfer(exchange, _owner), do: exchange

  defp record_reason(facts, reason) when reason in @reasons do
    :atomics.compare_exchange(facts, @reason, 0, index(@reasons, reason))
  end

  defp record_reason(_facts, _reason), do: :ok

  defp observe(owner, facts, metadata, started) do
    monitor = Process.monitor(owner)
    loop(owner, monitor, facts, metadata, started)
  end

  defp loop(owner, monitor, facts, metadata, started) do
    receive do
      {:facts, new_facts} ->
        loop(owner, monitor, facts, Map.merge(metadata, new_facts), started)

      {:commit, status, reason} ->
        if :atomics.get(facts, @committed) == 0 do
          :atomics.put(facts, @committed, 1)
          :atomics.put(facts, @status, status)
          if reason, do: record_reason(facts, reason)

          Telemetry.execute(
            @request,
            %{duration: System.monotonic_time() - started},
            Map.merge(metadata, %{status: status})
          )
        end

        loop(owner, monitor, facts, metadata, started)

      {:transfer, next} ->
        Process.demonitor(monitor, [:flush])
        loop(next, Process.monitor(next), facts, metadata, started)

      {:finish, declaration} ->
        emit(facts, drain(metadata), started, declaration)

      {:DOWN, ^monitor, :process, ^owner, _} ->
        emit(facts, drain(metadata), started, :down)
    end
  end

  # A fact sent just before the end is still reported.
  defp drain(metadata) do
    receive do
      {:facts, new_facts} -> drain(Map.merge(metadata, new_facts))
    after
      0 -> metadata
    end
  end

  defp emit(facts, metadata, started, declaration) do
    stop(facts, metadata, started, declaration)
  end

  defp stop(facts, metadata, started, declaration) do
    recorded_reason = value(@reasons, :atomics.get(facts, @reason))
    outcome_record = value(@outcomes, :atomics.get(facts, @outcome))
    status = nonzero(:atomics.get(facts, @status))

    {outcome, reason, status} =
      case declaration do
        :ended when is_nil(recorded_reason) -> {:ok, nil, status}
        :ended -> {outcome_record || :not_sent, recorded_reason, status}
        :down -> {outcome_record || :not_sent, recorded_reason || :killed, status}
      end

    metadata =
      Map.merge(metadata, %{
        status: status,
        outcome: outcome,
        reason: reason
      })

    Telemetry.execute(
      @stop,
      %{
        duration: System.monotonic_time() - started,
        request_bytes: :atomics.get(facts, @request_bytes),
        response_bytes: :atomics.get(facts, @response_bytes)
      },
      metadata
    )
  end

  defp index(values, value), do: Enum.find_index(values, &(&1 == value)) + 1
  defp value(_, 0), do: nil
  defp value(values, index), do: Enum.at(values, index - 1)
  defp nonzero(0), do: nil
  defp nonzero(value), do: value
end
