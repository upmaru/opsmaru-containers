defmodule Opsmaru.Containers.TestSupport.EngineFixture do
  @moduledoc """
  A scripted Docker engine on a private Unix socket. The test process plays
  dockerd on accepted connections; `Dialer` is the host transport the
  library dials. Every dial is reported to the observer as
  `{:dialed, dialing_pid}`, so a test can prove a request never dialed, or
  dialed exactly once. No real engine, daemon socket or network is used.
  """

  alias Opsmaru.Containers.Context
  alias Opsmaru.Containers.Docker.Capabilities
  alias Opsmaru.Containers.Nested.Target
  alias Opsmaru.Incus

  @socket_options [:binary, active: false, exit_on_close: false, send_timeout: 2_000]

  defmodule Dialer do
    @moduledoc false
    @behaviour Opsmaru.Containers.Transport
    @behaviour Opsmaru.Containers.Transport.Stream

    alias Opsmaru.Containers.Transport.Stream

    @impl Opsmaru.Containers.Transport
    def dial(_target, %{path: path, observer: observer}, _deadline) do
      send(observer, {:dialed, self()})

      options = [:binary, active: false, exit_on_close: false, send_timeout: 2_000]

      case :gen_tcp.connect({:local, path}, 0, options, 2_000) do
        {:ok, socket} -> {:ok, %Stream{adapter: __MODULE__, handle: socket}}
        error -> error
      end
    end

    @impl Opsmaru.Containers.Transport.Stream
    def recv(socket, limit, deadline) do
      timeout = max(deadline - System.monotonic_time(:millisecond), 1)

      case :gen_tcp.recv(socket, 0, timeout) do
        {:ok, bytes} when byte_size(bytes) <= limit -> {:ok, bytes}
        {:ok, _} -> {:error, :oversized}
        {:error, :closed} -> :eof
        _ -> {:error, :socket_read}
      end
    end

    @impl Opsmaru.Containers.Transport.Stream
    def send(socket, bytes, _deadline), do: :gen_tcp.send(socket, bytes)

    @impl Opsmaru.Containers.Transport.Stream
    def shutdown_write(socket, _deadline), do: :gen_tcp.shutdown(socket, :write)

    @impl Opsmaru.Containers.Transport.Stream
    def close(socket), do: :gen_tcp.close(socket)
  end

  defmodule AllowHost do
    @moduledoc false
    @behaviour Opsmaru.Containers.Host

    @impl Opsmaru.Containers.Host
    def context(%{host_peer: {context, observer}}) do
      send(observer, :context_called)
      {:ok, context}
    end

    @impl Opsmaru.Containers.Host
    def authorize(_context, _request), do: :allow
  end

  defmodule DenyHost do
    @moduledoc false
    @behaviour Opsmaru.Containers.Host

    @impl Opsmaru.Containers.Host
    def context(%{host_peer: {context, observer}}) do
      send(observer, :context_called)
      {:ok, context}
    end

    @impl Opsmaru.Containers.Host
    def authorize(_context, _request), do: :deny
  end

  @doc "Listen on a fresh private Unix socket for the calling test."
  def start(observer \\ self()) do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
    path = "/tmp/occ-engine-#{suffix}.sock"
    {:ok, listener} = :gen_tcp.listen(0, [{:ifaddr, {:local, path}} | @socket_options])
    ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)
    %{path: path, listener: listener, observer: observer}
  end

  @doc "Accept the next dialed connection as the engine."
  def accept(%{listener: listener}, timeout \\ 2_000) do
    {:ok, socket} = :gen_tcp.accept(listener, timeout)
    socket
  end

  @doc "A ready host context dialing this engine, or not ready with `ready?: false`."
  def context(engine, opts \\ []) do
    client = %Incus{
      connection: Incus.Connection.unix!("/unused", owner: :fixture, project: "fixtures"),
      context: Incus.Context.new!(owner: :fixture, identity: :host, ready?: fn -> true end),
      server: nil
    }

    target = %Target{client: client, instance: "engine"}

    %Context{
      identity: :verified_peer,
      target: target,
      dialer: {Dialer, %{path: engine.path, observer: engine.observer}},
      ready?: Keyword.get(opts, :ready?, true),
      capabilities: %Capabilities{
        target: target,
        minimum: "1.40",
        maximum: "1.57",
        expires_at: System.monotonic_time(:millisecond) + 60_000
      }
    }
  end

  @doc "Read one HTTP/1.1 request head and its Content-Length body as the engine."
  def read_request(socket, buffer \\ "") do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, rest] ->
        length =
          case Regex.run(~r/\r\ncontent-length: *(\d+)/i, head) do
            [_, value] -> String.to_integer(value)
            nil -> 0
          end

        {body, rest} = read_exactly(socket, rest, length)
        {head, body, rest}

      [_] ->
        {:ok, chunk} = :gen_tcp.recv(socket, 0, 2_000)
        read_request(socket, buffer <> chunk)
    end
  end

  @doc "Read exactly `size` bytes, starting from `buffer`."
  def read_exactly(socket, buffer, size) do
    if byte_size(buffer) >= size do
      <<bytes::binary-size(size), rest::binary>> = buffer
      {bytes, rest}
    else
      {:ok, chunk} = :gen_tcp.recv(socket, 0, 2_000)
      read_exactly(socket, buffer <> chunk, size)
    end
  end

  @doc "Read until EOF; returns `{bytes, :eof | {:error, reason}}`."
  def read_to_eof(socket, acc \\ "", timeout \\ 2_000) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, bytes} -> read_to_eof(socket, acc <> bytes, timeout)
      {:error, :closed} -> {acc, :eof}
      {:error, reason} -> {acc, {:error, reason}}
    end
  end

  @upgraded "HTTP/1.1 101 UPGRADED\r\nContent-Type: application/vnd.docker.raw-stream\r\n" <>
              "Connection: Upgrade\r\nUpgrade: tcp\r\nApi-Version: 1.58\r\n" <>
              "Docker-Experimental: false\r\nOstype: linux\r\nServer: Docker/29.10.0 (linux)\r\n\r\n"

  @doc "dockerd's 101 for an attach or exec start, followed by `tail`."
  def upgraded(tail \\ ""), do: @upgraded <> tail
end
