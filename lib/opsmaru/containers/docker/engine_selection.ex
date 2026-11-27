defmodule Opsmaru.Containers.Docker.EngineSelection do
  @moduledoc false

  alias Opsmaru.Containers.Host

  @doc """
  Chooses `:nested` or `:native` for a container create. Hosts without
  `select_engine/2` always get `:nested`, and the body is not decoded for them.
  """
  @spec select(module(), map(), map(), binary(), integer()) :: :nested | :native
  def select(host, request, %{route: route, context: context}, body, deadline) do
    with true <- selects?(host),
         {:ok, %{} = decoded} <- Jason.decode(body),
         create_request = Map.merge(request, %{route: route, body: decoded}),
         {:ok, :native} <- Host.decide(host, :select_engine, [context, create_request], deadline) do
      :native
    else
      _ -> :nested
    end
  end

  defp selects?(host),
    do: Code.ensure_loaded?(host) and function_exported?(host, :select_engine, 2)
end
