defmodule Mix.Tasks.Docker.Reference do
  @shortdoc "Generate or check the pinned Docker route inventory"
  @moduledoc """
  Reconcile the vendored OpenAPI description with the audited daemon route table.
  Run `mix docker.reference --check` for a read-only consistency check.
  """
  use Mix.Task

  @directory "priv/docker"
  @methods ~w(get put post delete options head patch trace query)
  @takeovers ~w(websocket docker_stream h2c_upgrade)
  @evidence_fields ~w(fixture differential real_incus consumer)

  @impl Mix.Task
  def run(args) when args in [[], ["--check"]] do
    Mix.Task.run("loadpaths")
    routes = inventory()
    write_or_check(args, routes)
    check_ledger(routes)
    Mix.shell().info("Checked #{length(routes)} Docker routes")
  end

  def run(_), do: Mix.raise("Usage: mix docker.reference [--check]")

  defp inventory do
    reference = read_json("reference.json")
    %{"openapi" => %{"path" => path, "sha256" => expected}, "engine" => engine} = reference
    document = @directory |> Path.join(path) |> File.read!() |> :zlib.gunzip()
    checksum = :sha256 |> :crypto.hash(document) |> Base.encode16(case: :lower)

    unless checksum == expected, do: Mix.raise("Pinned OpenAPI SHA-256 differs")
    {version, documented} = openapi_routes(document)

    unless version == engine["max_api_version"], do: Mix.raise("OpenAPI API version differs")

    daemon = read_json("daemon-routes.json")
    keys = Enum.map(daemon, &route_key(&1["method"], &1["path"]))

    if keys != Enum.uniq(keys), do: Mix.raise("Duplicate daemon route")

    missing = MapSet.difference(documented, MapSet.new(keys))
    unless MapSet.size(missing) == 0, do: Mix.raise("Unclassified routes: #{inspect(missing)}")

    Enum.zip_with(daemon, keys, fn route, key ->
      validate_route!(route)
      Map.put(route, "openapi", MapSet.member?(documented, key))
    end)
  end

  defp openapi_routes(document) do
    {:ok, _} = Application.ensure_all_started(:yamerl)
    [schema] = :yamerl_constr.string(document, str_node_as_binary: true)

    version =
      schema |> List.keyfind!("info", 0) |> elem(1) |> List.keyfind!("version", 0) |> elem(1)

    {"paths", paths} = List.keyfind!(schema, "paths", 0)

    routes =
      for {path, operations} <- paths,
          {method, _} <- operations,
          method in @methods,
          into: MapSet.new(),
          do: route_key(String.upcase(method), path)

    {version, routes}
  end

  defp route_key(method, path), do: {method, String.replace(path, ~r/\{[^}]+\}/, "{}")}

  defp validate_route!(%{"class" => "nested", "reason" => _} = route), do: invalid_route!(route)

  defp validate_route!(%{"class" => "nested"} = route) do
    if Map.get(route, "takeover") not in [nil | @takeovers], do: invalid_route!(route)
  end

  defp validate_route!(%{"class" => "unsupported", "reason" => reason})
       when is_binary(reason) and byte_size(reason) > 0,
       do: :ok

  defp validate_route!(route), do: invalid_route!(route)

  defp invalid_route!(route),
    do: Mix.raise("Invalid Docker route classification: #{inspect(route)}")

  defp write_or_check([], routes) do
    file = Path.join(@directory, "routes.json")
    rows = Enum.map_join(routes, ",\n", &("  " <> Jason.encode!(&1)))
    File.write!(file, "[\n" <> rows <> "\n]\n")
  end

  defp write_or_check(["--check"], routes) do
    unless read_json("routes.json") == routes, do: Mix.raise("Stale Docker route inventory")
  end

  defp check_ledger(routes) do
    entries = read_json("coverage.json")
    route_identity = &Map.take(&1, ~w(method path class))
    expected = Enum.map(routes, route_identity)

    unless Enum.map(entries, route_identity) == expected and
             Enum.all?(entries, &evidence_entry?/1),
           do: Mix.raise("Evidence ledger does not match the Docker route inventory")
  end

  defp evidence_entry?(entry) do
    Enum.all?(@evidence_fields, fn field ->
      records = Map.get(entry, field)
      is_list(records) and Enum.all?(records, &(is_binary(&1) and &1 != ""))
    end)
  end

  defp read_json(file), do: @directory |> Path.join(file) |> File.read!() |> Jason.decode!()
end
