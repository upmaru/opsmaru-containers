defmodule Opsmaru.Containers.Host do
  @moduledoc """
  Host-owned Docker request policy. Both listener adapters call the same policy.

  Implementations perform local admission only. Backend access begins after
  admission. The deadline is shared by context, authorization and bind mapping.
  """

  alias Opsmaru.Containers.Context

  @callback context(request :: map()) :: {:ok, Context.t()} | {:error, term()}
  @callback authorize(Context.t(), classified_request :: map()) :: :allow | :deny
  @callback map_bind_source(Context.t(), String.t()) :: {:ok, String.t()} | :deny

  @doc """
  Chooses the engine for one `POST /containers/create`.

  The request is the classified request with `:route` and the decoded create
  body under `:body`. It runs under the admission deadline. A missing
  callback, a failing or late answer, or any value other than `:native`
  selects `:nested`.
  """
  @callback select_engine(Context.t(), create_request :: map()) :: :nested | :native
  @optional_callbacks map_bind_source: 2, select_engine: 2

  @doc false
  def decide(module, function, args, deadline) do
    if remaining(deadline) > 0 do
      reply_to = Process.alias()

      {pid, monitor} =
        spawn_monitor(fn ->
          result = invoke(module, function, args)
          send(reply_to, {reply_to, result})
        end)

      try do
        receive do
          {^reply_to, result} ->
            if remaining(deadline) > 0, do: {:ok, result}, else: :error

          {:DOWN, ^monitor, :process, ^pid, _} ->
            :error
        after
          remaining(deadline) ->
            :error
        end
      after
        Process.unalias(reply_to)
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])

        receive do
          {^reply_to, _} -> :ok
        after
          0 -> :ok
        end
      end
    else
      :error
    end
  end

  defp invoke(module, function, args) do
    apply(module, function, args)
  rescue
    _ -> :deny
  catch
    _, _ -> :deny
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
