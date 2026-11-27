defmodule Opsmaru.Containers.Native do
  @moduledoc """
  Host-invoked maintenance for the native engine.

  The library starts no processes, so nothing runs in the background. A host
  that routes containers to the native engine calls these on its own
  schedule, serialized per target as it serializes engine lifecycle work.
  """

  alias Opsmaru.Containers.Native.{Container, Images, Translate, Wait}
  alias Opsmaru.Containers.Nested.Target

  @doc """
  Deletes the Incus copies of handed-off images that no instance in the
  native project was created from. Removing an image from dockerd does not
  remove its Incus copy, so this bounds the second copy of each image.

  Options: `:timeout` in milliseconds (default 60 000). Returns
  `{:ok, deleted_fingerprints}`.
  """
  @spec prune_images(Target.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def prune_images(%Target{native: native} = target, options \\ []) when not is_nil(native) do
    timeout = Keyword.get(options, :timeout, 60_000)

    if Target.valid?(target) and is_integer(timeout) and timeout in 1..3_600_000,
      do: Images.prune(native, System.monotonic_time(:millisecond) + timeout),
      else: {:error, :invalid_native_target}
  end

  @doc """
  Deletes stopped `AutoRemove` containers that no `wait` removed, for
  example after the client disconnected. A container that was never started
  is kept for its first start.

  Options: `:timeout` in milliseconds (default 60 000). Returns
  `{:ok, deleted_container_ids}`.
  """
  @spec reap(Target.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def reap(%Target{native: native} = target, options \\ []) when not is_nil(native) do
    timeout = Keyword.get(options, :timeout, 60_000)

    with true <- Target.valid?(target) and is_integer(timeout) and timeout in 1..3_600_000,
         deadline = System.monotonic_time(:millisecond) + timeout,
         {:ok, instances} <- native.backend.list_instances(native.client, deadline) do
      Wait.reap(native, Container.from_instances(instances), deadline)
    else
      false -> {:error, :invalid_native_target}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Whether a decoded container create body could run natively, judged from
  the body alone: `:ok`, or `{:error, fields}` naming each field the native
  engine cannot honour. A host's `select_engine/2` can use it to route only
  eligible creates to native. The image, the host's bind mapping and names
  are checked later, at create.
  """
  @spec eligibility(map()) :: :ok | {:error, [String.t()]}
  def eligibility(body), do: Translate.eligibility(body)
end
