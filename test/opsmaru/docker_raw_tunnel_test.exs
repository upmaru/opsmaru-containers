defmodule Opsmaru.Containers.Docker.RawTunnelTest do
  use ExUnit.Case, async: true

  alias Opsmaru.Containers.{Context, Host, Transport}
  alias Opsmaru.Containers.Docker.{Capabilities, Raw, RawTunnel}
  alias Opsmaru.Containers.Nested.Target
  alias Opsmaru.Containers.Transport.Stream
  alias Opsmaru.Incus

  defmodule RawHost do
    @moduledoc false
    @behaviour Host
    @impl Host
    def context(%{host_peer: context}), do: {:ok, context}
    @impl Host
    def authorize(_context, _request), do: :allow
  end

  defmodule SocketAdapter do
    @moduledoc false
    @behaviour Transport
    @behaviour Stream

    @impl Transport
    def dial(_target, socket, _deadline), do: {:ok, %Stream{adapter: __MODULE__, handle: socket}}

    @impl Stream
    def recv(socket, limit, deadline) do
      timeout = max(deadline - System.monotonic_time(:millisecond), 1)

      case :gen_tcp.recv(socket, 0, timeout) do
        {:ok, bytes} when byte_size(bytes) <= limit -> {:ok, bytes}
        {:error, :closed} -> :eof
        _ -> {:error, :socket_read}
      end
    end

    @impl Stream
    def send(socket, bytes, _deadline), do: :gen_tcp.send(socket, bytes)

    @impl Stream
    def shutdown_write(socket, _deadline), do: :gen_tcp.shutdown(socket, :write)

    @impl Stream
    def close(socket), do: :gen_tcp.close(socket)
  end

  @socket_options [
    :binary,
    active: false,
    exit_on_close: false,
    send_timeout: 2_000,
    buffer: 16_384,
    sndbuf: 16_384,
    recbuf: 16_384
  ]
  @handshakes [
    "HTTP/1.1 101 UPGRADED\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n",
    "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.docker.raw-stream\r\n\r\n"
  ]

  for {response, index} <- Enum.with_index(@handshakes) do
    @response response
    @tag :unix_socket
    test "host-owned socket preserves handshake #{index + 1}, parser tails and independent EOF" do
      {cli, listener} = unix_pair()
      {daemon, dialer} = unix_pair()

      task =
        relay(listener, dialer,
          deadline: deadline(),
          request_tail: "buffered input ",
          response_head: @response,
          response_tail: "buffered output "
        )

      assert :ok = :gen_tcp.send(cli, "live input")
      assert :ok = :gen_tcp.shutdown(cli, :write)
      assert recv(daemon, "buffered input live input") == "buffered input live input"
      assert {:error, :closed} = :gen_tcp.recv(daemon, 0, 2_000)

      assert :ok = :gen_tcp.send(daemon, "after EOF")
      assert :ok = :gen_tcp.shutdown(daemon, :write)
      output = @response <> "buffered output after EOF"
      assert recv(cli, output) == output
      assert {:error, :closed} = :gen_tcp.recv(cli, 0, 2_000)
      assert Task.await(task) == :ok
    end
  end

  @tag :unix_socket
  test "idle handoff is bounded and closes both sockets" do
    {cli, listener} = unix_pair()
    {daemon, dialer} = unix_pair()

    task =
      relay(listener, dialer,
        deadline: System.monotonic_time(:millisecond) + 200,
        request_tail: "",
        response_head: hd(@handshakes),
        response_tail: ""
      )

    assert recv(cli, hd(@handshakes)) == hd(@handshakes)
    assert {:error, _} = Task.await(task)
    assert {:error, :closed} = :gen_tcp.recv(cli, 0, 2_000)
    assert {:error, :closed} = :gen_tcp.recv(daemon, 0, 2_000)
  end

  @tag :unix_socket
  test "a stalled client does not delay a second relay and disconnect releases the first" do
    {stalled_cli, stalled_listener} = unix_pair()
    {stalled_daemon, stalled_dialer} = unix_pair()

    opts = [
      deadline: deadline(),
      request_tail: "",
      response_head: hd(@handshakes),
      response_tail: ""
    ]

    stalled = relay(stalled_listener, stalled_dialer, opts)
    assert recv(stalled_cli, hd(@handshakes)) == hd(@handshakes)

    writer = Task.async(fn -> flood(stalled_daemon, :binary.copy(<<42>>, 16_384)) end)

    assert Task.yield(writer, 25) == nil

    {cli, listener} = unix_pair()
    {daemon, dialer} = unix_pair()
    active = relay(listener, dialer, opts)
    assert :ok = :gen_tcp.shutdown(cli, :write)
    assert :ok = :gen_tcp.send(daemon, "short")
    assert :ok = :gen_tcp.shutdown(daemon, :write)
    assert recv(cli, hd(@handshakes) <> "short") == hd(@handshakes) <> "short"
    assert Task.await(active) == :ok

    :ok = :gen_tcp.close(stalled_cli)
    assert {:error, _} = Task.await(stalled)
    assert {:error, _} = Task.await(writer)
  end

  defp flood(socket, chunk) do
    Enum.reduce_while(1..256, :ok, fn _, :ok ->
      case :gen_tcp.send(socket, chunk) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  for {path, headers, body, handshake} <- [
        {"/grpc", [{"connection", "upgrade"}, {"upgrade", "h2c"}], "",
         "HTTP/1.1 101 UPGRADED\r\nconnection: Upgrade\r\nupgrade: h2c\r\n\r\n"},
        {"/session", [{"connection", "upgrade"}, {"upgrade", "h2c"}], "",
         "HTTP/1.1 101 UPGRADED\r\nconnection: Upgrade\r\nupgrade: h2c\r\n\r\n"},
        {"/containers/engine/attach", [], "",
         "HTTP/1.1 200 OK\r\ncontent-type: application/vnd.docker.raw-stream\r\n\r\n"},
        {"/exec/fixture/start", [{"connection", "upgrade"}, {"upgrade", "tcp"}],
         ~s({"Detach":false,"Tty":true}),
         "HTTP/1.1 101 UPGRADED\r\nconnection: Upgrade\r\nupgrade: tcp\r\n\r\n"}
      ] do
    @path path
    @headers headers
    @body body
    @handshake handshake

    @tag :unix_socket
    test "raw adapter preserves handshake, prefix and reverse EOF for #{path}" do
      {cli, listener} = unix_pair()
      {daemon, dialer} = unix_pair()

      request = %{
        method: "POST",
        path: @path,
        query: "",
        headers:
          @headers ++
            [
              {"x-docker-expose-session-grpc-method", "/one"},
              {"x-docker-expose-session-grpc-method", "/two"}
            ],
        body: @body,
        host_peer: host_context(dialer)
      }

      task = handoff(listener, dialer, &raw(&1, &2, request))

      {head, body} = read_request(daemon, "", byte_size(@body))
      assert head =~ "POST #{@path} HTTP/1.1\r\n"
      assert head =~ "x-docker-expose-session-grpc-method: /one\r\n"
      assert head =~ "x-docker-expose-session-grpc-method: /two\r\n"
      assert body == @body

      assert :ok = :gen_tcp.send(daemon, @handshake <> "backend prefix")
      assert :ok = :gen_tcp.shutdown(daemon, :write)
      assert recv(cli, @handshake <> "backend prefix") == @handshake <> "backend prefix"
      assert {:error, :closed} = :gen_tcp.recv(cli, 0, 2_000)

      assert :ok = :gen_tcp.send(cli, " after backend EOF")
      assert :ok = :gen_tcp.shutdown(cli, :write)
      assert recv(daemon, "client prefix after backend EOF") == "client prefix after backend EOF"
      assert {:relayed, :ok} = Task.await(task)
    end
  end

  defp raw(frontend, _backend, request) do
    Raw.relay(RawHost, request, frontend,
      request_tail: "client prefix",
      admission_deadline: deadline(),
      deadline: deadline()
    )
  end

  defp host_context(socket) do
    client = %Incus{
      connection: Incus.Connection.unix!("/unused", owner: :fixture, project: "fixtures"),
      context: Incus.Context.new!(owner: :fixture, identity: :host, ready?: fn -> true end),
      server: nil
    }

    target = %Target{client: client, instance: "engine"}

    %Context{
      identity: :verified_peer,
      target: target,
      dialer: {SocketAdapter, socket},
      ready?: true,
      capabilities: %Capabilities{
        target: target,
        minimum: "1.40",
        maximum: "1.57",
        expires_at: deadline()
      }
    }
  end

  defp relay(listener, dialer, opts) do
    handoff(listener, dialer, &RawTunnel.run(&1, &2, opts))
  end

  defp handoff(listener, dialer, relay) do
    task =
      Task.async(fn ->
        receive do
          :start ->
            relay.(
              %Stream{adapter: SocketAdapter, handle: listener},
              %Stream{adapter: SocketAdapter, handle: dialer}
            )
        end
      end)

    :ok = :gen_tcp.controlling_process(listener, task.pid)
    :ok = :gen_tcp.controlling_process(dialer, task.pid)
    send(task.pid, :start)
    task
  end

  defp unix_pair do
    path = "/tmp/occ-#{Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)}"
    address = {:local, path}
    {:ok, listening} = :gen_tcp.listen(0, [{:ifaddr, address} | @socket_options])
    on_exit(fn -> File.rm(path) end)

    try do
      {:ok, client} = :gen_tcp.connect(address, 0, @socket_options, 2_000)
      {:ok, server} = :gen_tcp.accept(listening, 2_000)
      {client, server}
    after
      :gen_tcp.close(listening)
    end
  end

  defp recv(socket, expected) do
    {:ok, bytes} = :gen_tcp.recv(socket, byte_size(expected), 2_000)
    bytes
  end

  defp read_request(socket, buffer, body_size) do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, body] when byte_size(body) == body_size ->
        {head <> "\r\n\r\n", body}

      _ ->
        {:ok, bytes} = :gen_tcp.recv(socket, 0, 2_000)
        read_request(socket, buffer <> bytes, body_size)
    end
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 2_000
end
