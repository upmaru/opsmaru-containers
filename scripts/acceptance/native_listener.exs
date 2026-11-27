# Disposable host listener for native-engine acceptance (task 7 of
# add-native-oci-engine). It serves the library from this checkout on two
# owner-private Unix sockets in one directory: `nested.sock`, whose creates
# stay in the nested engine, and `native.sock`, whose creates run as native
# containers. Every other route resolves the owning engine the same way on
# both sockets, so one pinned CLI workflow can run unchanged against each.
#
# Run it only against an isolated Incus project with disposable fixtures:
#
#     OPSMARU_NATIVE_ACCEPTANCE=isolated \
#     OPSMARU_INCUS_URL=https://127.0.0.1:PORT \
#     OPSMARU_INCUS_CONF=/absolute/incus/client/config \
#     OPSMARU_INCUS_REMOTE=REMOTE \
#     OPSMARU_ENGINE_PROJECT=PROJECT OPSMARU_ENGINE_INSTANCE=INSTANCE \
#     OPSMARU_NATIVE_PROJECT=PROJECT \
#     OPSMARU_NATIVE_INIT_ARM64=/absolute/native-init-arm64 \
#     OPSMARU_BIND_SOURCE=/absolute/path/seen/by/both/servers \
#     OPSMARU_LISTENER_DIR=/absolute/private/dir \
#     MIX_ENV=test mise exec -- mix run --no-halt scripts/acceptance/native_listener.exs
#
# The Incus client configuration supplies `client.crt`, `client.key` and
# `servercerts/REMOTE.crt`, whose SHA-256 is pinned. Container binds map
# every client source to OPSMARU_BIND_SOURCE, which must exist in the engine
# instance and on the Incus server. The listener writes one JSON line per
# exchange to `telemetry.jsonl` in the listener directory.

alias Opsmaru.Containers.Context
alias Opsmaru.Containers.Docker.{Capabilities, CowboyHandler}
alias Opsmaru.Containers.Native
alias Opsmaru.Containers.Nested
alias Opsmaru.Containers.Transport.ExecBridge
alias Opsmaru.Incus

defmodule Opsmaru.Containers.Acceptance.NativeHost do
  @moduledoc false
  @behaviour Opsmaru.Containers.Host

  @impl true
  def context(%{host_peer: {context, _engine}}), do: {:ok, context}

  @impl true
  def authorize(_, _), do: :allow

  @impl true
  def select_engine(_, %{host_peer: {_, engine}}), do: engine

  @impl true
  def map_bind_source(_, _source),
    do: {:ok, :persistent_term.get({__MODULE__, :bind_source})}
end

defmodule Opsmaru.Containers.Acceptance.NativeRouter do
  @moduledoc false
  def init(options), do: Opsmaru.Containers.Docker.Plug.init(options)

  def call(conn, {peer, options}) do
    conn
    |> Plug.Conn.put_private(:opsmaru_containers_peer, peer)
    |> Opsmaru.Containers.Docker.Plug.call(options)
  end
end

environment = System.get_env()

unless environment["OPSMARU_NATIVE_ACCEPTANCE"] == "isolated",
  do: raise("Opt in with OPSMARU_NATIVE_ACCEPTANCE=isolated for disposable fixtures")

absolute! = fn key ->
  path = Map.get(environment, key, "")
  unless Path.type(path) == :absolute, do: raise("#{key} must be an absolute path")
  path
end

fetch! = fn key ->
  case Map.get(environment, key, "") do
    "" -> raise "#{key} is required"
    value -> value
  end
end

conf = absolute!.("OPSMARU_INCUS_CONF")
remote = fetch!.("OPSMARU_INCUS_REMOTE")
url = fetch!.("OPSMARU_INCUS_URL")
engine_project = fetch!.("OPSMARU_ENGINE_PROJECT")
native_project = fetch!.("OPSMARU_NATIVE_PROJECT")
instance = fetch!.("OPSMARU_ENGINE_INSTANCE")
shim = absolute!.("OPSMARU_NATIVE_INIT_ARM64")
bind_source = absolute!.("OPSMARU_BIND_SOURCE")
directory = absolute!.("OPSMARU_LISTENER_DIR")

if engine_project == native_project,
  do: raise("The native project must differ from the engine's project")

[{_, der, _}] =
  :public_key.pem_decode(File.read!(Path.join(conf, "servercerts/#{remote}.crt")))

fingerprint = Base.encode16(:crypto.hash(:sha256, der), case: :lower)
identity = Incus.Context.new!(owner: :acceptance, identity: :acceptance, ready?: fn -> true end)

