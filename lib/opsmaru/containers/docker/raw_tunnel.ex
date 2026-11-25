defmodule Opsmaru.Containers.Docker.RawTunnel do
  @moduledoc """
  Relay two claimed streams after the listener and backend have accepted a
  Docker hijack. The adapters hand over bytes already read by their HTTP
  parsers. The listener supplies the checked upstream handshake exactly once.
  """

  alias Opsmaru.Containers.Transport.Stream

  @chunk_bytes 65_536

  @spec run(Stream.t(), Stream.t(), keyword()) :: :ok | {:error, :stream_failed | :deadline}
  def run(frontend, backend, opts) do
    deadline = Keyword.fetch!(opts, :deadline)
    request_tail = Keyword.fetch!(opts, :request_tail)
    response_head = Keyword.fetch!(opts, :response_head)
    response_tail = Keyword.fetch!(opts, :response_tail)

    upload = pump(frontend, backend, request_tail, deadline)
    download = pump(backend, frontend, [response_head, response_tail], deadline)

    try do
      wait(%{upload.ref => upload, download.ref => download}, deadline)
    after
      Task.shutdown(upload, :brutal_kill)
      Task.shutdown(download, :brutal_kill)
      close(backend)
      close(frontend)
    end
  end

  defp pump(source, destination, prefix, deadline) do
    Task.async(fn -> transfer(source, destination, prefix, deadline) end)
  end

  defp transfer(source, destination, prefix, deadline) do
    with :ok <- Stream.send(destination, prefix, deadline),
         do: copy(source, destination, deadline)
  rescue
    _ -> {:error, :stream_failed}
  catch
    _, _ -> {:error, :stream_failed}
  end

  defp copy(source, destination, deadline) do
    case Stream.recv(source, @chunk_bytes, deadline) do
      {:ok, data} when is_binary(data) and byte_size(data) in 1..@chunk_bytes ->
        with :ok <- Stream.send(destination, data, deadline),
             do: copy(source, destination, deadline)

      :eof ->
        Stream.shutdown_write(destination, deadline)

      _ ->
        {:error, :stream_failed}
    end
  end

  defp wait(tasks, _) when map_size(tasks) == 0, do: :ok

  defp wait(tasks, deadline) do
    receive do
      {ref, :ok} when is_map_key(tasks, ref) ->
        Process.demonitor(ref, [:flush])
        wait(Map.delete(tasks, ref), deadline)

      {ref, _} when is_map_key(tasks, ref) ->
        {:error, :stream_failed}

      {:DOWN, ref, :process, _, _} when is_map_key(tasks, ref) ->
        {:error, :stream_failed}
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
