defmodule Opsmaru.Containers.Native.LifecycleTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Elixir.Plug.{Conn, Test}
  alias Opsmaru.Containers.Docker.Plug
  alias Opsmaru.Containers.Native.{Container, Images, Lifecycle, LogRecord, RunRecord}
  alias Opsmaru.Containers.TestSupport.{EngineFixture, ScriptedIncus}

  @web "aaaa1111" <> String.duplicate("1", 56)
  @old "bbbb2222" <> String.duplicate("2", 56)
  @record "/.opsmaru/state/run.json"
  @image_id "sha256:" <> String.duplicate("b", 64)
  @init "/.opsmaru/init"

  defmodule NativeHost do
    @moduledoc false
    @behaviour Opsmaru.Containers.Host

    @impl true
    def context(%{host_peer: {context, _}}), do: {:ok, context}

    @impl true
    def authorize(_, _), do: :allow

    @impl true
    def select_engine(_, _), do: :native

    @impl true
    def map_bind_source(_, "/denied" <> _), do: :deny
    def map_bind_source(_, source), do: {:ok, "/host" <> source}
  end

  setup %{tmp_dir: tmp_dir} do
    engine = EngineFixture.start()
    shim_path = Path.join(tmp_dir, "init-arm64")
    shim_bytes = "shim-binary-" <> :crypto.strong_rand_bytes(16)
    File.write!(shim_path, shim_bytes)
    digest = :crypto.hash(:sha256, shim_bytes) |> Base.encode16(case: :lower)

    native =
      ScriptedIncus.target(
        instances: [instance(@web, "web", "Running"), instance(@old, "old", "Stopped")],
        images: [
          %{"fingerprint" => "fp-nginx", "properties" => %{Images.property() => @image_id}}
        ],
        files: %{
          {Container.instance_name(@web), @record} => record(1, nil, nil),
          {Container.instance_name(@old), @record} => record(2, ago(60), 3)
        },
        exec: fn _, _ -> {:ok, %{status: 0, stdout: "", stderr: ""}} end
      )

    # Requests through the Plug need a target with the library's shim
    # digests, whose binary the tests do not have. Creates called directly
    # use a scratch shim, over the same scripted Incus.
    context = with_native(EngineFixture.context(engine), native)
    scratch = %{native | init: %{"aarch64" => %{path: shim_path, sha256: digest}}}

    %{
      engine: engine,
      context: context,
      create_context: with_native(context, scratch),
      native: native,
      shim: shim_bytes,
      shim_path: shim_path
    }
  end

  describe "create" do
    test "creates the instance, pushes the shim and spec, and answers dockerd's 201", %{
      engine: engine,
      create_context: context,
      shim: shim
    } do
      body =
        ~s({"Image":"nginx","Cmd":["printf","%s|","$HOME","a b"],"HostConfig":{"Memory":268435456,"NanoCpus":500000000,"Binds":["/data:/data:ro"]}})

      task = create(context, "name=api", body)

      {head, _} = serve(engine, 404, ~s({"message":"No such container: api"}))
      assert head =~ "GET /v1.57/containers/api/json HTTP/1.1"
      {head, _} = serve(engine, 200, Jason.encode!(image()))
      assert head =~ "GET /v1.57/images/nginx/json HTTP/1.1"

      assert {:ok, 201, %{"Id" => id, "Warnings" => []}} = Task.await(task)
      instance = Container.instance_name(id)

      assert_received {:incus, {:create_instance, create}}
      assert create["name"] == instance
      assert create["source"] == %{"type" => "image", "fingerprint" => "fp-nginx"}
      assert create["start"] == false
      assert create["config"]["oci.entrypoint"] == @init
      assert create["config"]["limits.memory"] == "268435456B"
      assert create["config"]["limits.cpu.allowance"] == "50ms/100ms"
      assert create["config"]["user.opsmaru.containers.name"] == "api"
      assert create["config"]["user.opsmaru.containers.image_ref"] == "nginx"
      assert create["devices"]["bind0"]["source"] == "/host/data"

      assert_received {:incus, {:head_file, ^instance, "/.opsmaru"}}
      assert_received {:incus, {:push_file, ^instance, "/.opsmaru", 0o700, :directory}}
      assert_received {:incus, {:push_file, ^instance, @init, 0o755, ^shim}}
      assert_received {:incus, {:push_file, ^instance, "/.opsmaru/spec.json", 0o600, spec}}

      spec = Jason.decode!(spec)
      assert spec["argv"] == ["/docker-entrypoint.sh", "printf", "%s|", "$HOME", "a b"]
      assert spec["hostname"] == binary_part(id, 0, 12)
      assert spec["user"] == "nginx"

      assert {:ok, container} =
               context.target.native
               |> instances()
               |> Enum.find(&(&1["name"] == instance))
               |> Container.from_instance()

      assert container.config["Config"]["Hostname"] == binary_part(id, 0, 12)
      assert container.config["Path"] == "/docker-entrypoint.sh"
    end

    test "a refused field is answered before any image transfer or instance", %{
      create_context: context
    } do
      body = ~s({"Image":"nginx","HostConfig":{"PortBindings":{"80/tcp":[{"HostPort":"8080"}]}}})

      assert {:error, 400, "native engine cannot honour: HostConfig.PortBindings"} =
               Task.await(create(context, "", body))

      refute_received {:dialed, _}
      refute_received {:incus, _}
    end

    test "a denied bind source, a bad name and a taken name are refused before the image", %{
      create_context: context
    } do
      body = ~s({"Image":"nginx","HostConfig":{"Binds":["/denied/x:/x"]}})

      assert {:error, 400, "invalid mount config: bind source path /denied/x is not allowed"} =
               Task.await(create(context, "", body))

      assert {:error, 400,
              "Invalid container name (-x), only [a-zA-Z0-9][a-zA-Z0-9_.-] are allowed"} =
               Task.await(create(context, "name=-x", ~s({"Image":"nginx"})))

      assert {:error, 409, "Conflict. The container name \"/web\" is already in use" <> _} =
               Task.await(create(context, "name=web", ~s({"Image":"nginx"})))

      refute_received {:dialed, _}
      refute_received {:incus, {:create_instance, _}}
    end

    test "an image holding /.opsmaru is refused and its instance deleted", %{
      engine: engine,
      create_context: context,
      native: native
    } do
      ScriptedIncus.update(native, &%{&1 | image_files: ["/.opsmaru"]})
      task = create(context, "", ~s({"Image":"nginx"}))
      serve(engine, 200, Jason.encode!(image()))

      assert {:error, 400, "native engine: the image already contains /.opsmaru" <> _} =
               Task.await(task)

      assert_received {:incus, {:create_instance, %{"name" => instance}}}
      assert_received {:incus, {:delete_instance, ^instance}}
      refute_received {:incus, {:push_file, _, _, _, _}}
      refute Enum.any?(instances(native), &(&1["name"] == instance))
    end

    test "a shim file changed since the target was built is never pushed", %{
      engine: engine,
      create_context: context,
      shim_path: shim_path
    } do
      File.write!(shim_path, "tampered")
      task = create(context, "", ~s({"Image":"nginx"}))
      serve(engine, 200, Jason.encode!(image()))

      assert {:error, 500, "native engine: the init shim at " <> _} = Task.await(task)
      assert_received {:incus, {:delete_instance, _}}
      refute_received {:incus, {:push_file, _, _, _, _}}
    end

    test "an image architecture without a shim is refused before any instance", %{
      engine: engine,
      create_context: context
    } do
      task = create(context, "", ~s({"Image":"nginx"}))
      serve(engine, 200, Jason.encode!(%{image() | "Architecture" => "amd64"}))

      assert {:error, 400,
              "native engine: no init shim is configured for image architecture \"amd64\""} =
               Task.await(task)

      refute_received {:incus, {:create_instance, _}}
    end

    test "the Plug hands a create the host routes to native to the native engine", %{
      engine: engine,
      context: context,
      native: native
    } do
      task =
        Task.async(fn ->
          "POST"
          |> Test.conn("/v1.57/containers/create", ~s({"Image":"nginx"}))
          |> Conn.put_req_header("content-type", "application/json")
          |> Conn.put_private(:opsmaru_containers_peer, {context, self()})
          |> Plug.call(Plug.init(host: NativeHost))
        end)

      serve(engine, 200, Jason.encode!(image()))
      conn = Task.await(task)

      # The scripted target names the library's shim path, which this host
      # does not have, so the create gets as far as the shim push.
      assert conn.status == 500

      assert Jason.decode!(conn.resp_body)["message"] ==
               "native engine: the init shim at /opt/shim/init-arm64 is unreadable (enoent)"

      assert_received {:incus, {:create_instance, %{"name" => instance}}}
      assert_received {:incus, {:delete_instance, ^instance}}
      assert length(instances(native)) == 2
    end
  end

  describe "start" do
    test "a start waits for the shim's new run and answers 204", %{
      context: context,
      native: native
    } do
      play_start(native, Container.instance_name(@old), record(3, nil, nil, pid: 7))
      assert {204, ""} = call(context, "POST", "/containers/old/start")
      assert_received {:incus, {:update_state, "oc-bbbb22222222", "start", false}}
    end

    test "a failed execve is answered as dockerd answers it and leaves exit 127", %{
      context: context,
      native: native
    } do
      error = ~s(exec: "nope": executable file not found in $PATH)

      play_start(
        native,
        Container.instance_name(@old),
        record(3, ago(0), 127, error: error),
        "Stopped"
      )

      assert {400, %{"message" => message}} = call(context, "POST", "/containers/old/start")
      assert message == "native engine: failed to start container process: " <> error

      assert {200, %{"State" => state}} = call(context, "GET", "/containers/old/json")
      assert %{"Status" => "exited", "ExitCode" => 127, "Error" => ^error} = state
    end

    test "a start whose instance stops before the shim records it is an error, not a hang", %{
      context: context,
      native: native
    } do
      ScriptedIncus.update(native, fn state ->
        %{
          state
          | on_state: fn instance, "start", state ->
              ScriptedIncus.put_status(state, instance, "Stopped")
            end
        }
      end)

      assert {500, %{"message" => message}} = call(context, "POST", "/containers/old/start")

      assert message ==
               "native engine: container #{@old} stopped before its init shim recorded a start"
    end

    test "a running container answers 304 and a paused one 409", %{
      context: context,
      native: native
    } do
      assert {304, ""} = call(context, "POST", "/containers/web/start")

      ScriptedIncus.update(native, &ScriptedIncus.put_status(&1, "oc-aaaa11111111", "Frozen"))

      assert {409, %{"message" => "cannot start a paused container, try unpause instead"}} =
               call(context, "POST", "/containers/web/start")
    end
  end

  describe "stop, kill and restart" do
    test "stop runs init stop with the timeout and signal, then waits for the instance", %{
      context: context,
      native: native
    } do
      play_exit(native, "oc-aaaa11111111", 143)

      assert {204, ""} = call(context, "POST", "/containers/web/stop?t=5&signal=SIGINT")

      assert_received {:incus,
                       {:exec, "oc-aaaa11111111",
                        [@init, "stop", "--timeout", "5", "--signal", "SIGINT"]}}

      refute_received {:incus, {:update_state, _, "stop", true}}
      assert {304, ""} = call(context, "POST", "/containers/web/stop")
    end

    test "stop uses the container's StopTimeout, and unfreezes a paused container first", %{
      context: context,
      native: native
    } do
      ScriptedIncus.update(native, &ScriptedIncus.put_status(&1, "oc-aaaa11111111", "Frozen"))
      play_exit(native, "oc-aaaa11111111", 143)

      assert {204, ""} = call(context, "POST", "/containers/web/stop")
      assert_received {:incus, {:update_state, "oc-aaaa11111111", "unfreeze", false}}
      assert_received {:incus, {:exec, "oc-aaaa11111111", [@init, "stop", "--timeout", "42"]}}
    end

    test "a failed init stop is backed by an Incus forced stop", %{
      context: context,
      native: native
    } do
      ScriptedIncus.update(native, fn state ->
        %{
          state
          | exec: fn _, _ ->
              {:ok, %{status: 1, stdout: "", stderr: "container is not running"}}
            end
        }
      end)

      assert {204, ""} = call(context, "POST", "/containers/web/stop?t=1")
      assert_received {:incus, {:update_state, "oc-aaaa11111111", "stop", true}}
    end

    test "kill delivers any signal through the shim", %{context: context} do
      assert {204, ""} = call(context, "POST", "/containers/web/kill?signal=HUP")
      assert_received {:incus, {:exec, "oc-aaaa11111111", [@init, "kill", "SIGHUP"]}}
      refute_received {:incus, {:update_state, _, _, _}}
    end

    test "kill follows dockerd's errors", %{context: context, native: native} do
      assert {400, %{"message" => "Invalid signal: SIGNOPE"}} =
               call(context, "POST", "/containers/web/kill?signal=SIGNOPE")

      assert {409, %{"message" => "Container #{@old} is not running"}} ==
               call(context, "POST", "/containers/old/kill")

      ScriptedIncus.update(native, &ScriptedIncus.put_status(&1, "oc-aaaa11111111", "Frozen"))

      assert {409, %{"message" => message}} =
               call(context, "POST", "/containers/web/kill?signal=HUP")

      assert message ==
               "Container #{@web} is paused. Unpause the container before stopping or killing"

      assert {204, ""} = call(context, "POST", "/containers/web/kill")
      assert_received {:incus, {:update_state, "oc-aaaa11111111", "stop", true}}
    end

    test "SIGKILL falls back to a forced stop when the shim cannot be reached", %{
      context: context,
      native: native
    } do
      ScriptedIncus.update(native, &%{&1 | exec: fn _, _ -> {:error, :closed} end})

      assert {204, ""} = call(context, "POST", "/containers/web/kill?signal=9")
      assert_received {:incus, {:update_state, "oc-aaaa11111111", "stop", true}}
    end

    test "restart stops then starts", %{context: context, native: native} do
      play_exit(native, "oc-aaaa11111111", 143)
      play_start(native, "oc-aaaa11111111", record(2, nil, nil, pid: 9))

      assert {204, ""} = call(context, "POST", "/containers/web/restart?t=3")
      assert_received {:incus, {:exec, "oc-aaaa11111111", [@init, "stop", "--timeout", "3"]}}
      assert_received {:incus, {:update_state, "oc-aaaa11111111", "start", false}}
    end
  end

  describe "pause, rename, remove and inspect" do
    test "pause and unpause freeze and unfreeze with dockerd's conflicts", %{context: context} do
      assert {204, ""} = call(context, "POST", "/containers/web/pause")
      assert_received {:incus, {:update_state, "oc-aaaa11111111", "freeze", false}}

      assert {409, %{"message" => "Container #{@web} is already paused"}} ==
               call(context, "POST", "/containers/web/pause")

      assert {204, ""} = call(context, "POST", "/containers/web/unpause")

      assert {409, %{"message" => "Container #{@web} is not paused"}} ==
               call(context, "POST", "/containers/web/unpause")

      assert {409, %{"message" => "Container #{@old} is not running"}} ==
               call(context, "POST", "/containers/old/pause")
    end

    test "rename rewrites the name key after checking both engines", %{
      engine: engine,
      context: context,
      native: native
    } do
      assert {400, %{"message" => "Renaming a container with the same name as its current name"}} =
               call(context, "POST", "/containers/web/rename?name=web")

      assert {409, %{"message" => "Error when allocating new name: Conflict." <> _}} =
               call(context, "POST", "/containers/web/rename?name=old")

      task = Task.async(fn -> call(context, "POST", "/containers/web/rename?name=front") end)
      {head, _} = serve(engine, 404, ~s({"message":"No such container: front"}))
      assert head =~ "GET /v1.57/containers/front/json HTTP/1.1"
      assert {204, ""} = Task.await(task)

      assert_received {:incus,
                       {:patch_config, "oc-aaaa11111111",
                        %{"user.opsmaru.containers.name" => "front"}}}

      assert Enum.find(instances(native), &(&1["name"] == "oc-aaaa11111111"))["name"] ==
               "oc-aaaa11111111"
    end

    test "removing a running container needs force", %{context: context, native: native} do
      assert {409, %{"message" => message}} = call(context, "DELETE", "/containers/web")

      assert message ==
               ~s(cannot remove container "/web": container is running: ) <>
                 "stop the container before removing or force remove"

      refute_received {:incus, {:delete_instance, _}}

      assert {204, ""} = call(context, "DELETE", "/containers/web?force=1")
      assert_received {:incus, {:update_state, "oc-aaaa11111111", "stop", true}}
      assert_received {:incus, {:delete_instance, "oc-aaaa11111111"}}

      assert {204, ""} = call(context, "DELETE", "/containers/old")
      assert instances(native) == []
    end

    test "a delete Incus refuses as running just after the stop is retried", %{
      context: context,
      native: native
    } do
      ScriptedIncus.update(native, &%{&1 | delete_refusals: 2})
      assert {204, ""} = call(context, "DELETE", "/containers/old")
      assert instances(native) |> Enum.map(& &1["name"]) == ["oc-aaaa11111111"]

      deletes = for {:incus, {:delete_instance, "oc-bbbb22222222"}} <- messages(), do: :delete
      assert length(deletes) == 3
    end

    test "a run record read that fails while the instance changes state is retried", %{
      context: context,
      native: native
    } do
      ScriptedIncus.update(native, &%{&1 | read_failures: 2})

      assert {200, %{"State" => %{"ExitCode" => 3}}} =
               call(context, "GET", "/containers/old/json")

      # Every attempt fails: the answer names Incus, not a missing record.
      ScriptedIncus.update(native, &%{&1 | read_failures: 10})

      assert {503, %{"message" => "native engine: Incus is not available"}} =
               call(context, "GET", "/containers/old/json")
    end

    test "inspect reports the exit record, and 137 when none was written", %{
      context: context,
      native: native
    } do
      assert {200, body} = call(context, "GET", "/containers/old/json")
      assert body["Id"] == @old
      assert body["Name"] == "/old"
      assert body["Path"] == "/docker-entrypoint.sh"
      assert body["Image"] == @image_id

      assert %{"Status" => "exited", "ExitCode" => 3, "Running" => false, "Error" => ""} =
               body["State"]

      assert body["Config"]["Labels"] == %{"tier" => "back"}

      ScriptedIncus.update(native, fn state ->
        state
        |> ScriptedIncus.put_status("oc-aaaa11111111", "Stopped")
        |> ScriptedIncus.put_instance(
          "oc-aaaa11111111",
          &Map.put(&1, "state", %{"status" => "Stopped"})
        )
      end)

      assert {200, %{"State" => state}} = call(context, "GET", "/containers/web/json")

      assert %{
               "Status" => "exited",
               "ExitCode" => 137,
               "Error" => "native: exit status not recorded"
             } = state
    end

    test "inspect of a running container reports its pid and address", %{
      context: context,
      native: native
    } do
      network = %{
        "eth0" => %{
          "hwaddr" => "00:16:3e:00:00:01",
          "addresses" => [
            %{"family" => "inet6", "address" => "fe80::1", "netmask" => "64", "scope" => "link"},
            %{
              "family" => "inet",
              "address" => "10.20.0.5",
              "netmask" => "24",
              "scope" => "global"
            }
          ]
        }
      }

      ScriptedIncus.update(native, fn state ->
        ScriptedIncus.put_instance(
          state,
          "oc-aaaa11111111",
          &Map.put(&1, "state", %{"network" => network})
        )
      end)

      assert {200, body} = call(context, "GET", "/containers/web/json")
      assert %{"Status" => "running", "Running" => true, "Pid" => 12} = body["State"]

      assert %{
               "IPAddress" => "10.20.0.5",
               "IPPrefixLen" => 24,
               "MacAddress" => "00:16:3e:00:00:01"
             } =
               body["NetworkSettings"]["Networks"]["bridge"]
    end

    test "a tampered run record gives an error naming the native engine", %{
      context: context,
      native: native
    } do
      ScriptedIncus.update(
        native,
        &ScriptedIncus.put_file(&1, "oc-bbbb22222222", @record, "{not json")
      )

      assert {500, %{"message" => message}} = call(context, "GET", "/containers/old/json")
      assert message == "native engine: the run record of container #{@old} is malformed"

      assert {200, _} = call(context, "GET", "/containers/web/json")
    end
  end

  describe "shim file parsers" do
    test "run records are bounded and strictly parsed" do
      assert %RunRecord{run: 3, exit_code: 3} = RunRecord.parse(record(3, ago(1), 3))

      for bad <- [
            ~s({"version":2,"run":1,"started_at":"2026-01-01T00:00:00Z"}),
            ~s({"version":1,"run":0,"started_at":"2026-01-01T00:00:00Z"}),
            ~s({"version":1,"run":1,"started_at":"yesterday"}),
            ~s({"version":1,"run":1,"started_at":"2026-01-01T00:00:00Z","exit_code":300}),
            ~s({"version":1,"run":1,"started_at":"2026-01-01T00:00:00Z","error":") <>
              String.duplicate("x", 5_000) <> ~s("}),
            "[]",
            ""
          ] do
        assert RunRecord.parse(bad) == :malformed, bad
      end

      assert RunRecord.limit() == 65_536
    end

    test "log records round-trip and malformed records are refused" do
      records = [
        %LogRecord{stream: :stdout, run: 1, time: 1_000, data: "hello\n"},
        %LogRecord{stream: :stderr, run: 1, time: 2_000, data: "warn", partial: true}
      ]

      file = LogRecord.magic() <> Enum.map_join(records, &LogRecord.encode/1)
      assert {:ok, ^records, ""} = LogRecord.decode_file(file)

      # A record still being written is left for the next read.
      truncated = binary_part(file, 0, byte_size(file) - 2)
      assert {:ok, [first], rest} = LogRecord.decode_file(truncated)
      assert first == hd(records)
      assert byte_size(rest) == LogRecord.header_size() + 4 - 2

      assert {:ok, [], "OC"} = LogRecord.decode_file("OC")
      assert {:error, :malformed} = LogRecord.decode_file("XXXX")
      assert {:error, :malformed} = LogRecord.decode_file("NOPE" <> "x")

      header = fn stream, flags, length -> <<stream, flags, 1::32, 0::64, length::32>> end
      assert {:error, :malformed} = LogRecord.decode(header.(3, 0, 1) <> "x")
      assert {:error, :malformed} = LogRecord.decode(header.(1, 2, 1) <> "x")
      assert {:error, :malformed} = LogRecord.decode(header.(1, 0, 0))
      assert {:error, :malformed} = LogRecord.decode(header.(1, 0, 16_385))
    end
  end

  # -- Helpers -------------------------------------------------------------------

  # Plays the shim's start: the instance runs and writes a new run record.
  defp play_start(native, instance, record, status_after \\ "Running") do
    ScriptedIncus.update(native, fn state ->
      on_state = state.on_state

      %{
        state
        | on_state: fn
            ^instance, "start", state ->
              state
              |> ScriptedIncus.put_file(instance, @record, record)
              |> ScriptedIncus.put_status(instance, status_after)

            name, action, state ->
              on_state.(name, action, state)
          end
      }
    end)
  end

  # Plays init stop: the process exits with `code` and the instance stops.
  defp play_exit(native, instance, code) do
    ScriptedIncus.update(native, fn state ->
      %{
        state
        | exec: fn
            ^instance, [@init, "stop" | _] ->
              ScriptedIncus.update(native, fn state ->
                state
                |> ScriptedIncus.put_file(instance, @record, record(1, ago(0), code))
                |> ScriptedIncus.put_status(instance, "Stopped")
              end)

              {:ok, %{status: 0, stdout: "", stderr: ""}}

            _, _ ->
              {:ok, %{status: 0, stdout: "", stderr: ""}}
          end
      }
    end)
  end

  defp with_native(context, native) do
    target = %{context.target | native: native}
    %{context | target: target, capabilities: %{context.capabilities | target: target}}
  end

  defp create(context, query, body) do
    Task.async(fn ->
      Lifecycle.create(context, NativeHost, URI.decode_query(query), body, "1.57", deadline())
    end)
  end

  defp call(context, method, path) do
    conn =
      method
      |> Test.conn(path, "")
      |> Conn.put_private(:opsmaru_containers_peer, {context, self()})
      |> Plug.call(Plug.init(host: EngineFixture.AllowHost, stream_timeout: 5_000))

    {conn.status, if(conn.resp_body == "", do: "", else: Jason.decode!(conn.resp_body))}
  end

  defp instances(native) do
    {:ok, instances} = ScriptedIncus.list_instances(native.client, deadline())
    instances
  end

  defp serve(engine, status, body) do
    socket = EngineFixture.accept(engine)
    {head, request_body, _} = EngineFixture.read_request(socket)

    :ok =
      :gen_tcp.send(
        socket,
        "HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\n" <>
          "Content-Length: #{byte_size(body)}\r\n\r\n" <> body
      )

    :gen_tcp.close(socket)
    {head, request_body}
  end

  defp image do
    %{
      "Id" => @image_id,
      "Architecture" => "arm64",
      "Config" => %{
        "Entrypoint" => ["/docker-entrypoint.sh"],
        "Cmd" => ["nginx", "-g", "daemon off;"],
        "Env" => ["PATH=/usr/bin:/bin"],
        "User" => "nginx"
      }
    }
  end

  defp instance(id, name, status) do
    keys =
      Container.keys(%{
        id: id,
        name: name,
        created: DateTime.from_unix!(100),
        image_id: @image_id,
        image_ref: "nginx:1.29",
        labels: %{"tier" => if(name == "web", do: "front", else: "back")},
        config: %{
          "Path" => "/docker-entrypoint.sh",
          "Args" => ["nginx", "-g", "daemon off;"],
          "Config" => %{"StopTimeout" => 42, "Image" => "nginx:1.29"},
          "HostConfig" => %{"NetworkMode" => "bridge"}
        },
        init: "digest",
        autoremove: false
      })

    %{"name" => Container.instance_name(id), "status" => status, "config" => keys}
  end

  defp record(run, finished, code, extra \\ []) do
    Jason.encode!(%{
      "version" => 1,
      "run" => run,
      "pid" => Keyword.get(extra, :pid, 12),
      "started_at" => ago(120),
      "finished_at" => finished,
      "exit_code" => code,
      "signal" => nil,
      "oom_killed" => false,
      "error" => Keyword.get(extra, :error)
    })
  end

  defp ago(seconds), do: DateTime.utc_now() |> DateTime.add(-seconds) |> DateTime.to_iso8601()
  defp deadline, do: System.monotonic_time(:millisecond) + 4_000

  defp messages do
    receive do
      message -> [message | messages()]
    after
      0 -> []
    end
  end
end