connect = fn project ->
  connection =
    Incus.Connection.https!(url,
      owner: :acceptance,
      project: project,
      timeout: 30_000,
      tls: [
        certfile: Path.join(conf, "client.crt"),
        keyfile: Path.join(conf, "client.key"),
        fingerprint: fingerprint
      ]
    )

  {:ok, client} = Incus.connect(connection, identity)
  client
end

{:ok, native} = Native.Target.new(connect.(native_project), %{"aarch64" => shim})
target = %Nested.Target{client: connect.(engine_project), instance: instance, native: native}

dialer =
  {ExecBridge,
   %{helper: "/usr/local/libexec/opsmaru/exec-socket-bridge", socket: "/var/run/docker.sock"}}

# `Nested.readiness/2` probes only engines that `Nested.ensure/3` created. An
# isolated fixture engine built by hand has no role marker, so ask dockerd
# for its range directly through the same dialer.
probe_version = fn ->
  {module, dial_options} = dialer
  deadline = System.monotonic_time(:millisecond) + 30_000
  {:ok, stream} = module.dial(target, dial_options, deadline)
  :ok = Opsmaru.Containers.Transport.Stream.send(stream, "GET /version HTTP/1.0\r\n\r\n", deadline)
  :ok = Opsmaru.Containers.Transport.Stream.shutdown_write(stream, deadline)

  read = fn read, acc ->
    case Opsmaru.Containers.Transport.Stream.recv(stream, 65_536, deadline) do
      {:ok, bytes} -> read.(read, acc <> bytes)
      _ -> acc
    end
  end

  response = read.(read, "")
  Opsmaru.Containers.Transport.Stream.close(stream)
  [_, body] = :binary.split(response, "\r\n\r\n")
  %{"MinAPIVersion" => minimum, "ApiVersion" => maximum} = Jason.decode!(body)
  %{minimum: minimum, maximum: maximum}
end

request_context = Incus.RequestContext.new!(timeout: 30_000)

%{minimum: minimum, maximum: maximum} =
  case Nested.readiness(target, request_context: request_context, dialer: dialer) do
    {:ok, %{} = range} -> range
    {:error, :foreign_instance} -> probe_version.()
    other -> raise "engine is not ready: #{inspect(other)}"
  end

context = %Context{
  identity: :acceptance,
  target: target,
  dialer: dialer,
  ready?: true,
  capabilities: %Capabilities{
    target: target,
    minimum: minimum,
    maximum: maximum,
    expires_at: System.monotonic_time(:millisecond) + 86_400_000
  }
}

:persistent_term.put({Opsmaru.Containers.Acceptance.NativeHost, :bind_source}, bind_source)

File.mkdir_p!(directory)
File.chmod!(directory, 0o700)
telemetry = Path.join(directory, "telemetry.jsonl")

:telemetry.attach(
  "native-acceptance",
  [:opsmaru_containers, :docker, :exchange, :stop],
  fn _, measurements, metadata, path ->
    line =
      metadata
      |> Map.take([:adapter, :method, :route, :status, :outcome, :reason])
      |> Map.merge(Map.take(measurements, [:duration, :request_bytes, :response_bytes]))
      |> Map.update(:duration, 0, &System.convert_time_unit(&1, :native, :millisecond))
      |> Map.new(fn {key, value} -> {key, if(is_atom(value), do: to_string(value), else: value)} end)

    File.write!(path, [Jason.encode!(line), ?\n], [:append])
  end,
  telemetry
)

options = [host: Opsmaru.Containers.Acceptance.NativeHost, admission_timeout: 5_000]

for engine <- [:nested, :native] do
  path = Path.join(directory, "#{engine}.sock")
  File.rm(path)
  peer = {context, engine}

  handler = %{
    host: Opsmaru.Containers.Acceptance.NativeHost,
    host_peer: peer,
    fallback:
      {Plug.Cowboy.Handler,
       {Opsmaru.Containers.Acceptance.NativeRouter,
        {peer, Opsmaru.Containers.Acceptance.NativeRouter.init(options)}}}
  }

  dispatch = :cowboy_router.compile([{:_, [{:_, CowboyHandler, handler}]}])

  {:ok, _} =
    :cowboy.start_clear(
      {:native_acceptance, engine},
      %{socket_opts: [ip: {:local, String.to_charlist(path)}, port: 0]},
      %{env: %{dispatch: dispatch}, idle_timeout: 600_000}
    )

  File.chmod!(path, 0o600)
  IO.puts("listening #{engine} #{path}")
end

IO.puts("engine API #{minimum}..#{maximum}")
