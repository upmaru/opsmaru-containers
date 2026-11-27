defmodule Mix.Tasks.Docker.Reference do
  @shortdoc "Generate or check the pinned Docker route inventory"
  @moduledoc """
  Reconcile the vendored OpenAPI description with the audited daemon route table.
  Run `mix docker.reference --check` for a read-only consistency check.

  Both modes also check `priv/docker/native-create.json` against the create
  body fields of the pinned OpenAPI description.
  """
  use Mix.Task

  @directory "priv/docker"
  @methods ~w(get put post delete options head patch trace query)
  @takeovers ~w(websocket docker_stream h2c_upgrade)
  @evidence_fields ~w(fixture differential real_incus consumer)

  @impl Mix.Task
  def run(args) when args in [[], ["--check"]] do
    Mix.Task.run("loadpaths")
    {routes, schema, api_version} = inventory()
    write_or_check(args, routes)
    check_ledger(routes)
    fields = check_native_create(schema, api_version)
    Mix.shell().info("Checked #{length(routes)} Docker routes and #{fields} native create fields")
  end

  def run(_), do: Mix.raise("Usage: mix docker.reference [--check]")

  defp inventory do
    reference = read_json("reference.json")
    %{"openapi" => %{"path" => path, "sha256" => expected}, "engine" => engine} = reference
    document = @directory |> Path.join(path) |> File.read!() |> :zlib.gunzip()
    checksum = :sha256 |> :crypto.hash(document) |> Base.encode16(case: :lower)

    unless checksum == expected, do: Mix.raise("Pinned OpenAPI SHA-256 differs")
    {version, documented, schema} = openapi_routes(document)

    unless version == engine["max_api_version"], do: Mix.raise("OpenAPI API version differs")

    daemon = read_json("daemon-routes.json")
    keys = Enum.map(daemon, &route_key(&1["method"], &1["path"]))

    if keys != Enum.uniq(keys), do: Mix.raise("Duplicate daemon route")

    missing = MapSet.difference(documented, MapSet.new(keys))
    unless MapSet.size(missing) == 0, do: Mix.raise("Unclassified routes: #{inspect(missing)}")

    routes =
      Enum.zip_with(daemon, keys, fn route, key ->
        validate_route!(route)
        Map.put(route, "openapi", MapSet.member?(documented, key))
      end)

    {routes, schema, version}
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

    {version, routes, schema}
  end

  defp route_key(method, path), do: {method, String.replace(path, ~r/\{[^}]+\}/, "{}")}

  defp validate_route!(%{"class" => "nested", "reason" => _} = route), do: invalid_route!(route)

  defp validate_route!(%{"class" => "nested"} = route) do
    if Map.get(route, "takeover") not in [nil | @takeovers] or
         not valid_native?(container_scoped?(route), Map.get(route, "native")),
       do: invalid_route!(route)
  end

  defp validate_route!(%{"class" => "unsupported", "reason" => reason} = route)
       when is_binary(reason) and byte_size(reason) > 0 do
    if Map.has_key?(route, "native"), do: invalid_route!(route)
  end

  defp validate_route!(route), do: invalid_route!(route)

  # Container and exec routes record whether native containers are served.
  defp container_scoped?(%{"path" => path}),
    do: String.starts_with?(path, "/containers") or String.starts_with?(path, "/exec/")

  defp valid_native?(false, native), do: native == nil
  defp valid_native?(true, %{"class" => "translated"} = native), do: map_size(native) == 1

  defp valid_native?(true, %{"class" => "refused", "reason" => reason} = native),
    do: is_binary(reason) and reason != "" and map_size(native) == 2

  defp valid_native?(true, _), do: false

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
             Enum.all?(entries, &evidence_entry?/1) and
             Enum.all?(Enum.zip(routes, entries), &native_evidence?/1),
           do: Mix.raise("Evidence ledger does not match the Docker route inventory")
  end

  defp evidence_entry?(entry) do
    Enum.all?(@evidence_fields, fn field ->
      records = Map.get(entry, field)
      is_list(records) and Enum.all?(records, &(is_binary(&1) and &1 != ""))
    end)
  end

  # A route that serves native containers keeps their evidence apart, so
  # nested passthrough evidence never counts for native containers.
  defp native_evidence?({route, entry}) do
    case {Map.has_key?(route, "native"), Map.get(entry, "native")} do
      {false, nil} ->
        true

      {true, %{} = native} ->
        Map.keys(native) |> Enum.sort() == Enum.sort(@evidence_fields) and evidence_entry?(native)

      _ ->
        false
    end
  end

  @native_classes %{"translated" => "to", "ignored" => "reason", "refused" => "reason"}

  defp check_native_create(schema, api_version) do
    table = read_json("native-create.json")
    expected = create_fields(schema)
    names = Enum.map(Map.get(table, "fields", []), &Map.get(&1, "field"))

    unless table["api_version"] == api_version,
      do: Mix.raise("Native create table is not for API #{api_version}")

    unless text?(table["default"]) and differences?(table["differences"]),
      do: Mix.raise("Native create table needs its default rule and recorded differences")

    if names != Enum.uniq(names), do: Mix.raise("Duplicate native create field")

    missing = expected -- names
    extra = names -- expected
    unless missing == [], do: Mix.raise("Native create fields missing: #{inspect(missing)}")
    unless extra == [], do: Mix.raise("Native create fields not in the API: #{inspect(extra)}")

    Enum.each(table["fields"], fn entry ->
      unless native_field?(entry), do: Mix.raise("Invalid native create field: #{inspect(entry)}")
    end)

    length(names)
  end

  defp native_field?(%{"field" => field, "class" => class} = entry) do
    with {:ok, key} <- Map.fetch(@native_classes, class),
         true <- Map.keys(entry) |> Enum.sort() == Enum.sort(["field", "class", key]) do
      text?(field) and text?(entry[key])
    else
      _ -> false
    end
  end

  defp native_field?(_), do: false

  defp differences?([_ | _] = differences) do
    Enum.all?(differences, fn
      %{"topic" => topic, "difference" => difference} = entry when map_size(entry) == 2 ->
        text?(topic) and text?(difference)

      _ ->
        false
    end)
  end

  defp differences?(_), do: false

  defp text?(value), do: is_binary(value) and String.trim(value) != ""

  # Top-level create fields, with HostConfig and NetworkingConfig expanded.
  defp create_fields(schema) do
    schemas = schema |> field("components") |> field("schemas")

    schema
    |> field("paths")
    |> field("/containers/create")
    |> field("post")
    |> field("requestBody")
    |> field("content")
    |> field("application/json")
    |> field("schema")
    |> properties(schemas)
    |> Enum.flat_map(fn
      {name, node} when name in ["HostConfig", "NetworkingConfig"] ->
        for {nested, _} <- properties(node, schemas), do: name <> "." <> nested

      {name, _} ->
        [name]
    end)
  end

  defp properties(node, schemas) do
    cond do
      ref = field(node, "$ref") -> properties(field(schemas, Path.basename(ref)), schemas)
      all = field(node, "allOf") -> Enum.flat_map(all, &properties(&1, schemas))
      true -> field(node, "properties") || []
    end
  end

  defp field(node, key) do
    case List.keyfind(node, key, 0) do
      {^key, value} -> value
      nil -> nil
    end
  end

  defp read_json(file), do: @directory |> Path.join(file) |> File.read!() |> Jason.decode!()
end
