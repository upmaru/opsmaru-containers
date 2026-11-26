defmodule Opsmaru.Containers.Docker.CowboyHandlerTest do
  # Tasks 2.1-2.4 and 2.6 of add-cowboy-gateway-embedding: the same-listener
  # Cowboy handler on loopback TLS 1.3 and TCP fixture listeners, with a
  # scripted engine. Telemetry handlers are VM-global, so this runs serially.
  use ExUnit.Case, async: false

  import Opsmaru.Containers.TestSupport.TelemetryCapture, only: [assert_exchange: 0]

  alias Opsmaru.Containers.Docker.CowboyHandler

  alias Opsmaru.Containers.TestSupport.{
    CowboyFixture,
    EngineFixture,
    TelemetryCapture,
    TLSFixture
  }

  alias Opsmaru.Containers.TestSupport.EngineFixture.{AllowHost, DenyHost}

  @moduletag :capture_log

  @exec_body ~s({"Detach":false,"Tty":false})

  defmodule SlowHost do
    @moduledoc false
    # Reports its callback process, then holds admission for a second.
    @behaviour Opsmaru.Containers.Host

    @impl Opsmaru.Containers.Host
    def context(%{host_peer: {context, observer}}) do
      send(observer, {:opening, self()})
      Process.sleep(1_000)
      {:ok, context}
    end

    @impl Opsmaru.Containers.Host
    def authorize(_context, _request), do: :allow
  end

  setup do
    engine = EngineFixture.start()
    TelemetryCapture.attach()
    %{engine: engine}
  end

  defp tls_listener(engine, extra \\ [], opts \\ []) do
    context = Keyword.get(opts, :context, EngineFixture.context(engine))
    host = Keyword.get(opts, :host, AllowHost)
    CowboyFixture.start_tls(CowboyFixture.handler_opts(host, context, self(), extra), opts)
  end

  defp exec_start(extra \\ "", path \\ "/v1.57/exec/fixture/start") do
    "POST #{path} HTTP/1.1\r\nHost: docker\r\nContent-Type: application/json\r\n" <>
      "Connection: Upgrade\r\nUpgrade: tcp\r\nContent-Length: #{byte_size(@exec_body)}\r\n\r\n" <>
      @exec_body <> extra
  end

  defp request(method, path, headers \\ [], body \\ "") do
    lines = Enum.map(headers, fn {name, value} -> "#{name}: #{value}\r\n" end)
    length = if body == "", do: [], else: ["Content-Length: #{byte_size(body)}\r\n"]

    IO.iodata_to_binary([
      "#{method} #{path} HTTP/1.1\r\nHost: docker\r\n",
      lines,
      length,
      "\r\n",
      body
    ])
  end

  defp tls_request(listener, bytes) do
    socket = CowboyFixture.connect_tls(listener)
    :ok = :ssl.send(socket, bytes)
    {status, _head, body} = CowboyFixture.recv_response(:ssl, socket)
    :ssl.close(socket)
    {status, body}
  end

  # The engine-side 101 after it read the exec start request.
  defp accept_upgrade(engine, tail) do
    backend = EngineFixture.accept(engine)
    {head, body, rest} = EngineFixture.read_request(backend)
    :ok = :gen_tcp.send(backend, EngineFixture.upgraded(tail))
    {backend, head, body, rest}
  end

  defp no_events do
    refute_receive {:docker_event, _, _, _}, 100
  end

  defp recv_until(_socket, remaining) when remaining <= 0, do: ""

  defp recv_until(socket, remaining) do
    {:ok, data} = :ssl.recv(socket, remaining, 5_000)
    data
  end

  describe "2.1 compiled with :cowboy_req" do
    test "the handler, tunnel and stream modules are loaded" do
      assert Code.ensure_loaded?(Opsmaru.Containers.Docker.CowboyHandler)
      assert Code.ensure_loaded?(Opsmaru.Containers.Docker.CowboyTunnel)
      assert Code.ensure_loaded?(Opsmaru.Containers.Transport.CowboyStream)
      assert function_exported?(CowboyHandler, :init, 2)
    end
  end

  describe "2.2 dispatch" do
    test "ordinary requests, detached exec and foreign WebSocket upgrades reach the fallback",
         %{engine: engine} do
      listener = tls_listener(engine)

      assert {200, "fallback GET /v1.57/containers/json body= upgrade="} =
               tls_request(listener, request("GET", "/v1.57/containers/json"))

      assert_receive {:fallback, "GET", "/v1.57/containers/json", "", []}

      detached = ~s({"Detach":true})

      assert {200, "fallback POST /v1.57/exec/abc/start body=" <> ^detached <> " upgrade="} =
               tls_request(
                 listener,
                 request(
                   "POST",
                   "/v1.57/exec/abc/start",
                   [{"Content-Type", "application/json"}],
                   detached
                 )
               )

      assert_receive {:fallback, "POST", "/v1.57/exec/abc/start", ^detached, []}

      websocket = [
        {"Connection", "Upgrade"},
        {"Upgrade", "websocket"},
        {"Sec-WebSocket-Version", "13"},
        {"Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ=="}
      ]

      assert {200, "fallback GET /live/websocket body= upgrade=websocket"} =
               tls_request(listener, request("GET", "/live/websocket", websocket))

      assert_receive {:fallback, "GET", "/live/websocket", "", ["websocket"]}

      # Unsupported routes are never takeover routes; they also go to the Plug.
      assert {200, _} = tls_request(listener, request("GET", "/v1.57/swarm"))

      refute_received :context_called
      refute_received {:dialed, _}
      no_events()
    end

    test "chained behind Opsmaru.Incus.Gateway.CowboyHandler, each request finds its handler",
         %{engine: engine} do
      incus = Opsmaru.Incus.Gateway.CowboyHandler

      unless Code.ensure_loaded?(incus),
        do: flunk("Opsmaru.Incus.Gateway.CowboyHandler is not loadable")

      docker_opts = CowboyFixture.handler_opts(AllowHost, EngineFixture.context(engine), self())

      listener =
        CowboyFixture.start_tls(%{gateway: nil, fallback: {CowboyHandler, docker_opts}},
          handler: incus
        )

      # An Incus SFTP upgrade is the Incus handler's (here: not configured,
      # in its own error shape).
      socket = CowboyFixture.connect_tls(listener)

      :ok =
        :ssl.send(
          socket,
          request("GET", "/1.0/instances/c1/sftp", [
            {"Connection", "Upgrade"},
            {"Upgrade", "sftp"}
          ])
        )

      {status, _, body} = CowboyFixture.recv_response(:ssl, socket)
      :ssl.close(socket)
      assert status == 503
      assert %{"type" => "error", "error" => "Gateway is not configured"} = Jason.decode!(body)

      # A Docker raw upgrade is this handler's.
      socket = CowboyFixture.connect_tls(listener)
      :ok = :ssl.send(socket, exec_start())
      {backend, _, _, _} = accept_upgrade(engine, "")
      {head, _} = CowboyFixture.recv_head(:ssl, socket)
      assert head =~ "HTTP/1.1 101 Switching Protocols"
      :gen_tcp.close(backend)
      :ssl.close(socket)

      # An ordinary Docker request is the Plug's.
      assert {200, "fallback GET /v1.57/info" <> _} =
               tls_request(listener, request("GET", "/v1.57/info"))

      assert_receive {:fallback, "GET", "/v1.57/info", "", []}
    end

    test "keyword-list handler options serve the fallback and the raw path", %{engine: engine} do
      handler_opts =
        AllowHost
        |> CowboyFixture.handler_opts(EngineFixture.context(engine), self())
        |> Map.to_list()

      listener = CowboyFixture.start_tls(handler_opts)

      assert {200, "fallback GET /v1.57/containers/json body= upgrade="} =
               tls_request(listener, request("GET", "/v1.57/containers/json"))

      socket = CowboyFixture.connect_tls(listener)
      :ok = :ssl.send(socket, exec_start("", "/v1.57/containers/missing/attach"))
      backend = EngineFixture.accept(engine)
      {_head, _body, _} = EngineFixture.read_request(backend)
      message = ~s({"message":"No such container: missing"})

      :ok =
        :gen_tcp.send(
          backend,
          "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\n" <>
            "Api-Version: 1.58\r\nContent-Length: #{byte_size(message)}\r\n\r\n" <> message
        )

      assert {404, _head, ^message} = CowboyFixture.recv_response(:ssl, socket)
      :ssl.close(socket)
    end

    test "raw-stream routes without Upgrade get a Docker-shaped 400 with no admission",
         %{engine: engine} do
      listener = tls_listener(engine)

      cases = [
        {"POST", "/v1.57/containers/abc/attach?stream=1&stdout=1", "tcp"},
        {"GET", "/v1.57/containers/abc/attach/ws?stream=1", "websocket"},
        {"POST", "/grpc", "h2c"},
        {"POST", "/v1.57/session", "h2c"},
        {"POST", "/containers/abc/attach", "tcp"}
      ]

      for {method, path, protocol} <- cases do
        assert {400, body} = tls_request(listener, request(method, path))

        assert Jason.decode!(body) == %{
                 "message" =>
                   "Docker stream requires an HTTP/1.1 request with an Upgrade: #{protocol} header"
               }

        exchange = assert_exchange()
        {_, start_meta} = exchange.start
        {_, stop_meta} = exchange.stop
        assert {_, %{status: 400}} = exchange.request
        assert start_meta.adapter == :cowboy
        assert start_meta.host == AllowHost
        assert %{status: 400, outcome: :not_sent, reason: :invalid_request, path: nil} = stop_meta
      end

      refute_received :context_called
      refute_received {:dialed, _}
      refute_received {:fallback, _, _, _, _}
    end

    test "an HTTP/2 request on a takeover route gets the same 400", %{engine: engine} do
      listener = tls_listener(engine, [], alpn: ["h2", "http/1.1"])

      # One connection per request, with no request body: the 400 is sent
      # without reading a body, and Cowboy ends an HTTP/2 connection that
      # keeps sending DATA on a stream it already answered.
      for path <- ["/v1.57/containers/abc/attach", "/v1.57/exec/abc/start"] do
        {:ok, conn} =
          Mint.HTTP.connect(:https, "localhost", listener.port,
            protocols: [:http2],
            transport_opts: [
              cacerts: TLSFixture.certificates(listener.identity.cafile)
            ]
          )

        {:ok, conn, ref} = Mint.HTTP.request(conn, "POST", path, [], nil)
        {conn, status, body} = h2_response(conn, ref)
        assert status == 400

        assert Jason.decode!(body) == %{
                 "message" =>
                   "Docker stream requires an HTTP/1.1 request with an Upgrade: tcp header"
               }

        exchange = assert_exchange()
        assert {_, %{reason: :invalid_request, outcome: :not_sent}} = exchange.stop
        Mint.HTTP.close(conn)
      end

      refute_received :context_called
      refute_received {:dialed, _}
      refute_received {:fallback, _, _, _, _}
    end

    test "denial, version errors and an unready engine never dial", %{engine: engine} do
      denied = tls_listener(engine, [], host: DenyHost)
      assert {403, body} = tls_request(denied, exec_start())
      assert Jason.decode!(body) == %{"message" => "request denied"}
      assert {_, %{status: 403, reason: :denied, outcome: :not_sent}} = assert_exchange().stop

      listener = tls_listener(engine)
      assert {400, body} = tls_request(listener, exec_start("", "/v1.20/exec/fixture/start"))

      assert Jason.decode!(body)["message"] ==
               "client version 1.20 is too old. Minimum supported API version is 1.40, " <>
                 "please upgrade your client to a newer version"

      assert {_, %{status: 400, reason: :version}} = assert_exchange().stop

      assert {400, body} = tls_request(listener, exec_start("", "/v1.99/exec/fixture/start"))

      assert Jason.decode!(body)["message"] ==
               "client version 1.99 is too new. Maximum supported API version is 1.57"

      assert {_, %{status: 400, reason: :version}} = assert_exchange().stop

      unready =
        tls_listener(engine, [], context: EngineFixture.context(engine, ready?: false))

      assert {503, body} = tls_request(unready, exec_start())
      assert Jason.decode!(body) == %{"message" => "Docker engine is not ready"}
      assert {_, %{status: 503, reason: :not_ready, outcome: :not_sent}} = assert_exchange().stop

      # A wrong upgrade protocol on a takeover route is admitted, then refused
      # by the stream handshake check, still before any dial.
      bad =
        request(
          "POST",
          "/v1.57/session",
          [{"Connection", "Upgrade"}, {"Upgrade", "tcp"}]
        )

      assert {400, body} = tls_request(listener, bad)
      assert Jason.decode!(body) == %{"message" => "Invalid Docker stream request"}

      refute_received {:dialed, _}
      refute_received {:fallback, _, _, _, _}
    end
  end

  describe "2.3 takeover" do
    test "buffered stdin, the engine tail and the exact 101 head", %{engine: engine} do
      listener = tls_listener(engine)
      socket = CowboyFixture.connect_tls(listener)

      # stdin sent in the same write as the exec start request.
      :ok = :ssl.send(socket, exec_start("early-stdin"))
      assert_receive {:dialed, _relay}, 2_000

      {backend, head, body, rest} = accept_upgrade(engine, "engine-tail")
      assert head =~ "POST /v1.57/exec/fixture/start HTTP/1.1"
      assert head =~ "\r\nconnection: Upgrade\r\nupgrade: tcp"
      assert body == @exec_body

      {client_head, client_rest} = CowboyFixture.recv_head(:ssl, socket)

      assert client_head ==
               "HTTP/1.1 101 Switching Protocols\r\n" <>
                 "api-version: 1.57\r\n" <>
                 "connection: Upgrade\r\n" <>
                 "content-type: application/vnd.docker.raw-stream\r\n" <>
                 "docker-experimental: false\r\n" <>
                 "ostype: linux\r\n" <>
                 "server: Docker/29.10.0 (linux)\r\n" <>
                 "upgrade: tcp"

      # relay/4 writes exactly these headers, in the engine's order.
      relay_headers = [
        {"content-type", "application/vnd.docker.raw-stream"},
        {"api-version", "1.57"},
        {"docker-experimental", "false"},
        {"ostype", "linux"},
        {"server", "Docker/29.10.0 (linux)"},
        {"connection", "Upgrade"},
        {"upgrade", "tcp"}
      ]

      cowboy_headers =
        client_head
        |> String.split("\r\n")
        |> tl()
        |> Enum.map(fn line ->
          [name, value] = String.split(line, ": ", parts: 2)
          {name, value}
        end)

      assert Enum.sort(cowboy_headers) == Enum.sort(relay_headers)

      # The engine tail reaches the client first.
      {tail, ""} = CowboyFixture.recv_exactly(:ssl, socket, client_rest, byte_size("engine-tail"))
      assert tail == "engine-tail"

      # The buffered stdin reaches the engine once, before later stdin.
      {early, ""} = EngineFixture.read_exactly(backend, rest, byte_size("early-stdin"))
      assert early == "early-stdin"

      # An HTTP request on the tunnel is opaque stdin, never parsed by Cowboy.
      late = "GET /v1.57/containers/json HTTP/1.1\r\nHost: docker\r\n\r\n"
      :ok = :ssl.send(socket, late)
      {received, ""} = EngineFixture.read_exactly(backend, "", byte_size(late))
      assert received == late
      refute_received {:fallback, _, _, _, _}

      :ok = :gen_tcp.send(backend, "output")
      {output, ""} = CowboyFixture.recv_exactly(:ssl, socket, "", 6)
      assert output == "output"

      # Engine EOF, then client EOF: the tunnel ends and the connection closes
      # without returning to Cowboy.
      :ok = :gen_tcp.shutdown(backend, :write)
      assert {:error, :closed} = :ssl.recv(socket, 0, 2_000)
      assert {"", :eof} = EngineFixture.read_to_eof(backend)

      exchange = assert_exchange()
      assert {_, %{status: 101}} = exchange.request
      {stop, stop_meta} = exchange.stop

      assert %{
               adapter: :cowboy,
               mode: :docker_stream,
               route: "/exec/{name:.*}/start",
               path: "/v1.57/exec/fixture/start",
               api_version: "1.57",
               method: "POST",
               status: 101,
               outcome: :ok,
               reason: nil
             } = stop_meta

      assert stop.request_bytes == byte_size("early-stdin") + byte_size(late)
      assert stop.response_bytes == byte_size("engine-tail") + byte_size("output")

      # Exactly one dial: the one asserted after the request was sent.
      refute_received {:dialed, _}
    end

    test "an engine refusing the upgrade answers through Cowboy and closes the backend",
         %{engine: engine} do
      listener = tls_listener(engine)
      socket = CowboyFixture.connect_tls(listener)
      :ok = :ssl.send(socket, exec_start("", "/v1.57/containers/missing/attach"))

      backend = EngineFixture.accept(engine)
      {_head, _body, _} = EngineFixture.read_request(backend)
      message = ~s({"message":"No such container: missing"})

      :ok =
        :gen_tcp.send(
          backend,
          "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\n" <>
            "Api-Version: 1.58\r\nContent-Length: #{byte_size(message)}\r\n\r\n" <> message
        )

      {status, head, body} = CowboyFixture.recv_response(:ssl, socket)
      assert status == 404
      assert body == message
      assert head =~ "api-version: 1.58"
      assert {"", :eof} = EngineFixture.read_to_eof(backend)

      exchange = assert_exchange()
      assert {_, %{status: 404}} = exchange.request
      assert {_, %{status: 404, outcome: :ok}} = exchange.stop

      assert_received {:dialed, _}
      refute_receive {:dialed, _}, 200
      :ssl.close(socket)
    end

    test "a handler killed before the cast closes the backend without retrying",
         %{engine: engine} do
      listener = tls_listener(engine)
      socket = CowboyFixture.connect_tls(listener)
      :ok = :ssl.send(socket, exec_start())

      assert_receive {:dialed, relay}, 2_000
      backend = EngineFixture.accept(engine)
      {_head, _body, _} = EngineFixture.read_request(backend)

      # The handler spawned the relay.
      {:parent, handler} = Process.info(relay, :parent)

      Process.exit(handler, :kill)

      # The relay ends with the handler, so the engine's late 101 meets a
      # closed backend.
      _ = :gen_tcp.send(backend, EngineFixture.upgraded())
      assert {"", :eof} = EngineFixture.read_to_eof(backend)

      case CowboyFixture.recv_head(:ssl, socket) do
        {head, _} -> refute head =~ " 101 "
        {:closed, _, _} -> :ok
      end

      exchange = assert_exchange()
      assert {_, %{reason: :killed, outcome: :uncertain}} = exchange.stop
      refute_receive {:dialed, _}, 200
      :ssl.close(socket)
    end

    test "a client lost during admission ends the relay before it dials", %{engine: engine} do
      listener = tls_listener(engine, [], host: SlowHost)
      socket = CowboyFixture.connect_tls(listener)
      :ok = :ssl.send(socket, exec_start())

      # Host callbacks run in their own process, spawned by the relay.
      assert_receive {:opening, callback}, 2_000
      {:parent, relay} = Process.info(callback, :parent)
      monitor = Process.monitor(relay)
      :ssl.close(socket)

      assert_receive {:DOWN, ^monitor, :process, ^relay, :killed}, 500
      exchange = assert_exchange()
      assert {_, %{status: nil, outcome: :not_sent, reason: reason}} = exchange.stop
      assert reason in [:caller_closed, :killed]
      refute_receive {:dialed, _}, 1_200
    end

    test "a client lost during a stalled handshake closes the backend at once",
         %{engine: engine} do
      listener = tls_listener(engine)
      socket = CowboyFixture.connect_tls(listener)
      :ok = :ssl.send(socket, exec_start())

      assert_receive {:dialed, _relay}, 2_000
      backend = EngineFixture.accept(engine)
      {_head, _body, _} = EngineFixture.read_request(backend)
      :ssl.close(socket)

      # Well before the 30 s dial timeout that bounds the handshake.
      assert {"", :eof} = EngineFixture.read_to_eof(backend, "", 1_000)
      exchange = assert_exchange()
      assert {_, %{status: nil, outcome: :uncertain, reason: reason}} = exchange.stop
      # No response can reach a closed connection, so none is recorded.
      assert exchange.request == nil
      assert reason in [:caller_closed, :killed]
      refute_receive {:dialed, _}, 200
    end

    test "a takeover that misses the handoff timeout closes the backend", %{engine: engine} do
      listener = tls_listener(engine, handoff_timeout: 200)
      socket = CowboyFixture.connect_tls(listener)
      :ok = :ssl.send(socket, exec_start())

      backend = EngineFixture.accept(engine)
      {_head, _body, _} = EngineFixture.read_request(backend)

      # Hold Cowboy's connection process so the switch_protocol cast waits.
      [connection] = :ranch.procs(listener.ref, :connections)
      :ok = :sys.suspend(connection)
      :ok = :gen_tcp.send(backend, EngineFixture.upgraded("unseen-tail"))

      assert {"", :eof} = EngineFixture.read_to_eof(backend, "", 3_000)
      exchange = assert_exchange()
      assert {_, %{status: 101, reason: :handoff_timeout, outcome: :sent}} = exchange.stop

      :ok = :sys.resume(connection)
      # Cowboy writes its 101 late; the tunnel then closes with no bytes.
      case CowboyFixture.recv_head(:ssl, socket) do
        {_head, rest} -> assert rest == "" and match?({:error, _}, :ssl.recv(socket, 0, 2_000))
        {:closed, _, _} -> :ok
      end

      assert_received {:dialed, _}
      refute_receive {:dialed, _}, 200
      :ssl.close(socket)
    end
  end

  describe "repeated request headers" do
    test "BuildKit session methods reach the engine as separate headers", %{engine: engine} do
      listener = tls_listener(engine)
      socket = CowboyFixture.connect_tls(listener)

      methods = [
        "/moby.filesync.v1.FileSync/DiffCopy",
        "/moby.filesync.v1.FileSync/TarStream",
        "/grpc.health.v1.Health/Check"
      ]

      headers =
        [{"Connection", "Upgrade"}, {"Upgrade", "h2c"}, {"X-Docker-Expose-Session-Uuid", "s1"}] ++
          Enum.map(methods, &{"X-Docker-Expose-Session-Grpc-Method", &1})

      :ok = :ssl.send(socket, request("POST", "/session", headers))
      assert_receive {:dialed, _relay}, 2_000

      backend = EngineFixture.accept(engine)
      {head, _body, _rest} = EngineFixture.read_request(backend)

      forwarded =
        for line <- String.split(head, "\r\n"),
            [name, value] <- [String.split(line, ": ", parts: 2)],
            String.downcase(name) == "x-docker-expose-session-grpc-method",
            do: value

      assert forwarded == methods
      assert head =~ "\r\nx-docker-expose-session-uuid: s1"

      # The engine accepts the session as dockerd does, and the upgrade
      # completes end to end.
      :ok =
        :gen_tcp.send(
          backend,
          "HTTP/1.1 101 UPGRADED\r\nConnection: Upgrade\r\nUpgrade: h2c\r\n\r\nengine-h2"
        )

      {client_head, client_rest} = CowboyFixture.recv_head(:ssl, socket)
      assert client_head =~ ~r/\AHTTP\/1\.1 101 Switching Protocols\r\n/
      assert client_head =~ "\r\nupgrade: h2c"

      assert client_rest <> recv_until(socket, byte_size("engine-h2") - byte_size(client_rest)) ==
               "engine-h2"

      :ok = :ssl.send(socket, "client-h2")
      assert {:ok, "client-h2"} = :gen_tcp.recv(backend, byte_size("client-h2"), 5_000)

      :ssl.close(socket)
      :gen_tcp.close(backend)
    end
  end

  describe "2.4 half-close" do
    @tag :go
    test "TLS: engine EOF first sends close_notify and the client's later bytes still arrive",
         %{engine: engine} do
      client = go_client!()
      listener = tls_listener(engine)
      port = go_run(client, listener, "engine-first")

      {backend, _head, _body, rest} = accept_upgrade(engine, "")
      assert rest == ""
      :ok = :gen_tcp.send(backend, "all-output")
      :ok = :gen_tcp.shutdown(backend, :write)

      lines = go_lines(port)
      assert lines["OUTPUT"] == "all-output"
      assert lines["READ"] == "ok"
      assert lines["WROTE"] == "ok"
      assert lines["CLOSEWRITE"] == "ok"

      assert {"late-input", :eof} = EngineFixture.read_to_eof(backend)

      assert {_, %{outcome: :ok, reason: nil}} = assert_exchange().stop
    end

    @tag :go
    test "TLS: client close_notify first forwards EOF; a later failed write is :caller_closed",
         %{engine: engine} do
      client = go_client!()
      listener = tls_listener(engine)
      port = go_run(client, listener, "client-first")

      {backend, _head, _body, rest} = accept_upgrade(engine, "")
      {input, :eof} = EngineFixture.read_to_eof(backend, rest)
      assert input == "client-input"

      # OTP ended the TLS session on the client's close_notify (decision 4):
      # output written after it cannot be delivered.
      :ok = :gen_tcp.send(backend, "output-after-client-eof")
      :ok = :gen_tcp.shutdown(backend, :write)

      lines = go_lines(port)
      assert lines["WROTE"] == "ok"
      assert lines["CLOSEWRITE"] == "ok"
      refute lines["OUTPUT"] =~ "output-after-client-eof"

      assert {_, %{outcome: :sent, reason: :caller_closed}} = assert_exchange().stop
    end

    test "TCP: client EOF first keeps the engine's output flowing", %{engine: engine} do
      listener =
        CowboyFixture.start_clear(
          CowboyFixture.handler_opts(AllowHost, EngineFixture.context(engine), self())
        )

      socket = CowboyFixture.connect_tcp(listener)
      :ok = :gen_tcp.send(socket, exec_start("client-input"))
      {backend, _head, _body, rest} = accept_upgrade(engine, "")
      {head, ""} = CowboyFixture.recv_head(:gen_tcp, socket)
      assert head =~ "HTTP/1.1 101 Switching Protocols"

      :ok = :gen_tcp.shutdown(socket, :write)
      assert {"client-input", :eof} = EngineFixture.read_to_eof(backend, rest)

      :ok = :gen_tcp.send(backend, "output-after-client-eof")
      :ok = :gen_tcp.shutdown(backend, :write)
      assert {"output-after-client-eof", :eof} = EngineFixture.read_to_eof(socket)

      exchange = assert_exchange()
      {stop, meta} = exchange.stop
      assert %{outcome: :ok, reason: nil} = meta
      assert stop.request_bytes == byte_size("client-input")
      assert stop.response_bytes == byte_size("output-after-client-eof")
    end

    test "TCP: engine EOF first keeps the client's input flowing", %{engine: engine} do
      listener =
        CowboyFixture.start_clear(
          CowboyFixture.handler_opts(AllowHost, EngineFixture.context(engine), self())
        )

      socket = CowboyFixture.connect_tcp(listener)
      :ok = :gen_tcp.send(socket, exec_start())
      {backend, _head, _body, ""} = accept_upgrade(engine, "output")
      :ok = :gen_tcp.shutdown(backend, :write)

      {_head, rest} = CowboyFixture.recv_head(:gen_tcp, socket)
      assert {"output", :eof} = EngineFixture.read_to_eof(socket, rest)

      :ok = :gen_tcp.send(socket, "input-after-engine-eof")
      :ok = :gen_tcp.shutdown(socket, :write)
      assert {"input-after-engine-eof", :eof} = EngineFixture.read_to_eof(backend)

      assert {_, %{outcome: :ok, reason: nil}} = assert_exchange().stop
    end
  end

  describe "4.3 telemetry redaction" do
    test "events carry no query, header, body, stream byte or identity; the fingerprint names the certificate",
         %{engine: engine} do
      context = %{EngineFixture.context(engine) | identity: "secret-identity-marker"}
      listener = tls_listener(engine, [], context: context)

      socket =
        CowboyFixture.connect_tls(listener,
          ssl: [
            certfile: String.to_charlist(listener.identity.certfile),
            keyfile: String.to_charlist(listener.identity.keyfile)
          ]
        )

      body = ~s({"Detach":false,"Tty":false,"secret-body-marker":1})

      request =
        "POST /v1.57/exec/fixture/start?secret-query-marker=1 HTTP/1.1\r\nHost: docker\r\n" <>
          "Authorization: Bearer secret-auth-marker\r\n" <>
          "X-Registry-Auth: secret-registry-marker\r\n" <>
          "Connection: Upgrade\r\nUpgrade: tcp\r\nContent-Length: #{byte_size(body)}\r\n\r\n" <>
          body

      :ok = :ssl.send(socket, request)
      {backend, _head, ^body, _rest} = accept_upgrade(engine, "")
      {_head, ""} = CowboyFixture.recv_head(:ssl, socket)

      :ok = :ssl.send(socket, "secret-stream-marker")
      {_, ""} = EngineFixture.read_exactly(backend, "", byte_size("secret-stream-marker"))
      :ok = :gen_tcp.send(backend, "secret-stream-marker")
      {_, ""} = CowboyFixture.recv_exactly(:ssl, socket, "", byte_size("secret-stream-marker"))
      :gen_tcp.close(backend)
      :ssl.close(socket)

      exchange = assert_exchange()

      [{:Certificate, der, _} | _] =
        :public_key.pem_decode(File.read!(listener.identity.certfile))

      fingerprint = :crypto.hash(:sha256, der) |> Base.encode16(case: :lower)

      for {_, meta} <- [exchange.start, exchange.request, exchange.stop] do
        assert meta.peer_fingerprint == fingerprint
        text = inspect(meta, limit: :infinity, printable_limit: :infinity)

        for marker <- ~w(secret-query-marker secret-auth-marker secret-registry-marker
                         secret-body-marker secret-stream-marker secret-identity-marker) do
          refute text =~ marker
        end
      end

      {_, start} = exchange.start
      assert {start.peer_address, is_integer(start.peer_port)} == {{127, 0, 0, 1}, true}

      plain = tls_listener(engine)
      assert {400, _} = tls_request(plain, request("POST", "/v1.57/containers/abc/attach"))
      assert {_, %{peer_fingerprint: nil}} = assert_exchange().start
    end
  end

  describe "2.6 passivity and failure cleanup" do
    test "loading the handler starts no process and opens no listener" do
      before = MapSet.new(Process.list())
      listeners = :ranch.info()

      for module <- [
            CowboyHandler,
            Opsmaru.Containers.Docker.CowboyTunnel,
            Opsmaru.Containers.Transport.CowboyStream
          ] do
        :code.purge(module)
        :code.delete(module)
        {:module, ^module} = Code.ensure_loaded(module)
      end

      Process.sleep(50)
      assert MapSet.difference(MapSet.new(Process.list()), before) |> MapSet.size() == 0
      assert :ranch.info() == listeners
      refute function_exported?(CowboyHandler, :start_link, 1)
      refute function_exported?(CowboyHandler, :child_spec, 1)
    end

    test "a raised handler error closes the backend", %{engine: engine} do
      context = EngineFixture.context(engine)
      opts = CowboyFixture.handler_opts(AllowHost, context, self())

      # A request map whose connection pid is not a pid: the switch_protocol
      # cast raises after the relay has opened the backend.
      req = %{
        pid: :not_a_pid,
        streamid: 1,
        method: "POST",
        version: :"HTTP/1.1",
        scheme: "https",
        host: "docker",
        port: 443,
        path: "/v1.57/exec/fixture/start",
        qs: "",
        headers: %{"connection" => "Upgrade", "upgrade" => "tcp", "host" => "docker"},
        peer: {{127, 0, 0, 1}, 50_000},
        sock: {{127, 0, 0, 1}, 443},
        cert: :undefined,
        has_body: false
      }

      test = self()

      {pid, monitor} =
        spawn_monitor(fn ->
          send(test, {:raised, catch_error(CowboyHandler.init(req, opts))})
        end)

      {backend, _head, _body, _} = accept_upgrade(engine, "")
      # The handler re-raises the cast's raw `:badarg` after killing the relay.
      assert_receive {:raised, :badarg}, 2_000
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}
      assert {"", :eof} = EngineFixture.read_to_eof(backend)
      assert {_, %{reason: :killed, outcome: :sent}} = assert_exchange().stop
    end

    test "a killed relay closes the backend and the client socket", %{engine: engine} do
      listener = tls_listener(engine)
      socket = CowboyFixture.connect_tls(listener)
      :ok = :ssl.send(socket, exec_start())
      assert_receive {:dialed, relay}, 2_000
      {backend, _, _, _} = accept_upgrade(engine, "")
      {_head, ""} = CowboyFixture.recv_head(:ssl, socket)

      :ok = :ssl.send(socket, "x")
      assert {"x", ""} = EngineFixture.read_exactly(backend, "", 1)

      Process.exit(relay, :kill)
      assert {:error, :closed} = :ssl.recv(socket, 0, 2_000)
      assert {"", :eof} = EngineFixture.read_to_eof(backend)

      exchange = assert_exchange()
      {stop, meta} = exchange.stop
      assert %{reason: :killed, outcome: :sent} = meta
      assert stop.request_bytes == 1
    end
  end

  # --- HTTP/2 client --------------------------------------------------------

  defp h2_response(conn, ref, status \\ nil, body \\ "") do
    # Only the connection's socket messages: telemetry events share the mailbox.
    {:ok, conn, responses} =
      receive do
        message when is_tuple(message) and elem(message, 0) in [:ssl, :ssl_closed, :ssl_error] ->
          Mint.HTTP.stream(conn, message)
      after
        5_000 -> flunk("no HTTP/2 response")
      end

    Enum.reduce(responses, {conn, status, body, false}, fn
      {:status, ^ref, value}, {c, _, b, d} -> {c, value, b, d}
      {:data, ^ref, data}, {c, s, b, d} -> {c, s, b <> data, d}
      {:done, ^ref}, {c, s, b, _} -> {c, s, b, true}
      _, acc -> acc
    end)
    |> case do
      {conn, status, body, true} -> {conn, status, body}
      {conn, status, body, false} -> h2_response(conn, ref, status, body)
    end
  end

  # --- Go TLS client --------------------------------------------------------

  defp go_client! do
    go = System.find_executable("go")
    if is_nil(go), do: flunk("Go is required for the TLS half-close fixture (mise install)")

    output = Path.join(System.tmp_dir!(), "occ-go-#{System.unique_integer([:positive])}")
    File.mkdir_p!(output)
    on_exit(fn -> File.rm_rf(output) end)
    binary = Path.join(output, "tls_hijack_client")
    source = Path.expand("../support/go/tls_hijack_client.go", __DIR__)

    {log, status} =
      System.cmd(go, ["build", "-o", binary, source],
        stderr_to_stdout: true,
        env: [{"GOFLAGS", "-mod=mod"}, {"GO111MODULE", "off"}]
      )

    assert status == 0, log
    binary
  end

  defp go_run(binary, listener, mode) do
    Port.open({:spawn_executable, binary}, [
      :binary,
      :exit_status,
      {:line, 65_536},
      args: ["127.0.0.1:#{listener.port}", listener.identity.cafile, mode]
    ])
  end

  defp go_lines(port, acc \\ %{}) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        [key, value] = String.split(line, " ", parts: 2)
        {unquoted, _} = Code.eval_string(value)
        go_lines(port, Map.put(acc, key, unquoted))

      {^port, {:exit_status, 0}} ->
        acc

      {^port, {:exit_status, status}} ->
        flunk("Go client exited #{status}: #{inspect(acc)}")
    after
      10_000 -> flunk("Go client timed out: #{inspect(acc)}")
    end
  end
end
