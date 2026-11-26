defmodule Opsmaru.Containers.Acceptance.ExecSocketBridge do
  @moduledoc """
  Acceptance-only dialer for the installed exec socket bridge.

  The host supplies the helper path, engine socket and connected Incus target.
  Framing stays inside the exec stream. The Docker relay receives only peer
  bytes and directional EOF. An optional `:keepalive_interval` in milliseconds
  sends WebSocket pings on stdout, stderr and control during acceptance.
  """

  @behaviour Opsmaru.Containers.Transport
  @behaviour Opsmaru.Containers.Transport.Stream

  alias Opsmaru.Containers.Transport.Stream
  alias Opsmaru.Incus.{Error, Operation, Session, WebSocket}

  @chunk_size 16_384

  @impl Opsmaru.Containers.Transport
  def dial(target, %{helper: helper, socket: socket} = options, deadline) do
    keepalive_interval = options[:keepalive_interval]

    request = %{
      "command" => [helper, socket],
      "interactive" => false,
      "wait-for-websocket" => true,
      "record-output" => false
    }

    with :ok <- validate_keepalive(keepalive_interval),
         {:ok, session} <- Session.exec(target.client, target.instance, request) do
      start_stream(session, options[:observer], keepalive_interval, deadline)
    end
  end

  defp validate_keepalive(nil), do: :ok

  defp validate_keepalive(interval) when is_integer(interval) and interval in 1..3_600_000,
    do: :ok

  defp validate_keepalive(_), do: {:error, :invalid_keepalive_interval}

  defp start_stream(session, observer, keepalive_interval, deadline) do
    {:ok, buffer} = Agent.start_link(fn -> "" end)
    handle = %{session: session, buffer: buffer, observer: observer, keepalive: nil}
    spawn_link(fn -> drain_stderr(handle, deadline) end)

    case take(handle, 4, deadline) do
      {:ok, "OCB1"} ->
        keepalive = start_keepalive(handle, keepalive_interval)
        {:ok, %Stream{adapter: __MODULE__, handle: %{handle | keepalive: keepalive}}}

      failure ->
        close(handle)
        {:error, {:bridge_handshake, failure}}
    end
  end

  defp start_keepalive(_, nil), do: nil

  defp start_keepalive(handle, interval) do
    owner = self()
    channels = Map.take(handle.session.channels, ["1", "2", "control"])

    spawn(fn -> keepalive(Process.monitor(owner), channels, handle, interval) end)
  end

  defp keepalive(owner, channels, handle, interval) do
    receive do
      {:DOWN, ^owner, :process, _, _} -> :ok
    after
      interval ->
        for {name, channel} <- channels do
          case WebSocket.send_frame(channel, {:ping, ""}) do
            :ok -> :ok
            {:error, %Error{kind: kind}} -> notify(handle, {:bridge_keepalive, name, kind})
          end
        end

        keepalive(owner, channels, handle, interval)
    end
  end

  defp drain_stderr(handle, deadline) do
    case output(handle.session, "2", deadline) do
      {:ok, data} ->
        notify(handle, {:helper_stderr, data})
        drain_stderr(handle, deadline)

      _ ->
        :ok
    end
  end

  @impl Stream
  def recv(handle, limit, deadline) when limit > 0 do
    case Agent.get(handle.buffer, & &1) do
      :eof ->
        :eof

      {:remaining, data, rest} ->
        deliver_chunk(handle, data, rest, limit)

      _ ->
        recv_frame(handle, limit, deadline)
    end
  end

  defp recv_frame(handle, limit, deadline) do
    case take(handle, 5, deadline) do
      {:ok, <<0, size::32>>} when size in 1..@chunk_size ->
        with {:ok, data} <- take(handle, size, deadline) do
          rest = Agent.get(handle.buffer, & &1)
          deliver_chunk(handle, data, rest, limit)
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

  defp deliver_chunk(handle, data, rest, limit) when byte_size(data) > limit do
    <<chunk::binary-size(limit), remaining::binary>> = data
    Agent.update(handle.buffer, fn _ -> {:remaining, remaining, rest} end)
    {:ok, chunk}
  end

  defp deliver_chunk(handle, data, rest, _) do
    Agent.update(handle.buffer, fn _ -> rest end)
    {:ok, data}
  end

  defp take(handle, size, deadline) do
    case Agent.get(handle.buffer, & &1) do
      <<data::binary-size(size), rest::binary>> ->
        Agent.update(handle.buffer, fn _ -> rest end)
        {:ok, data}

      prefix ->
        take_more(handle, prefix, size, deadline)
    end
  end

  defp take_more(handle, prefix, size, deadline) do
    with {:ok, chunk} <- output(handle.session, "1", deadline) do
      Agent.update(handle.buffer, fn _ -> prefix <> chunk end)
      take(handle, size, deadline)
    end
  end

  defp output(session, channel, deadline) do
    remaining = deadline - now()

    if remaining > 0 do
      case Session.output(session, channel, min(remaining, 1_000)) do
        {:ok, {:binary, ""}} -> output(session, channel, deadline)
        {:ok, {:binary, data}} -> {:ok, data}
        {:error, %Error{kind: :deadline}} -> output(session, channel, deadline)
        {:error, %Error{kind: kind}} -> {:error, {:exec_channel, kind}}
        _ -> {:error, :missing_bridge_eof}
      end
    else
      {:error, :deadline}
    end
  end

  @impl Stream
  def send(handle, data, deadline), do: send_bytes(handle, IO.iodata_to_binary(data), deadline, 0)

  defp send_bytes(_, "", _, _), do: :ok

  defp send_bytes(handle, data, deadline, sent) do
    size = min(byte_size(data), @chunk_size)
    <<chunk::binary-size(size), rest::binary>> = data

    with true <- now() < deadline,
         :ok <- Session.input(handle.session, chunk) do
      send_bytes(handle, rest, deadline, sent + size)
    else
      false ->
        {:error, :deadline}

      {:error, %Error{kind: kind}} = error ->
        notify(handle, {:bridge_input, kind, sent})
        error
    end
  end

  @impl Stream
  def shutdown_write(handle, deadline) do
    if now() < deadline, do: Session.close_input(handle.session), else: {:error, :deadline}
  end

  @impl Stream
  def close(handle) do
    session = handle.session
    if handle.keepalive, do: Process.exit(handle.keepalive, :kill)

    case Operation.poll(session.operation) do
      {:ok, operation} ->
        unless Operation.completed?(operation) do
          Session.signal(session, 15)
          Operation.wait(session.operation, timeout: 3_000)
        end

      _ ->
        :ok
    end

    Session.close(session)
    Agent.stop(handle.buffer)
  end

  defp notify(%{observer: observer}, event) when is_pid(observer),
    do: Kernel.send(observer, event)

  defp notify(_, _), do: :ok
  defp now, do: System.monotonic_time(:millisecond)
end
