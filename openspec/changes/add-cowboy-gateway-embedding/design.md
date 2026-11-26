# Design

## Context

See [proposal.md](proposal.md). This is the planned Macus gateway chain. Only the handler marked "this change" is new:

```
docker CLI ── TLS 1.3 ──▶ Cowboy listener (host-owned: TLS, trust, enrollment)
                           │
                           ▼
          Opsmaru.Incus.Gateway.CowboyHandler     SFTP/NBD raw upgrades
                           │ fallback
                           ▼
          Opsmaru.Containers.Docker.CowboyHandler Docker raw upgrades (this change)
                           │ fallback
                           ▼
          Plug.Cowboy.Handler ──▶ host router ──▶ Opsmaru.Containers.Docker.Plug
```

The 0.1.0 raw path, `Raw.relay/4`, assumes the host already owns its frontend stream. It admits the request, dials, completes the upstream handshake, writes the engine's response head and relays. Cowboy reverses that order. The handler must decide on the 101 headers and cast `{:switch_protocol, headers, Module, state}`. Cowboy then writes the 101 and calls `Module.takeover/7` in the connection process. The handler's own request process has already returned by then.

`opsmaru_incus` already solves the same problem for SFTP/NBD: `Gateway.CowboyHandler`, `RawRelay` and `RawTunnel`. This design follows that pattern. One relay actor owns the backend from the dial through the end of the tunnel. `takeover/7` hands it the client socket and Cowboy's buffer, and the handler never returns to Cowboy's HTTP parser.

## Goals / Non-Goals

**Goals:**

- Docker attach, attached exec, BuildKit `h2c` sessions and WebSocket attach work on a host's existing Cowboy listener, chained with other handlers.
- `Raw.relay/4` keeps its contract.
- The qualified exec bridge ships in the Hex package with its helper source, as an explicit opt-in.
- A host can build a Docker access log from library events alone.

**Non-Goals:**

- Owning a listener, TLS, trust or enrollment.
- Docker's raw HTTP 200 hijack on Cowboy.
- HTTP/2 raw streams.
- A default transport.
- Native engine routes.
- Macus code or Macus acceptance.

## Decisions

### 1. Split the raw entry into `open/3` and `run/4`

```elixir
@spec open(module(), map(), keyword()) ::
        {:upgrade, Raw.response(), Stream.t(), binary()}
        | {:http, pos_integer(), [{binary(), binary()}], binary()}

@spec run(Stream.t(), Stream.t(), binary(), keyword()) ::
        :ok | {:error, :stream_failed | :deadline}
```

`open(host, request, options)` takes the same request map and options as `relay/4`: `:admission_deadline`, `:deadline`, and optionally `:exchange`. It does not take `:request_tail`. It runs admission, protocol validation, the dial and the upstream request, and reads the engine's response head.

- **Raw response.** On a raw handshake it returns `{:upgrade, response, backend, tail}`:
  - `response` is `%{status: 101 | 200, protocol: "tcp" | "h2c" | "websocket" | nil, headers: headers}`. `headers` is exactly the header list `relay/4` writes today: end-to-end engine headers, `api-version` capped to the effective maximum, and `connection`/`upgrade` for the protocol.
  - `tail` is the engine bytes already read past the head.
- **Ordinary response.** Any other result is `{:http, status, headers, body}`, as today. That covers rejections, an engine answering with an ordinary response, and engine failure. The backend is already closed.

`run(frontend, backend, response_tail, options)` takes `:deadline`, `:request_tail` and optionally `:exchange`. It delivers `response_tail` to the frontend and `request_tail` (bytes the frontend read past the request) to the backend, then relays both directions with the existing `RawTunnel` semantics. It writes no response head and always closes both streams.

`relay/4` becomes `open/3`, then a write of `HTTP.raw_head` (unchanged bytes) on the host's stream, then `run/4`. Its return values and wire bytes stay as they are, and the existing raw fixtures guard that.

**Ownership contract.** `open` and `run` for the same exchange MUST run in the same process. That process, the relay owner, must outlive the exchange. `Transport.Stream` adapters may tie resources to the process that dialed: the exec bridge links an `Agent` and owns the Incus session. Moving a backend between processes would add an ownership-transfer callback to every adapter, which is a larger contract change than this release needs.

**Arity.** The brief named `open/4`. `open` has no frontend argument, so it is `/3`. `run/4` matches the brief.

*Alternative considered:* a single `relay`-style call with a `:write_head` callback. It cannot serve Cowboy. The 101 is written by Cowboy's connection process only after the handler process has returned, so no callback inside one call can wait for it.

