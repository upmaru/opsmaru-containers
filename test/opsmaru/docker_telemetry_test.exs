defmodule Opsmaru.Containers.Docker.TelemetryTest do
  # Telemetry handlers are VM-global, so this suite runs alone.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  import Opsmaru.Containers.TestSupport.TelemetryCapture, only: [assert_exchange: 0]

  alias Opsmaru.Containers.Docker.{Exchange, Raw}
  alias Opsmaru.Containers.Docker.Plug, as: DockerPlug
  alias Opsmaru.Containers.Telemetry
  alias Opsmaru.Containers.TestSupport.{EngineFixture, TelemetryCapture}
  alias Opsmaru.Containers.Transport.Stream

  @start [:opsmaru_containers, :docker, :exchange, :start]
  @request [:opsmaru_containers, :docker, :request]
  @stop [:opsmaru_containers, :docker, :exchange, :stop]

  @metadata_keys ~w(telemetry_span_context adapter host mode method route path api_version
                    peer_address peer_port peer_fingerprint status outcome reason)a

  # Values that must never reach event metadata (task 4.3).
  @markers [
    "secret-query-marker",
    "secret-auth-marker",
    "secret-registry-marker",
    "secret-body-marker",
    "secret-stream-marker",
    "secret-identity-marker",
    "secret-bind-marker",
    "secret-mapped-marker",
    "secret-refused-marker",
    "Docker engine",
    "request denied",
    "page not found"
  ]

  defmodule MarkerHost do
    @moduledoc false
    @behaviour Opsmaru.Containers.Host

    @impl Opsmaru.Containers.Host
    def context(%{host_peer: {context, _observer}}), do: {:ok, context}

    @impl Opsmaru.Containers.Host
    def authorize(_context, %{path: path}) do
      if String.contains?(path, "secret-refused-marker"), do: :deny, else: :allow
    end

    @impl Opsmaru.Containers.Host
    def map_bind_source(_context, "/host/secret-bind-marker"),
      do: {:ok, "/engine/secret-mapped-marker"}

    def map_bind_source(_context, _), do: :deny
  end

  defmodule FrontendSocket do
    @moduledoc false
    @behaviour Opsmaru.Containers.Transport.Stream

    @impl Stream
    def recv(socket, limit, deadline) do
      timeout = max(deadline - System.monotonic_time(:millisecond), 1)

      case :gen_tcp.recv(socket, 0, timeout) do
        {:ok, bytes} when byte_size(bytes) <= limit -> {:ok, bytes}
        {:error, :closed} -> :eof
        {:error, :timeout} -> {:error, :deadline}
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

  setup do
    detach_all()
    TelemetryCapture.attach()
    engine = EngineFixture.start()
    context = %{EngineFixture.context(engine) | identity: "secret-identity-marker"}
    %{engine: engine, context: context}
  end

  # --- Helpers ----------------------------------------------------------------

  defp detach_all do
    for %{id: id} <- :telemetry.list_handlers([:opsmaru_containers]), do: :telemetry.detach(id)
  end

  defp now, do: System.monotonic_time(:millisecond)

  # Every exchange in this suite passes through here: the documented keys,
  # closed value sets and no marker in any value.
  defp exchange! do
    exchange = assert_exchange()

    for {_, meta} <- [exchange.start, exchange.stop] ++ List.wrap(exchange.request) do
      assert_clean(meta)
    end

    {_, stop} = exchange.stop
    assert stop.outcome in [:ok | Exchange.outcomes()]
    assert stop.reason in [nil | Exchange.reason_set()]
    assert stop.outcome == :ok == is_nil(stop.reason)
    exchange
  end

  defp assert_clean(meta) do
    assert meta |> Map.keys() |> Enum.sort() == Enum.sort(@metadata_keys)
    text = inspect(meta, limit: :infinity, printable_limit: :infinity)
    for marker <- @markers, do: refute(text =~ marker, "metadata carried #{marker}: #{text}")
  end

  defp no_more_events(timeout \\ 100), do: refute_receive({:docker_event, _, _, _}, timeout)

  defp plug_conn(method, path, body \\ "", headers \\ []) do
    Enum.reduce(headers, Plug.Test.conn(method, path, body), fn {name, value}, conn ->
      Plug.Conn.put_req_header(conn, name, value)
    end)
  end

  defp serve_plug(conn, context, host \\ MarkerHost, opts \\ []) do
    conn
    |> Plug.Conn.put_private(:opsmaru_containers_peer, {context, self()})
    |> DockerPlug.call(DockerPlug.init([host: host] ++ opts))
  end

  defp async_plug(conn, context, host \\ MarkerHost, opts \\ []) do
    Task.async(fn ->
      try do
        serve_plug(conn, context, host, opts)
      rescue
        error -> {:raised, error}
      end
    end)
  end

  defp json_response(status, body) do
    "HTTP/1.1 #{status} OK\r\nContent-Type: application/json\r\n" <>
      "Content-Length: #{byte_size(body)}\r\nApi-Version: 1.58\r\n\r\n" <> body
  end

  defp frontend_pair do
    path = "/tmp/occ-front-#{Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)}"
    options = [:binary, active: false, exit_on_close: false, send_timeout: 2_000]
    {:ok, listener} = :gen_tcp.listen(0, [{:ifaddr, {:local, path}} | options])
    on_exit(fn -> File.rm(path) end)
    {:ok, client} = :gen_tcp.connect({:local, path}, 0, options, 2_000)
    {:ok, server} = :gen_tcp.accept(listener, 2_000)
    :gen_tcp.close(listener)
    {client, %Stream{adapter: FrontendSocket, handle: server}}
  end

  defp attach_request(context, headers \\ [{"connection", "Upgrade"}, {"upgrade", "tcp"}]) do
    %{
      method: "POST",
      path: "/v1.45/containers/fixture/attach",
      query: "stream=1&stdin=1&stdout=1&secret-query-marker=1",
      headers: [{"x-registry-auth", "secret-registry-marker"} | headers],
      body: "",
      peer: {127, 0, 0, 1},
      host_peer: {context, self()}
    }
  end

  defp relay(context, frontend, opts \\ []) do
    request = Keyword.get(opts, :request, attach_request(context))
    deadline = now() + Keyword.get(opts, :stream, 2_000)

    Raw.relay(MarkerHost, request, frontend,
      admission_deadline: now() + 1_000,
      deadline: deadline,
      request_tail: ""
    )
  end

  defp recv_until(socket, expected, buffer \\ "") do
    if String.contains?(buffer, expected) do
      buffer
    else
      {:ok, bytes} = :gen_tcp.recv(socket, 0, 2_000)
      recv_until(socket, expected, buffer <> bytes)
    end
  end

  # --- 4.1 Observer ------------------------------------------------------------

  describe "exchange observer" do
    test "no observer starts while no handler is attached" do
      detach_all()
      exchange = Exchange.start(%{adapter: :raw, method: "GET"})
      refute Exchange.active?(exchange)
      assert Exchange.finish(exchange) == exchange
      no_more_events()
    end

    test "a normal finish reports one start and exactly one stop" do
      exchange = Exchange.start(%{adapter: :raw, method: "GET"})
      Exchange.commit(exchange, 200)
      Exchange.response_bytes(exchange, 12)
      Exchange.finish(exchange)
      Exchange.finish(exchange)

      %{stop: {measurements, meta}, request: {_, request}} = exchange!()
      assert request.status == 200
      assert measurements.response_bytes == 12
      assert {meta.status, meta.outcome, meta.reason} == {200, :ok, nil}
      no_more_events()
    end

    test "a killed owner reports :killed with the outcome it recorded" do
      test = self()

      owner =
        spawn(fn ->
          exchange = Exchange.start(%{adapter: :raw, method: "POST"})
          Exchange.sent(exchange, :uncertain)
          send(test, :ready)
          Process.sleep(:infinity)
        end)

      assert_receive :ready
      Process.exit(owner, :kill)
      assert {_, %{outcome: :uncertain, reason: :killed, status: nil}} = exchange!().stop
      no_more_events()
    end

    test "a finish racing a kill reports exactly once" do
      test = self()

      for _ <- 1..20 do
        owner =
          spawn(fn ->
            exchange = Exchange.start(%{adapter: :raw, method: "GET"})
            send(test, :running)
            Exchange.finish(exchange)
            Process.sleep(:infinity)
          end)

        assert_receive :running
        Process.exit(owner, :kill)
        exchange!()
        no_more_events(20)
      end
    end

    test "a transfer to the relay followed by a kill reports once, at the kill" do
      test = self()
      relay = spawn(fn -> Process.sleep(:infinity) end)

      spawn(fn ->
        exchange = Exchange.start(%{adapter: :cowboy, method: "POST"})
        Exchange.transfer(exchange, relay)
        send(test, :transferred)
      end)

      assert_receive :transferred
      refute_receive {:docker_event, @stop, _, _}, 100
      Process.exit(relay, :kill)
      assert {_, %{reason: :killed}} = exchange!().stop
      no_more_events()
    end

    test "a handler attached mid-exchange yields no unpaired events" do
      detach_all()
      exchange = Exchange.start(%{adapter: :raw, method: "GET"})
      TelemetryCapture.attach()
      Exchange.commit(exchange, 200)
      Exchange.finish(exchange)
      no_more_events(200)
    end

    test "a loaded but unstarted :telemetry never raises", %{engine: engine, context: context} do
      :ok = Application.stop(:telemetry)
      on_exit(fn -> {:ok, _} = Application.ensure_all_started(:telemetry) end)

      assert Telemetry.list_handlers([:opsmaru_containers]) == []
      assert Telemetry.execute(@stop, %{}, %{}) == :ok
      refute Exchange.active?(Exchange.start(%{adapter: :plug, method: "GET"}))

      task = async_plug(plug_conn("GET", "/v1.45/containers/json"), context)
      socket = EngineFixture.accept(engine)
      EngineFixture.read_request(socket)
      :gen_tcp.send(socket, json_response(200, "[]"))
      assert Task.await(task).status == 200
    end

    test "facts outside the closed sets are dropped and peers are sanitized" do
      der = :crypto.strong_rand_bytes(64)

      exchange =
        Exchange.start(%{
          adapter: :cowboy,
          method: "PATCH",
          peer_address: {:local, "/secret"},
          peer_port: 70_000,
          certificate: der
        })

      Exchange.interrupt(exchange, :invented)
      Exchange.sent(exchange, :maybe)
      Exchange.finish(exchange)

      %{start: {_, start}, stop: {_, stop}} = exchange!()
      assert start.method == nil
      assert {start.peer_address, start.peer_port} == {nil, nil}
      assert start.peer_fingerprint == :crypto.hash(:sha256, der) |> Base.encode16(case: :lower)
      assert {stop.outcome, stop.reason} == {:ok, nil}

      Exchange.finish(Exchange.start(%{adapter: :raw, method: "GET", peer_port: 8_443}))
      %{start: {_, start}} = exchange!()
      assert {start.peer_fingerprint, start.peer_port} == {nil, 8_443}
    end
  end

  # --- 4.2 Docker.Plug ---------------------------------------------------------

  describe "Docker.Plug" do
    test "an ordinary read reports its route, status and body bytes", %{
      engine: engine,
      context: context
    } do
      conn =
        plug_conn("GET", "/v1.45/containers/json?all=1&secret-query-marker=1", "", [
          {"authorization", "Bearer secret-auth-marker"}
        ])

      task = async_plug(conn, context)
      socket = EngineFixture.accept(engine)
      EngineFixture.read_request(socket)
      body = ~s([{"Id":"abc"}])
      :gen_tcp.send(socket, json_response(200, body))
      conn = Task.await(task)
      assert {conn.status, conn.resp_body} == {200, body}

      %{start: {_, start}, request: {request_m, request}, stop: {stop_m, stop}} = exchange!()
      assert {start.adapter, start.method, start.host} == {:plug, "GET", MarkerHost}
      assert {start.peer_address, start.peer_port} == {{127, 0, 0, 1}, nil}
      assert {start.mode, start.route, start.path} == {nil, nil, nil}
      assert is_integer(request_m.duration) and request.status == 200
      assert {stop.mode, stop.route} == {:http, "/containers/json"}
      assert {stop.path, stop.api_version} == {"/v1.45/containers/json", "1.45"}
      assert {stop.status, stop.outcome, stop.reason} == {200, :ok, nil}
      assert {stop_m.request_bytes, stop_m.response_bytes} == {0, byte_size(body)}
    end

    test "a checked mutation counts the request body read from the client", %{
      engine: engine,
      context: context
    } do
      body =
        Jason.encode!(%{
          "Image" => "secret-body-marker",
          "HostConfig" => %{"Binds" => ["/host/secret-bind-marker:/data"]}
        })

      task = async_plug(plug_conn("POST", "/v1.45/containers/create", body), context)
      socket = EngineFixture.accept(engine)
      {_head, forwarded, _} = EngineFixture.read_request(socket)
      assert forwarded =~ "/engine/secret-mapped-marker"
      :gen_tcp.send(socket, json_response(201, ~s({"Id":"abc"})))
      assert Task.await(task).status == 201

      assert {measurements, %{status: 201, outcome: :ok, route: "/containers/create"}} =
               exchange!().stop

      assert measurements.request_bytes == byte_size(body)
      assert measurements.response_bytes == byte_size(~s({"Id":"abc"}))
    end

    test "refusals report their status and reason and never dial", %{
      engine: engine,
      context: context
    } do
      cases = [
        {plug_conn("GET", "/v1.45/containers/secret-refused-marker/json"), context, 403, :denied},
        {plug_conn("GET", "/v1.20/containers/json?secret-query-marker=1"), context, 400,
         :version},
        {plug_conn("GET", "/v1.45/secret-refused-marker"), context, 404, :not_found},
        {plug_conn("GET", "/v1.45/containers/json"), %{context | ready?: false}, 503, :not_ready},
        {plug_conn("POST", "/v1.45/containers/abc/attach?stream=1"), context, 501, :unsupported},
        {plug_conn("POST", "/v1.45/exec/abc/start", "not json"), context, 400, :invalid_request},
        {plug_conn(
           "POST",
           "/v1.45/containers/create",
           :binary.copy("secret-body-marker", 70_000)
         ), context, 413, :too_large}
      ]

      for {conn, context, status, reason} <- cases do
        assert serve_plug(conn, context).status == status
        %{request: {_, request}, stop: {measurements, stop}} = exchange!()
        assert request.status == status
        assert {stop.status, stop.outcome, stop.reason} == {status, :not_sent, reason}
        assert measurements.response_bytes > 0
        refute_received {:dialed, _}
      end

      _ = engine
    end

    test "an unreachable engine reports :engine_unavailable", %{context: context} do
      {dialer, options} = context.dialer
      context = %{context | dialer: {dialer, %{options | path: "/tmp/occ-missing.sock"}}}

      assert serve_plug(plug_conn("GET", "/v1.45/containers/json"), context).status == 503

      assert {_, %{status: 503, outcome: :not_sent, reason: :engine_unavailable}} =
               exchange!().stop
    end

    test "an interrupted mutation reports :uncertain and is not retried", %{
      engine: engine,
      context: context
    } do
      task = async_plug(plug_conn("POST", "/v1.45/containers/abc/start"), context)
      socket = EngineFixture.accept(engine)
      EngineFixture.read_request(socket)
      :gen_tcp.close(socket)
      assert Task.await(task).status == 502

      assert {_, %{status: 502, outcome: :uncertain, reason: :upstream_failed}} =
               exchange!().stop

      assert_received {:dialed, _}
      refute_received {:dialed, _}
    end

    test "a response cut after its head reports :backend_closed", %{
      engine: engine,
      context: context
    } do
      task = async_plug(plug_conn("GET", "/v1.45/containers/abc/logs?stdout=1"), context)
      socket = EngineFixture.accept(engine)
      EngineFixture.read_request(socket)

      :gen_tcp.send(
        socket,
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" <>
          "14\r\nsecret-stream-marker\r\n"
      )

      :gen_tcp.close(socket)
      assert {:raised, _} = Task.await(task)

      assert {measurements, %{status: 200, outcome: :sent, reason: :backend_closed}} =
               exchange!().stop

      assert measurements.response_bytes == byte_size("secret-stream-marker")
    end

    test "a caller lost while the engine works reports :caller_closed", %{
      engine: engine,
      context: context
    } do
      client = spawn(fn -> Process.sleep(:infinity) end)

      conn =
        plug_conn("POST", "/v1.45/containers/abc/wait")
        |> Plug.Conn.put_private(:opsmaru_containers_client, client)

      # The Plug process exits when its client goes away, so it is not linked.
      {pid, ref} = spawn_monitor(fn -> serve_plug(conn, context) end)
      socket = EngineFixture.accept(engine)
      EngineFixture.read_request(socket)
      Process.exit(client, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 1_000

      assert {_, %{status: nil, outcome: :uncertain, reason: :caller_closed}} =
               exchange!().stop
    end
  end

  # --- 4.2 Raw -----------------------------------------------------------------

  describe "Raw" do
    test "relay/4 reports the 101 at the head and tunnelled bytes at the end", %{
      engine: engine,
      context: context
    } do
      {client, frontend} = frontend_pair()
      task = Task.async(fn -> relay(context, frontend) end)
      socket = EngineFixture.accept(engine)
      EngineFixture.read_request(socket)
      :gen_tcp.send(socket, EngineFixture.upgraded("tail"))

      recv_until(client, "tail")
      assert_receive {:docker_event, @request, _, %{status: 101}}, 1_000
      refute_received {:docker_event, @stop, _, _}

      :gen_tcp.send(client, "secret-stream-marker")
      {stdin, _} = EngineFixture.read_exactly(socket, "", 20)
      assert stdin == "secret-stream-marker"
      :gen_tcp.send(socket, "out")
      :gen_tcp.shutdown(socket, :write)
      :gen_tcp.shutdown(client, :write)
      assert {"out", :eof} = EngineFixture.read_to_eof(client)
      assert {"", :eof} = EngineFixture.read_to_eof(socket)
      assert Task.await(task) == {:relayed, :ok}

      %{start: {_, start}, stop: {measurements, stop}} = exchange!()
      assert start.adapter == :raw
      assert {stop.mode, stop.route} == {:docker_stream, "/containers/{name:.*}/attach"}
      assert {stop.status, stop.outcome, stop.reason} == {101, :ok, nil}
      assert {measurements.request_bytes, measurements.response_bytes} == {20, 7}
    end

    test "the raw 200 form reports status 200", %{engine: engine, context: context} do
      {client, frontend} = frontend_pair()
      request = attach_request(context, [])
      task = Task.async(fn -> relay(context, frontend, request: request) end)
      socket = EngineFixture.accept(engine)
      EngineFixture.read_request(socket)

      :gen_tcp.send(
        socket,
        "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.docker.raw-stream\r\n\r\nout"
      )

      :gen_tcp.close(socket)
      recv_until(client, "out")
      :gen_tcp.close(client)
      assert {:relayed, _} = Task.await(task)

      %{request: {_, request}, stop: {_, stop}} = exchange!()
      assert request.status == 200
      assert stop.status == 200
    end

    test "open/3 and run/4 report one exchange", %{engine: engine, context: context} do
      {client, frontend} = frontend_pair()

      task =
        Task.async(fn ->
          {:upgrade, response, backend, tail} =
            Raw.open(MarkerHost, attach_request(context),
              admission_deadline: now() + 1_000,
              deadline: now() + 2_000
            )

          :ok = Stream.send(frontend, "HTTP/1.1 101 Switching Protocols\r\n\r\n", now() + 1_000)
          assert response.status == 101

          Raw.run(frontend, backend, tail, deadline: now() + 2_000, request_tail: "early")
        end)

      socket = EngineFixture.accept(engine)
      EngineFixture.read_request(socket)
      :gen_tcp.send(socket, EngineFixture.upgraded())
      {"early", _} = EngineFixture.read_exactly(socket, "", 5)
      :gen_tcp.shutdown(socket, :write)
      :gen_tcp.shutdown(client, :write)
      assert {"", :eof} = EngineFixture.read_to_eof(socket)
      assert Task.await(task) == :ok

      %{stop: {measurements, stop}} = exchange!()
      assert {stop.status, stop.outcome} == {101, :ok}
      assert measurements.request_bytes == 5
      no_more_events()
    end

    test "a stream deadline reports :deadline", %{engine: engine, context: context} do
      {_client, frontend} = frontend_pair()
      task = Task.async(fn -> relay(context, frontend, stream: 300) end)
      socket = EngineFixture.accept(engine)
      EngineFixture.read_request(socket)
      :gen_tcp.send(socket, EngineFixture.upgraded())
      assert Task.await(task) == {:relayed, {:error, :deadline}}

      assert {_, %{status: 101, outcome: :sent, reason: :deadline}} = exchange!().stop
    end

    test "a killed relay reports :killed and the bytes moved", %{
      engine: engine,
      context: context
    } do
      {client, frontend} = frontend_pair()
      test = self()

      owner =
        spawn(fn ->
          send(test, {:result, relay(context, frontend)})
        end)

      socket = EngineFixture.accept(engine)
      EngineFixture.read_request(socket)
      :gen_tcp.send(socket, EngineFixture.upgraded("tail"))
      recv_until(client, "tail")
      Process.exit(owner, :kill)

      assert {measurements, %{status: 101, outcome: :sent, reason: :killed}} =
               exchange!().stop

      assert measurements.response_bytes == 4
    end
  end

  # --- 4.4 Passivity -----------------------------------------------------------

  describe "passivity" do
    test "a raising handler changes no status or body", %{engine: engine, context: context} do
      read = fn ->
        task = async_plug(plug_conn("GET", "/v1.45/containers/json"), context)
        socket = EngineFixture.accept(engine)
        EngineFixture.read_request(socket)
        :gen_tcp.send(socket, json_response(200, "[1]"))
        conn = Task.await(task)
        {conn.status, conn.resp_headers, conn.resp_body}
      end

      baseline = read.()
      exchange!()

      :telemetry.attach_many(
        {__MODULE__, :raising},
        [@start, @request, @stop],
        fn _, _, _, _ -> raise "handler failure" end,
        nil
      )

      assert read.() == baseline
      assert read.() == baseline
    end

    test "a blocked stop handler holds no backend stream", %{engine: engine, context: context} do
      test = self()
      gate = make_ref()

      :telemetry.attach(
        {__MODULE__, :blocking},
        @stop,
        fn _, _, _, _ ->
          send(test, {:blocked, self()})
          receive do: (^gate -> :ok)
        end,
        nil
      )

      {client, frontend} = frontend_pair()
      task = Task.async(fn -> relay(context, frontend) end)
      socket = EngineFixture.accept(engine)
      EngineFixture.read_request(socket)
      :gen_tcp.send(socket, EngineFixture.upgraded())
      :gen_tcp.shutdown(socket, :write)
      :gen_tcp.shutdown(client, :write)

      assert Task.await(task) == {:relayed, :ok}
      assert_receive {:blocked, handler}, 1_000
      # The relay closed the engine side while the handler is still blocked.
      assert {"", :eof} = EngineFixture.read_to_eof(socket)
      assert Process.alive?(handler)
      send(handler, gate)
    end

    test "no event or observer exists when no handler is attached", %{
      engine: engine,
      context: context
    } do
      detach_all()
      task = async_plug(plug_conn("GET", "/v1.45/containers/json"), context)
      socket = EngineFixture.accept(engine)
      EngineFixture.read_request(socket)
      :gen_tcp.send(socket, json_response(200, "[]"))
      assert Task.await(task).status == 200
      no_more_events()
    end
  end

  # --- 4.5 Catalogue -----------------------------------------------------------

  describe "catalogue" do
    test "the documented events and reasons match the emitted catalogue" do
      docs = File.read!("docs/embedding.md")
      [_, section] = String.split(docs, "## Exchange telemetry", parts: 2)
      [section | _] = String.split(section, "\n## ", parts: 2)

      documented_events =
        ~r/`\[(:opsmaru_containers[^\]]*)\]`/
        |> Regex.scan(section, capture: :all_but_first)
        |> Enum.map(fn [event] -> event_list(event) end)
        |> Enum.reject(&(&1 == [:opsmaru_containers, :docker]))
        |> Enum.uniq()
        |> Enum.sort()

      assert documented_events == Enum.sort(TelemetryCapture.events())

      emitted_in_source =
        Path.wildcard("lib/**/*.ex")
        |> Enum.flat_map(fn path ->
          Regex.scan(~r/\[(:opsmaru_containers(?:, :\w+)+)\]/, File.read!(path),
            capture: :all_but_first
          )
        end)
        |> Enum.map(fn [event] -> event_list(event) end)
        |> Enum.reject(&(&1 == [:opsmaru_containers, :docker]))
        |> Enum.uniq()
        |> Enum.sort()

      assert emitted_in_source == documented_events

      # The reason table: one row per reason.
      documented_reasons =
        ~r/^\| `:(\w+)` \|/m
        |> Regex.scan(section, capture: :all_but_first)
        |> Enum.map(fn [name] -> String.to_atom(name) end)

      assert documented_reasons == Exchange.reason_set()
    end

    test "every documented event is emitted for one ordinary request", %{
      engine: engine,
      context: context
    } do
      task = async_plug(plug_conn("GET", "/v1.45/_ping"), context)
      socket = EngineFixture.accept(engine)
      EngineFixture.read_request(socket)
      :gen_tcp.send(socket, json_response(200, "OK"))
      Task.await(task)

      for event <- [@start, @request, @stop] do
        assert_received {:docker_event, ^event, _, _}
      end

      no_more_events()
    end
  end

  defp event_list(text) do
    text
    |> String.split(",")
    |> Enum.map(fn part -> part |> String.trim() |> String.trim_leading(":") end)
    |> Enum.map(&String.to_atom/1)
  end
end
