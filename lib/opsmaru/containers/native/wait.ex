defmodule Opsmaru.Containers.Native.Wait do
  @moduledoc false
  # Docker wait for native containers (design decision 13). The library
  # subscribes to the native project's lifecycle events, then reads the
  # instance, so an exit between the two is seen by the read. Each event for
  # the instance, and a periodic re-read, checks the state again.

  alias Opsmaru.Containers.Native.{Container, Lifecycle, RunRecord}

  @reread 1_000
  @settle 2_000
  @running ["Running", "Starting", "Stopping", "Frozen"]
  @not_recorded "native: exit status not recorded"

  defstruct [
    :native,
    :container,
    :condition,
    :channel,
    :target_run,
    :unrecorded_since,
    seen_running: false
  ]

  @doc "Docker's wait conditions. An empty condition is `not-running`."
  def condition(nil), do: {:ok, :not_running}
  def condition(""), do: {:ok, :not_running}
  def condition("not-running"), do: {:ok, :not_running}
  def condition("next-exit"), do: {:ok, :next_exit}
  def condition("removed"), do: {:ok, :removed}
  def condition(other), do: {:error, 400, "invalid condition: #{inspect(other)}"}

  @doc """
  Subscribes, then reads the instance and its run record, and decides which
  run's exit answers the wait. Close the result with `close/1`.
  """
  def begin(context, container, condition, deadline) do
    native = context.target.native

    case native.backend.subscribe(native.client, deadline) do
      {:ok, channel} ->
        waiter = %__MODULE__{
          native: native,
          container: container,
          condition: condition,
          channel: channel
        }

        case observe(waiter, deadline) do
          {:ok, status, record} ->
            {:ok,
             %{
               waiter
               | target_run: target(condition, status, record),
                 seen_running: status in @running
             }}

          error ->
            close(waiter)
            error
        end

      {:error, _} ->
        {:error, 503, "native engine: Incus events are not available"}
    end
  end

  def close(%__MODULE__{native: native, channel: channel}),
    do: native.backend.close_events(channel)

  # `not-running` answers the current run. `next-exit` and `removed` answer
  # the run in progress, or the next one when none is.
  defp target(:not_running, _, _), do: 0
  defp target(_, status, record) when status in @running, do: max(run(record), 1)
  defp target(_, _, record), do: run(record) + 1

  @doc """
  Waits until the condition holds. `cancelled?` is asked between reads: a
  cancelled wait answers nothing and removes nothing. Returns
  `{:ok, body}`, `:cancelled` or a Docker-shaped error.
  """
  def run(waiter, deadline, cancelled?) do
    cond do
      cancelled?.() ->
        :cancelled

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, 504, "native engine: the wait did not finish in time"}

      true ->
        case observe(waiter, deadline) do
          {:ok, status, record} ->
            waiter = %{waiter | seen_running: waiter.seen_running or status in @running}
            check(waiter, status, record, deadline, cancelled?)

          {:error, 404, _} ->
            gone(waiter, deadline, cancelled?)

          error ->
            error
        end
    end
  end

  defp check(waiter, status, record, deadline, cancelled?) do
    if done?(waiter, status, record) do
      body = if stale?(waiter, record), do: not_recorded(), else: body(record, waiter)

      case settled(waiter, body) do
        {:answer, _} -> answer(waiter, body, deadline, cancelled?)
        {:wait, waiter} -> next(waiter, deadline, cancelled?)
      end
    else
      next(%{waiter | unrecorded_since: nil}, deadline, cancelled?)
    end
  end

  defp answer(%{condition: :removed} = waiter, body, deadline, cancelled?),
    do: removed(waiter, body, deadline, cancelled?)

  defp answer(_, body, _, _), do: {:ok, body}

  # While Incus 7.0.1 starts an OCI instance it reports it as stopped, though
  # the shim may already have recorded the new run without an exit. A missing
  # exit status is final only once it has held for `@settle` milliseconds:
  # the start window is shorter, and a forced stop's missing record is
  # permanent.
  defp settled(waiter, body) do
    now = System.monotonic_time(:millisecond)

    cond do
      body != not_recorded() -> {:answer, waiter}
      waiter.unrecorded_since == nil -> {:wait, %{waiter | unrecorded_since: now}}
      now - waiter.unrecorded_since >= @settle -> {:answer, waiter}
      true -> {:wait, waiter}
    end
  end

  defp done?(_, status, _) when status in @running, do: false
  defp done?(%{condition: :not_running}, _, _), do: true
  defp done?(%{seen_running: true}, _, _), do: true
  defp done?(%{target_run: target}, _, record), do: run(record) >= target

  # The instance ran and stopped, but the shim never recorded the run the
  # wait was for: it was killed before it could (decision 7).
  defp stale?(%{condition: :not_running}, _), do: false
  defp stale?(%{target_run: target}, record), do: run(record) < target

  # An auto-remove container is deleted before the answer. Otherwise the wait
  # lasts until someone else removes the container.
  defp removed(%{container: %Container{autoremove: true}} = waiter, body, deadline, cancelled?) do
    if cancelled?.() do
      :cancelled
    else
      with :ok <- Lifecycle.delete(waiter.native, waiter.container, deadline), do: {:ok, body}
    end
  end

  defp removed(waiter, body, deadline, cancelled?) do
    waiter = %{waiter | condition: {:removed_after, body}}
    next(waiter, deadline, cancelled?)
  end

  defp gone(%{condition: {:removed_after, body}}, _, _), do: {:ok, body}

  defp gone(_, _, _),
    do: {:ok, %{"StatusCode" => 0}}

  defp next(%{condition: {:removed_after, _}} = waiter, deadline, cancelled?) do
    await_event(waiter, deadline)

    if cancelled?.() do
      :cancelled
    else
      case Lifecycle.instance_state(waiter.native, waiter.container, deadline) do
        {:error, 404, _} -> gone(waiter, deadline, cancelled?)
        {:ok, _} -> next(waiter, deadline, cancelled?)
        error -> error
      end
    end
  end

  defp next(waiter, deadline, cancelled?) do
    await_event(waiter, deadline)
    run(waiter, deadline, cancelled?)
  end

  # Returns after an event for this instance, the re-read interval, or the
  # deadline, whichever comes first.
  defp await_event(waiter, deadline) do
    until = min(System.monotonic_time(:millisecond) + @reread, deadline)
    await_event(waiter, deadline, until)
  end

  defp await_event(waiter, deadline, until) do
    remaining = max(until - System.monotonic_time(:millisecond), 0)

    with {:ok, event} <- waiter.native.backend.next_event(waiter.channel, remaining),
         false <- ours?(event, waiter.container.instance),
         true <- remaining > 0 do
      await_event(waiter, deadline, until)
    else
      _ -> :ok
    end
  end

  # Only state changes wake the wait. Every file read, including the wait's
  # own run-record reads, emits `instance-file-retrieved`, which would
  # otherwise wake it again at once.
  @actions ~w(instance-started instance-stopped instance-shutdown instance-restarted
              instance-paused instance-resumed instance-deleted instance-renamed)

  defp ours?(%{"metadata" => %{"source" => source, "action" => action}}, instance)
       when is_binary(source) and action in @actions do
    source |> String.split("?", parts: 2) |> hd() |> String.ends_with?("/instances/" <> instance)
  end

  defp ours?(_, _), do: false

  defp observe(waiter, deadline) do
    with {:ok, state} <- Lifecycle.instance_state(waiter.native, waiter.container, deadline),
         {:ok, record} <- Lifecycle.record(waiter.native, waiter.container, deadline) do
      {:ok, state["status"], record}
    end
  end

  defp body(%RunRecord{exit_code: code, error: nil}, _) when is_integer(code),
    do: %{"StatusCode" => code}

  defp body(%RunRecord{exit_code: code, error: error}, _) when is_integer(code),
    do: %{"StatusCode" => code, "Error" => %{"Message" => error}}

  # A stopped instance whose run has no exit record, or whose shim never
  # recorded the run it was started for.
  defp body(%RunRecord{}, _), do: not_recorded()

  defp body(:malformed, _),
    do: %{
      "StatusCode" => 137,
      "Error" => %{"Message" => "native engine: the run record is malformed"}
    }

  defp body(:missing, %{seen_running: true}), do: not_recorded()
  defp body(:missing, _), do: %{"StatusCode" => 0}

  defp not_recorded, do: %{"StatusCode" => 137, "Error" => %{"Message" => @not_recorded}}

  defp run(%RunRecord{run: run}), do: run
  defp run(_), do: 0

  @doc """
  Deletes stopped auto-remove containers whose run finished and that no wait
  removed. A container that was never started is left for its first start.
  """
  def reap(native, containers, deadline) do
    deleted =
      for %Container{autoremove: true, status: "Stopped"} = container <- containers,
          {:ok, %RunRecord{}} <- [RunRecord.read(native, container, deadline)],
          Lifecycle.delete(native, container, deadline) == :ok,
          do: container.id

    {:ok, deleted}
  end
end
