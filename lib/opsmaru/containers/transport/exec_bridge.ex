defmodule Opsmaru.Containers.Transport.ExecBridge do
  @moduledoc """
  An explicit opt-in transport that reaches dockerd through a non-interactive
  Incus exec of the packaged bridge helper, on the host-supplied Incus
  connection in the context's target.

  The library never selects it: a host chooses it by returning
  `dialer: {Opsmaru.Containers.Transport.ExecBridge, options}` in its
  `Opsmaru.Containers.Context`. Build the helper from `priv/exec_bridge`
  (see its README) and install it in the engine image.

  ## Options

  A map or keyword list, validated at dial time before any exec is created.
  Invalid options return `{:error, :invalid_options}`. Like any dial failure,
  the request then gets Docker's 503 "Docker engine is not ready".

    * `:helper` (required) - absolute guest path of the installed helper.
    * `:socket` (required) - absolute guest path of dockerd's Unix socket.
    * `:request_context` - an `Opsmaru.Incus.RequestContext` bound to the exec
      session. Its owner must outlive the stream, and its timeout (at most one
      hour) bounds the stream. When omitted, the target's client is used as
      the host supplied it, and the relay's stream deadline bounds the stream.
      A context built inside `Host.context/1` is owned by that callback's
      short-lived process, so do not pass one from there.
    * `:limits` - `max_input_bytes` and `max_output_bytes` per connection,
      each capped by the Incus connection's `max_stream_bytes` (the default).
      Exceeding a limit fails the stream with `{:error, :input_limit}` or
      `{:error, :output_limit}`; bytes are never truncated.
    * `:keepalive_interval` - `nil` (default) or 1 to 3,600,000 ms between
      WebSocket pings on the stdout, stderr and control channels. These are
      control frames on the client-to-gateway hop.
    * `:observer` - an optional local PID for diagnostic events: helper
      stderr, keepalive failures and channel failures. It never receives
      payload bytes.

  ## Helper protocol

  Stdin carries raw bytes to the Unix peer, and closing stdin half-closes
  the peer. Stdout starts with `OCB1`, followed by frames of a one-byte type
  and a four-byte big-endian length. Type 0 carries 1 to 16,384 data bytes.
  Type 1 has length 0 and ends output only. Anything else is a stream error.
  The relay sees only peer bytes and directional EOF.

  Creating the exec session and opening its channels ends by the dial
  deadline. A setup that misses it is abandoned with
  `{:error, {:exec, :deadline}}` and any channels it opened are closed. An
  exec Incus already accepted is neither deleted nor retried.

  Closing a stream signals an incomplete helper with SIGTERM, waits up to
  three seconds and closes the session channels. It never sends an Incus
  DELETE and never retries.

  ## Qualified scope

  The bridge qualified on 2026-11-25 with Incus 7.0.1, opsmaru_incus 0.2.10,
  Docker Engine 29.10.0 and arm64 (`docs/docker-live-acceptance.md`, "Exec
  qualification rerun on opsmaru_incus 0.2.10"). That run used the
  acceptance copy of this dialer. The packaged module is covered by
  scripted-session fixtures only. An intermittent stdin
  WebSocket write stall observed on earlier stacks remains open. Treat a
  stalled upload as a failed, possibly partially applied mutation: the relay
  returns a Docker-shaped 502 and never replays it.
  """

  @behaviour Opsmaru.Containers.Transport
  @behaviour Opsmaru.Containers.Transport.Stream

  alias Opsmaru.Containers.Transport.Stream
  alias Opsmaru.Incus.{Error, RequestContext}

  @header "OCB1"
  @frame_bytes 16_384
  @max_keepalive 3_600_000
  @terminate_wait 3_000
  @keys [:helper, :socket, :request_context, :limits, :keepalive_interval, :observer, :incus]
  @limit_keys [:max_input_bytes, :max_output_bytes]

  @impl Opsmaru.Containers.Transport
  def dial(target, options, deadline) do
    with {:ok, opts} <- validate(target, options) do
      request = %{
        "command" => [opts.helper, opts.socket],
        "interactive" => false,
        "wait-for-websocket" => true,
        "record-output" => false
      }

      case exec(opts, target.instance, request, deadline) do
        {:ok, session, holder} -> start_stream(session, holder, opts, deadline)
        {:error, _} = error -> error
      end
    end
  end

  # --- Session setup ----------------------------------------------------------

  # Creating the exec and opening its channels is bounded by the connection's
  # own timeouts, which may outlast the dial deadline. Run it in a holder
  # process and wait no longer than the deadline. The holder creates the
  # channels, so it owns them: it lives until `close/1` releases it or the
  # dialing process exits. A separate unlinked watcher monitors the dialing
  # process from outside the blocking exec call, so a dialing process that
  # exits while the exec is still running kills the holder and with it any
  # channels it opened. A setup that misses the deadline is killed, which
  # closes any channels it opened. An exec Incus already accepted is neither
  # deleted nor retried.
  defp exec(opts, instance, request, deadline) do
    caller = self()
    ref = make_ref()
    callers = [caller | Process.get(:"$callers", [])]

    holder =
      spawn(fn ->
        Process.put(:"$callers", callers)
        result = guard(fn -> opts.incus.exec(opts.client, instance, request) end)
        Kernel.send(caller, {ref, result})

        # A failed setup must not linger: only a successful session is held.
        case result do
          {:ok, _session} -> hold(ref)
          _ -> :ok
        end
      end)

    spawn(fn -> watch_caller(caller, holder, callers) end)

    monitor = Process.monitor(holder)

    receive do
      {^ref, {:ok, session}} ->
        Process.demonitor(monitor, [:flush])
        {:ok, session, {holder, ref}}

      {^ref, {:error, reason}} ->
        Process.demonitor(monitor, [:flush])
        {:error, {:exec, reason}}

      {^ref, other} ->
        Process.demonitor(monitor, [:flush])
        {:error, {:exec, other}}

      {:DOWN, ^monitor, :process, ^holder, reason} ->
        {:error, {:exec, reason}}
    after
      max(deadline - now(), 0) ->
        Process.exit(holder, :kill)
        Process.demonitor(monitor, [:flush])

        receive do
          {^ref, _} -> :ok
        after
          0 -> :ok
        end

        {:error, {:exec, :deadline}}
    end
  end

  # Kills the holder (and with it any channels it opened) as soon as the
  # dialing process exits, whatever the holder is doing. Exits when the
  # holder dies on its own, which is how close/1 releases it.
  defp watch_caller(caller, holder, callers) do
    Process.put(:"$callers", callers)
    caller_ref = Process.monitor(caller)
    holder_ref = Process.monitor(holder)

    receive do
      {:DOWN, ^caller_ref, :process, _, _} -> Process.exit(holder, :kill)
      {:DOWN, ^holder_ref, :process, _, _} -> :ok
    end
  end

  defp hold(ref) do
    receive do
      {^ref, :release} -> :ok
      _ -> hold(ref)
    end
  end

  defp release(%{holder: {pid, ref}}), do: Kernel.send(pid, {ref, :release})
  defp release(_), do: :ok

  # --- Options ----------------------------------------------------------------

  defp validate(target, options) when is_list(options) do
    if Keyword.keyword?(options) and unique_keys?(options),
      do: validate(target, Map.new(options)),
      else: {:error, :invalid_options}
  end

  defp validate(target, options) when is_map(options) do
    with true <- Map.keys(options) -- @keys == [],
         {:ok, cap} <- stream_cap(target),
         {:ok, helper} <- absolute(options[:helper]),
         {:ok, socket} <- absolute(options[:socket]),
         {:ok, client} <- client(target.client, options[:request_context]),
         {:ok, limits} <- limits(Map.get(options, :limits, %{}), cap),
         {:ok, keepalive} <- keepalive(options[:keepalive_interval]),
         {:ok, observer} <- observer(options[:observer]),
         {:ok, incus} <- incus(Map.get(options, :incus, __MODULE__.Incus)) do
      {:ok,
       %{
         helper: helper,
         socket: socket,
         client: client,
         limits: limits,
         keepalive: keepalive,
         observer: observer,
         incus: incus
       }}
    else
      _ -> {:error, :invalid_options}
    end
  end

  defp validate(_, _), do: {:error, :invalid_options}

  defp unique_keys?(options),
    do: length(options) == length(Enum.uniq(Keyword.keys(options)))

  defp stream_cap(%{client: %{connection: %{max_stream_bytes: cap}}})
       when is_integer(cap) and cap > 0,
       do: {:ok, cap}

  defp stream_cap(_), do: :error

  defp absolute(path) when is_binary(path) do
    if Path.type(path) == :absolute and not String.contains?(path, <<0>>),
      do: {:ok, path},
      else: :error
  end

  defp absolute(_), do: :error

  # Without a request context the client is used exactly as the host supplied it.
  defp client(client, nil), do: {:ok, client}

  defp client(client, %RequestContext{} = context) do
    {:ok, Opsmaru.Incus.with_context(client, context)}
  rescue
    ArgumentError -> :error
  end

  defp client(_, _), do: :error

  defp limits(limits, cap) when is_list(limits) do
    if Keyword.keyword?(limits) and unique_keys?(limits),
      do: limits(Map.new(limits), cap),
      else: :error
  end

  defp limits(limits, cap) when is_map(limits) do
    if Map.keys(limits) -- @limit_keys == [] do
      with {:ok, input} <- limit(Map.get(limits, :max_input_bytes, cap), cap),
           {:ok, output} <- limit(Map.get(limits, :max_output_bytes, cap), cap) do
        {:ok, %{input: input, output: output}}
      end
    else
      :error
    end
  end

  defp limits(_, _), do: :error

  defp limit(value, cap) when is_integer(value) and value > 0, do: {:ok, min(value, cap)}
  defp limit(_, _), do: :error

  defp keepalive(nil), do: {:ok, nil}

  defp keepalive(interval) when is_integer(interval) and interval in 1..@max_keepalive,
    do: {:ok, interval}

  defp keepalive(_), do: :error

  defp observer(nil), do: {:ok, nil}
  defp observer(pid) when is_pid(pid) and node(pid) == node(), do: {:ok, pid}
  defp observer(_), do: :error

  defp incus(module) when is_atom(module) and not is_nil(module), do: {:ok, module}
  defp incus(_), do: :error

  # --- Setup ------------------------------------------------------------------

  defp start_stream(session, holder, opts, deadline) do
    {:ok, buffer} = Agent.start_link(fn -> "" end)

    handle = %{
      session: session,
      incus: opts.incus,
      buffer: buffer,
      observer: opts.observer,
      limits: opts.limits,
      counters: :atomics.new(2, signed: false),
      keepalive: nil,
      stderr: nil,
      holder: holder
    }

    # Stderr is drained for the life of the session, not until the dial
    # deadline: a host may dial with a deadline far shorter than the stream
    # (`Docker.CowboyHandler` passes its open deadline). The drain ends when
    # channel 2 ends or fails, when `close/1` stops it, or within a second of
    # the dialing process's exit. It is not linked, so stopping it from any
    # process never takes the stream's owner down with it.
    owner = self()
    handle = %{handle | stderr: spawn(fn -> drain_stderr(handle, owner) end)}

    case take(handle, byte_size(@header), deadline) do
      {:ok, @header} ->
        keepalive = start_keepalive(handle, opts.keepalive)
        {:ok, %Stream{adapter: __MODULE__, handle: %{handle | keepalive: keepalive}}}

      failure ->
        close(handle)
        {:error, {:bridge_handshake, failure}}
    end
  end

  defp start_keepalive(_, nil), do: nil

  defp start_keepalive(handle, interval) do
    owner = self()
    spawn(fn -> keepalive_loop(Process.monitor(owner), handle, interval) end)
  end

  defp keepalive_loop(owner, handle, interval) do
    receive do
      {:DOWN, ^owner, :process, _, _} -> :ok
    after
      interval ->
        for channel <- ["1", "2", "control"] do
          case handle.incus.ping(handle.session, channel) do
            :ok -> :ok
            {:error, %Error{kind: kind}} -> notify(handle, {:bridge_keepalive, channel, kind})
            {:error, reason} -> notify(handle, {:bridge_keepalive, channel, reason})
          end
        end

        keepalive_loop(owner, handle, interval)
    end
  end

  defp drain_stderr(handle, owner) do
    result =
      if Process.alive?(owner),
        do: guard(fn -> handle.incus.output(handle.session, "2", 1_000) end),
        else: :owner_down

    case result do
      {:ok, {:binary, ""}} ->
        drain_stderr(handle, owner)

      {:ok, {:binary, data}} ->
        notify(handle, {:helper_stderr, data})
        drain_stderr(handle, owner)

      {:error, %Error{kind: :deadline}} ->
        drain_stderr(handle, owner)

      _ ->
        :ok
    end
  end

  # --- Stream -----------------------------------------------------------------

  @impl Stream
  def recv(handle, limit, deadline) when is_integer(limit) and limit > 0 do
    case Agent.get(handle.buffer, & &1) do
      :eof -> :eof
      {:remaining, data, rest} -> deliver(handle, data, rest, limit)
      _ -> recv_frame(handle, limit, deadline)
    end
  end

  defp recv_frame(handle, limit, deadline) do
    case take(handle, 5, deadline) do
      {:ok, <<0, size::32>>} when size in 1..@frame_bytes ->
        with :ok <- count(handle, 2, size, handle.limits.output, :output_limit),
             {:ok, data} <- take(handle, size, deadline) do
          deliver(handle, data, Agent.get(handle.buffer, & &1), limit)
        end

      {:ok, <<1, 0::32>>} ->
        Agent.update(handle.buffer, fn _ -> :eof end)
        :eof

      {:ok, _} ->
        {:error, :invalid_bridge_frame}

      failure ->
        notify(handle, {:bridge_output, failure})
        failure
    end
  end

  defp deliver(handle, data, rest, limit) when byte_size(data) > limit do
    <<chunk::binary-size(limit), remaining::binary>> = data
    Agent.update(handle.buffer, fn _ -> {:remaining, remaining, rest} end)
    {:ok, chunk}
  end

  defp deliver(handle, data, rest, _) do
    Agent.update(handle.buffer, fn _ -> rest end)
    {:ok, data}
  end

  defp take(handle, size, deadline) do
    case Agent.get(handle.buffer, & &1) do
      <<data::binary-size(size), rest::binary>> ->
        Agent.update(handle.buffer, fn _ -> rest end)
        {:ok, data}

      prefix when is_binary(prefix) ->
        fill(handle, prefix, size, deadline)

      _ ->
        {:error, :invalid_bridge_frame}
    end
  end

  defp fill(handle, prefix, size, deadline) do
    with {:ok, chunk} <- output(handle, "1", deadline) do
      Agent.update(handle.buffer, fn _ -> prefix <> chunk end)
      take(handle, size, deadline)
    end
  end

  defp output(handle, channel, deadline) do
    remaining = deadline - now()

    if remaining > 0 do
      case handle.incus.output(handle.session, channel, min(remaining, 1_000)) do
        {:ok, {:binary, ""}} -> output(handle, channel, deadline)
        {:ok, {:binary, data}} -> {:ok, data}
        {:error, %Error{kind: :deadline}} -> output(handle, channel, deadline)
        {:error, %Error{kind: kind}} -> {:error, {:exec_channel, kind}}
        _ -> {:error, :missing_bridge_eof}
      end
    else
      {:error, :deadline}
    end
  end

  @impl Stream
  def send(handle, data, deadline) do
    bytes = IO.iodata_to_binary(data)

    with :ok <- count(handle, 1, byte_size(bytes), handle.limits.input, :input_limit) do
      send_bytes(handle, bytes, deadline, 0)
    end
  end

  defp send_bytes(_, "", _, _), do: :ok

  defp send_bytes(handle, data, deadline, sent) do
    size = min(byte_size(data), @frame_bytes)
    <<chunk::binary-size(size), rest::binary>> = data

    with true <- now() < deadline,
         :ok <- handle.incus.input(handle.session, chunk) do
      send_bytes(handle, rest, deadline, sent + size)
    else
      false ->
        {:error, :deadline}

      {:error, %Error{kind: kind}} = error ->
        notify(handle, {:bridge_input, kind, sent})
        error

      {:error, _} = error ->
        error
    end
  end

  # Reserve `size` bytes against a per-connection limit before moving them,
  # so a limit fails visibly rather than truncating.
  defp count(_handle, _index, 0, _limit, _error), do: :ok

  defp count(handle, index, size, limit, error) do
    if :atomics.add_get(handle.counters, index, size) > limit,
      do: {:error, error},
      else: :ok
  end

  @impl Stream
  def shutdown_write(handle, deadline) do
    if now() < deadline,
      do: handle.incus.close_input(handle.session),
      else: {:error, :deadline}
  end

  @impl Stream
  def close(handle) do
    if handle.keepalive, do: Process.exit(handle.keepalive, :kill)
    stop_stderr(handle.stderr)
    %{incus: incus, session: session} = handle

    # Signal only a helper that is still running, wait a bounded time, then
    # close the session channels. Never an Incus DELETE, never a retry.
    if guard(fn -> incus.completed?(session) end) == {:ok, false} do
      guard(fn -> incus.signal(session, 15) end)
      guard(fn -> incus.wait(session, @terminate_wait) end)
    end

    guard(fn -> incus.close(session) end)
    release(handle)
    guard(fn -> Agent.stop(handle.buffer) end)
    :ok
  end

  defp stop_stderr(pid) when is_pid(pid), do: Process.exit(pid, :kill)

  defp stop_stderr(_), do: :ok

  defp guard(fun) do
    fun.()
  catch
    _, _ -> :error
  end

  defp notify(%{observer: observer}, event) when is_pid(observer),
    do: Kernel.send(observer, event)

  defp notify(_, _), do: :ok

  defp now, do: System.monotonic_time(:millisecond)

  defmodule Incus do
    @moduledoc false
    # The Incus calls the bridge makes, all through opsmaru_incus. Tests
    # substitute a scripted module with the same functions.

    alias Opsmaru.Incus.{Operation, Session, WebSocket}

    def exec(client, instance, request), do: Session.exec(client, instance, request)
    def output(session, channel, timeout), do: Session.output(session, channel, timeout)
    def input(session, bytes), do: Session.input(session, bytes)
    def close_input(session), do: Session.close_input(session)

    def ping(session, channel) do
      case Map.fetch(session.channels, channel) do
        {:ok, socket} -> WebSocket.send_frame(socket, {:ping, ""})
        :error -> :ok
      end
    end

    def completed?(session) do
      with {:ok, operation} <- Operation.poll(session.operation),
           do: {:ok, Operation.completed?(operation)}
    end

    def signal(session, signal), do: Session.signal(session, signal)
    def wait(session, timeout), do: Operation.wait(session.operation, timeout: timeout)
    def close(session), do: Session.close(session)
  end
end
