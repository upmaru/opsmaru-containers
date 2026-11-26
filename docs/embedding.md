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
forwards EOF to the engine at once. OTP then fails later server writes on
that connection, so output the engine sends after client EOF is lost, and
the exchange ends with `reason: :caller_closed`. Whether the pinned Docker
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

## Scope

The reference tracks Docker Engine and CLI 29.10.0, Buildx 0.39.1 with the
Docker driver, and Compose 5.8.0. See the route inventory and evidence ledger
under `priv/docker` for supported routes and recorded checks. The ledger
distinguishes scripted fixtures, real-engine differential checks, real-Incus
acceptance and consumer acceptance.

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