### 2. `Docker.CowboyHandler`: dispatch, relay actor, takeover

The handler is compiled only when `:cowboy_req` is loaded. It is mounted as a Cowboy handler with:

```elixir
%{
  host: HostPolicy,                     # Opsmaru.Containers.Host implementation
  fallback: {Plug.Cowboy.Handler, opts},
  admission_timeout: 1_000,             # optional, ms
  stream_timeout: 86_400_000,           # optional, ms: lifetime of one raw exchange
  handoff_timeout: 5_000                # optional, ms: 101 cast to takeover
}
```

**Dispatch.** A request is taken as a Docker raw attempt only when its path, with any `/vX.Y` prefix stripped, matches one of the route-table entries whose `takeover` is `docker_stream`, `h2c_upgrade` or `websocket`. Matching uses `Route.match/2` against the pinned table, so no second list of paths exists. Requests are classified as follows:

- **No match.** Everything else, including detached exec and every ordinary route, goes to `fallback` untouched. Fallback results are wrapped exactly as `Opsmaru.Incus.Gateway.CowboyHandler` wraps them, so `upgrade/4,5` and `terminate/3` delegate.
- **WebSocket upgrades on other paths.** These also go to `fallback`. A host's own LiveView or Incus WebSocket routes are therefore unaffected.
- **Matched route, `upgrade` header present.** The handler takes the request. The host policy and `Admission` run first, before any dial, through `Raw.open/3`.
- **Exec start without an `upgrade` header.** `POST /exec/{id}/start` goes to `fallback` untouched. Detached exec (`{"Detach": true}`) is sent without an upgrade, and the Plug already serves it. The Plug refuses attached exec without an upgrade with its own 501.
- **Other matched routes, no `upgrade` header.** This covers attach, WebSocket attach, `/grpc` and `/session`. The answer is a Docker-shaped 400, sent without admission or a dial. Cowboy cannot emit Docker's hijacked 200, so this listener cannot serve the request. Sending it to Plug would yield the Plug's 501 *requires the host's raw adapter*, which is wrong on a listener that has that adapter. For `h2c` routes, 400 is also dockerd's own answer to a missing upgrade. The exact message is fixture-checked. See Open Questions for 501.
- **HTTP/2 request on a matched route.** It gets the same Docker-shaped 400, because `switch_protocol` is HTTP/1.1-only. Hosts should not advertise `h2` in ALPN on a listener that serves Docker. The Docker CLI negotiates HTTP/1.1 for hijacks.

**Request body.** Attach and exec start carry a small JSON body. The handler reads it with `:cowboy_req.read_body/2`, bounded by the same 1 MiB cap `Raw` applies, and passes it as `:body`. Upgrades on `h2c` and WebSocket routes must have no body, as `Raw` already enforces. Whatever Cowboy has buffered past the body arrives later as `takeover/7`'s `buffer`.

**Relay actor.** The handler starts one unlinked, monitored relay process per accepted raw attempt. That process calls `Raw.open/3`, so it owns the backend. The handler waits for the `open` result, bounded by the admission deadline plus the dial-and-handshake deadline. Then:

- **`{:http, ...}`.** The handler replies with Cowboy and the relay exits.
- **`{:upgrade, response, backend, tail}`.** The handler casts `{:switch_protocol, header_map(response.headers), Docker.CowboyTunnel, relay_pid}` and returns `{:ok, req, opts}`. The relay then waits for an attach message, bounded by `handoff_timeout`.

`Docker.CowboyTunnel.takeover(_parent, _ref, socket, transport, _opts, buffer, relay)` does the handoff:

1. Sets `active: false`.
2. Transfers the socket with `transport.controlling_process/2`.
3. Sends the relay `{:attach, socket, transport, buffer}`.
4. Waits for the relay's `:DOWN`, then closes the socket and `exit(:normal)`. It never returns to Cowboy's HTTP loop after opaque traffic, as in `Opsmaru.Incus.Gateway.RawTunnel`.

The relay builds the frontend `Transport.CowboyStream` (decision 3) and calls `Raw.run/4` with `request_tail: buffer`.

**Failures before attach.**

- **Handler dies first.** If the handler process dies before the cast (client disconnect, Cowboy shutdown), the relay closes the backend.
- **No attach in time.** If `handoff_timeout` passes without an attach, the relay closes the backend and reports `reason: :handoff_timeout`, `outcome: :sent`. Either way the upstream request may have been accepted, so nothing is retried.
- **Socket transfer fails.** `takeover/7` kills the relay and closes the socket.

