defmodule Opsmaru.Containers.Native.Images do
  @moduledoc false
  # Image handoff (design decision 2). A native container's image always
  # comes from the nested engine: it is converted inside the engine instance
  # with skopeo and umoci, and both tarballs stream from the engine's files
  # API into a split upload to the native project, with no host files.
  #
  # Handoffs of one image ID are serialized per target, and the native project
  # is read before converting and after an uncertain upload. An uncertain
  # upload is reconciled by that read, and never replayed.

  alias Opsmaru.Containers.Docker.EngineRequest

  @property "opsmaru.containers.image_id"
  @image_id ~r/\Asha256:([0-9a-f]{64})\z/
  @architectures %{"arm64" => "aarch64", "amd64" => "x86_64"}
  @work "/var/lib/opsmaru-containers/handoff"
  @metadata_limit 16_777_216
  @lock_interval 50

  @tools ~S"""
  for tool in skopeo umoci; do command -v "$tool" >/dev/null 2>&1 || echo "$tool"; done
  """

  # Arguments: image ID, Incus architecture, work directory. No value is
  # interpolated into the script.
  @convert ~S"""
  set -eu
  id=$1 arch=$2 dir=$3
  rm -rf "$dir"
  mkdir -p "$dir"
  skopeo copy -q "docker-daemon:$id" "oci:$dir/oci:img"
  umoci unpack --image "$dir/oci:img" "$dir/bundle" >/dev/null
  printf '{"architecture":"%s","creation_date":%s,"expiry_date":0,"properties":{"type":"oci","opsmaru.containers.image_id":"%s"},"templates":null}\n' \
    "$arch" "$(date +%s)" "$id" > "$dir/metadata.yaml"
  tar -C "$dir" -cf "$dir/metadata.tar" metadata.yaml -C "$dir/bundle" config.json
  tar -C "$dir/bundle/rootfs" -cf "$dir/rootfs.tar" .
  gzip -1 "$dir/rootfs.tar"
  """

  def property, do: @property

  @doc """
  Resolves `reference` in the nested engine and returns the native project's
  Incus image for it, handing it over first if needed. Returns
  `{:ok, %{fingerprint: f, image: inspect}}`. A reference the nested engine
  does not have gets dockerd's own status and message.
  """
  def ensure(context, reference, api_version, deadline) do
    target = "/v#{api_version}/images/#{URI.encode(reference, &URI.char_unreserved?/1)}/json"

    case EngineRequest.json(context, "GET", target, nil, deadline) do
      {:ok, 200, %{"Id" => id} = image} ->
        with {:ok, fingerprint} <- ensure_image(context, id, image["Architecture"], deadline),
             do: {:ok, %{fingerprint: fingerprint, image: image}}

      {:ok, status, %{"message" => message}} when status in 400..499 ->
        {:error, status, message}

      _ ->
        {:error, 503, "Docker engine is not ready"}
    end
  end

  @doc false
  def ensure_image(context, image_id, docker_architecture, deadline) do
    native = context.target.native

    with {:ok, digest} <- digest(image_id),
         {:ok, architecture} <- architecture(docker_architecture),
         :none <- find(native, image_id, deadline) do
      serialized(lock(native, image_id), deadline, fn ->
        handoff_once(context, image_id, digest, architecture, deadline)
      end)
    end
  end

  # Another handoff may have finished while this one waited for the lock.
  defp handoff_once(context, image_id, digest, architecture, deadline) do
    case find(context.target.native, image_id, deadline) do
      :none -> handoff(context, image_id, digest, architecture, deadline)
      found -> found
    end
  end

  @doc "The fingerprint of the native project's image for a Docker image ID."
  def find(native, image_id, deadline) do
    case native.backend.list_images(native.client, deadline) do
      {:ok, images} ->
        case Enum.find(images, &(get_in(&1, ["properties", @property]) == image_id)) do
          %{"fingerprint" => fingerprint} -> {:ok, fingerprint}
          nil -> :none
        end

      {:error, _} ->
        {:error, 503, "native engine: Incus is not available"}
    end
  end

  @doc """
  Deletes the native project's handed-off images that no instance there was
  created from. Returns the deleted fingerprints.
  """
  def prune(native, deadline) do
    with {:ok, images} <- native.backend.list_images(native.client, deadline),
         {:ok, instances} <- native.backend.list_instances(native.client, deadline) do
      used = MapSet.new(instances, &get_in(&1, ["config", "volatile.base_image"]))

      deleted =
        for %{"fingerprint" => fingerprint} = image <- images,
            is_binary(get_in(image, ["properties", @property])),
            not MapSet.member?(used, fingerprint),
            native.backend.delete_image(native.client, fingerprint, deadline) == :ok,
            do: fingerprint

      {:ok, deleted}
    end
  end

  defp handoff(context, image_id, digest, architecture, deadline) do
    %{client: engine, instance: instance} = context.target
    native = context.target.native
    backend = native.backend
    dir = Path.join(@work, digest)

    with :ok <- tools(backend, engine, instance, deadline) do
      try do
        with :ok <- convert(backend, engine, instance, [image_id, architecture, dir], deadline),
             {:ok, metadata} <-
               file(
                 backend.read_file(
                   engine,
                   instance,
                   dir <> "/metadata.tar",
                   @metadata_limit,
                   deadline
                 )
               ) do
          rootfs = stream(backend, engine, instance, dir <> "/rootfs.tar.gz", deadline)
          properties = %{"type" => "oci", @property => image_id}

          upload(native, image_id, deadline, fn ->
            backend.import_image(native.client, properties, metadata, rootfs, deadline)
          end)
        end
      after
        backend.exec(engine, instance, ["rm", "-rf", dir], deadline)
      end
    end
  end

  defp tools(backend, engine, instance, deadline) do
    case backend.exec(engine, instance, ["sh", "-c", @tools], deadline) do
      {:ok, %{status: 0, stdout: ""}} ->
        :ok

      {:ok, %{status: 0, stdout: missing}} ->
        tool = missing |> String.split() |> hd()
        {:error, 500, "native engine: #{tool} is not installed in the engine instance"}

      _ ->
        {:error, 503, "native engine: the engine instance is not available"}
    end
  end

  defp convert(backend, engine, instance, arguments, deadline) do
    case backend.exec(engine, instance, ["sh", "-c", @convert, "handoff" | arguments], deadline) do
      {:ok, %{status: 0}} ->
        :ok

      {:ok, %{status: status, stderr: stderr}} ->
        detail = stderr |> String.slice(0, 512) |> String.trim()
        {:error, 500, "native engine: image conversion failed (exit #{status}): #{detail}"}

      _ ->
        {:error, 503, "native engine: the engine instance is not available"}
    end
  end

  defp file({:ok, bytes}), do: {:ok, bytes}
  defp file(_), do: {:error, 500, "native engine: the converted image could not be read"}

  defp upload(native, image_id, deadline, import) do
    result =
      try do
        import.()
      rescue
        _ -> {:error, :uncertain}
      catch
        _, _ -> {:error, :uncertain}
      end

    case result do
      {:ok, fingerprint} ->
        {:ok, fingerprint}

      {:error, :uncertain} ->
        case find(native, image_id, deadline) do
          {:ok, fingerprint} ->
            {:ok, fingerprint}

          _ ->
            {:error, 500,
             "native engine: the image upload outcome is unknown; it was not retried"}
        end

      {:error, _} ->
        {:error, 500, "native engine: Incus refused the image upload"}
    end
  end

  # The rootfs streams from the engine's files API into the upload, one chunk
  # at a time. The download runs in a producer process that hands each chunk
  # to whichever process enumerates the stream, and waits for it to ask for
  # the next. A failed download fails the upload rather than truncating it.
  defp stream(backend, engine, instance, path, deadline) do
    Stream.resource(
      fn -> producer(backend, engine, instance, path, deadline) end,
      fn
        :done ->
          {:halt, :done}

        producer ->
          send(producer, {:next, self()})

          receive do
            {^producer, {:chunk, bytes}} -> {[bytes], producer}
            {^producer, :done} -> {:halt, :done}
            {^producer, {:error, reason}} -> raise "rootfs download failed: #{inspect(reason)}"
          after
            max(deadline - System.monotonic_time(:millisecond), 0) ->
              raise "rootfs download timed out"
          end
      end,
      fn
        :done -> :ok
        producer -> Process.exit(producer, :kill)
      end
    )
  end

  # The producer hands chunks to the consumer. The download runs in a reader
  # process, and opsmaru_incus may call the sink from another process still,
  # so every message names its sender explicitly: the sink sends its chunk to
  # the producer and waits for the producer's acknowledgement.
  defp producer(backend, engine, instance, path, deadline) do
    spawn_link(fn ->
      producer = self()

      spawn_link(fn ->
        sink = &handoff(producer, &1, deadline)
        send(producer, {:result, backend.stream_file(engine, instance, path, sink, deadline)})
      end)

      produce(producer, deadline)
    end)
  end

  defp handoff(producer, bytes, deadline) do
    send(producer, {:chunk, self(), bytes})

    receive do
      {^producer, :ack} -> :ok
    after
      remaining(deadline) -> {:error, :deadline}
    end
  end

  defp produce(producer, deadline) do
    receive do
      {:next, consumer} ->
        receive do
          {:chunk, reader, bytes} ->
            send(consumer, {producer, {:chunk, bytes}})
            send(reader, {producer, :ack})
            produce(producer, deadline)

          {:result, :ok} ->
            send(consumer, {producer, :done})

          {:result, error} ->
            send(consumer, {producer, {:error, error}})
        after
          remaining(deadline) -> exit(:normal)
        end
    after
      remaining(deadline) -> exit(:normal)
    end
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp serialized(key, deadline, fun) do
    if :global.set_lock(key, [node()], 0) do
      try do
        fun.()
      after
        :global.del_lock(key, [node()])
      end
    else
      if System.monotonic_time(:millisecond) + @lock_interval < deadline do
        Process.sleep(@lock_interval)
        serialized(key, deadline, fun)
      else
        {:error, 503, "native engine: another handoff of this image did not finish in time"}
      end
    end
  end

  defp lock(native, image_id) do
    connection = native.client.connection
    {{__MODULE__, connection.owner, connection.project, image_id}, self()}
  end

  defp digest(image_id) do
    case Regex.run(@image_id, image_id || "", capture: :all_but_first) do
      [digest] -> {:ok, digest}
      _ -> {:error, 500, "native engine: invalid image ID #{inspect(image_id)}"}
    end
  end

  defp architecture(docker) do
    case Map.fetch(@architectures, docker) do
      {:ok, architecture} ->
        {:ok, architecture}

      :error ->
        {:error, 400, "native engine: image architecture #{inspect(docker)} is not supported"}
    end
  end
end
