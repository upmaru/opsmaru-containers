defmodule Opsmaru.Containers.Docker.PlugTest do
  # Telemetry events are VM-global, so this suite runs serially.
  use ExUnit.Case, async: false

  import Opsmaru.Containers.TestSupport.TelemetryCapture, only: [assert_exchange: 0]

  alias Opsmaru.Containers.TestSupport.TelemetryCapture

  alias Elixir.Plug.{Conn, Test}
  alias Opsmaru.Containers.{Context, Host, Transport}
  alias Opsmaru.Containers.Docker.{Capabilities, Plug}
  alias Opsmaru.Containers.Nested.Target
  alias Opsmaru.Containers.Transport.Stream
  alias Opsmaru.Incus

  @fixture_message_timeout 2_000

  defmodule Policy do
    @moduledoc false
    @behaviour Host

    @impl Host
    def context(%{host_peer: {context, _decision}}), do: {:ok, context}

    @impl Host
    def authorize(_, %{host_peer: {_, {:sleep, milliseconds}}}) do
      Process.sleep(milliseconds)
      :allow
    end

    def authorize(_, %{host_peer: {_, :raise}}), do: raise("private policy error")
    def authorize(_, %{host_peer: {_, decision}}), do: decision

    @impl Host
    def map_bind_source(_context, "/host/shared"), do: {:ok, "/engine/shared"}
    def map_bind_source(_context, _), do: :deny
  end

  defmodule SelectingPolicy do
    @moduledoc false
    @behaviour Host

    # The peer carries the test process, which observes each selection.
    @impl Host
    def context(%{host_peer: {context, _observer}}), do: {:ok, context}

    @impl Host
    def authorize(_, _), do: :allow

    @impl Host
    def select_engine(_context, %{body: %{"Labels" => %{"engine" => choice}}} = request) do
      {_, observer} = request.host_peer
      send(observer, {:selected, request})

      case choice do
        "native" -> :native
        "raise" -> raise "private selection error"
        "late" -> Process.sleep(2_000) && :native
        "other" -> :docker
        _ -> :nested
      end
    end
  end

  defmodule ScriptedEngine do
    @moduledoc false
    @behaviour Transport
    @behaviour Stream

    @impl Transport
    def dial(_target, {observer, response}, _deadline) do
      send(observer, :dialed)
      {response, block_upload?} = plan(response)
      {:ok, connection} = Agent.start_link(fn -> {observer, response, [], block_upload?} end)
      {:ok, %Stream{adapter: __MODULE__, handle: connection}}
    end

    defp plan(:reject_upload), do: {[:await], true}
    defp plan(response), do: {response, false}

    @impl Stream
    def recv(connection, limit, deadline) do
      result =
        Agent.get_and_update(connection, fn
          {observer, {:after_write, expected, response}, sent, blocked} = state ->
            if expected in sent,
              do: {:retry, {observer, response, sent, blocked}},
              else: {:pending, state}

          {observer, [:await | rest], sent, blocked} ->
            {{:await, observer}, {observer, rest, sent, blocked}}

          {observer, [next | rest], sent, blocked} ->
            {{:ok, next}, {observer, rest, sent, blocked}}

          state ->
            {:eof, state}
        end)

      case result do
        :retry -> recv(connection, limit, deadline)
        :pending -> wait_for_write(connection, limit, deadline)
        {:await, observer} -> await_fixture_data(observer, deadline)
        result -> result
      end
    end

    defp wait_for_write(connection, limit, deadline) do
      if deadline > System.monotonic_time(:millisecond) do
        Process.sleep(1)
        recv(connection, limit, deadline)
      else
        {:error, :deadline}
      end
    end

    defp await_fixture_data(observer, deadline) do
      send(observer, {:engine_reading, self()})

      receive do
        {:engine_data, data} -> {:ok, data}
      after
        max(0, deadline - System.monotonic_time(:millisecond)) -> {:error, :deadline}
      end
    end

    @impl Stream
    def send(connection, iodata, deadline) do
      bytes = IO.iodata_to_binary(iodata)

      case Agent.get_and_update(connection, fn {observer, response, sent, blocked} ->
             {{observer, blocked and sent != []}, {observer, response, [bytes | sent], blocked}}
           end) do
        {_, false} ->
          :ok

        {observer, true} ->
          send(observer, {:engine_writing, self()})

          receive do
            :reject_write -> {:error, :closed}
          after
            max(0, deadline - System.monotonic_time(:millisecond)) -> {:error, :deadline}
          end
      end
    end

    @impl Stream
    def shutdown_write(_, _), do: :ok

    @impl Stream
    def close(connection) do
      {observer, _, sent, _} = Agent.get(connection, & &1)
      send(observer, {:wire, IO.iodata_to_binary(Enum.reverse(sent))})
      Agent.stop(connection)
    end
  end

  defmodule CloseRaisingEngine do
    @moduledoc false
    # The scripted engine, except that closing the backend raises: a crash no
    # path of the Plug classifies.
    @behaviour Transport
    @behaviour Stream

    @impl Transport
    def dial(target, options, deadline) do
      {:ok, stream} = ScriptedEngine.dial(target, options, deadline)
      {:ok, %{stream | adapter: __MODULE__}}
    end

    @impl Stream
    defdelegate recv(connection, limit, deadline), to: ScriptedEngine

    @impl Stream
    defdelegate send(connection, iodata, deadline), to: ScriptedEngine

    @impl Stream
    defdelegate shutdown_write(connection, deadline), to: ScriptedEngine

    @impl Stream
    def close(_connection), do: raise("close failed")
  end

  defmodule FailingStreamAdapter do
    @moduledoc false
    # A Plug.Conn.Adapter that accepts the chunked send, then fails the write
    # mid-stream, simulating a client that disconnects while the engine's
    # successful response is being sent.
    def send_chunked(payload, _status, _headers), do: {:ok, nil, payload}
    def chunk(_payload, _body), do: raise("client write failed")
  end

  test "preserves the encoded request target, repeated headers and chunked engine body" do
    response = [
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nApi-Version:\t1.57\r\n",
      "Set-Cookie: name=a\r\nSet-Cookie: name=b\r\nConnection: x-private\r\nX-Private: hidden\r\n\r\n",
      "2\r\nab\r\n3\r\nc",
      "de\r\n0\r\nTrailer-One: value\r\n\r\n"
    ]

    conn = call("GET", "/v1.57/images/registry%2Frepo/json?filters=a%2Fb", engine(response))
    assert %{status: 200, resp_headers: headers, resp_body: "abcde"} = conn
    assert {"api-version", "1.57"} in headers
    assert {"set-cookie", "name=a"} in headers
    assert {"set-cookie", "name=b"} in headers
    refute List.keymember?(headers, "x-private", 0)

    assert_received :dialed

    assert_received {:wire,
                     "GET /v1.57/images/registry%2Frepo/json?filters=a%2Fb HTTP/1.1\r\n" <> _}

    refute_received :dialed
  end

  test "stale capability snapshots and late or raised policy answers never dial" do
    context = engine([])
    stale = put_in(context.capabilities.expires_at, now() - 1)

    assert response(call("GET", "/_ping", stale)) ==
             {503, %{"message" => "Docker engine is not ready"}}

    for decision <- [:deny, :raise, {:sleep, 100}] do
      conn = call("GET", "/_ping", context, "", decision, admission_timeout: 40)
      assert response(conn) == {403, %{"message" => "request denied"}}
    end

    refute_received :dialed
  end

  test "negotiates the engine range without dialing and caps unversioned requests" do
    data = ~s({"ApiVersion":"1.60","MinAPIVersion":"1.45","Os":"linux"})
    context = engine(fixed_response(200, data, [{"api-version", "1.60"}]), "1.45", "1.60")

    for {request, fragment} <- [
          {"/v1.44/version", "Minimum supported API version is 1.45"},
          {"/v1.58/version", "Maximum supported API version is 1.57"}
        ] do
      assert {400, %{"message" => message}} = response(call("GET", request, context))
      assert message =~ fragment
    end

    refute_received :dialed

    conn = call("GET", "/version", context)
    assert [version] = Conn.get_resp_header(conn, "api-version")
    assert version == "1.57"

    assert response(conn) ==
             {200, %{"ApiVersion" => "1.57", "MinAPIVersion" => "1.45", "Os" => "linux"}}

    assert_received {:wire, "GET /v1.57/version HTTP/1.1\r\n" <> _}
  end

  test "distinguishes unknown, unsupported and version-gated routes before dialing" do
    context = engine([])

    assert {404, %{"message" => "page not found"}} = response(call("GET", "/no-route", context))
    assert {501, %{"message" => "/swarm:" <> _}} = response(call("GET", "/swarm", context))

    assert {404, %{"message" => "page not found"}} =
             response(call("GET", "/v1.54/images/demo/attestations", context))

    refute_received :dialed
  end

  test "HEAD ping preserves the negotiated header and sends no body" do
    context = engine(["HTTP/1.1 200 OK\r\nApi-Version: 1.57\r\nContent-Length: 2\r\n\r\n"])
    conn = call("HEAD", "/_ping", context)
    assert %{status: 200, resp_body: ""} = conn
    assert Conn.get_resp_header(conn, "api-version") == ["1.57"]
    assert_received {:wire, "HEAD /_ping HTTP/1.1\r\n" <> _}
  end

  test "maps both container bind forms and preserves ordinary volume bodies" do
    body =
      ~s({"Image":"demo","HostConfig":{"Binds":["/host/shared:/src:ro"],"Mounts":[{"Type":"bind","Source":"/host/shared","Target":"/dest"}]}})

    rewritten = String.replace(body, "/host/shared", "/engine/shared")
    success = fixed_response(201, "{}")
    context = engine({:after_write, rewritten, success})
    options = [stream_timeout: 2_000]

    assert {201, %{}} =
             response(call("POST", "/containers/create", context, body, :allow, options))

    assert_received {:wire, wire}

    assert Jason.decode!(body_of(wire)) == %{
             "Image" => "demo",
             "HostConfig" => %{
               "Binds" => ["/engine/shared:/src:ro"],
               "Mounts" => [
                 %{"Type" => "bind", "Source" => "/engine/shared", "Target" => "/dest"}
               ]
             }
           }

    original = ~s( {"Name":"data", "DriverOpts":{} } )
    context = engine({:after_write, original, success})

    assert {201, %{}} =
             response(call("POST", "/volumes/create", context, original, :allow, options))

    assert_received {:wire, volume_wire}
    assert body_of(volume_wire) == original
  end

  test "refuses denied binds, ambiguous fields and custom volume driver options before dialing" do
    context = engine([])

    for {path, body} <- [
          {"/containers/create", ~s({"HostConfig":{"Binds":["/denied:/work"]}})},
          {"/containers/create", ~s({"HostConfig":{},"hostconfig":{"Binds":["/denied:/work"]}})},
          {"/volumes/create", ~s({"DriverOpts":{"type":"none","o":"bind"}})},
          {"/containers/create",
           ~s({"HostConfig":{"Mounts":[{"Type":"volume","VolumeOptions":{"DriverConfig":{"Options":{"o":"bind"}}}}]}})}
        ] do
      assert {400, %{"message" => _}} = response(call("POST", path, context, body))
    end

    refute_received :dialed
  end

  test "a create the host routes to native is refused without reaching nested" do
    body = ~s({"Image":"demo","Labels":{"engine":"native"}})

    assert {501, %{"message" => "native engine is not available in this release"}} =
             response(select("/containers/create", engine([]), body))

    assert_received {:selected, request}
    assert request.method == "POST"
    assert request.route["path"] == "/containers/create"
    assert request.body == %{"Image" => "demo", "Labels" => %{"engine" => "native"}}
    refute_received :dialed
  end

  test "a nested, failing, late or unknown selection keeps the create in nested" do
    success = fixed_response(201, "{}")

    for choice <- ["nested", "raise", "late", "other"] do
      body = ~s({"Image":"demo","Labels":{"engine":"#{choice}"}})
      context = engine({:after_write, body, success})
      options = [stream_timeout: 2_000, admission_timeout: 200]

      assert {201, %{}} = response(select("/containers/create", context, body, options))
      assert_received {:selected, _}
      assert_received {:wire, wire}
      assert body_of(wire) == body
    end
  end

  test "selection runs only for container creates with a JSON object body" do
    context = engine([])

    assert {400, %{"message" => _}} =
             response(select("/containers/create", context, ~s(["not an object"])))

    refute_received {:selected, _}
    refute_received :dialed
  end

  test "an upstream disconnect after a mutation attempt is reported without replay" do
    body = ~s({"Image":"fixture"})
    conn = call("POST", "/containers/create", engine({:after_write, body, []}), body)
    assert {502, %{"message" => "Docker engine connection failed"}} = response(conn)
    assert_received :dialed
    assert_received {:wire, wire}
    assert wire =~ "POST /containers/create "
    assert body_of(wire) == ~s({"Image":"fixture"})
    refute_received :dialed
  end

  test "streams a large request in chunks and does not replay it" do
    body = :binary.copy(<<42>>, 140_000)
    context = engine({:after_write, "0\r\n\r\n", fixed_response(200, "{}")})
    assert {200, %{}} = response(call("POST", "/images/load", context, body))
    assert_received :dialed
    assert_received {:wire, wire}
    refute_received :dialed
    assert wire =~ "transfer-encoding: chunked\r\n"
    assert body_of(wire) |> count_payload(0) == byte_size(body)
  end

  test "returns Docker's rejection while an upload write is blocked or has failed" do
    for {write_failed?, protocol, connection_header} <- [
          {false, :"HTTP/1.1", ["close"]},
          {true, :"HTTP/2", []}
        ] do
      context = engine(:reject_upload)
      body = :binary.copy("a", 140_000)

      caller =
        Task.async(fn ->
          conn = Test.conn("PUT", "/containers/missing/archive?path=/tmp", body)

          conn =
            if write_failed?,
              do: Conn.put_req_header(conn, "content-length", Integer.to_string(byte_size(body))),
              else: conn

          conn
          |> Test.put_http_protocol(protocol)
          |> Conn.put_private(:opsmaru_containers_peer, {context, :allow})
          |> Plug.call(Plug.init(host: Policy))
        end)

      assert_receive :dialed, @fixture_message_timeout
      assert_receive {:engine_reading, reader}, @fixture_message_timeout
      assert_receive {:engine_writing, writer}, @fixture_message_timeout
      monitor = Process.monitor(writer)

      if write_failed? do
        send(writer, :reject_write)
        assert_receive {:DOWN, ^monitor, :process, ^writer, :normal}, @fixture_message_timeout
      end

      reply = fixed_response(404, ~s({"message":"No such container"}))
      send(reader, {:engine_data, IO.iodata_to_binary(["HTTP/1.1 100 Continue\r\n\r\n", reply])})

      conn = Task.await(caller)
      assert response(conn) == {404, %{"message" => "No such container"}}
      assert Conn.get_resp_header(conn, "connection") == connection_header

      unless write_failed? do
        assert_receive {:DOWN, ^monitor, :process, ^writer, :killed}, @fixture_message_timeout
      end

      assert_receive {:wire, wire}, @fixture_message_timeout
      assert byte_size(body_of(wire)) < byte_size(body)
      refute_received :dialed
    end
  end

  test "a host disconnect interrupts an engine read before or after response commitment" do
    head = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"

    for replies <- [[:await], [head, :await]] do
      context = engine(replies)
      client = spawn(fn -> receive do: (:disconnect -> :ok) end)

      {caller, monitor} =
        spawn_monitor(fn ->
          "GET"
          |> Test.conn("/events")
          |> Conn.put_private(:opsmaru_containers_peer, {context, :allow})
          |> Conn.put_private(:opsmaru_containers_client, client)
          |> Plug.call(Plug.init(host: Policy, stream_timeout: 60_000))
        end)

      assert_receive :dialed, @fixture_message_timeout
      assert_receive {:engine_reading, reader}, @fixture_message_timeout
      reader_monitor = Process.monitor(reader)
      send(client, :disconnect)
      assert_receive {:DOWN, ^monitor, :process, ^caller, :shutdown}, @fixture_message_timeout

      assert_receive {:DOWN, ^reader_monitor, :process, ^reader, :killed},
                     @fixture_message_timeout

      assert_receive {:wire, "GET /events HTTP/1.1\r\n" <> _}, @fixture_message_timeout
    end
  end

  test "a truncated stream aborts the committed response and closes the dial" do
    response = ["HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nab"]
    context = engine(response)

    assert_raise RuntimeError, "Docker upstream response ended before completion", fn ->
      call("GET", "/containers/engine/logs?follow=true", context)
    end

    assert_received {:wire, "GET /containers/engine/logs?follow=true HTTP/1.1\r\n" <> _}
    refute_received {:wire, _}
  end

  test "streams Docker progress, stats and events without changing their records" do
    response = [
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
      "3\r\n{}\n\r\n",
      "3\r\n[]\n\r\n0\r\n\r\n"
    ]

    for {verb, path} <- [
          {"GET", "/events"},
          {"GET", "/containers/engine/stats"},
          {"POST", "/build"},
          {"POST", "/images/create"},
          {"POST", "/images/fixture/push"}
        ] do
      assert %{status: 200, resp_body: "{}\n[]\n"} = call(verb, path, engine(response))
      assert_received {:wire, _}
    end
  end

  test "a failed response write reports the interruption on the stop event" do
    TelemetryCapture.attach()

    response = [
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
      "2\r\nab\r\n",
      "0\r\n\r\n"
    ]

    assert_raise RuntimeError, "client write failed", fn ->
      call_with_failing_adapter("GET", "/events", engine(response))
    end

    assert %{stop: {_, stop}} = assert_exchange()
    assert stop.outcome == :sent
    assert stop.reason == :caller_closed
  end

  test "a crash outside a response write reports :killed, not :caller_closed" do
    TelemetryCapture.attach()
    response = fixed_response(200, "")
    context = %{engine(response) | dialer: {CloseRaisingEngine, {self(), response}}}

    assert_raise RuntimeError, "close failed", fn -> call("GET", "/_ping", context) end

    assert %{stop: {_, stop}} = assert_exchange()
    assert stop.reason == :killed
  end

  test "an ordinary successful request still reports outcome :ok" do
    TelemetryCapture.attach()

    conn = call("GET", "/_ping", engine(fixed_response(200, "")))

    assert %{status: 200} = conn

    assert %{stop: {_, stop}} = assert_exchange()
    assert stop.outcome == :ok
    assert stop.reason == nil
  end

  defp count_payload("0\r\n\r\n", total), do: total

  defp count_payload(chunks, total) do
    [hex_length, data] = :binary.split(chunks, "\r\n")
    length = String.to_integer(hex_length, 16)
    assert length <= 65_536
    <<bytes::binary-size(length), "\r\n", rest::binary>> = data
    assert bytes == :binary.copy(<<42>>, length)
    count_payload(rest, total + length)
  end

  defp call_with_failing_adapter(method, path, context) do
    conn =
      method
      |> Test.conn(path)
      |> Conn.put_private(:opsmaru_containers_peer, {context, :allow})
      |> Map.put(:adapter, {FailingStreamAdapter, %{}})

    Plug.call(conn, Plug.init(host: Policy))
  end

  defp call(method, path, context, body \\ "", decision \\ :allow, options \\ []) do
    method
    |> Test.conn(path, body)
    |> Conn.put_private(:opsmaru_containers_peer, {context, decision})
    |> Plug.call(Plug.init(Keyword.put(options, :host, Policy)))
  end

  defp select(path, context, body, options \\ []) do
    "POST"
    |> Test.conn(path, body)
    |> Conn.put_private(:opsmaru_containers_peer, {context, self()})
    |> Plug.call(Plug.init(Keyword.put(options, :host, SelectingPolicy)))
  end

  defp engine(response, minimum \\ "1.40", maximum \\ "1.57") do
    client = %Incus{
      connection: Incus.Connection.unix!("/unused", owner: :fixture, project: "fixtures"),
      context: Incus.Context.new!(owner: :fixture, identity: :host, ready?: fn -> true end),
      server: nil
    }

    target = %Target{client: client, instance: "engine"}

    %Context{
      identity: :verified_peer,
      dialer: {ScriptedEngine, {self(), response}},
      target: target,
      ready?: true,
      capabilities: %Capabilities{
        target: target,
        minimum: minimum,
        maximum: maximum,
        expires_at: now() + 5_000
      }
    }
  end

  defp fixed_response(status, body, headers \\ []) do
    headers = Enum.map_join(headers, "", fn {name, value} -> "#{name}: #{value}\r\n" end)
    ["HTTP/1.1 #{status} Fixture\r\nContent-Length: #{byte_size(body)}\r\n#{headers}\r\n#{body}"]
  end

  defp response(conn) do
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp body_of(wire) do
    [_, body] = :binary.split(wire, "\r\n\r\n")
    body
  end

  defp now, do: System.monotonic_time(:millisecond)
end
