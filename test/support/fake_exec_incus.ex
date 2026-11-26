defmodule Opsmaru.Containers.TestSupport.FakeExecIncus do
  @moduledoc """
  A scripted stand-in for the Incus calls `Transport.ExecBridge` makes. The
  session is a process holding per-channel output queues. Every call is
  reported to the observer, so a test can assert exactly what reached Incus.
  No Incus server, socket or network is used.

  The dialing process selects the session with `use_session/1` before dial.
  """

  use GenServer

  alias Opsmaru.Incus.Error

  @doc "Start a session reporting to `observer`."
  def start(observer, opts \\ []) do
    {:ok, pid} = GenServer.start(__MODULE__, {observer, Map.new(opts)})
    ExUnit.Callbacks.on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  @doc "Make `session` the result of the next exec in this process."
  def use_session(session), do: Process.put({__MODULE__, :session}, session)

  @doc "Make the next exec in this process fail with `reason`."
  def fail_exec(reason), do: Process.put({__MODULE__, :session}, {:error, reason})

  @doc """
  Make the next exec in this process never return. The calling process is
  reported to `session`'s observer as `{:incus, {:exec_stalled, pid}}`.
  """
  def stall_exec(session), do: Process.put({__MODULE__, :session}, {:stall, session})

  @doc "Queue an output item: `{:binary, bytes}` or `:closed`."
  def push(session, channel, item), do: GenServer.call(session, {:push, channel, item})

  @doc "Frame helper output bytes as the helper does."
  def frame(bytes), do: <<0, byte_size(bytes)::32, bytes::binary>>
  def eof_frame, do: <<1, 0::32>>

  # --- ExecBridge.Incus functions ---------------------------------------------

  # The bridge runs the exec in a setup process; the session selected by the
  # dialing process is found through `$callers`.
  def exec(client, instance, request) do
    case selected() do
      {:error, reason} ->
        {:error, reason}

      {:stall, session} ->
        report(session, {:exec_stalled, self()})
        Process.sleep(:infinity)

      session when is_pid(session) ->
        report(session, {:exec, client, instance, request})
        {:ok, session}
    end
  end

  defp selected do
    Enum.find_value([self() | Process.get(:"$callers", [])], fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dictionary} -> List.keyfind(dictionary, {__MODULE__, :session}, 0)
        nil -> nil
      end
    end)
    |> case do
      {_, selected} -> selected
      nil -> nil
    end
  end

  def output(session, channel, timeout) do
    GenServer.call(session, {:output, channel, timeout}, :infinity)
  catch
    :exit, _ -> {:error, %Error{kind: :closed}}
  end

  def input(session, bytes), do: call(session, {:input, bytes}, :input)
  def close_input(session), do: call(session, :close_input, :close_input)
  def ping(session, channel), do: call(session, {:ping, channel}, :ping)
  def completed?(session), do: call(session, :completed?, :completed?)
  def signal(session, signal), do: call(session, {:signal, signal}, :signal)
  def wait(session, timeout), do: call(session, {:wait, timeout}, :wait)
  def close(session), do: call(session, :close, :close)

  defp report(session, event), do: GenServer.call(session, {:report, event})

  defp call(session, event, key) do
    GenServer.call(session, {:call, event, key})
  catch
    :exit, _ -> {:error, %Error{kind: :closed}}
  end

  # --- Server -----------------------------------------------------------------

  @impl GenServer
  def init({observer, opts}) do
    results =
      Map.merge(
        %{
          input: :ok,
          close_input: :ok,
          ping: :ok,
          completed?: {:ok, false},
          signal: :ok,
          wait: {:ok, :done},
          close: :ok
        },
        Map.get(opts, :results, %{})
      )

    stderr = Map.get(opts, :stderr, [:closed])
    queues = %{"1" => :queue.new(), "2" => :queue.from_list(stderr)}
    {:ok, %{observer: observer, results: results, queues: queues, waiters: %{}}}
  end

  @impl GenServer
  def handle_call({:report, event}, _from, state) do
    send(state.observer, {:incus, event})
    {:reply, :ok, state}
  end

  def handle_call({:call, event, key}, _from, state) do
    send(state.observer, {:incus, event})
    {:reply, Map.fetch!(state.results, key), state}
  end

  def handle_call({:push, channel, item}, _from, state) do
    case Map.pop(state.waiters, channel) do
      {{from, timer}, waiters} ->
        Process.cancel_timer(timer)
        GenServer.reply(from, reply(item))
        {:reply, :ok, %{state | waiters: waiters}}

      {nil, _} ->
        queue = Map.get(state.queues, channel, :queue.new())
        {:reply, :ok, put_in(state.queues[channel], :queue.in(item, queue))}
    end
  end

  def handle_call({:output, channel, timeout}, from, state) do
    case :queue.out(Map.get(state.queues, channel, :queue.new())) do
      {{:value, item}, queue} ->
        {:reply, reply(item), put_in(state.queues[channel], queue)}

      {:empty, _} ->
        timer = Process.send_after(self(), {:timeout, channel}, timeout)
        {:noreply, put_in(state.waiters[channel], {from, timer})}
    end
  end

  @impl GenServer
  def handle_info({:timeout, channel}, state) do
    case Map.pop(state.waiters, channel) do
      {{from, _}, waiters} ->
        GenServer.reply(from, {:error, %Error{kind: :deadline}})
        {:noreply, %{state | waiters: waiters}}

      {nil, _} ->
        {:noreply, state}
    end
  end

  defp reply({:binary, bytes}), do: {:ok, {:binary, bytes}}
  defp reply(:closed), do: {:error, %Error{kind: :closed}}
end
