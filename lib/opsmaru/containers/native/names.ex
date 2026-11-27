defmodule Opsmaru.Containers.Native.Names do
  @moduledoc false
  # Container names are unique across both engines. The host serializes
  # container creates (and renames) per target, as it serializes engine
  # lifecycle mutations, so a check cannot interleave with another create
  # from the same host.

  alias Opsmaru.Containers.Docker.EngineRequest

  @doc """
  Checks a name for a nested create or rename against the native project.
  A missing name passes: dockerd generates one.
  """
  def check_native(_containers, nil, _), do: :nested
  def check_native(_containers, "", _), do: :nested

  def check_native(containers, name, operation) do
    bare = String.trim_leading(name, "/")

    case Enum.find(containers, &(&1.name == bare)) do
      nil -> :nested
      container -> conflict(bare, container.id, operation)
    end
  end

  @doc """
  Checks a name for a native create or rename against the nested engine,
  by exact name: a reference lookup would also match ID prefixes.
  """
  def check_nested(context, name, api_version, deadline, operation \\ :create) do
    bare = String.trim_leading(name, "/")
    target = "/v#{api_version}/containers/#{URI.encode(bare, &URI.char_unreserved?/1)}/json"

    case EngineRequest.json(context, "GET", target, nil, deadline) do
      {:ok, 200, %{"Id" => id, "Name" => "/" <> ^bare}} -> conflict(bare, id, operation)
      {:ok, status, _} when status in [200, 400, 404] -> :ok
      _ -> {:error, 503, "Docker engine is not ready"}
    end
  end

  # dockerd's own conflict message, so clients that match it keep working.
  defp conflict(name, id, operation) do
    message =
      ~s(Conflict. The container name "/#{name}" is already in use by container "#{id}". ) <>
        "You have to remove (or rename) that container to be able to reuse that name."

    message =
      if operation == :rename, do: "Error when allocating new name: " <> message, else: message

    {:error, 409, message}
  end
end
