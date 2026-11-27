defmodule Opsmaru.Containers.TestSupport.ScriptedIncus do
  @moduledoc """
  A scripted `Native.Backend`. Its state lives in an Agent whose pid is the
  scripted client's `server` field, so calls from any process reach it. Every
  call is reported to the observer as `{:incus, call}`. No Incus server,
  socket or network is used.

  State:

    * `:instances` - instance maps, as `GetInstances` returns them
    * `:files` - `%{{instance, path} => binary | {:error, reason}}`
    * `:images` - image maps, as `GetImages` returns them
    * `:exec` - `fn instance, command -> result end`
    * `:import` - `fn properties, metadata, rootfs_bytes -> result end`
  """

  @behaviour Opsmaru.Containers.Native.Backend

  alias Opsmaru.Containers.Native
  alias Opsmaru.Incus

  @doc "A scripted client for `project`, reporting calls to `observer`."
  def client(project, state, observer \\ self()) do
    defaults = %{instances: [], files: %{}, images: [], exec: nil, import: nil}

    {:ok, agent} =
      Agent.start(fn -> Map.merge(defaults, Map.new(state)) |> Map.put(:observer, observer) end)

    ExUnit.Callbacks.on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    %Incus{
      connection: Incus.Connection.unix!("/unused", owner: :fixture, project: project),
      context: Incus.Context.new!(owner: :fixture, identity: :host, ready?: fn -> true end),
      server: agent
    }
  end

  @doc "A native target in `project` over a scripted client."
  def target(state, observer \\ self()) do
    shim = %{path: "/opt/shim/init-arm64", sha256: Native.Target.digests()["aarch64"]}

    %Native.Target{
      client: client("native", state, observer),
      init: %{"aarch64" => shim},
      backend: __MODULE__
    }
  end

  @doc "Change the scripted state."
  def update(%Incus{server: agent}, fun), do: Agent.update(agent, fun)
  def update(%Native.Target{client: client}, fun), do: update(client, fun)

  @impl true
  def list_instances(client, _deadline) do
    report(client, :list_instances)
    {:ok, get(client, :instances)}
  end

  @impl true
  def read_file(client, instance, path, limit, _deadline) do
    report(client, {:read_file, instance, path})

    case Map.get(get(client, :files), {instance, path}, {:error, :not_found}) do
      bytes when is_binary(bytes) and byte_size(bytes) <= limit -> {:ok, bytes}
      bytes when is_binary(bytes) -> {:error, :too_large}
      error -> error
    end
  end

  @impl true
  def stream_file(client, instance, path, sink, _deadline) do
    report(client, {:stream_file, instance, path})

    case Map.get(get(client, :files), {instance, path}, {:error, :not_found}) do
      bytes when is_binary(bytes) -> deliver(chunks(bytes, 4096), sink)
      error -> error
    end
  end

  defp deliver([], _), do: :ok

  defp deliver([chunk | rest], sink) do
    if sink.(chunk) == :ok, do: deliver(rest, sink), else: {:error, :too_large}
  end

  @impl true
  def delete_instance(client, instance, _deadline) do
    report(client, {:delete_instance, instance})

    update(client, fn state ->
      %{state | instances: Enum.reject(state.instances, &(&1["name"] == instance))}
    end)

    :ok
  end

  @impl true
  def exec(client, instance, command, _deadline) do
    report(client, {:exec, instance, command})
    get(client, :exec).(instance, command)
  end

  @impl true
  def list_images(client, _deadline) do
    report(client, :list_images)
    {:ok, get(client, :images)}
  end

  @impl true
  def import_image(client, properties, metadata, rootfs, _deadline) do
    bytes = rootfs |> Enum.to_list() |> IO.iodata_to_binary()
    report(client, {:import_image, properties, metadata, bytes})
    get(client, :import).(properties, metadata, bytes)
  end

  @impl true
  def delete_image(client, fingerprint, _deadline) do
    report(client, {:delete_image, fingerprint})

    update(client, fn state ->
      %{state | images: Enum.reject(state.images, &(&1["fingerprint"] == fingerprint))}
    end)

    :ok
  end

  defp get(%Incus{server: agent}, key), do: Agent.get(agent, &Map.fetch!(&1, key))

  defp report(client, call), do: send(get(client, :observer), {:incus, call})

  defp chunks(<<chunk::binary-size(4096), rest::binary>>, 4096), do: [chunk | chunks(rest, 4096)]
  defp chunks("", _), do: []
  defp chunks(rest, _), do: [rest]
end
