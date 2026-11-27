defmodule Opsmaru.Containers.Native.Shim do
  @moduledoc false
  # Pushes the init shim and the process spec into a created, never-started
  # instance (design decision 4). The shim's bytes are read from the host's
  # file and hashed again here, so a file changed since `Target.new/2` is
  # never pushed.

  @root "/.opsmaru"
  @init @root <> "/init"
  @spec_path @root <> "/spec.json"

  def init_path, do: @init

  @doc """
  Pushes `/.opsmaru`, the shim and `spec.json`. An image that already holds
  `/.opsmaru` is refused. The caller deletes the instance on any error.
  """
  def push(native, instance, shim, spec, deadline) do
    backend = native.backend
    client = native.client

    with :ok <- absent(backend.head_file(client, instance, @root, deadline)),
         {:ok, bytes} <- verified(shim),
         :ok <- pushed(backend.push_file(client, instance, @root, :directory, 0o700, deadline)),
         :ok <- pushed(backend.push_file(client, instance, @init, bytes, 0o755, deadline)) do
      spec = Jason.encode!(spec)
      pushed(backend.push_file(client, instance, @spec_path, spec, 0o600, deadline))
    end
  end

  defp absent({:error, :not_found}), do: :ok

  defp absent({:ok, _}),
    do:
      {:error, 400,
       "native engine: the image already contains #{@root}, which the native engine reserves"}

  defp absent(_), do: {:error, 503, "native engine: Incus is not available"}

  defp verified(%{path: path, sha256: digest}) do
    case File.read(path) do
      {:ok, bytes} ->
        if Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == digest,
          do: {:ok, bytes},
          else:
            {:error, 500,
             "native engine: the init shim at #{path} changed since the target was built"}

      {:error, reason} ->
        {:error, 500, "native engine: the init shim at #{path} is unreadable (#{reason})"}
    end
  end

  defp pushed(:ok), do: :ok
  defp pushed(_), do: {:error, 500, "native engine: the init shim could not be pushed"}
end
