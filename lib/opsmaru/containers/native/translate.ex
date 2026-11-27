defmodule Opsmaru.Containers.Native.Translate do
  @moduledoc false
  # Create translation from `priv/docker/native-create.json` (design decision
  # 12). Field names match case-insensitively, as Go's JSON decoding does in
  # dockerd. A refused field, an unknown field, or a translated field with a
  # value native cannot honour is refused when it is not at its default.
  # Everything is decided before any Incus mutation.

  @table Path.expand("../../../../priv/docker/native-create.json", __DIR__)
  @external_resource @table

  @fields @table |> File.read!() |> Jason.decode!() |> Map.fetch!("fields")
  @classes Map.new(@fields, &{&1["field"], &1["class"]})
  @groups @fields
          |> Enum.map(& &1["field"])
          |> Enum.group_by(
            fn field ->
              case String.split(field, ".", parts: 2) do
                [_] -> :top
                [group, _] -> group
              end
            end,
            fn field -> field |> String.split(".") |> List.last() end
          )

  alias Opsmaru.Containers.Native.Signal

  @init "/.opsmaru/init"
  @reserved "/.opsmaru"
  @default_log %{"driver" => "local", "max_size" => 20_971_520, "max_files" => 5}
  @networks ["", "default", "bridge"]

  @doc "The table class of a field, such as `\"HostConfig.Memory\"`."
  def class(field), do: Map.get(@classes, field)

  @doc """
  The fields of a decoded create body that native cannot honour, without
  the image or host: `:ok` or `{:error, fields}`.
  """
  def eligibility(body) when is_map(body) do
    case normalise(body) do
      {:ok, normalised} ->
        case refusals(normalised) do
          [] -> :ok
          fields -> {:error, fields}
        end

      :error ->
        {:error, ["(ambiguous field names)"]}
    end
  end

  def eligibility(_), do: {:error, ["(body)"]}

  @doc """
  Checks a create body before anything is fetched or created: refusals,
  then bind sources through `map_source` (one absolute source to
  `{:ok, mapped}` or `:deny`, or `nil` when the host maps none). Returns
  `{:ok, prepared}` for `finish/2`, or a Docker-shaped 400.
  """
  def prepare(body, map_source) do
    with {:ok, normalised} <- normalise_or_400(body),
         :ok <- refused(refusals(normalised)),
         :ok <- image_given(normalised.top["Image"]),
         {:ok, devices, mounts} <- binds(normalised.host, map_source) do
      host = mapped_host(normalised.host, Enum.map(mounts, & &1["Source"]))
      {:ok, Map.merge(normalised, %{host: host, binds: devices, mounts: mounts})}
    end
  end

  # The stored HostConfig carries the mapped sources, as dockerd stores the
  # body the nested bind policy rewrote. Binds come first, then Mounts, in the
  # order `binds/2` mapped them.
  defp mapped_host(host, []), do: host

  defp mapped_host(host, sources) do
    {binds, sources} = Enum.split(sources, length(host["Binds"] || []))

    host
    |> replace_sources("Binds", binds, fn bind, source ->
      [_ | rest] = String.split(bind, ":")
      Enum.join([source | rest], ":")
    end)
    |> replace_sources("Mounts", sources, &Map.put(&1, "Source", &2))
  end

  defp replace_sources(host, key, sources, replace) do
    case host[key] do
      list when is_list(list) and list != [] ->
        Map.put(host, key, Enum.zip_with(list, sources, replace))

      _ ->
        host
    end
  end

  @doc """
  Merges a prepared body with the nested engine's image inspect. Returns
  `%{spec, hostname, config, devices, docker, labels, autoremove}`, where
  `spec` lacks only the hostname, whose default needs the container ID.
  """
  def finish(%{top: top, host: host} = prepared, image) do
    with {:ok, process} <- process(top, host, image["Config"] || %{}) do
      {:ok,
       %{
         spec: Map.put(process.spec, "log", log(host["LogConfig"])),
         hostname: present(top["Hostname"]),
         config: Map.merge(oci(), limits(host)),
         devices: Map.merge(network(top, host), prepared.binds),
         labels: process.labels,
         autoremove: host["AutoRemove"] == true,
         docker: docker(top, host, process, prepared.mounts, image)
       }}
    end
  end

  @doc "The image reference of a prepared body."
  def image(%{top: top}), do: top["Image"]

  defp image_given(image) when is_binary(image) and image != "", do: :ok
  defp image_given(_), do: {:error, 400, "native engine: a create needs an Image"}

  defp normalise_or_400(body) do
    case normalise(body) do
      {:ok, normalised} -> {:ok, normalised}
      :error -> {:error, 400, "invalid JSON: duplicate field names"}
    end
  end

  defp refused([]), do: :ok

  defp refused(fields),
    do: {:error, 400, "native engine cannot honour: " <> Enum.join(fields, ", ")}

  # -- Normalisation ---------------------------------------------------------

  defp normalise(body) do
    with {:ok, top, unknown} <-
           canonical(body, @groups[:top] ++ ["HostConfig", "NetworkingConfig"], ""),
         {:ok, host, host_unknown} <-
           canonical(top["HostConfig"] || %{}, @groups["HostConfig"], "HostConfig."),
         {:ok, net, net_unknown} <-
           canonical(
             top["NetworkingConfig"] || %{},
             @groups["NetworkingConfig"],
             "NetworkingConfig."
           ) do
      {:ok,
       %{
         top: Map.drop(top, ["HostConfig", "NetworkingConfig"]),
         host: host,
         net: net,
         unknown: unknown ++ host_unknown ++ net_unknown
       }}
    end
  end

  defp canonical(object, names, prefix) when is_map(object) do
    lookup = Map.new(names, &{String.downcase(&1), &1})

    Enum.reduce_while(object, {:ok, %{}, []}, fn {key, value}, {:ok, known, unknown} ->
      case Map.fetch(lookup, String.downcase(key)) do
        {:ok, name} when is_map_key(known, name) -> {:halt, :error}
        {:ok, name} -> {:cont, {:ok, Map.put(known, name, value), unknown}}
        :error -> {:cont, {:ok, known, [{prefix <> key, value} | unknown]}}
      end
    end)
  end

  defp canonical(_, _, _), do: :error

  # -- Refusals --------------------------------------------------------------

  defp refusals(%{top: top, host: host, net: net, unknown: unknown}) do
    fields =
      by_class(top, "") ++
        by_class(host, "HostConfig.") ++
        by_class(net, "NetworkingConfig.") ++
        for({field, value} <- unknown, not default?(field, value), do: field) ++
        values(top, host, net)

    fields |> Enum.uniq() |> Enum.sort()
  end

  defp by_class(object, prefix) do
    for {name, value} <- object,
        field = prefix <> name,
        class(field) == "refused",
        not default?(field, value),
        do: field
  end

  @doc false
  # A field is at its default when absent, null or its type's zero value,
  # unless its table reason names another default.
  def default?("HostConfig.MemorySwappiness", -1), do: true
  def default?("HostConfig.Isolation", "default"), do: true

  def default?(field, []) when field in ["HostConfig.MaskedPaths", "HostConfig.ReadonlyPaths"],
    do: false

  def default?(_, value), do: value in [nil, false, 0, "", [], %{}]

  # Translated fields whose value native cannot honour.
  defp values(top, host, net) do
    (host_values(host) ++
       top_values(top) ++
       [{"NetworkingConfig.EndpointsConfig", endpoints?(net["EndpointsConfig"], host)}])
    |> Enum.reject(&elem(&1, 1))
    |> Enum.map(&elem(&1, 0))
  end

  defp host_values(host) do
    [
      {"HostConfig.NetworkMode", network_mode(host) != :error},
      {"HostConfig.RestartPolicy", restart?(host["RestartPolicy"])},
      {"HostConfig.LogConfig", log_config(host["LogConfig"]) != :error},
      {"HostConfig.Binds", binds_valid?(host["Binds"])},
      {"HostConfig.Mounts", mounts_valid?(host["Mounts"])},
      {"HostConfig.NanoCpus", nano_cpus?(host)},
      {"HostConfig.CpuQuota", cpu_quota?(host)},
      {"HostConfig.Memory", optional_integer?(host["Memory"], 6_291_456)},
      {"HostConfig.PidsLimit", optional?(host["PidsLimit"], &is_integer/1)},
      {"HostConfig.CpusetCpus", optional?(host["CpusetCpus"], &cpuset?/1)},
      {"HostConfig.Dns", strings?(host["Dns"])},
      {"HostConfig.DnsSearch", strings?(host["DnsSearch"])},
      {"HostConfig.GroupAdd", strings?(host["GroupAdd"])}
    ]
  end

  defp top_values(top) do
    [
      {"Entrypoint", strings?(top["Entrypoint"])},
      {"Cmd", strings?(top["Cmd"])},
      {"Env", env?(top["Env"])},
      {"Hostname", optional?(top["Hostname"], &hostname?/1)},
      {"Labels", optional?(top["Labels"], &string_map?/1)},
      {"StopTimeout", optional?(top["StopTimeout"], &is_integer/1)},
      {"StopSignal", optional?(top["StopSignal"], &(Signal.parse(&1) != :error))},
      {"Image", optional?(top["Image"], &is_binary/1)}
    ]
  end

  # Unset (null or empty string) or valid.
  defp optional?(value, _) when value in [nil, ""], do: true
  defp optional?(value, valid?), do: valid?.(value)

  defp nano_cpus?(host),
    do:
      not (positive?(host["NanoCpus"]) and
             (positive?(host["CpuQuota"]) or positive?(host["CpuPeriod"])))

  defp network_mode(host) do
    case host["NetworkMode"] || "" do
      mode when mode in @networks -> :default
      "none" -> :none
      _ -> :error
    end
  end

  defp restart?(nil), do: true

  defp restart?(%{} = policy),
    do: (policy["Name"] || "") in ["", "no"] and (policy["MaximumRetryCount"] || 0) == 0

  defp restart?(_), do: false

  defp binds_valid?(nil), do: true

  defp binds_valid?(binds) when is_list(binds),
    do: Enum.all?(binds, &match?({:ok, _}, parse_bind(&1)))

  defp binds_valid?(_), do: false

  defp mounts_valid?(nil), do: true

  defp mounts_valid?(mounts) when is_list(mounts),
    do: Enum.all?(mounts, &match?({:ok, _}, parse_mount(&1)))

  defp mounts_valid?(_), do: false

  defp cpu_quota?(host) do
    quota = host["CpuQuota"]
    period = host["CpuPeriod"]

    cond do
      not optional_integer?(quota, 0) or not optional_integer?(period, 0) -> false
      positive?(period) and not positive?(quota) -> false
      positive?(period) and period not in 1_000..1_000_000 -> false
      positive?(quota) -> quota >= 1_000
      true -> true
    end
  end

  defp endpoints?(nil, _), do: true
  defp endpoints?(endpoints, _) when endpoints == %{}, do: true

  defp endpoints?(%{} = endpoints, host) when map_size(endpoints) == 1 do
    [{name, settings}] = Map.to_list(endpoints)
    mode = host["NetworkMode"] || ""

    (name == mode or (mode in @networks and name in @networks)) and
      (settings == nil or
         (is_map(settings) and Enum.all?(settings, fn {k, v} -> default?(k, v) end)))
  end

  defp endpoints?(_, _), do: false

  # -- Process ---------------------------------------------------------------

  # Docker's merge of the create body with the image config (moby `merge`).
  defp process(top, host, image) do
    {entrypoint, cmd} = command(top["Entrypoint"], top["Cmd"], image)
    argv = entrypoint ++ cmd

    if argv == [] do
      {:error, 400, "No command specified"}
    else
      env = merge_env(top["Env"] || [], image["Env"] || [])

      {:ok,
       %{
         entrypoint: entrypoint,
         cmd: cmd,
         env: env,
         labels: Map.merge(image["Labels"] || %{}, top["Labels"] || %{}),
         spec: spec(argv, env, top, host, image)
       }}
    end
  end

  defp spec(argv, env, top, host, image) do
    %{
      "version" => 1,
      "argv" => argv,
      # An entry without `=` unsets the name, as moby's
      # `ReplaceOrAppendEnvValues` does at start.
      "env" => Enum.filter(env, &String.contains?(&1, "=")),
      "cwd" => inherited(top, image, "WorkingDir") || "/",
      "user" => inherited(top, image, "User") || "",
      "group_add" => host["GroupAdd"] || [],
      "stop_signal" => stop_signal(inherited(top, image, "StopSignal"))
    }
  end

  # The create body's value, or the image config's when the body's is unset.
  defp inherited(top, image, key), do: present(top[key]) || present(image[key])

  # `--entrypoint ""` resets the image entrypoint and keeps only the
  # body's command. An empty entrypoint keeps the image's command.
  defp command([""], cmd, _), do: {[], cmd || []}
  defp command([_ | _] = entrypoint, cmd, _), do: {entrypoint, cmd || []}
  defp command([], cmd, image), do: {[], image_cmd(cmd, image)}
  defp command(nil, cmd, image), do: {image["Entrypoint"] || [], image_cmd(cmd, image)}

  defp image_cmd(cmd, image) when cmd in [nil, []], do: image["Cmd"] || []
  defp image_cmd(cmd, _), do: cmd

  defp stop_signal(nil), do: "SIGTERM"

  defp stop_signal(value) do
    case Signal.parse(value) do
      {:ok, signal} -> signal
      :error -> "SIGTERM"
    end
  end

  defp merge_env([], image), do: image

  defp merge_env(user, image) do
    keys = MapSet.new(user, &env_key/1)
    user ++ Enum.reject(image, &MapSet.member?(keys, env_key(&1)))
  end

  defp env_key(entry), do: entry |> String.split("=", parts: 2) |> hd()

  # -- Incus configuration -----------------------------------------------------

  defp oci do
    %{"oci.entrypoint" => @init, "oci.uid" => "0", "oci.gid" => "0", "oci.cwd" => "/"}
  end

  defp limits(host) do
    [
      {"limits.memory", positive?(host["Memory"]) && "#{host["Memory"]}B"},
      {"limits.cpu.allowance", cpu_allowance(host)},
      {"limits.cpu", present(host["CpusetCpus"])},
      {"limits.processes", positive?(host["PidsLimit"]) && "#{host["PidsLimit"]}"},
      {"oci.dns.nameservers", joined(host["Dns"])},
      {"oci.dns.search", joined(host["DnsSearch"])}
    ]
    |> Enum.filter(fn {_, value} -> is_binary(value) end)
    |> Map.new()
  end

  defp joined([_ | _] = values), do: Enum.join(values, ",")
  defp joined(_), do: nil

  # NanoCpus is CPUs in billionths; CpuQuota and CpuPeriod are microseconds.
  defp cpu_allowance(host) do
    cond do
      positive?(host["NanoCpus"]) ->
        allowance(host["NanoCpus"] * 100 / 1.0e9, 100)

      positive?(host["CpuQuota"]) ->
        period = if positive?(host["CpuPeriod"]), do: host["CpuPeriod"], else: 100_000
        allowance(host["CpuQuota"] / 1_000, period / 1_000)

      true ->
        nil
    end
  end

  defp allowance(quota_ms, period_ms),
    do: "#{max(round(quota_ms), 1)}ms/#{max(round(period_ms), 1)}ms"

  defp network(top, host) do
    if network_mode(host) == :none or top["NetworkDisabled"] == true,
      do: %{"eth0" => %{"type" => "none"}},
      else: %{}
  end

  defp log(config) do
    case log_config(config) do
      {:ok, log} -> log
      _ -> @default_log
    end
  end

  defp log_config(nil), do: {:ok, @default_log}

  defp log_config(%{} = config) do
    options = config["Config"] || %{}

    case config["Type"] || "" do
      "none" when options == %{} ->
        {:ok, %{"driver" => "none", "max_size" => 20_971_520, "max_files" => 5}}

      type when type in ["", "json-file", "local"] ->
        rotation(options)

      _ ->
        :error
    end
  end

  defp log_config(_), do: :error

  defp rotation(options) when is_map(options) do
    with [] <- Map.keys(options) -- ["max-size", "max-file"],
         {:ok, size} <- size(options["max-size"]),
         {:ok, files} <- files(options["max-file"]),
         true <- size >= 4_096 do
      {:ok, %{"driver" => "local", "max_size" => size, "max_files" => files}}
    else
      _ -> :error
    end
  end

  defp rotation(_), do: :error

  # go-units `RAMInBytes`, which Docker's log options use.
  defp size(nil), do: {:ok, 20_971_520}

  defp size(value) when is_binary(value) do
    case Regex.run(~r/\A(\d+(?:\.\d+)?) ?([kmgtp])?i?b?\z/i, value) do
      [_, number, unit | _] ->
        {number, _} = Float.parse(number)
        power = Enum.find_index(["", "k", "m", "g", "t", "p"], &(&1 == String.downcase(unit)))
        {:ok, round(number * Integer.pow(1024, power))}

      [_, number] ->
        {:ok, number |> Float.parse() |> elem(0) |> round()}

      nil ->
        :error
    end
  end

  defp size(_), do: :error

  defp files(nil), do: {:ok, 5}

  defp files(value) when is_binary(value) do
    case Integer.parse(value) do
      {files, ""} when files >= 1 -> {:ok, files}
      _ -> :error
    end
  end

  defp files(_), do: :error

  # -- Binds -------------------------------------------------------------------

  defp binds(host, map_source) do
    entries =
      Enum.map(host["Binds"] || [], &elem(parse_bind(&1), 1)) ++
        Enum.map(host["Mounts"] || [], &elem(parse_mount(&1), 1))

    cond do
      entries == [] ->
        {:ok, %{}, []}

      map_source == nil ->
        {:error, 400,
         "native engine cannot honour: HostConfig.Binds (the host maps no bind sources)"}

      true ->
        map_binds(entries, map_source)
    end
  end

  defp map_binds(entries, map_source) do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}, []}, fn {entry, index}, {:ok, devices, mounts} ->
      case map_source.(entry.source) do
        {:ok, mapped} when is_binary(mapped) ->
          device = %{
            "type" => "disk",
            "source" => mapped,
            "path" => entry.target,
            "readonly" => to_string(entry.readonly)
          }

          mount = %{
            "Type" => "bind",
            "Source" => mapped,
            "Destination" => entry.target,
            "Mode" => if(entry.readonly, do: "ro", else: ""),
            "RW" => not entry.readonly,
            "Propagation" => "rprivate"
          }

          {:cont, {:ok, Map.put(devices, "bind#{index}", device), mounts ++ [mount]}}

        _ ->
          {:halt,
           {:error, 400, "invalid mount config: bind source path #{entry.source} is not allowed"}}
      end
    end)
  end

  defp parse_bind(bind) when is_binary(bind) do
    case String.split(bind, ":") do
      [source, target] -> bind_entry(source, target, false)
      [source, target, "ro"] -> bind_entry(source, target, true)
      [source, target, "rw"] -> bind_entry(source, target, false)
      _ -> :error
    end
  end

  defp parse_bind(_), do: :error

  @mount_keys ["Type", "Source", "Target", "ReadOnly", "Consistency"]

  defp parse_mount(%{"Type" => "bind", "Source" => source, "Target" => target} = mount) do
    extra = Map.drop(mount, @mount_keys)

    if Enum.all?(extra, fn {k, v} -> default?(k, v) end) and
         mount["ReadOnly"] in [nil, true, false],
       do: bind_entry(source, target, mount["ReadOnly"] == true),
       else: :error
  end

  defp parse_mount(_), do: :error

  defp bind_entry("/" <> _ = source, "/" <> _ = target, readonly) do
    target = Path.expand(target)

    if target == "/" or target == @reserved or String.starts_with?(target, @reserved <> "/"),
      do: :error,
      else: {:ok, %{source: source, target: target, readonly: readonly}}
  end

  defp bind_entry(_, _, _), do: :error

  # -- Inspect configuration -----------------------------------------------------

  # What inspect needs later, kept in `user.opsmaru.containers.config`.
  defp docker(top, host, process, mounts, image) do
    [path | args] = process.spec["argv"]

    %{
      "Path" => path,
      "Args" => args,
      "Mounts" => mounts,
      "Config" => docker_config(top, process, image["Config"] || %{}),
      "HostConfig" => docker_host(host)
    }
  end

  defp docker_config(top, process, config) do
    %{
      "Domainname" => "",
      "User" => process.spec["user"],
      "AttachStdin" => false,
      "AttachStdout" => top["AttachStdout"] == true,
      "AttachStderr" => top["AttachStderr"] == true,
      "ExposedPorts" => top["ExposedPorts"] || config["ExposedPorts"],
      "Tty" => false,
      "OpenStdin" => false,
      "StdinOnce" => false,
      "Env" => process.env,
      "Cmd" => process.cmd,
      "Image" => top["Image"],
      "Volumes" => config["Volumes"],
      "WorkingDir" => inherited(top, config, "WorkingDir") || "",
      "Entrypoint" => if(process.entrypoint == [], do: nil, else: process.entrypoint),
      "OnBuild" => nil,
      "Labels" => process.labels,
      "StopSignal" => process.spec["stop_signal"],
      "StopTimeout" => top["StopTimeout"]
    }
  end

  @host_defaults %{
    "Memory" => 0,
    "NanoCpus" => 0,
    "CpuQuota" => 0,
    "CpuPeriod" => 0,
    "CpusetCpus" => "",
    "Dns" => [],
    "DnsSearch" => []
  }

  defp docker_host(host) do
    given =
      for {key, value} <- Map.take(host, Map.keys(@host_defaults)),
          value != nil,
          into: %{},
          do: {key, value}

    log = host["LogConfig"] || %{}

    @host_defaults
    |> Map.merge(given)
    |> Map.merge(%{
      "Binds" => host["Binds"],
      "NetworkMode" => present(host["NetworkMode"]) || "bridge",
      "RestartPolicy" => %{"Name" => "no", "MaximumRetryCount" => 0},
      "AutoRemove" => host["AutoRemove"] == true,
      "LogConfig" => %{
        "Type" => present(log["Type"]) || "local",
        "Config" => log["Config"] || %{}
      },
      "PidsLimit" => host["PidsLimit"],
      "GroupAdd" => host["GroupAdd"],
      "Init" => true,
      "Mounts" => host["Mounts"]
    })
  end

  # -- Helpers -------------------------------------------------------------------

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_), do: nil

  defp positive?(value), do: is_integer(value) and value > 0

  defp optional_integer?(nil, _), do: true
  defp optional_integer?(0, _), do: true
  defp optional_integer?(value, minimum), do: is_integer(value) and value >= minimum

  defp strings?(nil), do: true
  defp strings?(list) when is_list(list), do: Enum.all?(list, &is_binary/1)
  defp strings?(_), do: false

  defp env?(nil), do: true

  defp env?(env) when is_list(env),
    do:
      Enum.all?(
        env,
        &(is_binary(&1) and &1 != "" and not String.starts_with?(&1, "=") and
            not String.contains?(&1, <<0>>))
      )

  defp env?(_), do: false

  defp hostname?(name),
    do:
      is_binary(name) and byte_size(name) <= 64 and
        Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9.-]*\z/, name)

  defp string_map?(map),
    do: is_map(map) and Enum.all?(map, fn {k, v} -> is_binary(k) and is_binary(v) end)

  defp cpuset?(value),
    do: is_binary(value) and Regex.match?(~r/\A\d+(-\d+)?(,\d+(-\d+)?)*\z/, value)
end
