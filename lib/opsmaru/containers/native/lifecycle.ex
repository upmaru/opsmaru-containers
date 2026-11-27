defmodule Opsmaru.Containers.Native.Lifecycle do
  @moduledoc false
  # Create and lifecycle of native containers (design decisions 4, 12 and
  # 13). Each operation returns `{:ok, status}`, `{:ok, status, body}` or a
  # Docker-shaped `{:error, status, message}`, with dockerd's status codes and
  # messages where a client may match them.

  alias Opsmaru.Containers.Host

  alias Opsmaru.Containers.Native.{
    Container,
    Images,
    Listing,
    Names,
    Resolver,
    RunRecord,
    Shim,
    Signal,
    Target,
    Translate
  }

  @poll 100
  @default_stop 10
  @backstop 10_000
  @exec_grace 2_000
  @kill_wait 10_000
  @running ["Running", "Starting", "Stopping"]
  @zero_time "0001-01-01T00:00:00Z"
  @not_recorded "native: exit status not recorded"

  # -- Create ------------------------------------------------------------------

  @doc """
  Creates a native container from a create body the host routed to native.
  Every refusal is decided before the image handoff and the instance create.
  """
  def create(%{target: %{native: nil}}, _, _, _, _, _),
    do: {:error, 501, "native engine: the target has no native project"}

  def create(context, host, query, body, api_version, deadline) do
    native = context.target.native

    with {:ok, decoded} <- decode(body),
         {:ok, name} <- create_name(query["name"]),
         {:ok, prepared} <- Translate.prepare(decoded, mapper(host, context, deadline)),
         {:ok, containers} <- Resolver.containers(context, deadline),
         :nested <- Names.check_native(containers, name, :create),
         :ok <- nested_name(context, name, api_version, deadline),
         {:ok, %{fingerprint: fingerprint, image: image}} <-
           Images.ensure(context, Translate.image(prepared), api_version, deadline),
         {:ok, shim} <- shim(native, image["Architecture"]),
         {:ok, translated} <- Translate.finish(prepared, image) do
      attributes = %{
        name: name,
        fingerprint: fingerprint,
        image: image,
        image_ref: Translate.image(prepared),
        shim: shim,
        translated: translated
      }

      Container.create(deadline, &create_instance(native, attributes, &1, &2, deadline))
      |> created()
    end
  end

  defp created({:ok, id}), do: {:ok, 201, %{"Id" => id, "Warnings" => []}}
  defp created({:error, :deadline}), do: {:error, 503, "native engine: Incus is not available"}
  defp created(error), do: error

  defp create_instance(native, attributes, id, instance, deadline) do
    %{translated: translated, image: image} = attributes
    short = binary_part(id, 0, 12)
    hostname = translated.hostname || short
    spec = Map.put(translated.spec, "hostname", hostname)
    docker = put_in(translated.docker, ["Config", "Hostname"], hostname)

    keys =
      Container.keys(%{
        id: id,
        name: attributes.name || instance,
        created: DateTime.utc_now(),
        image_id: image["Id"],
        image_ref: attributes.image_ref,
        labels: translated.labels,
        config: docker,
        init: attributes.shim.sha256,
        autoremove: translated.autoremove
      })

    body = %{
      "name" => instance,
      "type" => "container",
      "source" => %{"type" => "image", "fingerprint" => attributes.fingerprint},
      "config" => Map.merge(translated.config, keys),
      "devices" => translated.devices,
      "start" => false
    }

    case native.backend.create_instance(native.client, body, deadline) do
      :ok ->
        push(native, instance, id, attributes.shim, spec, deadline)

      {:error, :conflict} ->
        {:error, :conflict}

      {:error, :uncertain} ->
        # The instance name holds this create's random ID, so an instance by
        # that name is this create's. It is removed rather than trusted.
        native.backend.delete_instance(native.client, instance, deadline)

        {:error, 500, "native engine: the instance create outcome is unknown; it was not retried"}

      {:error, _} ->
        {:error, 500, "native engine: Incus refused the instance"}
    end
  end

  defp push(native, instance, id, shim, spec, deadline) do
    case Shim.push(native, instance, shim, spec, deadline) do
      :ok ->
        {:ok, id}

      error ->
        native.backend.delete_instance(native.client, instance, deadline)
        error
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      _ -> {:error, 400, "Invalid Docker JSON request"}
    end
  end

  defp create_name(nil), do: {:ok, nil}
  defp create_name(""), do: {:ok, nil}

  defp create_name(name) do
    if Container.valid_name?(name),
      do: {:ok, String.trim_leading(name, "/")},
      else: invalid_name(name)
  end

  defp invalid_name(name),
    do:
      {:error, 400,
       "Invalid container name (#{name}), only [a-zA-Z0-9][a-zA-Z0-9_.-] are allowed"}

  defp nested_name(_, nil, _, _), do: :ok

  defp nested_name(context, name, api, deadline),
    do: Names.check_nested(context, name, api, deadline)

  defp mapper(host, context, deadline) do
    if Code.ensure_loaded?(host) and function_exported?(host, :map_bind_source, 2),
      do: &map_source(host, context, &1, deadline)
  end

  defp map_source(host, context, source, deadline) do
    case Host.decide(host, :map_bind_source, [context, source], deadline) do
      {:ok, {:ok, "/" <> _ = mapped}} ->
        if Regex.match?(~r/[[:cntrl:]]/, mapped), do: :deny, else: {:ok, mapped}

      _ ->
        :deny
    end
  end

  defp shim(native, architecture) do
    case Target.shim(native, architecture) do
      {:ok, shim} ->
        {:ok, shim}

      {:error, _} ->
        {:error, 400,
         "native engine: no init shim is configured for image architecture #{inspect(architecture)}"}
    end
  end

  # -- Start -------------------------------------------------------------------

  @doc """
  Starts a container and waits until the shim reports the run started or
  failed. A failed `execve` is answered as dockerd answers it.
  """
  def start(context, container, deadline) do
    native = context.target.native

    cond do
      container.status == "Frozen" ->
        {:error, 409, "cannot start a paused container, try unpause instead"}

      container.status in @running ->
        {:ok, 304}

      true ->
        with {:ok, previous} <- record(native, container, deadline),
             {:ok, record} <- start_run(native, container, run(previous), deadline) do
          start_result(record)
        end
    end
  end

  defp start_result(%RunRecord{error: nil}), do: {:ok, 204}

  defp start_result(%RunRecord{error: error, exit_code: code}) when code in [126, 127],
    do: {:error, 400, "native engine: failed to start container process: " <> error}

  defp start_result(%RunRecord{error: error}),
    do: {:error, 500, "native engine: failed to start container process: " <> error}

  # Incus may report a failed start when the entrypoint exits at once. The
  # shim's record, when it wrote one, still says why.
  defp start_run(native, container, previous, deadline) do
    case change(native, container, "start", false, deadline) do
      :ok ->
        started(native, container, previous, deadline)

      error ->
        case new_run(native, container, previous, deadline) do
          {:ok, %RunRecord{} = record} -> {:ok, record}
          _ -> error
        end
    end
  end

  defp started(native, container, previous, deadline) do
    with {:ok, :pending} <- new_run(native, container, previous, deadline),
         {:ok, %{"status" => status}} when status != "Stopped" <-
           instance_state(native, container, deadline) do
      if now() + @poll < deadline do
        Process.sleep(@poll)
        started(native, container, previous, deadline)
      else
        {:error, 500, "native engine: the container did not report its start in time"}
      end
    else
      {:ok, %RunRecord{} = record} ->
        {:ok, record}

      {:ok, %{"status" => "Stopped"}} ->
        stopped_before_record(native, container, previous, deadline)

      error ->
        error
    end
  end

  # The record may have landed between the two reads.
  defp stopped_before_record(native, container, previous, deadline) do
    case new_run(native, container, previous, deadline) do
      {:ok, %RunRecord{} = record} ->
        {:ok, record}

      {:ok, :pending} ->
        {:error, 500,
         "native engine: container #{container.id} stopped before its init shim recorded a start"}

      error ->
        error
    end
  end

  # The run after `previous`, once the shim recorded its start or failure.
  defp new_run(native, container, previous, deadline) do
    case record(native, container, deadline) do
      {:ok, %RunRecord{run: run} = record} when run > previous ->
        if record.pid != nil or record.error != nil or record.finished_at != nil,
          do: {:ok, record},
          else: {:ok, :pending}

      {:ok, :malformed} ->
        {:error, 500, "native engine: the run record of container #{container.id} is malformed"}

      {:ok, _} ->
        {:ok, :pending}

      error ->
        error
    end
  end

  # -- Stop, kill, restart -------------------------------------------------------

  @doc "Docker stop: the stop signal through the shim, SIGKILL after `t`."
  def stop(context, container, query, deadline) do
    with {:ok, timeout} <- stop_timeout(query["t"], container),
         {:ok, signal} <- optional_signal(query["signal"]),
         {:running, true} <- {:running, container.status in ["Frozen" | @running]},
         :ok <- halt(context.target.native, container, signal, timeout, deadline) do
      {:ok, 204}
    else
      {:running, false} -> {:ok, 304}
      error -> error
    end
  end

  @doc "Docker restart: stop with the same rules, then start."
  def restart(context, container, query, deadline) do
    native = context.target.native

    with {:ok, timeout} <- stop_timeout(query["t"], container),
         {:ok, signal} <- optional_signal(query["signal"]),
         :ok <- restart_halt(native, container, signal, timeout, deadline),
         {:ok, status} when status in [204, 304] <-
           start(context, %{container | status: "Stopped"}, deadline) do
      {:ok, 204}
    end
  end

  defp restart_halt(native, container, signal, timeout, deadline) do
    if container.status in ["Frozen" | @running],
      do: halt(native, container, signal, timeout, deadline),
      else: :ok
  end

  defp halt(native, container, signal, timeout, deadline) do
    command =
      [Shim.init_path(), "stop", "--timeout", Integer.to_string(timeout)] ++
        if(signal, do: ["--signal", signal], else: [])

    backstop = if timeout < 0, do: deadline, else: now() + timeout * 1_000 + @backstop

    with :ok <- thaw(native, container, deadline) do
      wait_until =
        case shim(native, container, command, deadline) do
          :ok -> min(backstop, deadline)
          :failed -> min(now() + @exec_grace, deadline)
        end

      stopped_or_forced(native, container, wait_until, deadline)
    end
  end

  @doc "Docker kill: any signal through the shim; SIGKILL falls back to a forced stop."
  def kill(context, container, query, deadline) do
    native = context.target.native
    value = if query["signal"] in [nil, ""], do: "SIGKILL", else: query["signal"]

    case Signal.parse(value) do
      :error -> {:error, 400, "Invalid signal: #{value}"}
      {:ok, signal} -> deliver(native, container, signal, deadline)
    end
  end

  defp deliver(native, container, signal, deadline) do
    cond do
      container.status not in ["Frozen" | @running] ->
        {:error, 409, "Container #{container.id} is not running"}

      container.status == "Frozen" and signal != "SIGKILL" ->
        {:error, 409,
         "Container #{container.id} is paused. Unpause the container before stopping or killing"}

      container.status == "Frozen" ->
        with :ok <- force(native, container, deadline), do: {:ok, 204}

      true ->
        signal_running(native, container, signal, deadline)
    end
  end

  defp signal_running(native, container, signal, deadline) do
    case {shim(native, container, [Shim.init_path(), "kill", signal], deadline), signal} do
      {:ok, "SIGKILL"} ->
        with :ok <-
               stopped_or_forced(native, container, min(now() + @kill_wait, deadline), deadline),
             do: {:ok, 204}

      {:ok, _} ->
        {:ok, 204}

      {:failed, "SIGKILL"} ->
        with :ok <- force(native, container, deadline), do: {:ok, 204}

      {:failed, _} ->
        {:error, 409, "Container #{container.id} is not running"}
    end
  end

  # -- Pause, unpause --------------------------------------------------------------

  def pause(context, container, deadline) do
    case container.status do
      "Frozen" -> {:error, 409, "Container #{container.id} is already paused"}
      status when status in @running -> changed(context, container, "freeze", deadline)
      _ -> {:error, 409, "Container #{container.id} is not running"}
    end
  end

  def unpause(context, container, deadline) do
    if container.status == "Frozen",
      do: changed(context, container, "unfreeze", deadline),
      else: {:error, 409, "Container #{container.id} is not paused"}
  end

  defp changed(context, container, action, deadline) do
    with :ok <- change(context.target.native, container, action, false, deadline), do: {:ok, 204}
  end

  # -- Rename ----------------------------------------------------------------------

  @doc "Docker rename: rewrites the name key. The instance name stays."
  def rename(context, container, query, api_version, deadline) do
    native = context.target.native
    name = query["name"] || ""
    bare = String.trim_leading(name, "/")

    cond do
      bare == "" ->
        {:error, 400, "Neither old nor new names may be empty"}

      not Container.valid_name?(name) ->
        invalid_name(name)

      bare == container.name ->
        {:error, 400, "Renaming a container with the same name as its current name"}

      true ->
        with {:ok, containers} <- Resolver.containers(context, deadline),
             :nested <- Names.check_native(containers, bare, :rename),
             :ok <- Names.check_nested(context, bare, api_version, deadline, :rename),
             :ok <- patch(native, container, %{Container.name_key() => bare}, deadline) do
          {:ok, 204}
        end
    end
  end

  # -- Remove ----------------------------------------------------------------------

  @doc "Docker remove: a running container needs `force`, which kills it first."
  def remove(context, container, query, deadline) do
    native = context.target.native

    cond do
      truthy?(query["link"]) ->
        {:error, 400, "native engine: native containers have no links to remove"}

      container.status in ["Frozen" | @running] and not truthy?(query["force"]) ->
        {:error, 409,
         ~s(cannot remove container "/#{container.name}": container is running: ) <>
           "stop the container before removing or force remove"}

      true ->
        with :ok <- remove_running(native, container, deadline),
             :ok <- delete(native, container, deadline) do
          {:ok, 204}
        end
    end
  end

  defp remove_running(native, container, deadline) do
    if container.status in ["Frozen" | @running],
      do: force(native, container, deadline),
      else: :ok
  end

  @doc false
  def delete(native, container, deadline) do
    case native.backend.delete_instance(native.client, container.instance, deadline) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      _ -> {:error, 500, "native engine: Incus could not delete container #{container.id}"}
    end
  end

  # -- Inspect ---------------------------------------------------------------------

  @doc "Docker inspect, synthesised from the instance, its state, config and run record."
  def inspect(context, container, deadline) do
    native = context.target.native

    with {:ok, state} <- instance_state(native, container, deadline),
         {:ok, record} <- record(native, container, deadline),
         :ok <- well_formed(record, container) do
      container = %{container | status: state["status"]}
      {:ok, 200, inspect_body(container, state, record)}
    end
  end

  defp well_formed(:malformed, container) do
    {:error, 500, "native engine: the run record of container #{container.id} is malformed"}
  end

  defp well_formed(_, _), do: :ok

  defp inspect_body(container, state, record) do
    config = container.config
    docker_state = docker_state(container, record)
    host_config = config["HostConfig"] || %{}

    %{
      "Id" => container.id,
      "Created" => DateTime.to_iso8601(container.created),
      "Path" => config["Path"],
      "Args" => config["Args"] || [],
      "State" => docker_state,
      "Image" => container.image_id,
      "ResolvConfPath" => "",
      "HostnamePath" => "",
      "HostsPath" => "",
      "LogPath" => "",
      "Name" => "/" <> container.name,
      "RestartCount" => 0,
      "Driver" => "incus",
      "Platform" => "linux",
      "MountLabel" => "",
      "ProcessLabel" => "",
      "AppArmorProfile" => "",
      "ExecIDs" => exec_ids(container),
      "HostConfig" => host_config,
      "GraphDriver" => %{"Name" => "incus", "Data" => nil},
      "Mounts" => config["Mounts"] || [],
      "Config" => Map.put(config["Config"] || %{}, "Labels", container.labels),
      "NetworkSettings" => network_settings(host_config["NetworkMode"], state)
    }
  end

  defp docker_state(container, record) do
    summary = Listing.state(container, record, DateTime.utc_now())
    finished? = summary.state == "exited"

    error =
      cond do
        not finished? -> ""
        match?(%RunRecord{exit_code: nil}, record) -> @not_recorded
        match?(%RunRecord{error: e} when is_binary(e), record) -> record.error
        true -> ""
      end

    %{
      "Status" => summary.state,
      "Running" => summary.state in ["running", "paused"],
      "Paused" => summary.state == "paused",
      "Restarting" => false,
      "OOMKilled" => match?(%RunRecord{oom_killed: true}, record) and finished?,
      "Dead" => false,
      "Pid" => pid(summary.state, record),
      "ExitCode" => summary.exit_code,
      "Error" => error,
      "StartedAt" => time(summary.started_at),
      "FinishedAt" => time(summary.finished_at)
    }
  end

  defp pid(state, %RunRecord{pid: pid}) when state in ["running", "paused"] and is_integer(pid),
    do: pid

  defp pid(_, _), do: 0

  defp time(nil), do: @zero_time
  defp time(%DateTime{} = time), do: DateTime.to_iso8601(time)

  defp exec_ids(%{execs: execs}) when map_size(execs) == 0, do: nil
  defp exec_ids(%{execs: execs}), do: Map.keys(execs)

  defp network_settings(mode, state) do
    networks =
      case {mode || "bridge", address(state)} do
        {"none", _} -> %{}
        {name, address} -> %{name => endpoint(address, state)}
      end

    %{"Networks" => networks, "Ports" => %{}, "SandboxID" => "", "SandboxKey" => ""}
  end

  defp address(state) do
    get_in(state, ["network", "eth0", "addresses"])
    |> List.wrap()
    |> Enum.find(&(is_map(&1) and &1["family"] == "inet" and &1["scope"] in [nil, "global"]))
  end

  defp endpoint(address, state) do
    %{
      "IPAddress" => (address && address["address"]) || "",
      "IPPrefixLen" => prefix(address),
      "MacAddress" => get_in(state, ["network", "eth0", "hwaddr"]) || "",
      "Gateway" => "",
      "NetworkID" => "",
      "EndpointID" => "",
      "Aliases" => nil,
      "DNSNames" => nil
    }
  end

  defp prefix(%{"netmask" => netmask}) when is_binary(netmask) do
    case Integer.parse(netmask) do
      {bits, ""} -> bits
      _ -> 0
    end
  end

  defp prefix(_), do: 0

  # -- Shared --------------------------------------------------------------------

  @doc false
  def record(native, container, deadline) do
    case RunRecord.read(native, container, deadline) do
      {:ok, record} -> {:ok, record}
      {:error, _} -> {:error, 503, "native engine: Incus is not available"}
    end
  end

  defp run(%RunRecord{run: run}), do: run
  defp run(_), do: 0

  @doc false
  def instance_state(native, container, deadline) do
    case native.backend.instance_state(native.client, container.instance, deadline) do
      {:ok, state} -> {:ok, state}
      {:error, :not_found} -> {:error, 404, "No such container: #{container.id}"}
      {:error, _} -> {:error, 503, "native engine: Incus is not available"}
    end
  end

  defp change(native, container, action, force, deadline) do
    case native.backend.update_state(native.client, container.instance, action, force, deadline) do
      :ok -> :ok
      {:error, :not_found} -> {:error, 404, "No such container: #{container.id}"}
      _ -> {:error, 500, "native engine: Incus could not #{action} container #{container.id}"}
    end
  end

  defp patch(native, container, config, deadline) do
    case native.backend.patch_config(native.client, container.instance, config, deadline) do
      :ok -> :ok
      {:error, :not_found} -> {:error, 404, "No such container: #{container.id}"}
      _ -> {:error, 500, "native engine: Incus could not update container #{container.id}"}
    end
  end

  # Incus refuses exec into a frozen instance.
  defp thaw(native, %{status: "Frozen"} = container, deadline),
    do: change(native, container, "unfreeze", false, deadline)

  defp thaw(_, _, _), do: :ok

  defp shim(native, container, command, deadline) do
    case native.backend.exec(native.client, container.instance, command, deadline) do
      {:ok, %{status: 0}} -> :ok
      _ -> :failed
    end
  end

  # Waits for the instance to stop, then forces the stop as the backstop.
  defp stopped_or_forced(native, container, wait_until, deadline) do
    case await_stopped(native, container, wait_until) do
      :ok -> :ok
      :timeout -> force(native, container, deadline)
      error -> error
    end
  end

  defp force(native, container, deadline) do
    with :ok <- change(native, container, "stop", true, deadline) do
      case await_stopped(native, container, deadline) do
        :timeout -> {:error, 500, "native engine: container #{container.id} did not stop"}
        result -> result
      end
    end
  end

  defp await_stopped(native, container, until) do
    case native.backend.instance_state(native.client, container.instance, until) do
      {:ok, %{"status" => "Stopped"}} ->
        :ok

      {:error, :not_found} ->
        :ok

      _ ->
        if now() + @poll < until do
          Process.sleep(@poll)
          await_stopped(native, container, until)
        else
          :timeout
        end
    end
  end

  defp stop_timeout(nil, container), do: {:ok, configured_timeout(container)}
  defp stop_timeout("", container), do: {:ok, configured_timeout(container)}

  defp stop_timeout(value, _) do
    case Integer.parse(value) do
      {timeout, ""} when timeout >= -1 -> {:ok, timeout}
      _ -> {:error, 400, "invalid value for t: #{value}"}
    end
  end

  defp configured_timeout(container) do
    case get_in(container.config, ["Config", "StopTimeout"]) do
      timeout when is_integer(timeout) -> timeout
      _ -> @default_stop
    end
  end

  defp optional_signal(value) when value in [nil, ""], do: {:ok, nil}

  defp optional_signal(value) do
    case Signal.parse(value) do
      {:ok, signal} -> {:ok, signal}
      :error -> {:error, 400, "Invalid signal: #{value}"}
    end
  end

  defp truthy?(value), do: value in ["1", "true", "True", "TRUE"]

  defp now, do: System.monotonic_time(:millisecond)
end
