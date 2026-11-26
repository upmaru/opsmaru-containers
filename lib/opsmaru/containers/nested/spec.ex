defmodule Opsmaru.Containers.Nested.Spec do
  @moduledoc """
  Host-provided Incus system container configuration for a packaged dockerd.

  The target supplies the instance name and project. The image source must
  resolve through that same host-selected Incus backend.
  """

  @marker "user.opsmaru.containers.role"
  @required %{@marker => "engine", "security.nesting" => "true"}

  @enforce_keys [:source]
  defstruct [:source, profiles: [], config: %{}, devices: %{}]

  @type t :: %__MODULE__{source: map(), profiles: [String.t()], config: map(), devices: map()}

  @doc false
  def body(%__MODULE__{source: %{"type" => "image"} = source} = spec, instance) do
    with true <- image?(source),
         true <- string_list?(spec.profiles),
         true <- string_map?(spec.config),
         true <- devices?(spec.devices),
         true <-
           Enum.all?(@required, fn {key, value} -> Map.get(spec.config, key, value) == value end) do
      {:ok,
       %{
         "name" => instance,
         "type" => "container",
         "source" => source,
         "profiles" => spec.profiles,
         "config" => Map.merge(spec.config, @required),
         "devices" => spec.devices,
         "start" => false
       }}
    else
      _ -> {:error, :invalid_engine_spec}
    end
  end

  def body(_, _), do: {:error, :invalid_engine_spec}

  @doc false
  def owned?(%{"type" => "container", "config" => %{@marker => "engine"}}), do: true
  def owned?(_), do: false

  defp image?(source),
    do: Enum.any?(["alias", "fingerprint"], &nonempty?(source[&1]))

  defp devices?(devices) when is_map(devices),
    do: Enum.all?(devices, fn {key, value} -> nonempty?(key) and string_map?(value) end)

  defp devices?(_), do: false

  defp string_map?(values) when is_map(values),
    do: Enum.all?(values, fn {key, value} -> nonempty?(key) and is_binary(value) end)

  defp string_map?(_), do: false

  defp string_list?(values) when is_list(values), do: Enum.all?(values, &nonempty?/1)
  defp string_list?(_), do: false

  defp nonempty?(value), do: is_binary(value) and value != ""
end
