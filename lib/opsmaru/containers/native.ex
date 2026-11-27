defmodule Opsmaru.Containers.Native do
  @moduledoc """
  Host-invoked maintenance for the native engine.

  The library starts no processes, so nothing runs in the background. A host
  that routes containers to the native engine calls these on its own
  schedule, serialized per target as it serializes engine lifecycle work.
  """

  alias Opsmaru.Containers.Native.Images
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
end
