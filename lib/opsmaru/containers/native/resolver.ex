defmodule Opsmaru.Containers.Native.Resolver do
  @moduledoc false
  # Resolves a container or exec reference to the engine that owns it.
  #
  # Docker resolves a container reference as a full ID, then an exact name,
  # then a unique ID prefix. A full ID or a name matched in the native project
  # is final: IDs are random and names are kept unique across engines. Only
  # a native prefix match asks the nested engine, because an exact match there
  # wins and a prefix match in both engines is ambiguous. A reference that
  # matches nothing native goes to nested, which answers dockerd's own 404.

  alias Opsmaru.Containers.Docker.EngineRequest
  alias Opsmaru.Containers.Native.Container

  @type resolution ::
          :nested | {:native, Container.t()} | {:error, pos_integer(), String.t()}

  @doc "The native containers in the target's native project."
  def containers(%{target: %{native: native}}, deadline) do
    case native.backend.list_instances(native.client, deadline) do
      {:ok, instances} -> {:ok, Container.from_instances(instances)}
      {:error, _} -> {:error, 503, "native engine: Incus is not available"}
    end
  end

  @spec resolve(map(), String.t(), String.t(), integer()) :: resolution()
  def resolve(context, reference, api_version, deadline) do
    with {:ok, containers} <- containers(context, deadline) do
      resolve_in(containers, context, reference, api_version, deadline)
    end
  end

  @doc false
  def resolve_in(containers, context, reference, api_version, deadline) do
    case match(containers, reference) do
      {:exact, container} -> {:native, container}
      [] -> :nested
      [container] -> against_nested(container, context, reference, api_version, deadline)
      [_, _ | _] -> ambiguous(reference)
    end
  end

  @doc "Resolves an exec ID. Docker matches exec IDs exactly."
  def resolve_exec(context, exec_id, deadline) do
    with {:ok, containers} <- containers(context, deadline) do
      case Enum.find(containers, &Map.has_key?(&1.execs, exec_id)) do
        nil -> :nested
        container -> {:native, container}
      end
    end
  end

  @doc """
  Docker's match order within one engine: `{:exact, container}` for a full ID
  or a name, otherwise the containers whose ID starts with the reference.
  """
  def match(containers, reference) do
    name = String.trim_leading(reference, "/")

    cond do
      container = Enum.find(containers, &(&1.id == reference)) -> {:exact, container}
      container = Enum.find(containers, &(&1.name == name)) -> {:exact, container}
      reference == "" -> []
      true -> Enum.filter(containers, &String.starts_with?(&1.id, reference))
    end
  end

  defp against_nested(container, context, reference, api_version, deadline) do
    target = "/v#{api_version}/containers/#{URI.encode(reference, &URI.char_unreserved?/1)}/json"

    case EngineRequest.json(context, "GET", target, nil, deadline) do
      {:ok, 404, _} ->
        {:native, container}

      {:ok, 200, %{"Id" => id, "Name" => nested_name}} ->
        if id == reference or nested_name == "/" <> String.trim_leading(reference, "/"),
          do: :nested,
          else: ambiguous(reference)

      {:ok, 400, _} ->
        ambiguous(reference)

      _ ->
        {:error, 503, "Docker engine is not ready"}
    end
  end

  defp ambiguous(reference),
    do: {:error, 400, "multiple IDs found with provided prefix: #{reference}"}
end
