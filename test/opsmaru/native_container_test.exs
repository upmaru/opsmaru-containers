defmodule Opsmaru.Containers.Native.ContainerTest do
  use ExUnit.Case, async: true

  alias Opsmaru.Containers.Native.Container

  @created ~U[2026-11-27 10:00:00.123456Z]

  test "IDs are 64 lowercase hex characters and name their instance" do
    ids = for _ <- 1..64, do: Container.new_id()

    assert Enum.all?(ids, &Regex.match?(~r/\A[0-9a-f]{64}\z/, &1))
    assert length(Enum.uniq(ids)) == 64

    id = "3f1c0a9b2d4e" <> String.duplicate("a", 52)
    assert Container.instance_name(id) == "oc-3f1c0a9b2d4e"
  end

  test "the keys an instance carries read back as the same container" do
    id = Container.new_id()
    keys = Container.keys(attributes(id))

    assert keys[Container.role_key()] == "container"
    assert keys["user.opsmaru.containers.name"] == "web"
    assert keys["user.opsmaru.containers.labels"] == ~s({"tier":"front"})
    assert keys["user.opsmaru.containers.autoremove"] == "true"

    exec_id = Container.new_id()
    config = Map.put(keys, Container.exec_key(exec_id), ~s({"Cmd":["sh"]}))

    assert {:ok, container} =
             Container.from_instance(%{
               "name" => Container.instance_name(id),
               "status" => "Stopped",
               "config" => Map.put(config, "volatile.base_image", "f00d")
             })

    assert %Container{
             id: ^id,
             name: "web",
             created: @created,
             image_id: "sha256:" <> _,
             image_ref: "nginx:1.29",
             labels: %{"tier" => "front"},
             config: %{"Cmd" => ["nginx"]},
             init: "digest",
             autoremove: true,
             status: "Stopped",
             base_image: "f00d"
           } = container

    assert container.execs == %{exec_id => %{"Cmd" => ["sh"]}}
  end

  test "instances without the role key or with keys that do not parse are ignored" do
    id = Container.new_id()
    keys = Container.keys(attributes(id))
    name = Container.instance_name(id)
    instance = &%{"name" => name, "status" => "Running", "config" => &1}

    for config <- [
          %{},
          Map.delete(keys, Container.role_key()),
          %{keys | Container.role_key() => "engine"},
          %{keys | "user.opsmaru.containers.id" => "XYZ"},
          %{keys | "user.opsmaru.containers.id" => Container.new_id()},
          %{keys | "user.opsmaru.containers.name" => "-bad"},
          %{keys | "user.opsmaru.containers.created" => "yesterday"},
          %{keys | "user.opsmaru.containers.labels" => ~s({"a":1})},
          %{keys | "user.opsmaru.containers.config" => "[]"}
        ] do
      assert Container.from_instance(instance.(config)) == :ignore
    end

    engine = %{"name" => "engine", "status" => "Running", "config" => %{}}
    assert [%Container{id: ^id}] = Container.from_instances([engine, instance.(keys)])
  end

  test "names follow Docker's rule" do
    assert Container.valid_name?("web")
    assert Container.valid_name?("/web-1.blue_2")
    refute Container.valid_name?("w")
    refute Container.valid_name?("_web")
    refute Container.valid_name?("web/1")
    refute Container.valid_name?(nil)
  end

  test "a name collision gets a fresh ID until the deadline" do
    parent = self()

    result =
      Container.create(now() + 1_000, fn id, instance ->
        send(parent, {:attempt, id, instance})
        attempts = Process.get(:attempts, 0) + 1
        Process.put(:attempts, attempts)
        if attempts < 3, do: {:error, :conflict}, else: {:ok, id}
      end)

    assert {:ok, id} = result
    assert_received {:attempt, first, "oc-" <> _}
    assert_received {:attempt, second, _}
    assert_received {:attempt, ^id, instance}
    assert instance == Container.instance_name(id)
    assert length(Enum.uniq([first, second, id])) == 3

    assert {:error, :deadline} = Container.create(now() - 1, fn _, _ -> {:error, :conflict} end)

    assert {:error, :rejected} =
             Container.create(now() + 1_000, fn _, _ -> {:error, :rejected} end)
  end

  defp attributes(id) do
    %{
      id: id,
      name: "/web",
      created: @created,
      image_id: "sha256:" <> String.duplicate("b", 64),
      image_ref: "nginx:1.29",
      labels: %{"tier" => "front"},
      config: %{"Cmd" => ["nginx"]},
      init: "digest",
      autoremove: true
    }
  end

  defp now, do: System.monotonic_time(:millisecond)
end
