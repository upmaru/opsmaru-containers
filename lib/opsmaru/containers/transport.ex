defmodule Opsmaru.Containers.Transport do
  @moduledoc """
  A host-supplied connector to a selected nested Docker engine.

  Each call opens an independent duplex stream. The dialer honors the supplied
  absolute monotonic deadline and releases transport resources if the owning
  request exits. A host dialer can use a private path to the engine it owns.
  """

  alias Opsmaru.Containers.Nested.Target
  alias Opsmaru.Containers.Transport.Stream

  @type dialer :: {module(), term()}
  @callback dial(Target.t(), options :: term(), deadline :: integer()) ::
              {:ok, Stream.t()} | {:error, term()}

  @doc false
  def dial({module, options}, target, deadline) do
    if deadline > System.monotonic_time(:millisecond) do
      case module.dial(target, options, deadline) do
        {:ok, %Stream{} = stream} -> {:ok, stream}
        _ -> {:error, :engine_unavailable}
      end
    else
      {:error, :deadline}
    end
  rescue
    _ -> {:error, :engine_unavailable}
  catch
    _, _ -> {:error, :engine_unavailable}
  end
end
