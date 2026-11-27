defmodule Opsmaru.Containers.Native.TranslateTest do
  use ExUnit.Case, async: true

  alias Opsmaru.Containers.Native
  alias Opsmaru.Containers.Native.Translate

  @table "priv/docker/native-create.json" |> File.read!() |> Jason.decode!()

  @image %{
    "Id" => "sha256:" <> String.duplicate("a", 64),
    "Architecture" => "arm64",
    "Config" => %{
      "Entrypoint" => ["/docker-entrypoint.sh"],
      "Cmd" => ["nginx", "-g", "daemon off;"],
      "Env" => ["PATH=/usr/local/bin:/usr/bin:/bin", "NGINX_VERSION=1.29.3", "MODE=image"],
      "WorkingDir" => "/srv",
      "User" => "nginx",
      "StopSignal" => "SIGQUIT",
      "Labels" => %{"maintainer" => "image", "tier" => "image"},
      "ExposedPorts" => %{"80/tcp" => %{}}
    }
  }

  # What docker CLI 29 sends for `docker run -d nginx`, zero values included.
  @cli_body %{
    "Hostname" => "",
    "Domainname" => "",
    "User" => "",
    "AttachStdin" => false,
    "AttachStdout" => false,
    "AttachStderr" => false,
    "Tty" => false,
    "OpenStdin" => false,
    "StdinOnce" => false,
    "Env" => nil,
    "Cmd" => nil,
    "Image" => "nginx",
    "Volumes" => nil,
    "WorkingDir" => "",
    "Entrypoint" => nil,
    "OnBuild" => nil,
    "Labels" => %{},
    "HostConfig" => %{
      "Binds" => nil,
      "ContainerIDFile" => "",
      "LogConfig" => %{"Type" => "", "Config" => %{}},
      "NetworkMode" => "default",
      "PortBindings" => %{},
      "RestartPolicy" => %{"Name" => "no", "MaximumRetryCount" => 0},
      "AutoRemove" => false,
      "VolumeDriver" => "",
      "VolumesFrom" => nil,
      "ConsoleSize" => [24, 80],
      "CapAdd" => nil,
      "CapDrop" => nil,
      "CgroupnsMode" => "",
      "Dns" => [],
      "DnsOptions" => [],
      "DnsSearch" => [],
      "ExtraHosts" => nil,
      "GroupAdd" => nil,
      "IpcMode" => "",
      "Cgroup" => "",
      "Links" => nil,
      "OomScoreAdj" => 0,
      "PidMode" => "",
      "Privileged" => false,
      "PublishAllPorts" => false,
      "ReadonlyRootfs" => false,
      "SecurityOpt" => nil,
      "UTSMode" => "",
      "UsernsMode" => "",
      "ShmSize" => 0,
      "Isolation" => "",
      "CpuShares" => 0,
      "Memory" => 0,
      "NanoCpus" => 0,
      "CgroupParent" => "",
      "BlkioWeight" => 0,
      "BlkioWeightDevice" => [],
      "CpuPeriod" => 0,
      "CpuQuota" => 0,
      "CpusetCpus" => "",
      "Devices" => [],
      "DeviceCgroupRules" => nil,
      "DeviceRequests" => nil,
      "MemoryReservation" => 0,
      "MemorySwap" => 0,
      "MemorySwappiness" => nil,
      "OomKillDisable" => false,
      "PidsLimit" => nil,
      "Ulimits" => [],
      "MaskedPaths" => nil,
      "ReadonlyPaths" => nil
    },
    "NetworkingConfig" => %{"EndpointsConfig" => %{}}
  }

  test "a docker CLI body with only zero values is eligible" do
    assert :ok = Native.eligibility(@cli_body)
    assert {:ok, prepared} = Translate.prepare(@cli_body, nil)
    assert {:ok, translated} = Translate.finish(prepared, @image)

    assert translated.spec == %{
             "version" => 1,
             "argv" => ["/docker-entrypoint.sh", "nginx", "-g", "daemon off;"],
             "env" => ["PATH=/usr/local/bin:/usr/bin:/bin", "NGINX_VERSION=1.29.3", "MODE=image"],
             "cwd" => "/srv",
             "user" => "nginx",
             "group_add" => [],
             "stop_signal" => "SIGQUIT",
             "log" => %{"driver" => "local", "max_size" => 20_971_520, "max_files" => 5}
           }

    assert translated.config == %{
             "oci.entrypoint" => "/.opsmaru/init",
             "oci.uid" => "0",
             "oci.gid" => "0",
             "oci.cwd" => "/"
           }

    assert translated.devices == %{}
    assert translated.hostname == nil
    assert translated.labels == %{"maintainer" => "image", "tier" => "image"}
    refute translated.autoremove
  end

  test "every refused field with a non-default value is named, before anything else" do
    refused = for %{"class" => "refused", "field" => field} <- @table["fields"], do: field
    assert length(refused) == 59

    for field <- refused do
      body = put_field(%{"Image" => "nginx"}, field, 1)
      message = "native engine cannot honour: " <> field

      assert {:error, 400, ^message} = Translate.prepare(body, nil), field
      assert {:error, [^field]} = Native.eligibility(body)
    end
  end

  test "refused fields are all named in one answer, sorted" do
    body = %{
      "Image" => "nginx",
      "Tty" => true,
      "HostConfig" => %{
        "PortBindings" => %{"80/tcp" => [%{"HostPort" => "8080"}]},
        "Privileged" => true
      }
    }

    assert {:error, 400,
            "native engine cannot honour: HostConfig.PortBindings, HostConfig.Privileged, Tty"} =
             Translate.prepare(body, nil)
  end

  test "documented non-zero defaults are accepted" do
    body = %{
      "Image" => "nginx",
      "HostConfig" => %{"MemorySwappiness" => -1, "Isolation" => "default"}
    }

    assert :ok = Native.eligibility(body)

    assert {:error, ["HostConfig.MaskedPaths"]} =
             Native.eligibility(%{"HostConfig" => %{"MaskedPaths" => []}})
  end

  test "unknown fields are refused unless at their default, and names match without case" do
    assert {:error, ["HostConfig.KernelMemory"]} =
             Native.eligibility(%{"hostconfig" => %{"KernelMemory" => 5}})

    assert {:error, ["Frobnicate"]} = Native.eligibility(%{"Frobnicate" => true})
    assert :ok = Native.eligibility(%{"Frobnicate" => nil, "MacAddress" => ""})
    assert {:error, ["Tty"]} = Native.eligibility(%{"tty" => true})

    assert {:error, 400, "invalid JSON: duplicate field names"} =
             Translate.prepare(%{"Image" => "a", "image" => "b"}, nil)
  end

  test "translated fields become spec fields, Incus keys and devices" do
    body = %{
      "Hostname" => "web-1",
      "User" => "101:101",
      "Env" => ["MODE=create", "EXTRA=1", "NGINX_VERSION"],
      "Cmd" => ["printf", "%s|", "$HOME", "a b"],
      "Entrypoint" => [""],
      "Image" => "nginx",
      "WorkingDir" => "/work",
      "Labels" => %{"tier" => "create"},
      "StopSignal" => "hup",
      "StopTimeout" => 30,
      "HostConfig" => %{
        "Memory" => 268_435_456,
        "NanoCpus" => 1_500_000_000,
        "CpusetCpus" => "0-1",
        "PidsLimit" => 64,
        "Binds" => ["/data:/data:ro", "/cache:/var/cache"],
        "Mounts" => [
          %{"Type" => "bind", "Source" => "/logs", "Target" => "/logs", "ReadOnly" => true}
        ],
        "LogConfig" => %{
          "Type" => "json-file",
          "Config" => %{"max-size" => "10m", "max-file" => "3"}
        },
        "NetworkMode" => "bridge",
        "RestartPolicy" => %{"Name" => "no"},
        "AutoRemove" => true,
        "Dns" => ["10.0.0.2", "10.0.0.3"],
        "DnsSearch" => ["example.internal"],
        "GroupAdd" => ["audio"]
      },
      "NetworkingConfig" => %{"EndpointsConfig" => %{"bridge" => %{"Aliases" => nil}}}
    }

    mapper = fn source -> {:ok, "/srv/host" <> source} end
    assert {:ok, prepared} = Translate.prepare(body, mapper)
    assert {:ok, t} = Translate.finish(prepared, @image)

    assert t.spec["argv"] == ["printf", "%s|", "$HOME", "a b"]
    assert t.spec["env"] == ["MODE=create", "EXTRA=1", "PATH=/usr/local/bin:/usr/bin:/bin"]
    assert t.spec["cwd"] == "/work"
    assert t.spec["user"] == "101:101"
    assert t.spec["group_add"] == ["audio"]
    assert t.spec["stop_signal"] == "SIGHUP"
    assert t.spec["log"] == %{"driver" => "local", "max_size" => 10_485_760, "max_files" => 3}
    assert t.hostname == "web-1"
    assert t.autoremove
    assert t.labels == %{"maintainer" => "image", "tier" => "create"}

    assert Map.drop(t.config, ["oci.entrypoint", "oci.uid", "oci.gid", "oci.cwd"]) == %{
             "limits.memory" => "268435456B",
             "limits.cpu.allowance" => "150ms/100ms",
             "limits.cpu" => "0-1",
             "limits.processes" => "64",
             "oci.dns.nameservers" => "10.0.0.2,10.0.0.3",
             "oci.dns.search" => "example.internal"
           }

    assert t.devices == %{
             "bind0" => %{
               "type" => "disk",
               "source" => "/srv/host/data",
               "path" => "/data",
               "readonly" => "true"
             },
             "bind1" => %{
               "type" => "disk",
               "source" => "/srv/host/cache",
               "path" => "/var/cache",
               "readonly" => "false"
             },
             "bind2" => %{
               "type" => "disk",
               "source" => "/srv/host/logs",
               "path" => "/logs",
               "readonly" => "true"
             }
           }

    assert t.docker["Path"] == "printf"
    assert t.docker["Args"] == ["%s|", "$HOME", "a b"]

    assert t.docker["Config"]["Env"] == [
             "MODE=create",
             "EXTRA=1",
             "NGINX_VERSION",
             "PATH=/usr/local/bin:/usr/bin:/bin"
           ]

    assert t.docker["Config"]["Entrypoint"] == nil
    assert t.docker["Config"]["StopTimeout"] == 30
    assert t.docker["HostConfig"]["NetworkMode"] == "bridge"
    assert t.docker["HostConfig"]["AutoRemove"]
    assert [%{"Destination" => "/data", "RW" => false} | _] = t.docker["Mounts"]
  end

  test "Docker's entrypoint and command merge rules" do
    finish = fn body ->
      {:ok, prepared} = Translate.prepare(Map.put(body, "Image", "nginx"), nil)
      with {:ok, t} <- Translate.finish(prepared, @image), do: t.spec["argv"]
    end

    assert finish.(%{}) == ["/docker-entrypoint.sh", "nginx", "-g", "daemon off;"]
    assert finish.(%{"Cmd" => ["sh"]}) == ["/docker-entrypoint.sh", "sh"]
    assert finish.(%{"Entrypoint" => ["/bin/sh", "-c"]}) == ["/bin/sh", "-c"]
    assert finish.(%{"Entrypoint" => [], "Cmd" => []}) == ["nginx", "-g", "daemon off;"]
    assert finish.(%{"Entrypoint" => [""], "Cmd" => ["id"]}) == ["id"]
    assert {:error, 400, "No command specified"} = finish.(%{"Entrypoint" => [""]})
  end

  test "network none and NetworkDisabled replace eth0" do
    for body <- [%{"HostConfig" => %{"NetworkMode" => "none"}}, %{"NetworkDisabled" => true}] do
      {:ok, prepared} = Translate.prepare(Map.put(body, "Image", "nginx"), nil)
      {:ok, t} = Translate.finish(prepared, @image)
      assert t.devices == %{"eth0" => %{"type" => "none"}}
    end
  end

  test "CPU quota and period become an allowance" do
    {:ok, prepared} =
      Translate.prepare(
        %{"Image" => "a", "HostConfig" => %{"CpuQuota" => 50_000, "CpuPeriod" => 200_000}},
        nil
      )

    {:ok, t} = Translate.finish(prepared, @image)
    assert t.config["limits.cpu.allowance"] == "50ms/200ms"
  end

  test "translated fields with values native cannot honour are refused by name" do
    cases = [
      {"HostConfig.NetworkMode", %{"HostConfig" => %{"NetworkMode" => "host"}}},
      {"HostConfig.NetworkMode", %{"HostConfig" => %{"NetworkMode" => "container:web"}}},
      {"HostConfig.RestartPolicy",
       %{"HostConfig" => %{"RestartPolicy" => %{"Name" => "always"}}}},
      {"HostConfig.LogConfig", %{"HostConfig" => %{"LogConfig" => %{"Type" => "syslog"}}}},
      {"HostConfig.LogConfig",
       %{
         "HostConfig" => %{
           "LogConfig" => %{"Type" => "local", "Config" => %{"compress" => "true"}}
         }
       }},
      {"HostConfig.LogConfig",
       %{"HostConfig" => %{"LogConfig" => %{"Config" => %{"max-size" => "1k"}}}}},
      {"HostConfig.Binds", %{"HostConfig" => %{"Binds" => ["named:/data"]}}},
      {"HostConfig.Binds", %{"HostConfig" => %{"Binds" => ["/data:/.opsmaru/x"]}}},
      {"HostConfig.Binds", %{"HostConfig" => %{"Binds" => ["/data:/"]}}},
      {"HostConfig.Binds", %{"HostConfig" => %{"Binds" => ["/data:/data:z"]}}},
      {"HostConfig.Mounts",
       %{
         "HostConfig" => %{"Mounts" => [%{"Type" => "volume", "Source" => "v", "Target" => "/v"}]}
       }},
      {"HostConfig.Mounts",
       %{
         "HostConfig" => %{
           "Mounts" => [%{"Type" => "bind", "Source" => "/a", "Target" => "/.opsmaru"}]
         }
       }},
      {"HostConfig.NanoCpus",
       %{"HostConfig" => %{"NanoCpus" => 1_000_000_000, "CpuQuota" => 50_000}}},
      {"HostConfig.Memory", %{"HostConfig" => %{"Memory" => 1024}}},
      {"HostConfig.CpusetCpus", %{"HostConfig" => %{"CpusetCpus" => "all"}}},
      {"NetworkingConfig.EndpointsConfig",
       %{"NetworkingConfig" => %{"EndpointsConfig" => %{"other" => %{}}}}},
      {"NetworkingConfig.EndpointsConfig",
       %{
         "NetworkingConfig" => %{"EndpointsConfig" => %{"bridge" => %{"IPAddress" => "10.0.0.9"}}}
       }},
      {"Env", %{"Env" => ["=x"]}},
      {"StopSignal", %{"StopSignal" => "SIGNOPE"}},
      {"Hostname", %{"Hostname" => "bad/name"}}
    ]

    for {field, body} <- cases do
      assert {:error, [^field]} = Native.eligibility(body), inspect(body)
    end
  end

  test "binds need the host's mapping, and a denied source is named" do
    body = %{"Image" => "a", "HostConfig" => %{"Binds" => ["/data:/data"]}}

    assert {:error, 400,
            "native engine cannot honour: HostConfig.Binds (the host maps no bind sources)"} =
             Translate.prepare(body, nil)

    assert {:error, 400, "invalid mount config: bind source path /data is not allowed"} =
             Translate.prepare(body, fn _ -> :deny end)
  end

  defp put_field(body, field, value) do
    case String.split(field, ".") do
      [name] -> Map.put(body, name, value)
      [group, name] -> Map.update(body, group, %{name => value}, &Map.put(&1, name, value))
    end
  end
end
