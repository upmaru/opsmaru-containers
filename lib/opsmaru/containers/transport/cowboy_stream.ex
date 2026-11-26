if Code.ensure_loaded?(:cowboy_req) do
  defmodule Opsmaru.Containers.Transport.CowboyStream do
    @moduledoc false
    # Adapts a Cowboy `{transport, socket}` pair (`ranch_tcp` or `ranch_ssl`)
    # to `Transport.Stream` for the relay after `CowboyTunnel.takeover/7`.
    #
    # One reader process owns the socket and reads in `active: :once` mode,
    # armed only while a `recv/3` waits, so a slow backend applies
    # backpressure to the client. Active mode is required: OTP surfaces a
    # TLS peer's `close_notify` only as `{:ssl_closed, _}` (a passive recv
    # never reports it), and the transport's closed message is reported as
    # `:eof`. Over TLS, OTP then ends the session: later writes are never
    # delivered, and OTP may still accept some of them. The reader therefore
    # flags a TLS peer close before it reports EOF, and `send/3` refuses to
    # write after it, so the relay reports `:caller_closed` rather than
    # counting bytes the client will never see (design decision 4). Over TCP the
    # socket is switched to `exit_on_close: false`, so a client half-close
    # keeps the write side open.
    #
    # `send/3`, `shutdown_write/2` and `close/1` run in the caller. Cowboy's
    # already-buffered bytes never come through `recv/3`: they travel to
    # `Raw.run/4` as `request_tail`.

    @behaviour Opsmaru.Containers.Transport.Stream

    defstruct [:reader, :monitor, :transport, :socket, :peer_closed]

    @doc false
    def start(transport, socket, owner, deadline) do
      ref = make_ref()
      peer_closed = :atomics.new(1, [])
      reader = spawn(fn -> reader_init(transport, socket, owner, ref, peer_closed) end)

      case transport.controlling_process(socket, reader) do
        :ok ->
          remaining = max(deadline - System.monotonic_time(:millisecond), 1)
          _ = setopts(transport, socket, send_timeout: remaining, send_timeout_close: true)
          _ = setopts(transport, socket, exit_on_close: false)
          monitor = Process.monitor(reader)
          send(reader, {:owned, ref})

          %__MODULE__{
            reader: reader,
            monitor: monitor,
            transport: transport,
            socket: socket,
            peer_closed: peer_closed
          }

        {:error, reason} ->
          Process.exit(reader, :kill)
          raise "CowboyStream cannot transfer the socket: #{inspect(reason)}"
      end
    end

    defp setopts(transport, socket, options) do
      transport.setopts(socket, options)
    catch
      _, _ -> :error
    end

    @impl Opsmaru.Containers.Transport.Stream
    def recv(%__MODULE__{reader: reader, monitor: monitor}, limit, deadline) do
      remaining = deadline - System.monotonic_time(:millisecond)

      if remaining > 0 do
        ref = make_ref()
        send(reader, {:recv, self(), ref, limit, deadline})

        receive do
          {^ref, result} -> result
          {:DOWN, ^monitor, :process, _, _} -> {:error, :closed}
        after
          remaining -> {:error, :deadline}
        end
      else
        {:error, :deadline}
      end
    end

    @impl Opsmaru.Containers.Transport.Stream
    def send(%__MODULE__{transport: transport, socket: socket} = stream, bytes, deadline) do
      cond do
        deadline <= System.monotonic_time(:millisecond) ->
          {:error, :deadline}

        :atomics.get(stream.peer_closed, 1) == 1 ->
          {:error, :closed}

        true ->
          case transport.send(socket, bytes) do
            :ok -> :ok
            {:error, _} -> {:error, :closed}
          end
      end
    end

    # A peer that already ended the connection (TLS `close_notify`, after
    # which OTP closes the session) has nothing left to lose from our EOF.
    @impl Opsmaru.Containers.Transport.Stream
    def shutdown_write(%__MODULE__{} = stream, _deadline) do
      case stream.transport.shutdown(stream.socket, :write) do
        :ok -> :ok
        {:error, _} -> if peer_closed?(stream), do: :ok, else: {:error, :closed}
      end
    end

    defp peer_closed?(%__MODULE__{reader: reader, monitor: monitor}) do
      ref = make_ref()
      send(reader, {:closed?, self(), ref})

      receive do
        {^ref, closed?} -> closed?
        {:DOWN, ^monitor, :process, _, _} -> false
      after
        1_000 -> false
      end
    end

    @impl Opsmaru.Containers.Transport.Stream
    def close(%__MODULE__{reader: reader, monitor: monitor, transport: transport, socket: socket}) do
      send(reader, :stop)

      receive do
        {:DOWN, ^monitor, :process, _, _} -> :ok
      after
        1_000 -> Process.exit(reader, :kill)
      end

      transport.close(socket)
      :ok
    catch
      _, _ -> :ok
    end

    # --- Reader -----------------------------------------------------------------

    defp reader_init(transport, socket, owner, ref, peer_closed) do
      owner_monitor = Process.monitor(owner)

      receive do
        {:owned, ^ref} -> :ok
        {:DOWN, ^owner_monitor, :process, _, _} -> exit(:normal)
      end

      loop(%{
        transport: transport,
        socket: socket,
        owner_monitor: owner_monitor,
        peer_closed: peer_closed,
        buffer: "",
        closed: false,
        error: nil,
        pending: nil,
        armed: false
      })
    end

    defp loop(state) do
      receive do
        {:recv, from, ref, limit, deadline} ->
          loop(recv_request(state, {from, ref, limit, deadline}))

        {:closed?, from, ref} ->
          send(from, {ref, state.closed})
          loop(state)

        {tag, _socket, data} when tag in [:ssl, :tcp] and is_binary(data) ->
          loop(deliver(%{state | armed: false, buffer: state.buffer <> data}))

        {:ssl_closed, _socket} ->
          # Flagged before EOF is reported, so no write ordered after it
          # reaches OTP.
          :atomics.put(state.peer_closed, 1, 1)
          loop(deliver(%{state | armed: false, closed: true}))

        {:tcp_closed, _socket} ->
          loop(deliver(%{state | armed: false, closed: true}))

        {tag, _socket, reason} when tag in [:ssl_error, :tcp_error] ->
          loop(deliver(%{state | armed: false, error: reason}))

        {:DOWN, monitor, :process, _, _} when monitor == state.owner_monitor ->
          exit(:normal)

        :stop ->
          exit(:normal)
      end
    end

    defp recv_request(state, pending) do
      # A recv the caller gave up on is replaced; its late answer is ignored.
      deliver(%{state | pending: pending})
    end

    defp deliver(%{pending: nil} = state), do: state

    defp deliver(%{pending: {from, ref, limit, _deadline}} = state) do
      cond do
        state.buffer != "" ->
          size = min(limit, byte_size(state.buffer))
          <<chunk::binary-size(size), rest::binary>> = state.buffer
          send(from, {ref, {:ok, chunk}})
          %{state | buffer: rest, pending: nil}

        state.error != nil ->
          send(from, {ref, {:error, state.error}})
          %{state | pending: nil}

        state.closed ->
          send(from, {ref, :eof})
          %{state | pending: nil}

        state.armed ->
          state

        true ->
          case state.transport.setopts(state.socket, active: :once) do
            :ok -> %{state | armed: true}
            {:error, reason} -> deliver(%{state | error: reason})
          end
      end
    end
  end
end
