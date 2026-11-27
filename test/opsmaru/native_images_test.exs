defmodule Opsmaru.Containers.Native.ImagesTest do
  use ExUnit.Case, async: true

  alias Opsmaru.Containers.Native
  alias Opsmaru.Containers.Native.Images
  alias Opsmaru.Containers.TestSupport.{EngineFixture, ScriptedIncus}

  @digest String.duplicate("d", 64)
  @image_id "sha256:" <> @digest
  @dir "/var/lib/opsmaru-containers/handoff/" <> @digest
  @rootfs :binary.copy("r", 10_000)

  setup do
    engine = EngineFixture.start()
    test = self()

    native =
      ScriptedIncus.target(
        import: fn _properties, _metadata, _rootfs ->
          send(test, :imported)
          {:ok, "fp-new"}
        end
      )

    engine_client =
      ScriptedIncus.client("fixtures",
        files: %{
          {"engine", @dir <> "/metadata.tar"} => "metadata-tar",
          {"engine", @dir <> "/rootfs.tar.gz"} => @rootfs
        },
        exec: fn "engine", _command -> {:ok, %{status: 0, stdout: "", stderr: ""}} end
      )

    context = EngineFixture.context(engine)
    target = %{context.target | client: engine_client, native: native}
    context = %{context | target: target, capabilities: %{context.capabilities | target: target}}
    %{engine: engine, context: context, native: native, engine_client: engine_client}
  end

  test "the first use of an image converts it in the engine and streams a split upload", %{
    engine: engine,
    context: context
  } do
    task = Task.async(fn -> Images.ensure(context, "nginx:1.29", "1.57", deadline()) end)
    {head, _} = serve(engine, 200, Jason.encode!(%{"Id" => @image_id, "Architecture" => "arm64"}))
    assert head =~ "GET /v1.57/images/nginx%3A1.29/json HTTP/1.1"

    assert {:ok, %{fingerprint: "fp-new", image: %{"Id" => @image_id}}} = Task.await(task)

    assert_received {:incus, :list_images}
    assert_received {:incus, :list_images}
    assert_received {:incus, {:exec, "engine", ["sh", "-c", tools]}}
    assert tools =~ "skopeo umoci"

    assert_received {:incus,
                     {:exec, "engine",
                      ["sh", "-c", convert, "handoff", @image_id, "aarch64", @dir]}}

    assert convert =~ ~s(skopeo copy -q "docker-daemon:$id")
    refute convert =~ @image_id
    assert_received {:incus, {:read_file, "engine", @dir <> "/metadata.tar"}}
    assert_received {:incus, {:stream_file, "engine", @dir <> "/rootfs.tar.gz"}}

    assert_received {:incus, {:import_image, properties, "metadata-tar", @rootfs}}
    assert properties == %{"type" => "oci", "opsmaru.containers.image_id" => @image_id}
    assert_received {:incus, {:exec, "engine", ["rm", "-rf", @dir]}}
  end

  test "an image already handed off is reused without conversion", %{
    context: context,
    native: native
  } do
    ScriptedIncus.update(native, &%{&1 | images: [image("fp-old", @image_id)]})

    assert {:ok, "fp-old"} = Images.ensure_image(context, @image_id, "arm64", deadline())
    refute_received {:incus, {:exec, _, _}}
    refute_received :imported
  end

  test "an image missing from the nested engine gets dockerd's own error", %{
    engine: engine,
    context: context
  } do
    task = Task.async(fn -> Images.ensure(context, "missing", "1.57", deadline()) end)
    serve(engine, 404, ~s({"message":"No such image: missing:latest"}))

    assert {:error, 404, "No such image: missing:latest"} = Task.await(task)
    refute_received {:incus, _}
  end

  test "missing conversion tools are named before any conversion", %{
    context: context,
    engine_client: engine_client
  } do
    ScriptedIncus.update(engine_client, fn state ->
      %{state | exec: fn _, _ -> {:ok, %{status: 0, stdout: "umoci\n", stderr: ""}} end}
    end)

    assert {:error, 500, "native engine: umoci is not installed in the engine instance"} =
             Images.ensure_image(context, @image_id, "arm64", deadline())

    assert_received {:incus, {:exec, "engine", ["sh", "-c", _]}}
    refute_received {:incus, {:exec, "engine", ["sh", "-c", _, "handoff" | _]}}
    refute_received :imported
  end

  test "an uncertain upload is reconciled by reading Incus and never replayed", %{
    context: context,
    native: native
  } do
    ScriptedIncus.update(native, fn state ->
      %{
        state
        | import: fn _, _, _ ->
            ScriptedIncus.update(native, &%{&1 | images: [image("fp-landed", @image_id)]})
            {:error, :uncertain}
          end
      }
    end)

    assert {:ok, "fp-landed"} = Images.ensure_image(context, @image_id, "arm64", deadline())

    ScriptedIncus.update(
      native,
      &%{&1 | images: [], import: fn _, _, _ -> {:error, :uncertain} end}
    )

    assert {:error, 500, message} = Images.ensure_image(context, @image_id, "arm64", deadline())
    assert message =~ "was not retried"
    assert_received {:incus, {:import_image, _, _, _}}
    assert_received {:incus, {:import_image, _, _, _}}
    refute_received {:incus, {:import_image, _, _, _}}
  end

  test "a failed rootfs download fails the upload instead of truncating it", %{
    context: context,
    engine_client: engine_client
  } do
    ScriptedIncus.update(engine_client, fn state ->
      %{state | files: Map.delete(state.files, {"engine", @dir <> "/rootfs.tar.gz"})}
    end)

    assert {:error, 500, _} = Images.ensure_image(context, @image_id, "arm64", deadline())
    refute_received :imported
    assert_received {:incus, {:exec, "engine", ["rm", "-rf", @dir]}}
  end

  test "concurrent handoffs of one image upload it once", %{
    context: context,
    native: native,
    engine_client: engine_client
  } do
    test = self()

    ScriptedIncus.update(engine_client, fn state ->
      exec = fn
        _, ["sh", "-c", _, "handoff" | _] ->
          send(test, {:converting, self()})
          receive do: (:go -> {:ok, %{status: 0, stdout: "", stderr: ""}})

        _, _ ->
          {:ok, %{status: 0, stdout: "", stderr: ""}}
      end

      %{state | exec: exec}
    end)

    ScriptedIncus.update(native, fn state ->
      %{
        state
        | import: fn _, _, _ ->
            ScriptedIncus.update(native, &%{&1 | images: [image("fp-once", @image_id)]})
            {:ok, "fp-once"}
          end
      }
    end)

    first = Task.async(fn -> Images.ensure_image(context, @image_id, "arm64", deadline()) end)
    assert_receive {:converting, converter}, 1_000
    second = Task.async(fn -> Images.ensure_image(context, @image_id, "arm64", deadline()) end)
    Process.sleep(150)
    send(converter, :go)

    assert {:ok, "fp-once"} = Task.await(first)
    assert {:ok, "fp-once"} = Task.await(second)
    assert_received {:incus, {:import_image, _, _, _}}
    refute_received {:incus, {:import_image, _, _, _}}
    refute_received {:converting, _}
  end

  test "unsupported architectures and malformed IDs are refused", %{context: context} do
    assert {:error, 400, _} = Images.ensure_image(context, @image_id, "riscv64", deadline())
    assert {:error, 500, _} = Images.ensure_image(context, "sha256:short", "arm64", deadline())
  end

  test "prune_images deletes only unused handed-off images", %{context: context, native: native} do
    ScriptedIncus.update(native, fn state ->
      %{
        state
        | images: [
            image("fp-used", @image_id),
            image("fp-unused", "sha256:" <> String.duplicate("e", 64)),
            %{"fingerprint" => "fp-foreign", "properties" => %{"os" => "debian"}}
          ],
          instances: [%{"name" => "oc-1", "config" => %{"volatile.base_image" => "fp-used"}}]
      }
    end)

    assert {:ok, ["fp-unused"]} = Native.prune_images(context.target, timeout: 1_000)
    assert_received {:incus, {:delete_image, "fp-unused"}}
    refute_received {:incus, {:delete_image, _}}
  end

  defp image(fingerprint, image_id),
    do: %{"fingerprint" => fingerprint, "properties" => %{Images.property() => image_id}}

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

  defp deadline, do: System.monotonic_time(:millisecond) + 3_000
end
