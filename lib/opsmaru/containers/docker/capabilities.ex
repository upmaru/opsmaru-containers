defmodule Opsmaru.Containers.Docker.Capabilities do
  @moduledoc """
  An observed Docker API range for one engine, published by the host with a
  local monotonic expiration in milliseconds.
  """

  alias Opsmaru.Containers.Docker.Version
  alias Opsmaru.Containers.Nested.Target

  @enforce_keys [:target, :minimum, :maximum, :expires_at]
  defstruct [:target, :minimum, :maximum, :expires_at]

  @type t :: %__MODULE__{
          target: Target.t(),
          minimum: String.t(),
          maximum: String.t(),
          expires_at: integer()
        }

  @doc false
  def range(%__MODULE__{target: target, expires_at: expires_at} = capabilities, target)
      when is_integer(expires_at) do
    if expires_at > System.monotonic_time(:millisecond),
      do: Version.effective(capabilities.minimum, capabilities.maximum),
      else: {:error, :engine_not_ready}
  end

  def range(_, _), do: {:error, :engine_not_ready}
end
