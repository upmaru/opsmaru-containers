defmodule Opsmaru.Containers.Native.WaitTest do
  use ExUnit.Case, async: true

  alias Elixir.Plug.{Conn, Test}
  alias Opsmaru.Containers.Docker.Plug
  alias Opsmaru.Containers.Native
  alias Opsmaru.Containers.Native.{Container, Wait}
  alias Opsmaru.Containers.TestSupport.{EngineFixture, ScriptedIncus}

  @web "aaaa1111" <> String.duplicate("1", 56)
  @job "bbbb2222" <> String.duplicate("2", 56)
  @record "/.opsmaru/state/run.json"
  @web_instance "oc-aaaa11111111"
  @job_instance "oc-bbbb22222222"

  setup do
    engine = EngineFixture.start()

    native =
      ScriptedIncus.target(
        instances: [
          instance(@web, "web", "Running", false),
          instance(@job, "job", "Stopped", true)
        ],
        files: %{{@web_instance, @record} => record(1, nil)}
      )

    context = EngineFixture.context(engine)
    target = %{context.target | native: native}
    context = %{context | target: target, capabilities: %{context.capabilities | target: target}}
    %{context: context, native: native}
  end

  test "an exit between subscribe and read is reported by the read", %{
    context: context,
    native: native
  } do
    # The routing read saw the container running. It exits after the
    # subscription starts, and no event is ever delivered.
    ScriptedIncus.update(native, fn state ->
      %{
        state
        | on_subscribe: fn state ->
            state
            |> ScriptedIncus.put_file(@web_instance, @record, record(1, 3))
            |> ScriptedIncus.put_status(@web_instance, "Stopped")
          end
      }
    end)

    assert {200, ~s({"StatusCode":3}\n)} = call(context, "/containers/web/wait")
  end

  test "not-running answers at once for a container that is not running", %{context: context} do
    assert {200, ~s({"StatusCode":0}\n)} =
             call(context, "/containers/job/wait?condition=not-running")
  end

  test "next-exit on a created container waits for the run it is about to start", %{
    context: context,
    native: native
  } do
    container = container(native, @job)
    {:ok, waiter} = Wait.begin(context, container, :next_exit, deadline())
    assert waiter.target_run == 1

    task = Task.async(fn -> Wait.run(waiter, deadline(), fn -> false end) end)
    Process.sleep(50)
    assert Task.yield(task, 0) == nil

    # The start and the exit both happen between two reads.
    ScriptedIncus.update(
      native,
      &ScriptedIncus.put_file(&1, @job_instance, @record, record(1, 7))
    )

    ScriptedIncus.event(native, ScriptedIncus.lifecycle(@job_instance, "instance-shutdown"))

    assert {:ok, %{"StatusCode" => 7}} = Task.await(task)
    Wait.close(waiter)
  end

  test "a stopped instance whose run has no exit record answers 137 with the reason", %{
    context: context,
    native: native
  } do
    {:ok, waiter} = Wait.begin(context, container(native, @web), :next_exit, deadline())
    ScriptedIncus.update(native, &ScriptedIncus.put_status(&1, @web_instance, "Stopped"))
    ScriptedIncus.event(native, ScriptedIncus.lifecycle(@web_instance, "instance-stopped"))

    assert {:ok,
            %{"StatusCode" => 137, "Error" => %{"Message" => "native: exit status not recorded"}}} =
             Wait.run(waiter, deadline(), fn -> false end)
  end

  test "removed deletes an auto-remove container after its exit, then answers", %{
    context: context,
    native: native
  } do
    ScriptedIncus.update(native, fn state ->
      state
      |> ScriptedIncus.put_status(@job_instance, "Running")
      |> ScriptedIncus.put_file(@job_instance, @record, record(1, nil))
    end)

    task = Task.async(fn -> call(context, "/containers/job/wait?condition=removed") end)

    # The exit happens only after the wait subscribed and read the running run.
    assert_receive {:incus, :subscribe}, 2_000
    assert_receive {:incus, {:read_file, @job_instance, @record}}, 2_000

    ScriptedIncus.update(native, fn state ->
      state
      |> ScriptedIncus.put_file(@job_instance, @record, record(1, 3))
      |> ScriptedIncus.put_status(@job_instance, "Stopped")
    end)

    ScriptedIncus.event(native, ScriptedIncus.lifecycle(@job_instance, "instance-shutdown"))

    assert {200, ~s({"StatusCode":3}\n)} = Task.await(task)
    assert_received {:incus, {:delete_instance, @job_instance}}
  end

  test "removed without auto-remove answers once someone else removes it", %{
    context: context,
    native: native
  } do
    ScriptedIncus.update(
      native,
      &ScriptedIncus.put_file(&1, @web_instance, @record, record(1, 0))
    )

    ScriptedIncus.update(native, &ScriptedIncus.put_status(&1, @web_instance, "Stopped"))

    {:ok, waiter} = Wait.begin(context, container(native, @web), :removed, deadline())

    ScriptedIncus.update(
      native,
      &ScriptedIncus.put_file(&1, @web_instance, @record, record(2, 4))
    )

    task = Task.async(fn -> Wait.run(waiter, deadline(), fn -> false end) end)
    Process.sleep(50)
    assert Task.yield(task, 0) == nil
    refute_received {:incus, {:delete_instance, _}}

    ScriptedIncus.delete_instance(native.client, @web_instance, deadline())
    ScriptedIncus.event(native, ScriptedIncus.lifecycle(@web_instance, "instance-deleted"))
    assert {:ok, %{"StatusCode" => 4}} = Task.await(task)
  end

  test "a client gone before removal removes nothing, and reap deletes it later", %{
    context: context,
    native: native
  } do
    ScriptedIncus.update(
      native,
      &ScriptedIncus.put_file(&1, @job_instance, @record, record(1, 0))
    )

    {:ok, waiter} = Wait.begin(context, container(native, @job), :removed, deadline())

    ScriptedIncus.update(
      native,
      &ScriptedIncus.put_file(&1, @job_instance, @record, record(2, 0))
    )

    gone = :counters.new(1, [])

    # The client disconnects after the exit is seen and before the removal.
    cancelled? = fn ->
      :counters.add(gone, 1, 1)
      :counters.get(gone, 1) > 1
    end

    assert :cancelled = Wait.run(waiter, deadline(), cancelled?)
    refute_received {:incus, {:delete_instance, _}}

    assert {:ok, [@job]} = Native.reap(context.target, timeout: 1_000)
    assert_received {:incus, {:delete_instance, @job_instance}}
  end

  test "the Plug ends a wait without removal when its client process exits", %{
    context: context,
    native: native
  } do
    ScriptedIncus.update(native, &ScriptedIncus.put_status(&1, @job_instance, "Running"))
    client = spawn(fn -> receive do: (:never -> :ok) end)

    task =
      Task.async(fn ->
        "POST"
        |> Test.conn("/containers/job/wait?condition=removed", "")
        |> Conn.put_private(:opsmaru_containers_peer, {context, self()})
        |> Conn.put_private(:opsmaru_containers_client, client)
        |> Plug.call(Plug.init(host: EngineFixture.AllowHost, stream_timeout: 5_000))
      end)

    Process.sleep(100)
    Process.exit(client, :kill)

    ScriptedIncus.update(native, fn state ->
      state
      |> ScriptedIncus.put_file(@job_instance, @record, record(1, 0))
      |> ScriptedIncus.put_status(@job_instance, "Stopped")
    end)

    conn = Task.await(task)
    assert conn.status == 200
    assert conn.resp_body == ""
    refute_received {:incus, {:delete_instance, _}}
  end

  test "reap keeps auto-remove containers that never started or still run", %{
    context: context,
    native: native
  } do
    assert {:ok, []} = Native.reap(context.target, timeout: 1_000)

    ScriptedIncus.update(
      native,
      &ScriptedIncus.put_file(&1, @job_instance, @record, record(1, 0))
    )

    assert {:ok, [@job]} = Native.reap(context.target, timeout: 1_000)
    refute_received {:incus, {:delete_instance, @web_instance}}
  end

  test "unknown conditions are refused", %{context: context} do
    assert {400, ~s({"message":"invalid condition: \\"later\\""})} =
             call(context, "/containers/web/wait?condition=later")
  end

  defp call(context, path) do
    conn =
      "POST"
      |> Test.conn(path, "")
      |> Conn.put_private(:opsmaru_containers_peer, {context, self()})
      |> Plug.call(Plug.init(host: EngineFixture.AllowHost, stream_timeout: 5_000))

    {conn.status, conn.resp_body}
  end

  defp container(native, id) do
    {:ok, instances} = ScriptedIncus.list_instances(native.client, deadline())
    instances |> Container.from_instances() |> Enum.find(&(&1.id == id))
  end

  defp instance(id, name, status, autoremove) do
    keys =
      Container.keys(%{
        id: id,
        name: name,
        created: DateTime.from_unix!(100),
        image_id: "sha256:" <> String.duplicate("b", 64),
        image_ref: "busybox",
        labels: %{},
        config: %{"Path" => "sh", "Args" => [], "HostConfig" => %{"AutoRemove" => autoremove}},
        init: "digest",
        autoremove: autoremove
      })

    %{"name" => Container.instance_name(id), "status" => status, "config" => keys}
  end

  defp record(run, code) do
    Jason.encode!(%{
      "version" => 1,
      "run" => run,
      "pid" => 5,
      "started_at" => "2026-11-27T10:00:00Z",
      "finished_at" => if(code, do: "2026-11-27T10:00:04Z"),
      "exit_code" => code,
      "signal" => nil,
      "oom_killed" => false,
      "error" => nil
    })
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 4_000
end