**101 status line.** Cowboy writes `HTTP/1.1 101 Switching Protocols`, where dockerd writes `101 UPGRADED`. Headers are identical to `relay/4`'s. Docker, Compose and Buildx are Go clients and do not read reason phrases, but this is still a wire difference. It is recorded in the docs, and the TLS fixture asserts the exact head.

*Alternative considered:* running `Raw.open` in the handler process and passing the backend through the cast. That violates the ownership contract in decision 1. The exec bridge's linked `Agent` would die with the request process.

### 3. Cowboy frontend stream

`Transport.CowboyStream` adapts `{transport, socket}` for `ranch_tcp` and `ranch_ssl` to `Transport.Stream`. It is internal and created only by the relay.

- **`recv/3`** reads with an absolute-deadline timeout. Its first result is never Cowboy's buffer: the buffer travels as `request_tail`, so it reaches the backend exactly once and before any later bytes.
- **`send/3`** writes with the remaining deadline. The transport's `send_timeout` option is set from the deadline before relaying.
- **`shutdown_write/2`** maps to `transport.shutdown(socket, :write)`, which on TLS sends `close_notify`.
- **`close/1`** maps to `transport.close/1`.

### 4. TLS half-close on OTP is asymmetric, and that is a recorded limitation

Docker hijacks rely on independent write EOF in both directions. On Unix sockets and plain TCP both directions work today. Over TLS, OTP's behaviour on a *received* `close_notify` decides the client-to-engine direction.

A local probe on 2026-11-26 tested Elixir 1.19.5, OTP 27 and ssl 11.2.12.11 as a TLS 1.3 server against a Go 1.23.7 `tls.Conn` client. The Docker CLI uses `tls.Conn`. Each case was run more than once with the same result:

| Direction | Observed |
| --- | --- |
| Engine EOF first: server `ssl:shutdown(S, write)` | The Go client read all output and then EOF. It then wrote a marker, and the server received it. **Half-close works.** |
| Client EOF first: Go `CloseWrite()` sends `close_notify`; server in passive mode | The server's pending `ssl:recv/3` timed out and never reported EOF. A later server write succeeded and the client read it. |
| Client EOF first; server in `active: :once` | The server received `{:ssl_closed, S}`. Later server writes returned `{:error, :closed}`. |

This matches the note in opsmaru_incus's `RawChannel`: OTP ends the TLS connection on the peer's `close_notify`. OTP 27 offers no mode that both surfaces client EOF and keeps the server's write side. Of the two failure modes, a hang is worse:

- **Passive mode** never forwards stdin EOF. A `docker exec -i … < file`, or a BuildKit stream that waits on client EOF, would hang until the stream deadline.
- **Active mode** forwards EOF promptly but loses engine output written after it.

So `CowboyStream` observes the transport's closed message (`{:ssl_closed, _}` / `{:tcp_closed, _}`) and reports `:eof`. The relay forwards `shutdown_write` to the backend. Output arriving later is written if the transport still allows it. If a frontend write then fails, the exchange ends with `reason: :caller_closed`, as an honest failure rather than a silent success.

The CLI's exact behaviour still needs confirming against the pinned source and a fixture. On TLS it may send `close_notify` through `tls.Conn.CloseWrite`, or close the raw TCP write side beneath TLS. Either way OTP ends the session. The real impact on `docker exec -i`, `docker attach` and Buildx over the TLS gateway must be measured with the pinned CLI before Macus relies on it (task 2.5). The result goes into `docs/embedding.md`, and Macus's design should weigh it. A host-owned Unix socket listener, the foundation's original plan, keeps both directions. Re-run the probe whenever the pinned OTP changes.

### 5. Package the exec bridge as an explicit opt-in transport

