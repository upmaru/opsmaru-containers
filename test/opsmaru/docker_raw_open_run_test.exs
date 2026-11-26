defmodule Opsmaru.Containers.Docker.RawOpenRunTest do
  use ExUnit.Case, async: true

  alias Opsmaru.Containers.{Context, Host, Transport}
  alias Opsmaru.Containers.Docker.{Capabilities, Raw}
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

  defmodule RefusingHost do
    @moduledoc false
    @behaviour Host
    @impl Host
    def context(%{host_peer: _}), do: {:error, :denied}
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

  defmodule NeverDial do
    @moduledoc false
    @behaviour Transport

    @impl Transport
    def dial(_target, observer, _deadline) do
      send(observer, :dialed)
      {:error, :not_dialed}
    end
  end

  defmodule FailingFrontend do
    @moduledoc false
    @behaviour Stream

    @impl Stream
    def recv(_handle, _limit, _deadline), do: {:error, :caller_failed}

    @impl Stream
    def send(_handle, _bytes, _deadline), do: :ok

    @impl Stream
    def shutdown_write(_handle, _deadline), do: :ok

    @impl Stream
    def close(_handle), do: :ok
  end

  defmodule UnreachableBackend do
    @moduledoc false
    @behaviour Stream

    @impl Stream
    def recv(_handle, _limit, _deadline), do: {:error, :backend_failed}

    @impl Stream
    def send(_handle, _bytes, _deadline), do: :ok

    @impl Stream
    def shutdown_write(_handle, _deadline), do: :ok

    @impl Stream
    def close(_handle), do: :ok
  end

  defmodule DeadlineFrontend do
    @moduledoc false
    # A frontend adapter that reports its own deadline long before the
    # exchange deadline passes.
    @behaviour Stream

    @impl Stream
    def recv(_handle, _limit, _deadline), do: {:error, :deadline}

    @impl Stream
    def send(_handle, _bytes, _deadline), do: :ok

    @impl Stream
    def shutdown_write(_handle, _deadline), do: :ok

    @impl Stream
    def close(_handle), do: :ok
  end

  defmodule RaisingFrontend do
    @moduledoc false
    # A host frontend whose head write raises; close/1 reports to the test.
    @behaviour Stream

    @impl Stream
    def recv(_test, _limit, _deadline), do: :eof

    @impl Stream
    def send(_test, _bytes, _deadline), do: raise("frontend write failed")

    @impl Stream
    def shutdown_write(_test, _deadline), do: :ok

    @impl Stream
    def close(test), do: send(test, :frontend_closed)
  end

  @socket_options [:binary, active: false, exit_on_close: false, send_timeout: 2_000]

  defp now, do: System.monotonic_time(:millisecond)
  defp deadline, do: now() + 2_000

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

  defp never_dial_context do
    client = %Incus{
      connection: Incus.Connection.unix!("/unused", owner: :fixture, project: "fixtures"),
      context: Incus.Context.new!(owner: :fixture, identity: :host, ready?: fn -> true end),
      server: nil
    }

    target = %Target{client: client, instance: "engine"}

    %Context{
      identity: :verified_peer,
      target: target,
      dialer: {NeverDial, self()},
      ready?: true,
      capabilities: %Capabilities{
        target: target,
        minimum: "1.40",
        maximum: "1.57",
        expires_at: deadline()
      }
    }
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

  defp read_request(socket, buffer, body_size) do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, body] when byte_size(body) == body_size ->
        {head <> "\r\n\r\n", body}

      _ ->
        case :gen_tcp.recv(socket, 0, 2_000) do
          {:ok, bytes} -> read_request(socket, buffer <> bytes, body_size)
          {:error, :closed} -> {"", ""}
        end
    end
  end

  defp detached_exec_request(context, overrides \\ %{}) do
    Map.merge(
      %{
        method: "POST",
        path: "/exec/fixture/start",
        query: "",
        headers: [
          {"connection", "upgrade"},
          {"upgrade", "tcp"}
        ],
        body: ~s({"Detach":false,"Tty":true}),
        host_peer: context
      },
      overrides
    )
  end

  test "open/3 normalizes the head, caps api-version and returns the tail" do
    {_cli, _listener} = unix_pair()
    {daemon, dialer} = unix_pair()
    context = host_context(dialer)
    request = detached_exec_request(context)

    task =
      Task.async(fn ->
        {_head, body} = read_request(daemon, "", byte_size(request.body))
        assert body == request.body

        :ok =
          :gen_tcp.send(
            daemon,
            "HTTP/1.1 101 UPGRADED\r\n" <>
              "Connection: Upgrade\r\n" <>
              "Upgrade: tcp\r\n" <>
              "Api-Version: 1.60\r\n" <>
              "Content-Type: application/vnd.docker.raw-stream\r\n\r\n" <>
              "engine-prefix"
          )
      end)

    {:upgrade, %{status: 101, protocol: "tcp", headers: headers}, backend, tail} =
      Raw.open(RawHost, request,
        admission_deadline: deadline(),
        deadline: deadline()
      )

    assert {"api-version", "1.57"} in headers
    assert {"connection", "Upgrade"} in headers
    assert {"upgrade", "tcp"} in headers
    assert tail == "engine-prefix"

    Task.shutdown(task, :brutal_kill)
    Stream.close(backend)
  end

  test "open/3 returns {:http, ...} with the backend closed for an ordinary response" do
    {_cli, _listener} = unix_pair()
    {daemon, dialer} = unix_pair()
    context = host_context(dialer)
    request = detached_exec_request(context)
    body = ~s({"Id":"x"})

    task =
      Task.async(fn ->
        _ = read_request(daemon, "", byte_size(request.body))

        :ok =
          :gen_tcp.send(
            daemon,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\n\r\n" <>
              body
          )
      end)

    assert {:http, 200, headers, response_body} =
             Raw.open(RawHost, request,
               admission_deadline: deadline(),
               deadline: deadline()
             )

    assert {"content-type", "application/json"} in headers
    assert response_body == body

    assert {:error, :closed} = :gen_tcp.recv(daemon, 0, 1_000)
    Task.shutdown(task, :brutal_kill)
  end

  test "open/3 returns {:http, ...} for engine 4xx/5xx with the backend closed" do
    for status <- [418, 422, 500] do
      {_cli, _listener} = unix_pair()
      {daemon, dialer} = unix_pair()
      context = host_context(dialer)
      request = detached_exec_request(context)
      body = ~s({"message":"engine error"})

      task =
        Task.async(fn ->
          _ = read_request(daemon, "", byte_size(request.body))

          :ok =
            :gen_tcp.send(
              daemon,
              "HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\n\r\n" <>
                body
            )
        end)

      assert {:http, ^status, headers, response_body} =
               Raw.open(RawHost, request,
                 admission_deadline: deadline(),
                 deadline: deadline()
               )

      assert {"content-type", "application/json"} in headers
      assert response_body == body

      assert {:error, :closed} = :gen_tcp.recv(daemon, 0, 1_000)
      Task.shutdown(task, :brutal_kill)
    end
  end

  test "open/3 returns the 502 body on engine failure and closes the backend" do
    {_cli, _listener} = unix_pair()
    {daemon, dialer} = unix_pair()
    context = host_context(dialer)
    request = detached_exec_request(context)

    task =
      Task.async(fn ->
        _ = read_request(daemon, "", byte_size(request.body))
        :ok = :gen_tcp.close(daemon)
      end)

    assert {:http, 502, [{"content-type", "application/json"}], body} =
             Raw.open(RawHost, request,
               admission_deadline: deadline(),
               deadline: deadline()
             )

    assert Jason.decode!(body) == %{"message" => "Docker engine connection failed"}

    Task.shutdown(task, :brutal_kill)
  end

  test "open/3 never dials for denial, unsupported route, out-of-range version or protocol errors" do
    # Denied context: the host denies the request.
    assert {:http, 403, _, _} =
             Raw.open(RefusingHost, detached_exec_request(never_dial_context()),
               admission_deadline: deadline(),
               deadline: deadline()
             )

    refute_received :dialed

    # Unsupported route: POST /swarm/init is unsupported in the reference table.
    assert {:http, 501, _, _} =
             Raw.open(
               RawHost,
               detached_exec_request(never_dial_context(), %{path: "/swarm/init"}),
               admission_deadline: deadline(),
               deadline: deadline()
             )

    refute_received :dialed

    # Out of range version: client too old.
    assert {:http, 400, _, _} =
             Raw.open(
               RawHost,
               detached_exec_request(never_dial_context(), %{path: "/v0.1/exec/fixture/start"}),
               admission_deadline: deadline(),
               deadline: deadline()
             )

    refute_received :dialed

    # Bad protocol for the takeover route: upgrade not tcp/h2c/websocket.
    assert {:http, 400, _, _} =
             Raw.open(
               RawHost,
               detached_exec_request(never_dial_context(), %{
                 headers: [{"connection", "upgrade"}, {"upgrade", "sftp"}]
               }),
               admission_deadline: deadline(),
               deadline: deadline()
             )

    refute_received :dialed
  end

  test "open/3 never dials when the engine is not ready" do
    context = never_dial_context()
    context = %{context | ready?: false}

    assert {:http, 503, _, _} =
             Raw.open(RawHost, detached_exec_request(context),
               admission_deadline: deadline(),
               deadline: deadline()
             )

    refute_received :dialed
  end

  test "run/4 delivers tails once, relays with independent EOF and closes both streams" do
    {cli, listener} = unix_pair()
    {daemon, dialer} = unix_pair()

    frontend = %Stream{adapter: SocketAdapter, handle: listener}
    backend = %Stream{adapter: SocketAdapter, handle: dialer}

    task =
      Task.async(fn ->
        receive do
          :start ->
            Raw.run(frontend, backend, "engine-tail",
              deadline: deadline(),
              request_tail: "buffered-input "
            )
        end
      end)

    :ok = :gen_tcp.controlling_process(listener, task.pid)
    :ok = :gen_tcp.controlling_process(dialer, task.pid)
    send(task.pid, :start)

    # The daemon receives the buffered request tail first.
    {:ok, request_body} = :gen_tcp.recv(daemon, 0, 2_000)
    assert request_body == "buffered-input "

    # Daemon writes later output then EOF.
    :ok = :gen_tcp.send(daemon, "later-output")
    :ok = :gen_tcp.shutdown(daemon, :write)

    # Client receives the tail first and later bytes after it.
    assert {:ok, "engine-tail"} = :gen_tcp.recv(cli, 11, 2_000)
    assert {:ok, "later-output"} = :gen_tcp.recv(cli, 12, 2_000)

    # Client keeps its write side open and sends bytes the engine must get
    # even after the engine's EOF.
    :ok = :gen_tcp.send(cli, "after-eof")
    :ok = :gen_tcp.shutdown(cli, :write)

    assert {:ok, "after-eof"} = :gen_tcp.recv(daemon, 9, 2_000)
    assert {:error, :closed} = :gen_tcp.recv(daemon, 0, 2_000)

    assert Task.await(task, 5_000) == :ok

    # Both streams are closed by the tunnel.
    assert {:error, :closed} = :gen_tcp.recv(cli, 0, 2_000)
  end

  test "run/4 writes no head and closes both streams on deadline" do
    {_cli, listener} = unix_pair()
    {_daemon, dialer} = unix_pair()

    frontend = %Stream{adapter: SocketAdapter, handle: listener}
    backend = %Stream{adapter: SocketAdapter, handle: dialer}

    task =
      Task.async(fn ->
        receive do
          :start ->
            Raw.run(frontend, backend, "",
              deadline: now() + 200,
              request_tail: ""
            )
        end
      end)

    :ok = :gen_tcp.controlling_process(listener, task.pid)
    :ok = :gen_tcp.controlling_process(dialer, task.pid)
    send(task.pid, :start)

    assert {:error, :deadline} = Task.await(task, 5_000)

    assert {:error, :closed} = :gen_tcp.recv(listener, 0, 2_000)
    assert {:error, :closed} = :gen_tcp.recv(dialer, 0, 2_000)
  end

  test "run/4 closes both streams on frontend failure" do
    {_cli, _listener} = unix_pair()
    {_daemon, dialer} = unix_pair()

    frontend = %Stream{adapter: FailingFrontend, handle: nil}
    backend = %Stream{adapter: SocketAdapter, handle: dialer}

    task =
      Task.async(fn ->
        receive do
          :start ->
            Raw.run(frontend, backend, "",
              deadline: deadline(),
              request_tail: ""
            )
        end
      end)

    :ok = :gen_tcp.controlling_process(dialer, task.pid)
    send(task.pid, :start)

    assert {:error, :stream_failed} = Task.await(task, 5_000)
    assert {:error, :closed} = :gen_tcp.recv(dialer, 0, 2_000)
  end

  test "run/4 closes both streams on backend failure" do
    {_cli, listener} = unix_pair()

    frontend = %Stream{adapter: SocketAdapter, handle: listener}
    backend = %Stream{adapter: UnreachableBackend, handle: nil}

    task =
      Task.async(fn ->
        receive do
          :start ->
            Raw.run(frontend, backend, "",
              deadline: deadline(),
              request_tail: ""
            )
        end
      end)

    :ok = :gen_tcp.controlling_process(listener, task.pid)
    send(task.pid, :start)

    assert {:error, :stream_failed} = Task.await(task, 5_000)
    assert {:error, :closed} = :gen_tcp.recv(listener, 0, 2_000)
  end

  test "run/4 reports an adapter's own deadline as the deadline" do
    {daemon, dialer} = unix_pair()
    frontend = %Stream{adapter: DeadlineFrontend, handle: nil}
    backend = %Stream{adapter: SocketAdapter, handle: dialer}
    started = now()

    task =
      Task.async(fn ->
        receive do
          :start -> Raw.run(frontend, backend, "", deadline: now() + 10_000, request_tail: "")
        end
      end)

    :ok = :gen_tcp.controlling_process(dialer, task.pid)
    send(task.pid, :start)

    assert Task.await(task, 5_000) == {:error, :deadline}
    assert now() - started < 5_000
    assert {:error, :closed} = :gen_tcp.recv(daemon, 0, 2_000)
  end

  test "relay/4 closes both streams when the head write raises" do
    {daemon, dialer} = unix_pair()
    context = host_context(dialer)
    request = detached_exec_request(context)
    test = self()

    task =
      Task.async(fn ->
        Raw.relay(RawHost, request, %Stream{adapter: RaisingFrontend, handle: test},
          admission_deadline: deadline(),
          deadline: deadline(),
          request_tail: ""
        )
      end)

    :ok = :gen_tcp.controlling_process(dialer, task.pid)
    {_head, _body} = read_request(daemon, "", byte_size(request.body))

    :ok =
      :gen_tcp.send(
        daemon,
        "HTTP/1.1 101 UPGRADED\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n"
      )

    assert Task.await(task, 5_000) == {:relayed, {:error, :stream_failed}}
    assert_receive :frontend_closed
    assert {:error, :closed} = :gen_tcp.recv(daemon, 0, 2_000)
  end
end
