defmodule Opsmaru.Containers.Docker.Routing do
  @moduledoc false
  # Per-container engine routing, after admission. A host without a native
  # target, or a route without a `native` field, is relayed to nested exactly
  # as before, with no Incus call.

  alias Opsmaru.Containers.Docker.Route
  alias Opsmaru.Containers.Native.{Names, Resolver}

  @type t ::
          :nested
          | {:list, [map()]}
          | {:prune, [map()]}
          | {:native, Opsmaru.Containers.Native.Container.t()}
          | {:error, pos_integer(), String.t()}

  @spec route(map(), String.t(), integer()) :: t()
  def route(%{context: %{target: %{native: nil}}}, _, _), do: :nested
  def route(%{route: route}, _, _) when not is_map_key(route, "native"), do: :nested

  def route(%{route: %{"path" => path}} = admission, raw_query, deadline) do
    with {:ok, containers} <- Resolver.containers(admission.context, deadline) do
      route(path, containers, admission, raw_query, deadline)
    end
  end

  defp route(path, [], _, _, _) when path in ["/containers/json", "/containers/prune"],
    do: :nested

  defp route("/containers/json", containers, _, _, _), do: {:list, containers}
  defp route("/containers/prune", containers, _, _, _), do: {:prune, containers}

  defp route("/containers/create", containers, _, raw_query, _),
    do: Names.check_native(containers, URI.decode_query(raw_query)["name"], :create)

  defp route("/exec/" <> _, containers, admission, _, _) do
    exec_id = Route.reference(admission.route, admission.decoded_path)

    case Enum.find(containers, &Map.has_key?(&1.execs, exec_id)) do
      nil -> :nested
      _container -> unavailable(admission.route)
    end
  end

  defp route(path, containers, admission, raw_query, deadline) do
    reference = Route.reference(admission.route, admission.decoded_path)

    case Resolver.resolve_in(
           containers,
           admission.context,
           reference,
           admission.maximum,
           deadline
         ) do
      :nested when path == "/containers/{name:.*}/rename" ->
        Names.check_native(containers, URI.decode_query(raw_query)["name"], :rename)

      :nested ->
        :nested

      {:native, container} ->
        native(admission.route, container)

      {:error, _, _} = error ->
        error
    end
  end

  defp native(%{"native" => %{"class" => "refused", "reason" => reason}}, _),
    do: {:error, 501, "native engine: #{reason}"}

  defp native(%{"native" => %{"class" => "translated"}}, container), do: {:native, container}

  @doc "The answer for a translated route this release does not serve yet."
  def unavailable(%{"path" => path}),
    do: {:error, 501, "native engine: #{path} is not available in this release"}
end