Task 2.2 of `add-docker-engine-foundation` gated any exec implementation behind qualification task 1.4. The [0.2.10 rerun](../../../docs/docker-live-acceptance.md#exec-qualification-rerun-on-opsmaru_incus-0210) qualified the replacement bridge for that stack:

- setup and duplex EOF in both directions;
- idle streams;
- independent requests;
- disconnect and partial-setup cleanup;
- 8 MiB downloads and uploads;
- differential, CLI and BuildKit checks.

That run used Incus 7.0.1, opsmaru_incus 0.2.10, Docker 29.10.0 and arm64. It closes the gate *for that stack*, and this change packages the bridge on that basis.

- **Name and opt-in.** The module is `Opsmaru.Containers.Transport.ExecBridge`. It implements `Transport` and `Transport.Stream`. It is never chosen implicitly: a host selects it by returning `dialer: {ExecBridge, options}` in its `Context`. The library has no default dialer.
- **Options.** They are validated at dial time. Invalid options return `{:error, :invalid_options}`, which admission already reports as 503 *not ready* with no exec created.
  - `:helper`: absolute guest path of the installed helper. Required.
  - `:socket`: absolute guest path of dockerd's Unix socket. Required, no default.
  - `:request_context`: an `Opsmaru.Incus.RequestContext` whose owner outlives the stream. When omitted, the bridge uses the target's client as the host supplied it, and the relay's stream deadline bounds the stream. The bridge does not derive a context: a `RequestContext` is capped at one hour, while the Cowboy handler's default stream lifetime is 24 hours. A context built inside `Host.context/1` would be owned by that callback's short-lived process, so hosts should normally omit it.
  - `:limits`: `max_input_bytes` and `max_output_bytes` per connection, capped by the Incus connection's `max_stream_bytes`. Exceeding a limit fails the stream visibly and never truncates.
  - `:keepalive_interval`: `nil` (default) or 1–3,600,000 ms of WebSocket pings on stdout, stderr and control. These are hop-scoped control frames.
  - `:observer`: an optional local PID for diagnostic events (helper stderr, keepalive and channel failures). It never carries payload bytes.
- **Helper protocol.** The protocol is versioned by its header, and both sides check it.
  - **Request direction.** Stdin carries raw bytes to the Unix peer. Stdin close makes the helper `CloseWrite` the peer.
  - **Response direction.** Stdout begins with `OCB1`, followed by frames of a 1-byte type and a 4-byte big-endian length. Type 0 carries 1–16,384 bytes of data. Type 1 has length 0 and ends output only.
  - **Errors.** Any other frame is a stream error. A missing header within the dial deadline is `{:bridge_handshake, _}`.
- **Close.** `close/1` follows the qualified behaviour. If the exec operation is not complete, it signals 15 and waits a bounded 3 s. Then it closes the session channels. It never sends an Incus DELETE and never retries.
- **Known limit.** The intermittent stdin WebSocket write stall observed on earlier stacks is still open. The moduledoc states it with the qualified stack, and links to the report. Hosts must treat a stalled upload as a failed, possibly partially applied mutation: the relay already returns a Docker-shaped 502 and never replays.

*Alternatives considered:*

- Keep the bridge out of the package and let each host vendor it. Macus has declined. Central Opsmaru would then hold a second copy.
- Make it the default dialer. That would advertise qualification beyond the tested stack.

### 6. Ship the helper as source with a reproducible build

`priv/exec_bridge/` holds:

- `exec_socket_bridge.go`, moved from `scripts/acceptance`;
- `go.mod` (module `github.com/upmaru/opsmaru-containers/exec_bridge`, `go 1.25`, `toolchain go1.25.14`, no dependencies);
- `README.md` with the build recipe.

The Hex package already ships `priv`. No binary is packaged: engine images build the helper from the release they pin, for their own architecture.

```sh
CGO_ENABLED=0 GOOS=linux GOARCH=<amd64|arm64> GOFLAGS=-mod=readonly \
  go build -trimpath -buildvcs=false -ldflags='-s -w -buildid=' \
  -o exec-socket-bridge ./priv/exec_bridge
```

A `check:bridge` mise task runs `go vet` and builds both architectures twice from clean caches with the pinned toolchain, and fails if the SHA-256s differ. The digests for each release are recorded in `priv/exec_bridge/README.md`. They describe that toolchain only. Go joins `mise.toml`. The Hex consumers never need it, and the packaged-consumer check asserts that the source and `go.mod` are present in the unpacked package.

### 7. Docker exchange and request telemetry

This follows opsmaru_incus `add-gateway-exchange-telemetry` in spirit and mechanism:

- `{:telemetry, "~> 1.3", optional: true}`;
- an internal `Opsmaru.Containers.Telemetry` emitter that compiles to no-ops without `:telemetry` and never raises into a request;
- a per-exchange observer process, started only when a handler is attached to the `[:opsmaru_containers, :docker]` prefix.

| Event | Measurements | Emitted |
| --- | --- | --- |
| `[:opsmaru_containers, :docker, :exchange, :start]` | `system_time`, `monotonic_time` | in the adapter process (Plug request process, Cowboy handler, or `Raw.relay/4` / `Raw.open/3` caller), before admission |
| `[:opsmaru_containers, :docker, :request]` | `duration` (start to head) | once, when a response head is committed (101, raw 200, an HTTP status) or the request is refused; from the observer |
| `[:opsmaru_containers, :docker, :exchange, :stop]` | `duration`, `request_bytes`, `response_bytes` | exactly once, when the exchange really ends; from the observer |

The `request` event lets an access log write its line when a long stream such as attach, events or logs starts, and not hours later. The observer monitors the exchange owner: the Plug process, then the relay after handoff. A killed relay therefore still reports.

Byte counts:

- **Counted:** body bytes for ordinary HTTP, and tunnelled bytes for raw streams, counted once written or read at the frontend.
- **Not counted:** heads, chunk framing and helper framing.

Metadata, all keys always present:

| Key | Value |
| --- | --- |
| `telemetry_span_context` | reference shared by the events of one exchange |
| `adapter` | `:plug`, `:raw` or `:cowboy` |
| `host` | the host policy module |
| `mode` | `:http`, `:docker_stream`, `:h2c_upgrade` or `:websocket` |
| `method` | `GET`, `HEAD`, `POST`, `PUT`, `DELETE`, otherwise `nil` |
| `route` | the matched route template from `routes.json`, else `nil` |
| `path` | the original encoded path once admission accepted the target (at most 8192 bytes), else `nil` |
| `api_version` | the requested `X.Y` from the path, else `nil` |
| `peer_address`, `peer_port` | as the adapter knows them (Plug `remote_ip`, Cowboy peer), else `nil` |
| `peer_fingerprint` | lowercase hex SHA-256 of a presented client certificate (Cowboy only), else `nil`; names a certificate, not a trusted identity |
| `status` | `request`/`stop`: the status sent to the caller, `nil` if none |
| `outcome` | `stop`: `:ok`, or what the engine may have seen: `:not_sent`, `:uncertain`, `:sent` |
| `reason` | `stop`: `nil` when `:ok`, else one of `:invalid_request`, `:not_found`, `:denied`, `:unsupported`, `:version`, `:not_ready`, `:too_large`, `:engine_unavailable`, `:upstream_failed`, `:caller_closed`, `:backend_closed`, `:deadline`, `:handoff_timeout`, `:killed` |

Never emitted:

- the query string, which may carry build args and filters;
- any header, including `authorization` and `x-registry-auth`;
- bodies or stream bytes;
- the host identity or `Context`, the Incus client or target;
- bind sources or mapped paths;
- error messages;
- a path admission refused.

The library attaches no handler, writes no log and defines no metrics. No decision, deadline or wire byte depends on a handler.

### 8. Release 0.2.0

- **Version.** The new public API is additive, but the dependency floors change, so this is a minor bump on 0.x.
- **Release route.** It goes out through `release/0.2.0` from develop and the existing Hex workload-identity workflow. Every branch finish, tag and publish requires user authorization.
- **Git Flow gap.** `develop` does not yet contain the `release/0.1.0` back-merge (`0bce42c` on `main`). The release branch must start after that merge, or the 0.1.0 changelog and workflow changes will conflict.
- **Evidence.** The change records fixture, TLS-fixture and packaged-consumer evidence. Optionally it records a real-Incus rerun of the *packaged* bridge with the same opt-in and isolation as before. It records no Macus evidence. Foundation task 4.5 stays open and Macus-owned.

## Risks / Trade-offs

- **TLS half-close (decision 4).** Over the TLS gateway, engine output after the client's write EOF may be lost. The pinned-CLI measurement (task 2.5) decides what Macus documents or whether it chooses a Unix listener. → Measure before release notes claim attached exec over TLS.
- **The 101 reason phrase differs from dockerd's.** → Assert it in the fixture. Run the pinned CLI, Compose and Buildx over the Cowboy handler.
- **Ownership contract.** A host calling `open` and `run` from different processes breaks adapters that tie resources to their dialer. → Document it on both functions. The Cowboy handler is the reference user.
- **Stdin write stall.** The open stall can still leave a partial upload. → The relay returns 502 and never replays. The moduledoc and report state it.
- **Telemetry cost.** → No observer is started without a handler. The start handler runs in the adapter process, so hosts keep it cheap.

## Open Questions

- **Missing `Upgrade` on `docker_stream` routes.** Should a request there get 501 *not supported on this listener* instead of 400? The brief asked for 400, and dockerd answers 400 for `h2c` routes without an upgrade, so this design uses 400 with an explicit message. Docker clients always send the header.
- **Real-Incus rerun.** Should the packaged-bridge rerun (task 3.5) be required before 0.2.0, or recorded after it? The code is the qualified acceptance module, moved.
