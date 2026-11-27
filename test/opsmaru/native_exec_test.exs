defmodule Opsmaru.Containers.Native.ExecTest do
  use ExUnit.Case, async: true

  alias Elixir.Plug.{Conn, Test}
  alias Opsmaru.Containers.Docker.{Plug, Raw}
  alias Opsmaru.Containers.Native.Container
  alias Opsmaru.Containers.TestSupport.{EngineFixture, ScriptedIncus}
  alias Opsmaru.Containers.Transport.Stream

  @web "aaaa1111" <> String.duplicate("1", 56)
  @job "bbbb2222" <> String.duplicate("2", 56)
  @frozen "cccc3333" <> String.duplicate("3", 56)
  @web_instance "oc-aaaa11111111"

  setup do
    engine = EngineFixture.start()

    native =
      ScriptedIncus.target(
        instances: [
          instance(@web, "web", "Running"),
          instance(@job, "job", "Stopped"),
          instance(@frozen, "frozen", "Frozen")
        ]
      )

    context = EngineFixture.context(engine)
    target = %{context.target | native: native}
    context = %{context | target: target, capabilities: %{context.capabilities | target: target}}
    %{context: context, native: native}
  end

  describe "create" do
    test "stores the record on the instance and answers a 64-hex ID", %{
      context: context,
      native: native
    } do
      assert {201, %{"Id" => id}} =
               call(context, "POST", "/containers/web/exec", %{
                 "Cmd" => ["sh", "-c", "id"],
                 "Env" => ["A=1"],
                 "User" => "app",
                 "AttachStdout" => true
               })

      assert id =~ ~r/\A[0-9a-f]{64}\z/
      record = Jason.decode!(config(native, @web_instance)[Container.exec_key(id)])

      assert %{
               "Cmd" => ["sh", "-c", "id"],
               "Env" => ["A=1"],
               "User" => "app",
               "AttachStdout" => true,
               "AttachStdin" => false,
               "Started" => false,
               "Running" => false
             } = record

      assert {200, inspect} = call(context, "GET", "/exec/#{id}/json")

      assert %{
               "ID" => ^id,
               "Running" => false,
               "ExitCode" => nil,
               "ContainerID" => @web,
               "OpenStdout" => true,
               "OpenStdin" => false,
               "ProcessConfig" => %{
                 "entrypoint" => "sh",
                 "arguments" => ["-c", "id"],
                 "user" => "app",
                 "tty" => false,
                 "privileged" => false
               }
             } = inspect

      assert {200, %{"ExecIDs" => [^id]}} = call(context, "GET", "/containers/web/json")
    end

    test "keeps the newest 32 records on the instance", %{context: context, native: native} do
      old =
        for second <- 0..31 do
          id = String.duplicate(Integer.to_string(rem(second, 10)), 2) <> hex(62, second)
          created = "2026-01-01T10:00:#{String.pad_leading(Integer.to_string(second), 2, "0")}Z"
          {id, Jason.encode!(%{"Cmd" => ["true"], "Created" => created})}
        end

      ScriptedIncus.update(native, fn state ->
        keys = Map.new(old, fn {id, record} -> {Container.exec_key(id), record} end)
        put_config(state, @web_instance, keys)
      end)

      assert {201, %{"Id" => id}} =
               call(context, "POST", "/containers/web/exec", %{"Cmd" => ["true"]})

      execs = exec_ids(native, @web_instance)
      assert length(execs) == 32
      assert id in execs
      [{oldest, _} | _] = old
      refute oldest in execs
    end

    test "refuses Privileged, an empty command and a container that is not running", %{
      context: context
    } do
      assert {400, %{"message" => "native engine cannot honour: Privileged"}} =
               call(context, "POST", "/containers/web/exec", %{
                 "Cmd" => ["sh"],
                 "Privileged" => true
               })

      assert {400, %{"message" => "No exec command specified"}} =
               call(context, "POST", "/containers/web/exec", %{"Cmd" => []})

      assert {409, %{"message" => "container #{@job} is not running"}} ==
               call(context, "POST", "/containers/job/exec", %{"Cmd" => ["sh"]})

      assert {409,
              %{
                "message" => "Container #{@frozen} is paused, unpause the container before exec"
              }} == call(context, "POST", "/containers/frozen/exec", %{"Cmd" => ["sh"]})
    end
  end

  describe "attached start" do
    test "frames stdout and stderr and records the exit before the stream ends", %{
      context: context,
      native: native
    } do
      ScriptedIncus.update(native, fn state ->
        %{
          state
          | session: fn _, _ -> %{output: [{"1", "out\n"}, {"2", "err\n"}], exit: 3} end
        }
      end)

      id =
        create(context, %{
          "Cmd" => ["sh", "-c", "x"],
          "Env" => ["FOO=1", "BAR", "FOO=2"],
          "User" => "app",
          "WorkingDir" => "/srv",
          "AttachStdout" => true,
          "AttachStderr" => true
        })

      assert {:upgrade, response, stream, ""} = start(context, id, %{"Tty" => false})
      assert response.status == 101

      assert {"content-type", "application/vnd.docker.multiplexed-stream"} in response.headers

      assert frames(drain(stream)) |> Enum.sort() == [{1, "out\n"}, {2, "err\n"}]

      assert_received {:incus, {:exec_session, @web_instance, body}}

      assert body["command"] ==
               ["/.opsmaru/init", "exec", "--user", "app", "--cwd", "/srv", "--", "sh", "-c", "x"]

      assert body["interactive"] == false
      assert body["environment"]["FOO"] == "2"
      assert Jason.decode!(body["environment"]["OPSMARU_EXEC_ENV"]) == ["FOO"]
      assert Jason.decode!(body["environment"]["OPSMARU_EXEC_UNSET"]) == ["BAR"]
      refute Map.has_key?(body["environment"], "TERM")

      # Without AttachStdin, Incus stdin is closed at once.
      assert_received {:incus, :session_close_input}

      assert {200, %{"Running" => false, "ExitCode" => 3}} =
               call(context, "GET", "/exec/#{id}/json")

      assert {:http, 409, _, body} = start(context, id, %{})
      assert %{"message" => "exec command #{id} has already run"} == Jason.decode!(body)
    end

    test "client write EOF closes Incus stdin while output keeps flowing", %{
      context: context,
      native: native
    } do
      ScriptedIncus.update(native, fn state ->
        %{state | session: fn _, _ -> %{output: [], echo: true, exit: 0} end}
      end)

      id = create(context, %{"Cmd" => ["cat"], "AttachStdin" => true, "AttachStdout" => true})
      assert {:upgrade, _, stream, ""} = start(context, id, %{})

      assert :ok = Stream.send(stream, "hello", deadline())
      assert {:ok, frame} = Stream.recv(stream, 65_536, deadline())
      assert frames(frame) == [{1, "hello"}]
      assert_received {:incus, {:session_input, "hello"}}
      refute_received {:incus, :session_close_input}

      assert :ok = Stream.shutdown_write(stream, deadline())
      assert_receive {:incus, :session_close_input}
      assert drain(stream) == ""

      # Input after the write EOF is discarded rather than failing the relay.
      assert :ok = Stream.send(stream, "late", deadline())
      Stream.close(stream)
      assert_receive {:incus, :session_close}
    end

    test "a TTY exec is unframed, gets TERM and its console size, and resizes", %{
      context: context,
      native: native
    } do
      ScriptedIncus.update(native, fn state ->
        %{state | session: fn _, _ -> %{output: [{"0", "$ "}], echo: true, exit: 0} end}
      end)

      id =
        create(context, %{
          "Cmd" => ["sh"],
          "Tty" => true,
          "AttachStdin" => true,
          "AttachStdout" => true
        })

      assert {:upgrade, response, stream, ""} =
               start(context, id, %{"Tty" => true, "ConsoleSize" => [24, 80]})

      assert {"content-type", "application/vnd.docker.raw-stream"} in response.headers
      assert {:ok, "$ "} = Stream.recv(stream, 65_536, deadline())

      assert_received {:incus, {:exec_session, @web_instance, body}}
      assert %{"interactive" => true, "width" => 80, "height" => 24} = body
      assert body["environment"]["TERM"] == "xterm"
      assert Jason.decode!(body["environment"]["OPSMARU_EXEC_ENV"]) == ["TERM"]

      assert {200, %{"Running" => true}} = call(context, "GET", "/exec/#{id}/json")
      assert {200, _} = call(context, "POST", "/exec/#{id}/resize?h=40&w=100")
      assert_received {:incus, {:session_resize, 100, 40}}

      assert {400, _} = call(context, "POST", "/exec/#{id}/resize?h=0&w=100")

      assert :ok = Stream.send(stream, "ls\r", deadline())
      assert {:ok, "ls\r"} = Stream.recv(stream, 65_536, deadline())
      assert :ok = Stream.shutdown_write(stream, deadline())
      assert drain(stream) == ""

      # As dockerd answers once the exec's process has exited.
      assert {404, %{"message" => "NotFound: process does not exist #{id}: not found"}} ==
               call(context, "POST", "/exec/#{id}/resize?h=40&w=100")
    end

    test "a second start while the exec runs is a conflict", %{context: context, native: native} do
      ScriptedIncus.update(native, fn state ->
        %{state | session: fn _, _ -> %{output: [], echo: true, exit: 0} end}
      end)

      id = create(context, %{"Cmd" => ["cat"], "AttachStdin" => true})
      assert {:upgrade, _, stream, ""} = start(context, id, %{})

      assert {:http, 409, _, body} = start(context, id, %{})
      assert %{"message" => "exec command #{id} is already running"} == Jason.decode!(body)

      Stream.close(stream)
    end

    test "the Plug refuses an attached start", %{context: context} do
      id = create(context, %{"Cmd" => ["sh"]})

      assert {501, %{"message" => "Docker attached exec requires the host's raw adapter"}} ==
               call(context, "POST", "/exec/#{id}/start", %{"Detach" => false})
    end
  end

  describe "detached start" do
    test "runs without channels and reads its exit from the Incus operation", %{
      context: context,
      native: native
    } do
      id = create(context, %{"Cmd" => ["sleep", "1"], "Env" => ["A=1"]})
      url = "/1.0/operations/detached-" <> @web_instance

      ScriptedIncus.update(native, &%{&1 | operations: %{url => %{done: false, exit_code: nil}}})

      assert {200, ""} = call_raw(context, "POST", "/exec/#{id}/start", %{"Detach" => true})
      assert_received {:incus, {:exec_detached, @web_instance, body}}
      assert ["/.opsmaru/init", "exec", "--", "sleep", "1"] == body["command"]
      assert body["environment"]["A"] == "1"
      refute_received {:incus, {:exec_session, _, _}}

      assert {200, %{"Running" => true, "ExitCode" => nil}} =
               call(context, "GET", "/exec/#{id}/json")

      ScriptedIncus.update(native, &%{&1 | operations: %{url => %{done: true, exit_code: 4}}})

      assert {200, %{"Running" => false, "ExitCode" => 4}} =
               call(context, "GET", "/exec/#{id}/json")

      assert {409, %{"message" => "exec command #{id} has already run"}} ==
               call(context, "POST", "/exec/#{id}/start", %{"Detach" => true})
    end

    test "an operation Incus no longer holds reports the exec finished without a code", %{
      context: context
    } do
      id = create(context, %{"Cmd" => ["true"]})
      assert {200, ""} = call_raw(context, "POST", "/exec/#{id}/start", %{"Detach" => true})

      assert {200, %{"Running" => false, "ExitCode" => nil}} =
               call(context, "GET", "/exec/#{id}/json")
    end

    test "a detached start through the raw adapter answers plain HTTP", %{context: context} do
      id = create(context, %{"Cmd" => ["true"]})
      assert {:http, 200, _, ""} = start(context, id, %{"Detach" => true})
      assert_received {:incus, {:exec_detached, @web_instance, _}}
    end
  end

  # -- Helpers --------------------------------------------------------------------

  defp create(context, body) do
    {201, %{"Id" => id}} = call(context, "POST", "/containers/web/exec", body)
    id
  end

  defp start(context, id, body) do
    request = %{
      method: "POST",
      path: "/exec/#{id}/start",
      query: "",
      peer: {127, 0, 0, 1},
      host_peer: {context, self()},
      headers: [{"upgrade", "tcp"}, {"connection", "Upgrade"}],
      body: Jason.encode!(body)
    }

    Raw.open(EngineFixture.AllowHost, request,
      admission_deadline: deadline(),
      deadline: deadline()
    )
  end

  defp call(context, method, path, body \\ nil) do
    {status, body} = call_raw(context, method, path, body)
    {status, if(body == "", do: "", else: Jason.decode!(body))}
  end

  defp call_raw(context, method, path, body) do
    conn =
      method
      |> Test.conn(path, if(body, do: Jason.encode!(body), else: ""))
      |> Conn.put_private(:opsmaru_containers_peer, {context, self()})
      |> Plug.call(Plug.init(host: EngineFixture.AllowHost, stream_timeout: 5_000))

    {conn.status, conn.resp_body}
  end

  defp drain(stream, acc \\ "") do
    case Stream.recv(stream, 65_536, deadline()) do
      {:ok, bytes} -> drain(stream, acc <> bytes)
      :eof -> acc
    end
  end

  defp frames(<<stream, 0, 0, 0, size::32, data::binary-size(size), rest::binary>>),
    do: [{stream, data} | frames(rest)]

  defp frames(""), do: []

  defp config(native, instance) do
    {:ok, instances} = ScriptedIncus.list_instances(native.client, deadline())
    Enum.find(instances, &(&1["name"] == instance))["config"]
  end

  defp exec_ids(native, instance) do
    for {"user.opsmaru.containers.exec." <> id, _} <- config(native, instance), do: id
  end

  defp put_config(state, instance, keys) do
    instances =
      Enum.map(state.instances, fn
        %{"name" => ^instance} = found -> %{found | "config" => Map.merge(found["config"], keys)}
        other -> other
      end)

    %{state | instances: instances}
  end

  defp hex(length, seed),
    do: :crypto.hash(:sha256, <<seed>>) |> Base.encode16(case: :lower) |> binary_part(0, length)

  defp instance(id, name, status) do
    keys =
      Container.keys(%{
        id: id,
        name: name,
        created: DateTime.from_unix!(100),
        image_id: "sha256:" <> String.duplicate("b", 64),
        image_ref: "busybox",
        labels: %{},
        config: %{"Path" => "sh", "Args" => [], "HostConfig" => %{}},
        init: "digest",
        autoremove: false
      })

    %{"name" => Container.instance_name(id), "status" => status, "config" => keys}
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 4_000
end
