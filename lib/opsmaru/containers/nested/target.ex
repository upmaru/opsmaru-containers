defmodule Opsmaru.Containers.Nested.Target do
  @moduledoc """
  Host-selected Incus client and engine instance name. The supplied client
  carries the project, connection and Incus identity.

  `native` is an optional `Opsmaru.Containers.Native.Target` for hosts that
  route containers to the native engine.
  """

  alias Opsmaru.Containers.Native
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context}

  @enforce_keys [:client, :instance]
  defstruct [:client, :instance, :native]

  @type t :: %__MODULE__{
          client: Incus.t(),
          instance: String.t(),
          native: Native.Target.t() | nil
        }

  @doc false
  def valid?(%__MODULE__{
        client:
          %Incus{
            connection: %Connection{owner: owner, project: project},
            context: %Context{owner: owner, identity: identity}
          } = client,
        instance: instance,
        native: native
      }) do
    owner != nil and identity != nil and is_binary(project) and project != "" and
      is_binary(instance) and
      Regex.match?(~r/\A[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\z/, instance) and
      (native == nil or Native.Target.valid?(native, client))
  end

  def valid?(_), do: false
end
