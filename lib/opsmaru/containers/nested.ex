defmodule Opsmaru.Containers.Nested do
  @moduledoc """
  Explicit lifecycle and readiness for a nested Docker engine.

  Serialize ensure calls for a target in the host. The library makes no
  lifecycle call from a request handler and keeps no engine state.
  """

  alias Opsmaru.Containers.Docker.{HTTP, Version}
  alias Opsmaru.Containers.Nested.{Spec, Target}
  alias Opsmaru.Containers.Transport
  alias Opsmaru.Containers.Transport.Stream
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Error, Model, Operation, RequestContext, Response}

  @lookup_interval 100
  @probe_attempt 1_000

  @doc """
  Ensure that the chosen instance exists, belongs to this feature, is running
  and responds as a compatible engine. Return its observed Docker API range.
  Supply a host dialer and a finite Incus request context in the options.
  """
  def ensure(%Target{} = target, specification, options) do
    with {:ok, scoped, request_context, dialer} <- setup(target, options),
         {:ok, body} <- Spec.body(specification, target.instance),
         {:ok, instance} <- get_or_create(scoped, body),
         :ok <- ensure_started(scoped, instance, request_context) do
      await_readiness(scoped, dialer, request_context)
    end
  end

  @doc "Probe an already running engine explicitly, without starting or creating it."
  def readiness(%Target{} = target, options) do
    with {:ok, scoped, request_context, dialer} <- setup(target, options),
         {:ok, instance} <- find(scoped),
         :ok <- ownership(instance),
         {:ok, %Response{metadata: %Model{data: %{"status" => "Running"}}}} <-
           Incus.call(scoped.client, "GetInstanceState", args(scoped)) do
      probe(scoped, dialer, request_context.deadline)
    else
      {:ok, _state} -> {:error, :engine_not_ready}
      error -> error
    end
  end

  defp setup(target, options) do
    with true <- Target.valid?(target) and Keyword.keyword?(options),
         %RequestContext{} = lifetime <- options[:request_context],
         true <- target.client.connection.request_context in [nil, lifetime],
         {module, _} = dialer when is_atom(module) and not is_nil(module) <- options[:dialer] do
      client = Incus.with_context(target.client, lifetime)
      {:ok, %{target | client: client}, lifetime, dialer}
    else
      _ -> {:error, :invalid_engine_context}
    end
  rescue
    ArgumentError -> {:error, :invalid_engine_context}
  end

  defp get_or_create(scoped, body) do
    case find(scoped) do
      {:error, %Error{http_status: 404}} -> create(scoped, body)
      result -> result
    end
  end

  defp create(scoped, body) do
    result = Incus.call(scoped.client, "CreateInstance", %{}, body: body)

    case result do
      {:error, %Error{kind: :native, http_status: 409}} ->
        find(scoped)

      result ->
        with :ok <- await_mutation(scoped, result), do: find(scoped)
    end
  end

  defp find(scoped) do
    with {:ok, %Response{metadata: %Model{data: instance}}} <-
           Incus.call(scoped.client, "GetInstance", args(scoped)) do
      {:ok, instance}
    end
  end

  defp ensure_started(scoped, instance, request_context) do
    with :ok <- ownership(instance) do
      start_for_status(instance["status"], scoped, request_context)
    end
  end

  defp start_for_status("Running", _, _), do: :ok

  defp start_for_status("Stopped", scoped, _) do
    result =
      Incus.call(scoped.client, "UpdateInstanceState", args(scoped),
        body: %{"action" => "start", "timeout" => -1, "force" => false, "stateful" => false}
      )

    await_mutation(scoped, result)
  end

  defp start_for_status(_, scoped, request_context) do
    case RequestContext.status(request_context) do
      :active ->
        wait(request_context)

        with {:ok, observed} <- find(scoped),
             do: ensure_started(scoped, observed, request_context)

      kind ->
        {:error, kind}
    end
  end

  defp ownership(instance) do
    if Spec.owned?(instance), do: :ok, else: {:error, :foreign_instance}
  end

  defp await_mutation(scoped, {:ok, %Response{} = response}) do
    with {:ok, operation} <- Operation.from_response(scoped.client, response),
         remaining when remaining > 0 <- scoped.client.connection.request_context.deadline - now(),
         {:ok, _} <- Operation.wait(operation, timeout: remaining) do
      :ok
    else
      {:error, %Error{kind: :operation_failed}} = failure -> failure
      _ -> {:error, %Error{kind: :uncertain, operation: response.operation}}
    end
  end

  defp await_mutation(_, {:error, %Error{kind: :native, http_status: status} = error})
       when status >= 500,
       do: {:error, %{error | kind: :uncertain}}

  defp await_mutation(_, failure), do: failure

  defp await_readiness(scoped, dialer, request_context) do
    case RequestContext.status(request_context) do
      :active ->
        case readiness_attempt(scoped, dialer, request_context) do
          {:error, :engine_not_ready} ->
            wait(request_context)
            await_readiness(scoped, dialer, request_context)

          result ->
            result
        end

      kind ->
        {:error, kind}
    end
  end

  defp readiness_attempt(scoped, dialer, request_context) do
    case Incus.call(scoped.client, "GetInstanceState", args(scoped)) do
      {:ok, %Response{metadata: %Model{data: %{"status" => "Running"}}}} ->
        probe(scoped, dialer, min(request_context.deadline, now() + @probe_attempt))

      {:ok, _} ->
        {:error, :engine_not_ready}

      failure ->
        failure
    end
  end

  defp probe(target, dialer, deadline) do
    with {:ok, "OK"} <- request(target, dialer, deadline, "/_ping", 16),
         {:ok, body} <- request(target, dialer, deadline, "/version", 65_536),
         {:ok, %{"MinAPIVersion" => minimum, "ApiVersion" => maximum}} <- Jason.decode(body),
         {:ok, floor} <- Version.parse(minimum),
         {:ok, ceiling} <- Version.parse(maximum),
         true <- floor <= ceiling do
      compatible(minimum, maximum)
    else
      _ -> {:error, :engine_not_ready}
    end
  end

  defp compatible(minimum, maximum) do
    case Version.effective(minimum, maximum) do
      {:ok, _} ->
        {:ok, %{minimum: minimum, maximum: maximum}}

      {:error, :incompatible_engine} ->
        {:error,
         {:incompatible_engine,
          %{engine: {minimum, maximum}, reference: Version.reference_range()}}}
    end
  end

  defp request(target, dialer, deadline, path, limit) do
    with {:ok, stream} <- Transport.dial(dialer, target, deadline) do
      try do
        with :ok <- HTTP.send_head(stream, "GET", path, [], :none, deadline),
             {:ok, %{status: 200} = response} <- HTTP.receive_head(stream, "GET", deadline),
             do: HTTP.collect(response, limit)
      after
        Stream.close(stream)
      end
    end
  end

  defp wait(request_context) do
    delay = min(@lookup_interval, max(request_context.deadline - now(), 0))
    Process.sleep(delay)
  end

  defp args(scoped), do: %{"name" => scoped.instance}
  defp now, do: System.monotonic_time(:millisecond)
end
