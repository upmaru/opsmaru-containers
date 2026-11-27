defmodule Opsmaru.Containers.Native.Target do
  @moduledoc """
  Host-selected Incus client for native containers, and the verified init
  shim binaries.

  The client's project is the native project. It must differ from the nested
  engine's project and share its owner and identity. Build the target with
  `new/2`, which reads each shim binary once and refuses one whose SHA-256 is
  not listed in `priv/native_init/README.md` for its architecture.
  """

  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context}

  @readme Path.expand("../../../../priv/native_init/README.md", __DIR__)
  @external_resource @readme

  @architectures %{"linux/arm64" => "aarch64", "linux/amd64" => "x86_64"}
  @aliases %{
    "aarch64" => "aarch64",
    "arm64" => "aarch64",
    "x86_64" => "x86_64",
    "amd64" => "x86_64"
  }

  @digests (for line <- File.read!(@readme) |> String.split("\n"),
                [target, digest] <-
                  [
                    Regex.run(~r/\A\| (linux\/\w+) \| `([0-9a-f]{64})` \|\z/, line,
                      capture: :all_but_first
                    )
                  ],
                into: %{} do
              {Map.fetch!(@architectures, target), digest}
            end)

  if map_size(@digests) != map_size(@architectures),
    do: raise("priv/native_init/README.md must list one digest per architecture")

  @enforce_keys [:client, :init]
  # `backend` is the module making Incus calls. Tests replace it.
  defstruct [:client, :init, backend: Opsmaru.Containers.Native.Incus]

  @type architecture :: String.t()
  @type shim :: %{path: Path.t(), sha256: String.t()}
  @type t :: %__MODULE__{client: Incus.t(), init: %{architecture() => shim()}, backend: module()}

  @doc """
  Verifies the shim binaries and returns the target.

  `init` maps Incus architecture names (`"aarch64"`, `"x86_64"`) to absolute
  paths. At least one architecture is required.
  """
  @spec new(Incus.t(), %{architecture() => Path.t()}) :: {:ok, t()} | {:error, term()}
  def new(client, init), do: build(client, init, @digests)

  @doc false
  def digests, do: @digests

  @doc false
  def build(%Incus{} = client, init, digests) when is_map(init) and map_size(init) > 0 do
    init
    |> Enum.reduce_while({:ok, %{}}, fn {architecture, path}, {:ok, verified} ->
      case verify(architecture, path, digests) do
        {:ok, shim} -> {:cont, {:ok, Map.put(verified, architecture, shim)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, verified} -> {:ok, %__MODULE__{client: client, init: verified}}
      error -> error
    end
  end

  def build(_, _, _), do: {:error, :invalid_native_target}

  defp verify(architecture, path, digests) do
    with {:ok, expected} <- Map.fetch(digests, architecture) |> known(architecture),
         :ok <- absolute(path),
         {:ok, bytes} <- read(path) do
      digest = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

      if digest == expected,
        do: {:ok, %{path: path, sha256: digest}},
        else: {:error, {:unknown_native_init, architecture, digest}}
    end
  end

  defp known({:ok, digest}, _), do: {:ok, digest}
  defp known(:error, architecture), do: {:error, {:unsupported_architecture, architecture}}

  defp absolute(path) when is_binary(path) do
    if Path.type(path) == :absolute, do: :ok, else: {:error, {:invalid_native_init_path, path}}
  end

  defp absolute(path), do: {:error, {:invalid_native_init_path, path}}

  defp read(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, {:native_init_unreadable, path, reason}}
    end
  end

  @doc """
  The verified shim for an image architecture. Docker and Incus names are both
  accepted (`arm64` or `aarch64`, `amd64` or `x86_64`).
  """
  @spec shim(t(), String.t()) :: {:ok, shim()} | {:error, {:no_native_init, String.t()}}
  def shim(%__MODULE__{init: init}, architecture) do
    with {:ok, name} <- Map.fetch(@aliases, architecture),
         {:ok, shim} <- Map.fetch(init, name) do
      {:ok, shim}
    else
      :error -> {:error, {:no_native_init, architecture}}
    end
  end

  @doc false
  # Checked on every request, so it does not read the binaries again. They are
  # read in full, and hashed, when they are pushed into a container.
  def valid?(
        %__MODULE__{
          client: %Incus{
            connection: %Connection{owner: owner, project: project},
            context: %Context{owner: owner, identity: identity}
          },
          init: init,
          backend: backend
        },
        %Incus{
          connection: %Connection{owner: owner, project: nested_project},
          context: %Context{identity: identity}
        }
      )
      when is_map(init) and map_size(init) > 0 and is_atom(backend) and not is_nil(backend) do
    is_binary(project) and project != "" and project != nested_project and
      Enum.all?(init, &verified?/1)
  end

  def valid?(_, _), do: false

  defp verified?({architecture, %{path: path, sha256: digest}}) when is_binary(path),
    do: Map.get(@digests, architecture) == digest and Path.type(path) == :absolute

  defp verified?(_), do: false
end
