defmodule Opsmaru.Containers.Nested.Target do
  @moduledoc """
  Host-selected Incus client and engine instance name. The supplied client
  carries the project, connection and Incus identity.
  """

  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context}

  @enforce_keys [:client, :instance]
  defstruct [:client, :instance]

  @type t :: %__MODULE__{client: Incus.t(), instance: String.t()}

  @doc false
  def valid?(%__MODULE__{
        client: %Incus{
          connection: %Connection{owner: owner, project: project},
          context: %Context{owner: owner, identity: identity}
        },
        instance: instance
      }) do
    owner != nil and identity != nil and is_binary(project) and project != "" and
      is_binary(instance) and
      Regex.match?(~r/\A[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\z/, instance)
  end

  def valid?(_), do: false
end
