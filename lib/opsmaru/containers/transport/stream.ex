defmodule Opsmaru.Containers.Transport.Stream do
  @moduledoc """
  A caller-owned duplex byte stream. Its adapter must allow one reader and
  one writer concurrently. Read and write must respect the specified byte
  limits and deadline. Write EOF leaves the read direction available.
  """

  @derive {Inspect, only: [:adapter]}
  @enforce_keys [:adapter, :handle]
  defstruct [:adapter, :handle]

  @type t :: %__MODULE__{adapter: module(), handle: term()}
  @callback recv(term(), pos_integer(), integer()) ::
              {:ok, nonempty_binary()} | :eof | {:error, term()}
  @callback send(term(), iodata(), integer()) :: :ok | {:error, term()}
  @callback shutdown_write(term(), integer()) :: :ok | {:error, term()}
  @callback close(term()) :: :ok

  @doc false
  def recv(%__MODULE__{adapter: adapter, handle: handle}, limit, deadline),
    do: adapter.recv(handle, limit, deadline)

  @doc false
  def send(%__MODULE__{adapter: adapter, handle: handle}, bytes, deadline),
    do: adapter.send(handle, bytes, deadline)

  @doc false
  def shutdown_write(%__MODULE__{adapter: adapter, handle: handle}, deadline),
    do: adapter.shutdown_write(handle, deadline)

  @doc false
  def close(%__MODULE__{adapter: adapter, handle: handle}), do: adapter.close(handle)
end
