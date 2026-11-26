defmodule Opsmaru.Containers.TestSupport.CowboyFixture do
  @moduledoc """
  Loopback Cowboy listeners for the Docker Cowboy handler: TLS 1.3 with
  test-generated certificates, or plain TCP. The test owns and stops each
  listener; the library under test never opens one.
  """

  alias Opsmaru.Containers.Docker.CowboyHandler
  alias Opsmaru.Containers.TestSupport.TLSFixture

  defmodule Router do
    @moduledoc false
    # The host's fallback Plug pipeline. It reports every request it serves
    # to the test and echoes what it saw, reading the body itself.
    def call(conn, observer) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      upgrade = Plug.Conn.get_req_header(conn, "upgrade")
      send(observer, {:fallback, conn.method, conn.request_path, body, upgrade})

      Plug.Conn.send_resp(
        conn,
        200,
        "fallback #{conn.method} #{conn.request_path} body=#{body} upgrade=#{Enum.join(upgrade)}"
      )
    end
  end

  @doc "Handler options with the Plug fallback reporting to `observer`."
  def handler_opts(host, context, observer, extra \\ []) do
    Map.merge(
      %{
        host: host,
        host_peer: {context, observer},
        fallback: {Plug.Cowboy.Handler, {Router, observer}}
      },
      Map.new(extra)
    )
  end

  @doc "Start a TLS 1.3 listener. Returns `%{ref, port, identity}`."
  def start_tls(handler_opts, opts \\ []) do
    root = TLSFixture.root()
    identity = TLSFixture.generate(root)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(root) end)

    socket_opts = [
      ip: {127, 0, 0, 1},
      port: 0,
      certfile: String.to_charlist(identity.certfile),
      keyfile: String.to_charlist(identity.keyfile),
      cacerts: TLSFixture.certificates(identity.cafile),
      verify: :verify_peer,
      fail_if_no_peer_cert: false,
      versions: [:"tlsv1.3"],
      alpn_preferred_protocols: Keyword.get(opts, :alpn, ["http/1.1"])
    ]

    ref = {__MODULE__, make_ref()}
    {:ok, _} = :cowboy.start_tls(ref, %{socket_opts: socket_opts}, protocol(handler_opts, opts))
    ExUnit.Callbacks.on_exit(fn -> :cowboy.stop_listener(ref) end)
    %{ref: ref, port: :ranch.get_port(ref), identity: identity, root: root}
  end

  @doc "Start a plain TCP listener. Returns `%{ref, port}`."
  def start_clear(handler_opts, opts \\ []) do
    ref = {__MODULE__, make_ref()}

    {:ok, _} =
      :cowboy.start_clear(
        ref,
        %{socket_opts: [ip: {127, 0, 0, 1}, port: 0]},
        protocol(handler_opts, opts)
      )

    ExUnit.Callbacks.on_exit(fn -> :cowboy.stop_listener(ref) end)
    %{ref: ref, port: :ranch.get_port(ref)}
  end

  defp protocol(handler_opts, opts) do
    handler = Keyword.get(opts, :handler, CowboyHandler)
    dispatch = :cowboy_router.compile([{:_, [{:_, handler, handler_opts}]}])
    %{env: %{dispatch: dispatch}, idle_timeout: 10_000}
  end

  @doc "Connect an OTP TLS 1.3 client, optionally presenting a client certificate."
  def connect_tls(listener, opts \\ []) do
    {:ok, socket} =
      :ssl.connect(
        ~c"localhost",
        listener.port,
        [
          :binary,
          active: false,
          cacerts: TLSFixture.certificates(listener.identity.cafile),
          verify: :verify_peer,
          versions: [:"tlsv1.3"],
          alpn_advertised_protocols: ["http/1.1"]
        ] ++ Keyword.get(opts, :ssl, []),
        5_000
      )

    socket
  end

  def connect_tcp(listener) do
    {:ok, socket} =
      :gen_tcp.connect(
        {127, 0, 0, 1},
        listener.port,
        [:binary, active: false, exit_on_close: false],
        5_000
      )

    socket
  end

  @doc "Read a response head from an `:ssl` or `:gen_tcp` socket; returns `{head, rest}`."
  def recv_head(transport, socket, buffer \\ "") do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, rest] ->
        {head, rest}

      [_] ->
        case transport.recv(socket, 0, 5_000) do
          {:ok, chunk} -> recv_head(transport, socket, buffer <> chunk)
          {:error, reason} -> {:closed, buffer, reason}
        end
    end
  end

  @doc "Read a full Content-Length response; returns `{status, head, body}`."
  def recv_response(transport, socket) do
    {head, rest} = recv_head(transport, socket)
    [status_line | _] = String.split(head, "\r\n")
    [_, status | _] = String.split(status_line, " ")

    length =
      case Regex.run(~r/\r\ncontent-length: *(\d+)/i, head) do
        [_, value] -> String.to_integer(value)
        nil -> byte_size(rest)
      end

    {String.to_integer(status), head, read_body(transport, socket, rest, length)}
  end

  defp read_body(transport, socket, buffer, length) do
    if byte_size(buffer) >= length do
      binary_part(buffer, 0, length)
    else
      {:ok, chunk} = transport.recv(socket, 0, 5_000)
      read_body(transport, socket, buffer <> chunk, length)
    end
  end

  @doc "Read exactly `size` bytes from a client socket."
  def recv_exactly(transport, socket, buffer, size) do
    if byte_size(buffer) >= size do
      <<bytes::binary-size(size), rest::binary>> = buffer
      {bytes, rest}
    else
      {:ok, chunk} = transport.recv(socket, 0, 5_000)
      recv_exactly(transport, socket, buffer <> chunk, size)
    end
  end
end
