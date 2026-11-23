defmodule Opsmaru.Containers.Acceptance.ExecSocketBridge do
  @moduledoc """
  Acceptance-only dialer for the installed exec socket bridge.

  The host supplies the helper path, engine socket and connected Incus target.
  Framing stays inside the exec stream. The Docker relay receives only peer
  bytes and directional EOF.
  """

  @behaviour Opsmaru.Containers.Transport
  @behaviour Opsmaru.Containers.Transport.Stream

  alias Opsmaru.Containers.Transport.Stream
  alias Opsmaru.Incus.{Error, Operation, Session}

  @chunk_size 16_384

  @impl Opsmaru.Containers.Transport
  def dial(target, %{helper: helper, socket: socket} = options, deadline) do
    request = %{
      "command" => [helper, socket],
      "interactive" => false,
      "wait-for-websocket" => true,
      "record-output" => false
    }

    with {:ok, session} <- Session.exec(target.client, target.instance, request) do
      start_stream(session, options[:observer], deadline)
    end
  end

  defp start_stream(session, observer, deadline) do
    {:ok, buffer} = Agent.start_link(fn -> "" end)
    handle = %{session: session, buffer: buffer, observer: observer}
    spawn_link(fn -> drain_stderr(handle, deadline) end)

    case take(handle, 4, deadline) do
      {:ok, "OCB1"} ->
        {:ok, %Stream{adapter: __MODULE__, handle: handle}}

      failure ->
        close(handle)
        {:error, {:bridge_handshake, failure}}
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
