defmodule Opsmaru.Containers.Native.RoutingTest do
  use ExUnit.Case, async: true

  alias Elixir.Plug.{Conn, Test}
  alias Opsmaru.Containers.Docker.{Plug, Raw}
  alias Opsmaru.Containers.Native.{Container, Names}
  alias Opsmaru.Containers.TestSupport.{EngineFixture, ScriptedIncus}

  @web "aaaa1111" <> String.duplicate("1", 56)
  @old "aaaa2222" <> String.duplicate("2", 56)
  @new "bbbb3333" <> String.duplicate("3", 56)
  @nested "cccc4444" <> String.duplicate("4", 56)
  @record "/.opsmaru/state/run.json"

  setup do
    engine = EngineFixture.start()

    native =
      ScriptedIncus.target(
        instances: [
          instance(@web, "web", "Running", 300, %{"tier" => "front"}),
          instance(@old, "old", "Stopped", 100, %{"tier" => "back"}),
          instance(@new, "new", "Stopped", 400, %{}),
          %{"name" => "unmarked", "status" => "Running", "config" => %{}}
        ],
        files: %{
          {Container.instance_name(@web), @record} => record(1, ago(90), nil, nil),
          {Container.instance_name(@old), @record} => record(2, ago(7_200), ago(3_600), 3)
        }
      )

    context = EngineFixture.context(engine)
    target = %{context.target | native: native}
    context = %{context | target: target, capabilities: %{context.capabilities | target: target}}
    %{engine: engine, context: context}
  end

  test "routes without a native field never ask Incus", %{engine: engine, context: context} do
    task = request(context, "GET", "/images/json")
    serve(engine, 200, "[]")

    assert {200, []} = await(task)
    refute_received {:incus, _}
  end

  test "a native container by ID or name is never relayed to nested", %{context: context} do
    for reference <- [@web, "web", "/web"] do
      path = "/containers/#{URI.encode_www_form(reference)}/top"

      assert {501, %{"message" => "native engine: top is not served for native containers"}} =
               await(request(context, "GET", path))
    end

    refute_received {:dialed, _}
    assert_received {:incus, :list_instances}
  end

  test "a reference that matches nothing native goes to nested unchanged", %{
    engine: engine,
    context: context
  } do
    task = request(context, "GET", "/containers/unmarked/json")
    {head, _} = serve(engine, 404, ~s({"message":"No such container: unmarked"}))

    assert head =~ "GET /containers/unmarked/json HTTP/1.1"
    assert {404, %{"message" => "No such container: unmarked"}} = await(task)
  end

  test "a native ID prefix asks nested, where an exact match wins and a prefix is ambiguous", %{
    engine: engine,
    context: context
  } do
    # Only native matches.
    task = request(context, "GET", "/containers/bbbb/json")
    {head, _} = serve(engine, 404, ~s({"message":"No such container: bbbb"}))
    assert head =~ "GET /v1.57/containers/bbbb/json HTTP/1.1"
    assert {200, %{"Id" => @new, "Name" => "/new"}} = await(task)

    # Both engines match by prefix.
    task = request(context, "GET", "/containers/bbbb/json")

    serve(
      engine,
      200,
      Jason.encode!(%{"Id" => "bbbb" <> String.duplicate("9", 60), "Name" => "/x"})
    )

    assert {400, %{"message" => "multiple IDs found with provided prefix: bbbb"}} = await(task)

    # Nested has a container named like the prefix: Docker matches names first.
    task = request(context, "GET", "/containers/bbbb/json")
    serve(engine, 200, Jason.encode!(%{"Id" => @nested, "Name" => "/bbbb"}))
    {head, _} = serve(engine, 200, ~s({"Id":"#{@nested}"}))
    assert head =~ "GET /containers/bbbb/json HTTP/1.1"
    assert {200, %{"Id" => @nested}} = await(task)

    # Two native containers share the prefix.
    assert {400, %{"message" => "multiple IDs found with provided prefix: aaaa"}} =
             await(request(context, "GET", "/containers/aaaa/json"))
  end

  test "native exec IDs are routed by their container's exec records", %{
    engine: engine,
    context: context
  } do
    exec_id = String.duplicate("e", 64)

    ScriptedIncus.update(context.target.native, fn state ->
      [web | rest] = state.instances
      web = put_in(web, ["config", Container.exec_key(exec_id)], ~s({"Cmd":["sh"]}))
      %{state | instances: [web | rest]}
    end)

    assert {200, %{"ID" => ^exec_id, "ContainerID" => @web, "Running" => false}} =
             await(request(context, "GET", "/exec/#{exec_id}/json"))

    task = request(context, "GET", "/exec/#{String.duplicate("f", 64)}/json")
    serve(engine, 404, ~s({"message":"No such exec instance"}))
    assert {404, _} = await(task)
  end

  test "the listing merges both engines newest first", %{engine: engine, context: context} do
    nested = [%{"Id" => @nested, "Names" => ["/n"], "Created" => 200, "State" => "exited"}]

    task = request(context, "GET", "/containers/json?all=1")
    {head, _} = serve(engine, 200, Jason.encode!(nested))
    assert head =~ "GET /containers/json?all=1 HTTP/1.1"

    assert {200, entries} = await(task)
    assert Enum.map(entries, & &1["Id"]) == [@new, @web, @nested, @old]

    [new, web, _, old] = entries
    assert %{"Names" => ["/new"], "State" => "created", "Status" => "Created"} = new
    assert %{"State" => "running", "Status" => "Up About a minute"} = web
    assert %{"State" => "exited", "Status" => "Exited (3) About an hour ago"} = old
    assert web["Labels"] == %{"tier" => "front"}
    assert web["Image"] == "nginx:1.29"
    assert web["Created"] == 300
    assert web["Command"] == "/docker-entrypoint.sh nginx -g daemon off;"
  end

  test "the listing applies Docker's defaults, filters and limit", %{
    engine: engine,
    context: context
  } do
    list = fn query ->
      task = request(context, "GET", "/containers/json" <> query)
      serve(engine, 200, "[]")
      {200, entries} = await(task)
      Enum.map(entries, & &1["Id"])
    end

    filters = &("?filters=" <> URI.encode_www_form(Jason.encode!(&1)))

    assert list.("") == [@web]
    assert list.("?limit=2") == [@new, @web]
    assert list.(filters.(%{"status" => ["exited"]})) == [@old]
    assert list.(filters.(%{"exited" => ["3"]}) <> "&all=1") == [@old]
    assert list.(filters.(%{"label" => ["tier=back"]}) <> "&all=1") == [@old]
    assert list.(filters.(%{"label" => %{"tier" => true}}) <> "&all=1") == [@web, @old]
    assert list.(filters.(%{"name" => ["^/ne"]}) <> "&all=1") == [@new]
    assert list.(filters.(%{"id" => ["aaaa"]}) <> "&all=1") == [@web, @old]
  end

  test "the listing resolves ancestors in nested", %{engine: engine, context: context} do
    query = "?all=1&filters=" <> URI.encode_www_form(~s({"ancestor":["nginx"]}))
    task = request(context, "GET", "/containers/json" <> query)
    serve(engine, 200, "[]")
    {head, _} = serve(engine, 200, Jason.encode!(%{"Id" => image_id()}))
    assert head =~ "GET /v1.57/images/nginx/json HTTP/1.1"

    assert {200, entries} = await(task)
    assert Enum.map(entries, & &1["Id"]) == [@new, @web, @old]
  end

  test "the listing refuses filters native cannot apply and passes nested errors through", %{
    engine: engine,
    context: context
  } do
    query = "?filters=" <> URI.encode_www_form(~s({"before":["x"]}))

    assert {400, %{"message" => message}} =
             await(request(context, "GET", "/containers/json" <> query))

    assert message =~ "the before filter is not supported"
    refute_received {:dialed, _}

    query = "?filters=" <> URI.encode_www_form(~s({"status":["bogus"]}))
    task = request(context, "GET", "/containers/json" <> query)
    serve(engine, 400, ~s({"message":"Unrecognised filter value for status"}))
    assert {400, %{"message" => "Unrecognised filter value for status"}} = await(task)
  end

  test "an empty native project leaves the listing to nested", %{engine: engine, context: context} do
    ScriptedIncus.update(context.target.native, &%{&1 | instances: []})

    task = request(context, "GET", "/containers/json?all=1")
    {head, _} = serve(engine, 200, ~s([{"Id":"#{@nested}"}]))
    assert head =~ "GET /containers/json?all=1 HTTP/1.1"
    assert {200, [%{"Id" => @nested}]} = await(task)
  end

  test "prune removes stopped containers in both engines", %{engine: engine, context: context} do
    task = request(context, "POST", "/containers/prune")
    {head, _} = serve(engine, 200, ~s({"ContainersDeleted":["#{@nested}"],"SpaceReclaimed":5}))
    assert head =~ "POST /containers/prune HTTP/1.1"

    assert {200, %{"ContainersDeleted" => deleted, "SpaceReclaimed" => 5}} = await(task)
    assert Enum.sort(deleted) == Enum.sort([@nested, @old, @new])
    assert_received {:incus, {:delete_instance, "oc-aaaa22222222"}}
    assert_received {:incus, {:delete_instance, "oc-bbbb33333333"}}
    refute_received {:incus, {:delete_instance, "oc-aaaa11111111"}}
  end

  test "prune applies label and until filters", %{engine: engine, context: context} do
    query = "?filters=" <> URI.encode_www_form(~s({"label!":["tier=back"]}))
    task = request(context, "POST", "/containers/prune" <> query)
    serve(engine, 200, ~s({"ContainersDeleted":null,"SpaceReclaimed":0}))
    assert {200, %{"ContainersDeleted" => [@new]}} = await(task)

    query = "?filters=" <> URI.encode_www_form(~s({"until":["150"]}))
    task = request(context, "POST", "/containers/prune" <> query)
    serve(engine, 200, ~s({"ContainersDeleted":null,"SpaceReclaimed":0}))
    assert {200, %{"ContainersDeleted" => [@old]}} = await(task)
  end

  test "names stay unique across engines on nested create and rename", %{
    engine: engine,
    context: context
  } do
    body = ~s({"Image":"nginx"})

    assert {409, %{"message" => message}} =
             await(request(context, "POST", "/containers/create?name=web", body))

    assert message ==
             ~s(Conflict. The container name "/web" is already in use by container "#{@web}". ) <>
               "You have to remove (or rename) that container to be able to reuse that name."

    refute_received {:dialed, _}

    assert {409, %{"message" => "Error when allocating new name: Conflict." <> _}} =
             await(request(context, "POST", "/containers/#{@nested}/rename?name=old"))

    task = request(context, "POST", "/containers/create?name=fresh", body)
    {head, _} = serve(engine, 201, ~s({"Id":"#{@nested}","Warnings":[]}))
    assert head =~ "POST /containers/create?name=fresh HTTP/1.1"
    assert {201, _} = await(task)
  end

  test "a native create name is checked against nested by exact name", %{
    engine: engine,
    context: context
  } do
    check = fn name, status, body ->
      task = Task.async(fn -> Names.check_nested(context, name, "1.57", deadline()) end)
      {head, _} = serve(engine, status, body)
      assert head =~ "GET /v1.57/containers/#{name}/json HTTP/1.1"
      Task.await(task)
    end

    assert {:error, 409, "Conflict." <> _} =
             check.("taken", 200, Jason.encode!(%{"Id" => @nested, "Name" => "/taken"}))

    assert :ok = check.("cccc", 200, Jason.encode!(%{"Id" => @nested, "Name" => "/other"}))
    assert :ok = check.("free", 404, ~s({"message":"No such container: free"}))
  end

  test "a refused raw stream on a native container is answered before dialing", %{
    context: context
  } do
    request = %{
      method: "POST",
      path: "/containers/web/attach",
      query: "stream=1&stdout=1&stdin=1",
      peer: {127, 0, 0, 1},
      host_peer: {context, self()},
      headers: [{"upgrade", "tcp"}, {"connection", "Upgrade"}],
      body: ""
    }

    assert {:http, 501, _, body} =
             Raw.open(EngineFixture.AllowHost, request,
               admission_deadline: deadline(),
               deadline: deadline()
             )

    assert %{"message" => "native engine cannot honour: stdin attach"} = Jason.decode!(body)
    refute_received {:dialed, _}
  end

  defp request(context, method, path, body \\ "") do
    Task.async(fn ->
      conn =
        method
        |> Test.conn(path, body)
        |> Conn.put_private(:opsmaru_containers_peer, {context, self()})
        |> Plug.call(Plug.init(host: EngineFixture.AllowHost))

      {conn.status, Jason.decode!(conn.resp_body)}
    end)
  end

  defp await(task), do: Task.await(task, 5_000)

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

  defp instance(id, name, status, created, labels) do
    keys =
      Container.keys(%{
        id: id,
        name: name,
        created: DateTime.from_unix!(created),
        image_id: image_id(),
        image_ref: "nginx:1.29",
        labels: labels,
        config: %{
          "Path" => "/docker-entrypoint.sh",
          "Args" => ["nginx", "-g", "daemon off;"],
          "HostConfig" => %{"NetworkMode" => "bridge"}
        },
        init: "digest",
        autoremove: false
      })

    %{"name" => Container.instance_name(id), "status" => status, "config" => keys}
  end

  defp record(run, started, finished, code) do
    Jason.encode!(%{
      "version" => 1,
      "run" => run,
      "pid" => 12,
      "started_at" => started,
      "finished_at" => finished,
      "exit_code" => code,
      "signal" => nil,
      "oom_killed" => false,
      "error" => nil
    })
  end

  defp ago(seconds), do: DateTime.utc_now() |> DateTime.add(-seconds) |> DateTime.to_iso8601()
  defp image_id, do: "sha256:" <> String.duplicate("b", 64)
  defp deadline, do: System.monotonic_time(:millisecond) + 2_000
end
