defmodule Opsmaru.Containers.Native.Pipe do
  @moduledoc false
  # A `Transport.Stream` that the native engine serves itself, so the raw
  # adapter relays native attach and attached exec exactly as it relays a
  # nested engine's stream.
  #
  # One process per exchange holds the stream. It monitors the process that
  # opened it, the relay owner, and stops when that owner exits or the
  # stream is closed. A source runs inside it: the source's `start` opens
  # what it needs (an Incus exec session is then owned by this process) and
  # starts linked workers that `push/2` Docker-framed bytes and `finish/2`
  # the output. Client bytes and write EOF go to the source's `input` and
  # `close_input`. A push waits while more than 1 MiB is unread, so a slow
  # client slows the source instead of growing memory.

  use GenServer
  @behaviour Opsmaru.Containers.Transport.Stream

  alias Opsmaru.Containers.Transport.Stream

  @buffer_limit 1_048_576

  @type source :: %{
          required(:start) => (pid() -> {:ok, term()} | {:error, term()}),
          optional(:input) => (term(), binary() -> :ok | {:error, term()}),
          optional(:close_input) => (term() -> :ok | {:error, term()}),
          optional(:control) => (term(), term() -> term()),
          optional(:info) => (term(), term() -> term()),
          optional(:close) => (term() -> term())
        }

  @doc "Starts a pipe for `source`, whose `start` must finish by `deadline`."
  @spec open(source(), integer()) :: {:ok, Stream.t()} | {:error, term()}
  def open(source, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 1)

    case GenServer.start(__MODULE__, {source, self()}, timeout: timeout) do
      {:ok, pid} -> {:ok, %Stream{adapter: __MODULE__, handle: pid}}
      {:error, {:source, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Queues output bytes, waiting while the client is behind."
  def push(pipe, ""), do: pipe && :ok
  def push(pipe, bytes), do: GenServer.call(pipe, {:push, IO.iodata_to_binary(bytes)}, :infinity)

  @doc "Ends the output with `:eof` or `{:error, reason}` once queued bytes are read."
  def finish(pipe, result), do: GenServer.cast(pipe, {:finish, result})

  @doc "Calls the source's `control` function in the pipe, as for a TTY resize."
  def control(pipe, message, timeout \\ 5_000) do
    GenServer.call(pipe, {:control, message}, timeout)
  catch
    :exit, _ -> {:error, :closed}
  end

  # -- Stream --------------------------------------------------------------------

  @impl Stream
  def recv(pipe, limit, deadline), do: call(pipe, {:recv, limit}, deadline)

  @impl Stream
  def send(pipe, bytes, deadline), do: call(pipe, {:send, IO.iodata_to_binary(bytes)}, deadline)

  @impl Stream
  def shutdown_write(pipe, deadline), do: call(pipe, :shutdown_write, deadline)

  @impl Stream
  def close(pipe) do
    GenServer.stop(pipe, :normal, 5_000)
  catch
    :exit, _ -> :ok
  end

  defp call(pipe, request, deadline) do
    GenServer.call(pipe, request, max(deadline - System.monotonic_time(:millisecond), 0))
  catch
    :exit, {:timeout, _} -> {:error, :deadline}
    :exit, _ -> {:error, :closed}
  end

  # -- Server --------------------------------------------------------------------

  @impl GenServer
  def init({source, owner}) do
    monitor = Process.monitor(owner)

    case source.start.(self()) do
      {:ok, state} ->
        {:ok,
         %{
           source: source,
           state: state,
           owner: monitor,
           buffer: :queue.new(),
           size: 0,
           done: nil,
           reader: nil,
           pushers: :queue.new(),
           input_closed: false
         }}

      {:error, reason} ->
        {:stop, {:source, reason}}
    end
  end

  @impl GenServer
  def handle_call({:recv, limit}, from, state) do
    cond do
      state.size > 0 ->
        {bytes, state} = split(state, limit)
        {:reply, {:ok, bytes}, release(state)}

      state.done != nil ->
        {:reply, state.done, state}

      true ->
        {:noreply, %{state | reader: {from, limit}}}
    end
  end

  def handle_call({:push, bytes}, from, state) do
    state =
      deliver(%{
        state
        | buffer: :queue.in(bytes, state.buffer),
          size: state.size + byte_size(bytes)
      })

    if state.size > @buffer_limit,
      do: {:noreply, %{state | pushers: :queue.in(from, state.pushers)}},
      else: {:reply, :ok, state}
  end

  # Input after the source closed it, or after the output ended, is
  # discarded: the client may still be writing when the process exits.
  def handle_call({:send, bytes}, _, state) do
    if state.input_closed or state.done != nil,
      do: {:reply, :ok, state},
      else: {:reply, source(state, :input, [bytes]), state}
  end

  def handle_call(:shutdown_write, _, state) do
    result =
      if state.input_closed or state.done != nil, do: :ok, else: source(state, :close_input, [])

    {:reply, result, %{state | input_closed: true}}
  end

  def handle_call({:control, message}, _, state),
    do: {:reply, source(state, :control, [message]), state}

  @impl GenServer
  def handle_cast({:finish, result}, state), do: {:noreply, deliver(%{state | done: result})}

  @impl GenServer
  def handle_info({:DOWN, monitor, :process, _, _}, %{owner: monitor} = state),
    do: {:stop, :normal, state}

  def handle_info(message, state) do
    case state.source do
      %{info: info} -> {:noreply, %{state | state: info.(state.state, message)}}
      _ -> {:noreply, state}
    end
  end

  @impl GenServer
  def terminate(_, state) do
    case state.source do
      %{close: close} -> close.(state.state)
      _ -> :ok
    end
  end

  # Removes up to `limit` bytes from the head of the buffer.
  defp split(state, limit) do
    {{:value, head}, rest} = :queue.out(state.buffer)

    if byte_size(head) > limit do
      <<bytes::binary-size(limit), remaining::binary>> = head
      {bytes, %{state | buffer: :queue.in_r(remaining, rest), size: state.size - limit}}
    else
      {head, %{state | buffer: rest, size: state.size - byte_size(head)}}
    end
  end

  # Answers a waiting reader.
  defp deliver(%{reader: {from, limit}} = state) do
    cond do
      state.size > 0 ->
        {bytes, state} = split(state, limit)
        GenServer.reply(from, {:ok, bytes})
        release(%{state | reader: nil})

      state.done != nil ->
        GenServer.reply(from, state.done)
        %{state | reader: nil}

      true ->
        state
    end
  end

  defp deliver(state), do: state

  # Lets waiting pushers continue once the buffer is under the limit.
  defp release(state) do
    if state.size <= @buffer_limit do
      Enum.each(:queue.to_list(state.pushers), &GenServer.reply(&1, :ok))
      %{state | pushers: :queue.new()}
    else
      state
    end
  end

  defp source(state, name, args) do
    case Map.fetch(state.source, name) do
      {:ok, fun} -> apply(fun, [state.state | args])
      :error -> :ok
    end
  end
end
