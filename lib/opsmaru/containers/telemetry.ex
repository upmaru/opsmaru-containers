defmodule Opsmaru.Containers.Telemetry do
  @moduledoc """
  Optional `:telemetry` emission for the library.

  The library emits:

    * `[:opsmaru_containers, :docker, :exchange, :start]` - measurements
      `system_time`, `monotonic_time`; emitted in the adapter process before
      admission.
    * `[:opsmaru_containers, :docker, :request]` - measurements `duration`;
      emitted at most once, when a response head is committed or the request
      is refused; emitted from the exchange observer.
    * `[:opsmaru_containers, :docker, :exchange, :stop]` - measurements
      `duration`, `request_bytes`, `response_bytes`; emitted exactly once,
      when the exchange really ends; emitted from the exchange observer.

  Every event carries the same metadata keys: `telemetry_span_context`,
  `adapter`, `host`, `mode`, `method`, `route`, `path`, `api_version`,
  `peer_address`, `peer_port`, `peer_fingerprint`, `status`, `outcome` and
  `reason`. On `stop`, `outcome` is `:ok`, `:not_sent`, `:uncertain` or
  `:sent`, and `reason` is `nil` for `:ok` or one of `:invalid_request`,
  `:not_found`, `:denied`, `:unsupported`, `:version`, `:not_ready`,
  `:too_large`, `:engine_unavailable`, `:upstream_failed`, `:caller_closed`,
  `:backend_closed`, `:deadline`, `:handoff_timeout` and `:killed`. Events
  never carry the query string, headers, bodies or stream bytes, the host
  identity or context, the Incus client or target, bind sources, error
  messages or a refused path. `docs/embedding.md` ("Exchange telemetry")
  documents each value.

  `:telemetry` is an optional dependency. The implementation is chosen at
  compile time: without `:telemetry` every function is a no-op. Emission never
  raises into a request, including when `:telemetry` is loaded but not
  started. The library attaches no handler and writes no log.
  """

  if Code.ensure_loaded?(:telemetry) do
    @doc false
    def execute(event, measurements, metadata) do
      :telemetry.execute(event, measurements, metadata)
    catch
      _, _ -> :ok
    end

    @doc false
    def list_handlers(prefix) do
      :telemetry.list_handlers(prefix)
    catch
      _, _ -> []
    end
  else
    @doc false
    def execute(_event, _measurements, _metadata), do: :ok

    @doc false
    def list_handlers(_prefix), do: []
  end
end
