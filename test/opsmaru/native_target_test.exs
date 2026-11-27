defmodule Opsmaru.Containers.Native.TargetTest do
  use ExUnit.Case, async: true

  alias Opsmaru.Containers.{Context, Native}
  alias Opsmaru.Containers.Nested.Target
  alias Opsmaru.Incus

  @moduletag :tmp_dir

  test "reads one digest per architecture from the shim README" do
    digests = Native.Target.digests()

    assert Map.keys(digests) |> Enum.sort() == ["aarch64", "x86_64"]
    assert Enum.all?(Map.values(digests), &Regex.match?(~r/\A[0-9a-f]{64}\z/, &1))

    readme = File.read!("priv/native_init/README.md")
    assert readme =~ "| linux/arm64 | `#{digests["aarch64"]}` |"
    assert readme =~ "| linux/amd64 | `#{digests["x86_64"]}` |"
  end

  test "verifies each binary once and looks shims up by either architecture name", %{
    tmp_dir: dir
  } do
    {arm, arm_digest} = binary(dir, "arm", "arm64 shim")
    {x86, x86_digest} = binary(dir, "x86", "amd64 shim")
    digests = %{"aarch64" => arm_digest, "x86_64" => x86_digest}

    assert {:ok, target} =
             Native.Target.build(client("native"), %{"aarch64" => arm, "x86_64" => x86}, digests)

    assert target.init["aarch64"] == %{path: arm, sha256: arm_digest}
    assert {:ok, %{path: ^arm}} = Native.Target.shim(target, "arm64")
    assert {:ok, %{path: ^arm}} = Native.Target.shim(target, "aarch64")
    assert {:ok, %{path: ^x86}} = Native.Target.shim(target, "amd64")
    assert {:error, {:no_native_init, "riscv64"}} = Native.Target.shim(target, "riscv64")

    assert {:ok, only_arm} = Native.Target.build(client("native"), %{"aarch64" => arm}, digests)
    assert {:error, {:no_native_init, "amd64"}} = Native.Target.shim(only_arm, "amd64")
  end

  test "refuses unknown digests, unknown architectures and unusable paths", %{tmp_dir: dir} do
    {arm, arm_digest} = binary(dir, "arm", "arm64 shim")
    {other, other_digest} = binary(dir, "other", "edited shim")
    digests = %{"aarch64" => arm_digest}
    native = client("native")

    assert {:error, {:unknown_native_init, "aarch64", ^other_digest}} =
             Native.Target.build(native, %{"aarch64" => other}, digests)

    assert {:error, {:unsupported_architecture, "riscv64"}} =
             Native.Target.build(native, %{"riscv64" => arm}, digests)

    assert {:error, {:invalid_native_init_path, "relative/init"}} =
             Native.Target.build(native, %{"aarch64" => "relative/init"}, digests)

    missing = Path.join(dir, "missing")

    assert {:error, {:native_init_unreadable, ^missing, :enoent}} =
             Native.Target.build(native, %{"aarch64" => missing}, digests)

    assert {:error, :invalid_native_target} = Native.Target.build(native, %{}, digests)
  end

  test "the README digests are what new/2 checks against", %{tmp_dir: dir} do
    {path, _} = binary(dir, "arm", "not the released shim")

    assert {:error, {:unknown_native_init, "aarch64", _}} =
             Native.Target.new(client("native"), %{"aarch64" => path})
  end

  test "context validation keeps the native project apart from the nested one" do
    nested = client("fixtures")
    shim = %{path: "/opt/shim/init-arm64", sha256: Native.Target.digests()["aarch64"]}
    native = %Native.Target{client: client("native"), init: %{"aarch64" => shim}}

    assert Context.validate(context(nil)) == :ok
    assert Context.validate(context(native)) == :ok

    for invalid <- [
          %{native | client: nested},
          %{native | client: client("native", owner: :other)},
          %{native | client: client("native", identity: :other)},
          %{native | init: %{}},
          %{native | init: %{"aarch64" => %{shim | sha256: String.duplicate("0", 64)}}},
          %{native | init: %{"aarch64" => %{shim | path: "init"}}},
          %{native | init: %{"x86_64" => shim}},
          :native
        ] do
      assert Context.validate(context(invalid)) == {:error, :invalid_context}
    end
  end

  defp binary(dir, name, contents) do
    path = Path.join(dir, name)
    File.write!(path, contents)
    {path, :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)}
  end

  defp context(native) do
    %Context{
      identity: :verified_peer,
      dialer: {__MODULE__, nil},
      target: %Target{client: client("fixtures"), instance: "engine", native: native}
    }
  end

  defp client(project, options \\ []) do
    owner = Keyword.get(options, :owner, :fixture)

    %Incus{
      connection: Incus.Connection.unix!("/unused", owner: owner, project: project),
      context:
        Incus.Context.new!(
          owner: owner,
          identity: Keyword.get(options, :identity, :host),
          ready?: fn -> true end
        ),
      server: nil
    }
  end
end
