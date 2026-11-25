defmodule Opsmaru.Containers.Context do
  @moduledoc """
  Per-request context supplied by a trusted host.

  The Docker client identity is verified by the host. The target carries the
  separate host binding for Incus. An engine snapshot and a dialer are required
  for relayed engine requests.
  """

  alias Opsmaru.Containers.Docker.Capabilities
  alias Opsmaru.Containers.Nested.Target
  alias Opsmaru.Containers.Transport

  @derive {Inspect, only: []}
  @enforce_keys [:identity, :target, :dialer]
  defstruct [:identity, :target, :dialer, :capabilities, ready?: false]

  @type t :: %__MODULE__{
          identity: term(),
          target: Target.t(),
          dialer: Transport.dialer(),
          capabilities: Capabilities.t() | nil,
          ready?: boolean()
        }

  @doc false
  def validate(%__MODULE__{identity: identity, target: target, dialer: {module, _}})
      when not is_nil(identity) and is_atom(module) and not is_nil(module) do
    if Target.valid?(target), do: :ok, else: {:error, :invalid_context}
  end

  def validate(_), do: {:error, :invalid_context}

  @doc false
  def range(%__MODULE__{ready?: true, capabilities: capabilities, target: target}),
    do: Capabilities.range(capabilities, target)

  def range(_), do: {:error, :engine_not_ready}
end
