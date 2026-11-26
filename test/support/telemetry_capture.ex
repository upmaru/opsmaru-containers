defmodule Opsmaru.Containers.TestSupport.TelemetryCapture do
  @moduledoc """
  Attach a capturing handler for the Docker events. Each event arrives in the
  test mailbox as `{:docker_event, event, measurements, metadata}`. Handlers
  are VM-global, so suites using this run with `async: false`.
  """

  @events [
    [:opsmaru_containers, :docker, :exchange, :start],
    [:opsmaru_containers, :docker, :request],
    [:opsmaru_containers, :docker, :exchange, :stop]
  ]

  def events, do: @events

  def attach(id \\ make_ref()) do
    :ok = :telemetry.attach_many({__MODULE__, id}, @events, &__MODULE__.handle/4, self())
    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach({__MODULE__, id}) end)
    {__MODULE__, id}
  end

  def detach(id), do: :telemetry.detach(id)

  @doc false
  def handle(event, measurements, metadata, test),
    do: send(test, {:docker_event, event, measurements, metadata})

  @doc "Wait for one start, at most one request and exactly one stop of one exchange."
  defmacro assert_exchange(timeout \\ 2_000) do
    quote do
      assert_receive {:docker_event, [:opsmaru_containers, :docker, :exchange, :start], start,
                      start_meta},
                     unquote(timeout)

      span = start_meta.telemetry_span_context

      assert_receive {:docker_event, [:opsmaru_containers, :docker, :exchange, :stop], stop,
                      %{telemetry_span_context: ^span} = stop_meta},
                     unquote(timeout)

      request =
        receive do
          {:docker_event, [:opsmaru_containers, :docker, :request], measurements,
           %{telemetry_span_context: ^span} = meta} ->
            {measurements, meta}
        after
          0 -> nil
        end

      %{
        start: {start, start_meta},
        request: request,
        stop: {stop, stop_meta}
      }
    end
  end
end
