# Embedding the Docker Engine API

The host owns the listener, authenticated peer, Incus connection, readiness
and path mapping. Starting the library does not mount an endpoint.

## Provision and publish readiness

Supply a connected `Opsmaru.Incus` client scoped to an explicit project and
an instance name in `Opsmaru.Containers.Nested.Target`. The client remains
host-owned. `Opsmaru.Containers.Nested.ensure/3` accepts the target, a
`Nested.Spec` naming a prepared Docker image, and options containing a bounded
`Opsmaru.Incus.RequestContext` and a host dialer. The host serializes
lifecycle calls for each backend, project and instance. Reconcile uncertain
create and start outcomes before making another lifecycle mutation.

`ensure/3` returns the engine's observed minimum and maximum API versions.
Use `Nested.readiness/2` for a fresh observation of a running instance. The
host publishes those values in `Docker.Capabilities` bound to the same
target and a monotonic expiry in milliseconds, and supplies the snapshot
with a ready `Opsmaru.Containers.Context`. Admission consumes that snapshot
locally.

Implement `Opsmaru.Containers.Transport` to open an independent connection
to dockerd on the host's private transport. Its `Transport.Stream` adapter
supports one concurrent reader and writer, independent write EOF, bounded
reads and explicit closure. The owner of the request defines the lifetime of
that connection. The packaged Incus exec transport is described under
[Reach dockerd through Incus exec](#reach-dockerd-through-incus-exec).

## Mount ordinary HTTP and raw streams

Implement `Opsmaru.Containers.Host`. Its callbacks resolve the verified
identity and target, authorize the classified request and optionally map
bind paths. Keep these callbacks local and bounded. This policy covers
access to one Docker engine trust domain.

For ordinary HTTP, explicitly include Plug in the host, then mount
`Opsmaru.Containers.Docker.Plug` with `host: YourPolicy`. The host may pass
verified listener data in `conn.private[:opsmaru_containers_peer]`. The
library's Plug path also handles detached exec.

To cancel pending engine I/O on disconnect, put a separate host-owned PID in
`conn.private[:opsmaru_containers_client]` before invoking the Plug. The PID
must exit when the client disconnects. For a multiplexed listener, use a PID
that tracks the individual request stream so a stream reset cancels its relay.

The relay reads engine responses while forwarding uploads. An early final
response stops further writes and closes an HTTP/1.x client connection if its
request body remains unread. If the Plug adapter is currently reading the
client body, the relay can act on the engine response once that read returns.

For attaches, attached exec, and requests upgrading to WebSocket or h2c, the
host's HTTP/1.1 listener hands off its stream to
`Opsmaru.Containers.Docker.Raw.relay/4`. Pass the parsed method, origin-form
path, query, lowercase headers, bounded request body and any already-read
connection bytes. The adapter keeps the listener outside the library and
gives the relay ownership of the connection after a valid upstream
handshake. A returned `{:http, status, headers, body}` is an ordinary HTTP
response for the host to send. A returned `{:relayed, result}` means the
relay owned and closed both streams. The host chooses the listeners and
transport adapters for these handoff semantics.

### Split raw entry

`Raw.relay/4` is built from two functions. Use them directly when the
listener must write the frontend handshake itself:

- `Raw.open/3` admits the request, dials the transport and completes the
  upstream handshake. It returns `{:upgrade, response, backend, tail}`.
  `response` carries the normalized status (an engine `101` or the ordinary
  `200` form), the protocol and the headers. The `api-version` response
  header is capped at the context's maximum. `tail` holds engine bytes read
  past the head. The backend is returned open and owned by the caller. Any
  other result is `{:http, status, headers, body}`, with the backend already
  closed.
- `Raw.run/4` relays both streams in the caller's process. It delivers the
  response tail and the request tail exactly once, before later bytes. It
  then relays with independent write EOF in both directions. It writes no
  response head and always closes both streams. It returns `:ok` when both
  directions end cleanly, `{:error, :deadline}` when the stream deadline
  passes, and `{:error, :stream_failed}` for any other stream failure.

`Raw.relay/4` is `open/3`, then the response head, then `run/4`. It produces
the same bytes and closes both streams.

`open/3` and `run/4` must run in the same process, and that process must
outlive the exchange. One process owns the admission check, the backend
dial, the upstream handshake and the stream relay. Transport adapters may
tie resources to the dialing process. For example, the exec bridge keeps
its keepalive and output buffer with that process. Moving a backend between
processes is not supported.

## Serve Docker on a Cowboy listener

A host with a Cowboy listener can serve Docker raw streams on the same
listener with `Opsmaru.Containers.Docker.CowboyHandler`. It needs `:cowboy`
and, for the usual fallback, `:plug_cowboy` in the host. Both are optional
dependencies of this library. Mount the handler for the Docker routes with
`host:` and a `fallback:` that serves everything else, normally
`{Plug.Cowboy.Handler, {YourRouter, opts}}` with `Docker.Plug` mounted in the
router. The handler opens no listener and starts no process before a
request.

- **Fallback:** ordinary Docker routes, detached exec and foreign upgrades
  reach the fallback with their bodies unread.
- **Missing upgrade:** a raw-stream route without an `Upgrade` header, or
  sent over HTTP/2, gets a Docker-shaped 400. Cowboy cannot write Docker's
  hijacked HTTP 200, and `switch_protocol` exists only on HTTP/1.1.
- **Upgrade:** a raw-stream route with an `Upgrade` header runs policy,
  admission, the dial and the upstream handshake in one relay process. The
  handler then hands the connection to that relay through Cowboy's
  `switch_protocol` and `Docker.CowboyTunnel`. Bytes Cowboy had already
  buffered reach the engine first. The connection never returns to Cowboy's
  parser.
- **Status line:** Cowboy writes `HTTP/1.1 101 Switching Protocols`, while
  dockerd writes `101 UPGRADED`. The headers are identical. Docker clients
  check the status code only.

The 101 is sent only after the engine accepted the upgrade. If the handler
process dies first, or Cowboy does not take over within `:handoff_timeout`,
the relay closes the backend. The upstream request may already have been
accepted, so it is never retried.

### TLS half-close

On TLS the relay owns the socket through `Transport.CowboyStream`. Engine
EOF is sent to the client as TLS `close_notify`, and the client can keep
writing afterwards. When the client sends `close_notify` first, the relay
forwards EOF to the engine at once. OTP does not deliver later server
writes on that connection, though it can still accept some of them. The
relay therefore writes nothing to a TLS connection after the client's
`close_notify`. Output the engine sends after client EOF is lost, and the
exchange ends with `reason: :caller_closed`, never as a silent success. Whether the pinned Docker
CLI half-closes its hijacked TLS connection with `close_notify` or with a
TCP write shutdown beneath TLS is still being measured (task 2.5 of
`add-cowboy-gateway-embedding`). Until then, treat `docker exec -i` with
redirected stdin and `docker attach` over TLS as affected. Plain TCP keeps
the opposite direction open in both orders.

## Reach dockerd through Incus exec

`Opsmaru.Containers.Transport.ExecBridge` reaches dockerd through a
non-interactive Incus exec of a small guest helper. It uses the Incus
connection in the context's target and nothing else. The library never
selects it. A host opts in by returning it as the dialer:

```elixir
%Opsmaru.Containers.Context{
  # ...
  dialer:
    {Opsmaru.Containers.Transport.ExecBridge,
     %{
       helper: "/usr/local/libexec/opsmaru/exec-socket-bridge",
       socket: "/var/run/docker.sock"
     }}
}
```

Build the helper from `priv/exec_bridge` with the recipe and digests in its
[README](../priv/exec_bridge/README.md), and install it in the engine image.
No binary ships in the package. `mise run check:bridge` vets and tests the
helper and checks that its builds are reproducible.

Options are validated before any exec is created. Invalid options fail the
dial, so the request gets Docker's 503 "Docker engine is not ready".

- **`:limits`:** caps input and output bytes per connection. The caps
  default to, and never exceed, the Incus connection's `max_stream_bytes`.
  Exceeding a limit fails the stream. Bytes are never truncated.
- **`:keepalive_interval`:** turns on WebSocket pings for long, quiet
  streams.
- **`:observer`:** receives helper stderr and channel failures, never
  payload bytes.
- **`:request_context`:** normally leave this unset. The bridge then uses
  the target's client as supplied, and the relay's stream deadline bounds
  the stream. An `Opsmaru.Incus.RequestContext` is capped at one hour and
  is cancelled when its owner exits. A context built inside `Host.context/1`
  would be owned by that callback's short-lived process. Pass one only when
  its owner outlives the stream and an hour is long enough.

Closing a stream signals a running helper with SIGTERM and waits up to
three seconds. It never sends an Incus DELETE and never retries.

The bridge qualified on 2026-11-25 with Incus 7.0.1, opsmaru_incus 0.2.10,
Docker Engine 29.10.0 and arm64. See the
[live acceptance report](docker-live-acceptance.md). That run used the
acceptance copy of the dialer. The packaged module is covered by
scripted-session fixtures and has not been rerun against real Incus. An
intermittent stdin WebSocket write stall seen on earlier stacks is still
open. Treat a stalled upload as a failed mutation that may have been
partially applied. The relay answers with a Docker-shaped 502 and never
replays it.

## Exchange telemetry

The library emits optional `:telemetry` events for every request that
reaches `Docker.Plug`, `Raw.relay/4`, `Raw.open/3` or
`Docker.CowboyHandler`. Add `{:telemetry, "~> 1.3"}` to the host to receive
them. Without `:telemetry`, or with no handler attached to the
`[:opsmaru_containers, :docker]` prefix, no event is built and no process
starts. The library attaches no handler, writes no log and defines no
metrics. No decision, deadline or wire byte depends on a handler.

| Event | Measurements | Emitted |
| --- | --- | --- |
| `[:opsmaru_containers, :docker, :exchange, :start]` | `system_time`, `monotonic_time` | once, before admission, in the adapter process: the Plug request process, the Cowboy handler process, or the `Raw.relay/4` or `Raw.open/3` caller |
| `[:opsmaru_containers, :docker, :request]` | `duration` from start to head | at most once, when the response head is committed (a 101, the raw 200 form or an HTTP status) or the request is refused, from the exchange observer |
| `[:opsmaru_containers, :docker, :exchange, :stop]` | `duration`, `request_bytes`, `response_bytes` | exactly once, when the exchange ends, from the exchange observer |

Use the request event to write an access-log line when a long stream such as
attach, events or logs starts, rather than hours later at the stop. The
observer monitors the process that owns the exchange: the Plug process, the
`Raw` caller, or the Cowboy relay after the handler hands over. An owner
that is killed still gets its stop event. `start` handlers run in the
adapter process, so keep them short. `request` and `stop` handlers run in
the observer, which holds no socket. A handler that raises is detached by
`:telemetry` and changes nothing on the wire.

Byte counts cover body bytes for ordinary HTTP and tunnelled bytes for raw
streams, counted when read from or written to the frontend. Heads, chunk
framing and exec bridge framing are not counted.

All events carry the same metadata keys, and every key is always present:

| Key | Value |
| --- | --- |
| `telemetry_span_context` | a reference shared by the events of one exchange |
| `adapter` | `:plug`, `:raw` or `:cowboy` |
| `host` | the host policy module |
| `mode` | `:http`, `:docker_stream`, `:h2c_upgrade` or `:websocket` once admission accepted the target, else `nil` |
| `method` | `"GET"`, `"HEAD"`, `"POST"`, `"PUT"` or `"DELETE"`, else `nil` |
| `route` | the matched route template from `priv/docker/routes.json` once admission accepted the target, else `nil` |
| `path` | the original encoded path once admission accepted the target, at most 8,192 bytes, else `nil` |
| `api_version` | the `X.Y` the path requests once admission accepted the target, else `nil` |
| `peer_address` | the IP address tuple the adapter knows (Plug `remote_ip`, Cowboy peer), else `nil` |
| `peer_port` | the Cowboy peer port, else `nil` |
| `peer_fingerprint` | the lowercase hex SHA-256 of a client certificate presented to Cowboy, else `nil`. It names a certificate, not a trusted identity. |
| `status` | on `request` and `stop`: the status sent to the caller, or `nil` if none was sent |
| `outcome` | on `stop`: `:ok`, or what the engine may have seen: `:not_sent`, `:uncertain` or `:sent` |
| `reason` | on `stop`: `nil` when the outcome is `:ok`, else one reason below |

`start` reports `nil` for `mode`, `route`, `path`, `api_version`, `status`,
`outcome` and `reason`. A request the engine answered with its own error
status, such as a 404 for a missing container, still ends `:ok`. An
interrupted mutation reports `:uncertain` or `:sent` and is never retried.

| Reason | Meaning |
| --- | --- |
| `:invalid_request` | a malformed request, body, framing or stream handshake |
| `:not_found` | no route matches |
| `:denied` | the host policy refused the request |
| `:unsupported` | a route outside the relay profile, or a stream sent to an adapter that cannot take it over |
| `:version` | an invalid or out-of-range API version |
| `:not_ready` | the host context is not ready |
| `:too_large` | a checked request body over 1 MiB |
| `:engine_unavailable` | the transport dial failed |
| `:upstream_failed` | the engine failed before a usable response head |
| `:caller_closed` | the client went away, or a frontend write failed |
| `:backend_closed` | the engine stream failed after the head |
| `:deadline` | a stream deadline passed |
| `:handoff_timeout` | Cowboy did not take over the connection in time |
| `:killed` | the owning process exited without finishing |

Events never carry:

- the query string, which may hold build arguments and filters;
- any header, including `authorization` and `x-registry-auth`;
- request or response bodies, or stream bytes;
- the host identity or `Context`, or the Incus client or target;
- bind sources or mapped paths;
- error messages;
- a path admission refused.

## Route containers to the native engine

A host can run selected containers as Incus OCI application containers in a
project of its own, instead of inside dockerd. They are full Incus
instances, so Incus tooling, quotas and placement see them. Create, start,
stop, kill, restart, pause, unpause, rename, remove, inspect, wait, logs,
output-only attach and exec are served for them, and listing and prune
cover both engines. Attach and attached exec need the raw handoff, as they
do for nested containers; the library serves them from a stream of its own,
so the host's listener code is unchanged. Hosts that never opt in keep
today's behaviour exactly, and no Incus call is made for routing.

### Opt in

- **Target:** build `Opsmaru.Containers.Native.Target.new/2` from a client
  for the native project and a map of guest architecture to shim binary
  path, such as `%{"aarch64" => "/path/to/native-init-arm64"}`. Put it in
  the nested target's `native` field, and build the capabilities snapshot
  with that same target. The native project must differ from the engine's
  project and share its Incus owner and identity.
- **Choice:** implement the optional `select_engine/2` callback and return
  `:native` for the creates you want native. Call
  `Opsmaru.Containers.Native.eligibility/1` on the decoded body to choose
  native only when it can run there. A body the native engine cannot honour
  is refused with a 400 naming each field, never sent to nested instead.
- **Binds:** native bind sources go through `map_bind_source/2`, then become
  Incus disk devices of the native instance. Return the source path as the
  native project's Incus server sees it. Without the callback, native
  creates with binds are refused. Inspect reports the mapped source, as
  dockerd reports the source the nested bind policy rewrote.
- **Routing:** with a native target, each container and exec route lists the
  native project once to find the engine that owns the reference.
- **Serialize creates and renames:** names are unique across engines. Each
  engine checks the other before it creates or renames, so serialize
  container creates and renames per target, as you serialize engine lifecycle
  calls. Two hosts sharing a target need the same serialization.

### Build and pass the shim

Every native container runs the library's init shim as its entrypoint. The
package ships its source only, in `priv/native_init`, and no binary is built
at compile time. Build it for each guest architecture you run with the
recipe in [`priv/native_init/README.md`](../priv/native_init/README.md).
The build is reproducible: `Native.Target.new/2` refuses a binary whose
SHA-256 is not the one the library lists for that architecture, and the
README's digests come from `mise run check:init`. A create for an image
architecture without a shim is refused before any instance is made. The
library pushes the shim and the process spec into each new instance before
its first start.

### Prepare the engine and the native project

- **Engine image:** a native container's image is copied out of dockerd
  with `skopeo`, unpacked with `umoci` inside the engine instance, and
  uploaded to the native project. The engine image needs both tools.
- **Incus:** the server needs the `instance_oci` API extension. The
  acceptance run used Incus 7.0.1.
- **Root size:** the library sets none, so the native project's default
  profile chooses it. On a ZFS pool with `volume.zfs.reserve_space=true`,
  each instance reserves its full root size up front, and the default
  2 GiB lets about a dozen containers exhaust a 30 GiB pool. Give the
  project a small root size (the acceptance run used 256 MiB) or a
  different pool policy.
- **Network:** `bridge` and the default network mode use the project
  profile's `eth0`. `--network none` replaces it with no network.

### Translation, refusals and differences

`priv/docker/native-create.json` classifies every create field of the
pinned API as `translated`, `ignored` or `refused`, with a reason; `mix
docker.reference --check` fails when it drifts from the API description. In
brief:

- **Translated:** image, entrypoint and command, environment, working
  directory, user and group additions, hostname, stop signal and timeout,
  labels, bind mounts, memory, CPU (`--cpus`, quota and period, cpuset),
  PIDs limit, DNS, the `bridge`, default and `none` network modes, the log
  driver (`local`, `json-file` or `none`, with size and file count),
  auto-remove, and restart policy `no`.
- **Ignored:** `Init` (native containers always run under an init) and
  `ExposedPorts` (image metadata; nothing is published).
- **Refused, for now or by design:** a TTY and stdin for the main process
  (`-t`, `-i`), port publishing, networks other than the three above,
  volumes (named, anonymous and `--volumes-from`), tmpfs mounts, a create
  health check, `--privileged`, capabilities, devices, security options,
  namespace sharing, extra hosts, a read-only root, links, restart policies
  other than `no`, and limits Incus has no exact key for (CPU shares, block
  I/O, swap, ulimits, sysctls, `--shm-size`).

Routes refused for native containers, with a 501 naming the native engine:
`docker cp`, `export`, `diff`, `top`, `stats`, `update`, main-process TTY
resize and websocket attach. Stdin attach and attach with `logs=1` get the
same 501, and logs with `details` a 400.

Recorded differences from a Docker container:

- **Exit status and logs are written by the container.** The shim records
  each run's exit status and writes stdout and stderr inside the
  container's root filesystem, under `/.opsmaru`, which only root can read.
  The library parses them as untrusted, bounded input, but the container's
  own root user can falsify or delete them; dockerd keeps the same data
  outside the container. Logs use the container's disk, bounded by the log
  driver's rotation.
- **Forced stops:** a stop that Incus forces (a stop past its timeout plus
  10 s, or a kill the shim cannot deliver) leaves no exit record. The
  container then reports exit 137 with `State.Error` set to
  `native: exit status not recorded`.
- **Init:** the Docker process is not PID 1, so it behaves as under
  `docker run --init`: a process with no SIGTERM handler exits on `docker
  stop` with 143, where a Docker PID 1 would ignore it and be killed with
  137 after the timeout.
- **Hostname files:** the kernel hostname is set, but `/etc/hostname` and
  `/etc/hosts` are the image's or Incus's, not Docker's generated files.
- **Image health checks, image volumes and `/dev/shm`:** a `HEALTHCHECK` is
  not run, `VOLUME` paths stay in the root filesystem, and `/dev/shm` is
  Incus's rather than Docker's 64 MiB tmpfs.
- **Generated names:** a create without a name gets its instance name (`oc-`
  and 12 hex characters), not an `adjective_surname` name.
- **Listing:** native entries carry no `SizeRw` or `SizeRootFs`, `ancestor`
  filters match image IDs without descendant images, and prune's
  `SpaceReclaimed` counts only the nested engine.

### Images, auto-remove and deadlines

- **Double image storage:** each image a native container uses is stored
  twice, in dockerd and as an Incus image in the native project, copied
  once per image ID. The first native run of a large image takes tens of
  seconds (500 MB took about 31 s in the qualification spike). Removing an
  image from dockerd does not remove its Incus copy. Call
  `Opsmaru.Containers.Native.prune_images/2` on your own schedule to
  delete copies that no instance uses.
- **Auto-remove:** `docker run --rm` removes its container when the CLI's
  wait answers. A client that disconnects first leaves the stopped
  instance. Call `Opsmaru.Containers.Native.reap/2` on your own schedule to
  delete those.
- **Wait and stop deadlines:** native wait, stop and restart run within the
  Plug's `:stream_timeout`, as relayed requests do.

### Keep Compose nested

Compose projects need what the native engine refuses: a project network,
named volumes, published ports and often a TTY or stdin. Route them to
nested, for example by returning `:nested` from `select_engine/2` for any
create that carries the `com.docker.compose.project` label. A Compose
project split across engines would also lose its shared network.

### Native acceptance

The native differential runs one pinned CLI workflow against a nested and a
native container from the same image, and compares exit codes, output,
inspect fields, mounts and limits. It normalises only volatile IDs,
generated names and its own run tag. It needs a listener that serves the
library on two Unix sockets in one directory, `nested.sock` and
`native.sock`, which differ only in the engine chosen at create.
`scripts/acceptance/native_listener.exs` is such a listener. Run both only
against an isolated Incus project with disposable fixtures; see each
script's header for its variables.

```sh
OPSMARU_DOCKER_ACCEPTANCE=isolated \
OPSMARU_DOCKER_CLI=/absolute/docker \
OPSMARU_NESTED_SOCKET=/absolute/nested.sock \
OPSMARU_NATIVE_SOCKET=/absolute/native.sock \
OPSMARU_DOCKER_TEST_IMAGE=alpine:3.22 \
mise exec -- node test/acceptance/native_differential.mjs
```

The image must already be in the nested engine. The recorded run and its
results are in [the native acceptance report](native-oci-acceptance.md).

## Scope

The reference tracks Docker Engine and CLI 29.10.0, Buildx 0.39.1 with the
Docker driver, and Compose 5.8.0. See the route inventory and evidence ledger
under `priv/docker` for supported routes and recorded checks. The ledger
distinguishes scripted fixtures, real-engine differential checks, real-Incus
acceptance and consumer acceptance. Routes that serve native containers keep
native evidence in a separate `native` object, so nested passthrough
evidence never counts for native containers.

Container bind mounts require a host path mapping. Custom volume-driver
options are refused, including named volumes with local-driver bind
options. Host port forwarding belongs to the consumer. Swarm, daemon plugin
management and diagnostics are excluded from the relay profile.

## Live differential checks

The read-only differential harness expects separately supplied Unix socket
paths to direct and relayed access to pinned Docker 29.10.0 with equivalent
initial state. Run it only against an isolated project with private
connections and disposable fixtures.

```sh
OPSMARU_DOCKER_ACCEPTANCE=isolated \
OPSMARU_DOCKER_DIRECT_SOCKET=/path/to/direct.sock \
OPSMARU_DOCKER_RELAY_SOCKET=/path/to/relay.sock \
mise exec -- node test/acceptance/docker_differential.mjs
```

The harness checks version, ping, and container, image, volume and network
list responses. IDs and configured objects must match across the two views.
Mutation, streaming and CLI acceptance require their own fixtures and
evidence.

Run the CLI acceptance harness against a disposable relay target with the
same opt-in. Supply the absolute Docker CLI path in `OPSMARU_DOCKER_CLI`,
the pinned Buildx and Compose directory in `OPSMARU_DOCKER_PLUGIN_DIR`,
the listener in `OPSMARU_DOCKER_RELAY_SOCKET`, and a shell-capable public
fixture image by digest in `OPSMARU_DOCKER_TEST_IMAGE`. Run
`mise exec -- sh test/acceptance/docker_cli.sh`. The harness uses a fresh
Docker CLI configuration and run-scoped container and image names.
