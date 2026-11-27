defmodule Opsmaru.Containers.Native.Container do
  @moduledoc false
  # A native container's identity, read from and written to its Incus
  # instance's `user.opsmaru.containers.*` keys. The library keeps no other
  # record. Instances without the role key, or with keys that do not parse,
  # are not native containers and every route ignores them.

  @prefix "user.opsmaru.containers."
  @role @prefix <> "role"
  @exec_prefix @prefix <> "exec."
  @id ~r/\A[0-9a-f]{64}\z/
  # Docker's own container name rule (`daemon/names`), without the leading `/`.
  @name ~r/\A[a-zA-Z0-9][a-zA-Z0-9_.-]+\z/

  @enforce_keys [:id, :name, :instance]
  defstruct [
    :id,
    :name,
    :instance,
    :created,
    :image_id,
    :image_ref,
    :init,
    :status,
    :base_image,
    labels: %{},
    config: %{},
    autoremove: false,
    execs: %{}
  ]

  @type t :: %__MODULE__{}

  @doc "The key every native container instance carries."
  def role_key, do: @role

  @doc "The instance config key holding one exec record."
  def exec_key(exec_id), do: @exec_prefix <> exec_id

  @doc "A new 64-hex Docker ID from a cryptographically secure generator."
  def new_id, do: :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

  @doc "The instance name for a Docker ID: `oc-` and the first 12 hex characters."
  def instance_name(<<short::binary-size(12), _::binary>>), do: "oc-" <> short

  @doc "Whether a Docker container name is valid, with or without its leading `/`."
  def valid_name?("/" <> name), do: valid_name?(name)
  def valid_name?(name) when is_binary(name), do: Regex.match?(@name, name)
  def valid_name?(_), do: false

  @doc """
  The instance config keys for a new native container. `attributes` holds
  `:id`, `:name`, `:created` (a `DateTime`), `:image_id`, `:image_ref`,
  `:labels`, `:config`, `:init` (the shim digest) and `:autoremove`.
  """
  def keys(attributes) do
    %{
      @role => "container",
      (@prefix <> "id") => attributes.id,
      (@prefix <> "name") => String.trim_leading(attributes.name, "/"),
      (@prefix <> "created") => DateTime.to_iso8601(attributes.created),
      (@prefix <> "image_id") => attributes.image_id,
      (@prefix <> "image_ref") => attributes.image_ref,
      (@prefix <> "labels") => Jason.encode!(attributes.labels),
      (@prefix <> "config") => Jason.encode!(attributes.config),
      (@prefix <> "init") => attributes.init,
      (@prefix <> "autoremove") => to_string(attributes.autoremove == true)
    }
  end

  @doc """
  Reads a native container from an Incus instance. Returns `:ignore` for an
  instance without the role key or with keys that do not describe a native
  container.
  """
  def from_instance(%{"name" => instance, "config" => %{@role => "container"} = config} = data) do
    with id when is_binary(id) <- config[@prefix <> "id"],
         true <- Regex.match?(@id, id) and instance == instance_name(id),
         name when is_binary(name) <- config[@prefix <> "name"],
         true <- valid_name?(name),
         {:ok, created, _} <- DateTime.from_iso8601(config[@prefix <> "created"] || ""),
         {:ok, labels} <- json(config[@prefix <> "labels"], &string_map?/1),
         {:ok, create_config} <- json(config[@prefix <> "config"], &is_map/1) do
      {:ok,
       %__MODULE__{
         id: id,
         name: name,
         instance: instance,
         created: created,
         image_id: config[@prefix <> "image_id"],
         image_ref: config[@prefix <> "image_ref"],
         init: config[@prefix <> "init"],
         autoremove: config[@prefix <> "autoremove"] == "true",
         labels: labels,
         config: create_config,
         status: data["status"],
         base_image: config["volatile.base_image"],
         execs: execs(config)
       }}
    else
      _ -> :ignore
    end
  end

  def from_instance(_), do: :ignore

  @doc "The native containers among listed instances, ignoring every other instance."
  def from_instances(instances) do
    for instance <- instances, {:ok, container} <- [from_instance(instance)], do: container
  end

  @doc """
  Creates with a fresh ID until `create` stops reporting a name collision
  (`{:error, :conflict}`) or the deadline passes. `create` receives the ID and
  its instance name.
  """
  def create(deadline, create) do
    id = new_id()

    case create.(id, instance_name(id)) do
      {:error, :conflict} ->
        if System.monotonic_time(:millisecond) < deadline,
          do: create(deadline, create),
          else: {:error, :deadline}

      result ->
        result
    end
  end

  defp execs(config) do
    for {@exec_prefix <> exec_id, value} <- config,
        Regex.match?(@id, exec_id),
        {:ok, record} <- [json(value, &is_map/1)],
        into: %{},
        do: {exec_id, record}
  end

  defp json(value, valid?) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> if valid?.(decoded), do: {:ok, decoded}, else: :error
      _ -> :error
    end
  end

  defp json(_, _), do: :error

  defp string_map?(map),
    do: is_map(map) and Enum.all?(map, fn {k, v} -> is_binary(k) and is_binary(v) end)
end
