defmodule Opsmaru.Containers.Docker.RawTunnel do
  @moduledoc """
  Relay two claimed streams after the listener and backend have accepted a
  Docker hijack. The adapters hand over bytes already read by their HTTP
  parsers. The listener supplies the checked upstream handshake exactly once.

  Each pump reports the failure side: `:caller_closed` (the caller's stream
  failed), `:backend_closed` (the backend's stream failed) or `:deadline`
  (the exchange exceeded its deadline). `:ok` is returned when both
  directions end cleanly.

  With an `:exchange`, tunnelled bytes are counted at the frontend: request
  bytes once read from it (including the request tail), response bytes once
  written to it (including the response tail). Heads are never counted.
  """

  alias Opsmaru.Containers.Docker.Exchange
  alias Opsmaru.Containers.Transport.Stream

  @chunk_bytes 65_536

  @spec run(Stream.t(), Stream.t(), keyword()) ::
          :ok | {:error, :caller_closed | :backend_closed | :deadline}
  def run(frontend, backend, opts) do
    deadline = Keyword.fetch!(opts, :deadline)
    request_tail = Keyword.fetch!(opts, :request_tail)
    response_head = Keyword.get(opts, :response_head, "")
    response_tail = Keyword.fetch!(opts, :response_tail)
    exchange = Keyword.get(opts, :exchange)

    upload =
      pump(frontend, backend, request_tail, deadline, {:caller_closed, :backend_closed}, fn
        bytes, _ -> Exchange.request_bytes(exchange, bytes)
      end)

    download =
      pump(
        backend,
        frontend,
        [response_head, response_tail],
        deadline,
        {:backend_closed, :caller_closed},
        fn
          bytes, :tail ->
            Exchange.response_bytes(exchange, bytes - IO.iodata_length(response_head))

          bytes, :data ->
            Exchange.response_bytes(exchange, bytes)
        end
      )

    try do
      wait(%{upload.ref => upload, download.ref => download}, deadline)
    after
      Task.shutdown(upload, :brutal_kill)
      Task.shutdown(download, :brutal_kill)
      close(backend)
      close(frontend)
    end
  end

  # `count` is called with the byte count and `:tail` or `:data`. The
  # upload pump counts what it read from the frontend; the download pump
  # counts what it wrote to the frontend.
  defp pump(source, destination, prefix, deadline, {recv_reason, send_reason}, count) do
    upload? = recv_reason == :caller_closed

    Task.async(fn ->
      try do
        prefix = IO.iodata_to_binary(prefix)
        if upload? and prefix != "", do: count.(byte_size(prefix), :tail)

        if prefix == "" do
          copy(source, destination, deadline, {recv_reason, send_reason}, {count, upload?})
        else
          case guarded(fn -> Stream.send(destination, prefix, deadline) end) do
            :ok ->
              if not upload?, do: count.(byte_size(prefix), :tail)
              copy(source, destination, deadline, {recv_reason, send_reason}, {count, upload?})

            error ->
              failure(error, send_reason, deadline)
          end
        end
      rescue
        _ -> {:error, recv_reason}
      catch
        _, _ -> {:error, recv_reason}
      end
    end)
  end

  defp copy(source, destination, deadline, {recv_reason, _} = reasons, counter) do
    case guarded(fn -> Stream.recv(source, @chunk_bytes, deadline) end) do
      {:ok, data} when is_binary(data) and byte_size(data) in 1..@chunk_bytes ->
        forward(data, source, destination, deadline, reasons, counter)

      :eof ->
        end_write(destination, deadline, reasons)

      error ->
        failure(error, recv_reason, deadline)
    end
  end

  # Request bytes count once read from the frontend; response bytes count
  # once written to it.
  defp forward(data, source, destination, deadline, {_, send_reason} = reasons, counter) do
    {count, upload?} = counter
    if upload?, do: count.(byte_size(data), :data)

    case guarded(fn -> Stream.send(destination, data, deadline) end) do
      :ok ->
        if not upload?, do: count.(byte_size(data), :data)
        copy(source, destination, deadline, reasons, counter)

      error ->
        failure(error, send_reason, deadline)
    end
  end

  defp end_write(destination, deadline, {_, send_reason}) do
    case guarded(fn -> Stream.shutdown_write(destination, deadline) end) do
      :ok -> :ok
      error -> failure(error, send_reason, deadline)
    end
  end

  # An adapter call that raises, exits or throws fails the side it was made
  # on, so a raising write blames the destination, not the source.
  defp guarded(fun) do
    fun.()
  catch
    _, _ -> {:error, :raised}
  end

  # An adapter's own `:deadline`, or a failure once the deadline has passed,
  # is the deadline, not a broken peer.
  defp failure({:error, :deadline}, _side, _deadline), do: {:error, :deadline}

  defp failure(_error, side, deadline) do
    if System.monotonic_time(:millisecond) >= deadline,
      do: {:error, :deadline},
      else: {:error, side}
  end

  defp wait(tasks, _) when map_size(tasks) == 0, do: :ok

  defp wait(tasks, deadline) do
    receive do
      {ref, :ok} when is_map_key(tasks, ref) ->
        Process.demonitor(ref, [:flush])
        wait(Map.delete(tasks, ref), deadline)

      {ref, {:error, reason}} when is_map_key(tasks, ref) ->
        {:error, reason}

      {:DOWN, ref, :process, _, _} when is_map_key(tasks, ref) ->
        {:error, :caller_closed}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        {:error, :deadline}
    end
  end

  defp close(stream) do
    Stream.close(stream)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
