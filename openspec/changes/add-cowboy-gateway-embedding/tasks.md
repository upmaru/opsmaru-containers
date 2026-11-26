# Tasks

Evidence classes stay distinct. Fixture and TLS-fixture tests prove library behaviour against scripted backends. A real-Incus rerun proves the packaged bridge on the named stack. Macus consumer acceptance is separate and Macus-owned. Passthrough to the nested engine never counts as native evidence, and no ledger entry changes without a run that verifies it.

## 1. Split raw entry

- [x] 1.1 Add `Raw.open/3` and `Raw.run/4` (design decision 1) and refactor `Raw.relay/4` onto them. Verify that every existing raw fixture in `test/opsmaru/docker_raw_tunnel_test.exs` passes unchanged and that `relay/4` writes byte-identical heads for `tcp`, `h2c`, WebSocket and the raw 200 form.
- [x] 1.2 Verify against a scripted backend that:
  - `open/3` returns the normalized status, protocol and headers, with `api-version` capped;
  - `open/3` returns the engine tail it read past the head;
  - `open/3` returns `{:http, ...}` with the backend closed for an engine 4xx/5xx, an ordinary engine response and an engine failure;
  - a denial, an unsupported route, an out-of-range version and an engine that is not ready never dial.
- [x] 1.3 Verify that `run/4` delivers the response tail and the request tail exactly once, before later bytes, then relays with independent write EOF in both directions. Verify that it writes no response head and closes both streams on success, deadline, frontend failure and backend failure.
- [x] 1.4 Document the same-process ownership contract on `open/3` and `run/4`, and the split API in `docs/embedding.md`.

## 2. Cowboy handler

- [x] 2.1 Add `Docker.CowboyHandler`, `Docker.CowboyTunnel` and `Transport.CowboyStream`, compiled only with `:cowboy_req` (design decisions 2 and 3). Dispatch through `Route.match/2` on takeover routes and wrap fallback results as `Opsmaru.Incus.Gateway.CowboyHandler` does.
- [x] 2.2 Add a Cowboy fixture listener over TLS 1.3, with test-generated certificates and a scripted Docker backend dialer. On this listener, verify:
  - **Fallback:** ordinary requests, detached exec and a foreign WebSocket upgrade reach a `Plug.Cowboy.Handler` fallback with their bodies unread, and this handler emits no telemetry for them.
  - **Chaining:** a chain behind `Opsmaru.Incus.Gateway.CowboyHandler`, when the test can load it, serves each request with the right handler.
  - **Missing upgrade:** a raw-stream request without `Upgrade` (attach, WebSocket attach, `/grpc`, `/session`) gets a Docker-shaped 400 and is neither admitted, dialed nor passed to the fallback. Exec start without `Upgrade` goes to the fallback (detached exec).
  - **HTTP/2:** an HTTP/2 request on a takeover route also gets that 400.
  - **Policy before dial:** denial, an unsupported route, version errors and a not-ready context return the `relay/4` error bodies, and the dialer is never called.
- [x] 2.3 On the TLS fixture, prove takeover with buffered bytes:
  - stdin sent in the same segment as the exec start request reaches the backend exactly once, before later stdin;
  - the engine tail read past its 101 reaches the client first;
  - the 101 head carries exactly `relay/4`'s headers and Cowboy's reason phrase;
  - the connection never returns to Cowboy's parser afterwards.

  Also cover an engine that answers the upgrade with an ordinary error, a handler killed before the cast, and a takeover that misses `handoff_timeout`. In each case the backend closes and the request is not retried.
- [x] 2.4 Prove `close_notify` half-close in both directions on the TLS fixture, and TCP half-close on a plain listener:
  - engine EOF first sends `close_notify`, the client reads all output, and the client's later bytes reach the backend;
  - client `close_notify` first forwards EOF to the backend promptly, and a later failed frontend write ends the exchange with `reason: :caller_closed`;
  - the TCP cases keep the opposite direction in both orders.

  Use a Go TLS client pinned in the test (or the pinned Docker CLI's TLS dialer) for the client side, because OTP clients close both directions themselves.
  - Verified by `test/opsmaru/docker_cowboy_handler_test.exs` (2.2–2.4, 2.6) with `test/support/go/tls_hijack_client.go`. Unsupported routes are not takeover routes, so they reach the fallback; policy-before-dial is shown with denial, both version errors, a not-ready context and a wrong upgrade protocol.
- [ ] 2.5 Determine from the pinned Docker CLI 29.10.0 source and a fixture how its hijacked TLS connection half-closes after stdin EOF: `close_notify` through `tls.Conn.CloseWrite`, or TCP write shutdown beneath TLS. With the pinned CLI over the TLS fixture, measure what reaches the client in each of these cases:
  - `docker exec -i` with redirected stdin;
  - `docker attach`;
  - a Buildx build.

  Record the result and the decision-4 limitation in `docs/embedding.md`. Report it to Macus for its gateway design. Repeat the OTP probe whenever the pinned OTP changes.
- [x] 2.6 Verify that the handler opens no listener and starts no process before a request, and that a raised handler error still closes the backend and the socket.

## 3. Packaged exec bridge

- [x] 3.1 Add `Transport.ExecBridge` from `scripts/acceptance/exec_socket_bridge.ex` with validated options (design decision 5). Remove the acceptance copy and point `scripts/acceptance/exec_socket_bridge_half_close.ex` at the packaged module. Verify with a scripted Incus session or exec fixture:
  - option validation fails before any exec is created;
  - the `OCB1` header and frame checks reject a bad header, an unknown type and out-of-range lengths;
  - data and EOF frames decode, and chunks split at the relay's read limit;
  - stdin is chunked at 16 KiB and `shutdown_write` sends the write barrier;
  - input and output limits fail visibly;
  - keepalive pings run only when configured and stop with the owner;
  - `close/1` signals an incomplete operation, waits a bounded time and never sends a DELETE.
- [x] 3.2 Move the helper to `priv/exec_bridge/exec_socket_bridge.go` with `go.mod` (`go 1.25`, `toolchain go1.25.14`) and a build `README.md` (design decision 6). Add Go 1.25.14 to `mise.toml`. Add a `check:bridge` mise task, run by `mise run check` and CI, that runs `go vet` and builds linux/amd64 and linux/arm64 twice from clean caches, failing if the SHA-256s differ. Record the digests in the README.
- [x] 3.3 Add a Go unit test for the helper covering the header, frame bounds, output EOF before input EOF, input EOF before output EOF and exit codes 0, 1 and 2. Run it in `check:bridge`.
- [x] 3.4 Document the bridge in its moduledoc and `docs/embedding.md`: explicit selection only, the qualified stack (Incus 7.0.1, opsmaru_incus 0.2.10, Docker 29.10.0, arm64), the open stdin write stall, and why a host should normally omit `:request_context`. Update `docs/docker-live-acceptance.md` to reference the packaged paths without rewriting its recorded results.
  - Verified by `test/opsmaru/transport_exec_bridge_test.exs` against a scripted session (`test/support/fake_exec_incus.ex`) and by `priv/exec_bridge/exec_socket_bridge_test.go` under `mise run check:bridge`. The bridge reaches Incus through an internal adapter, so close/1 is shown to call only the completed check, SIGTERM, a 3 s wait and channel close. The adapter's one-line opsmaru_incus calls are not exercised against a server.
- [ ] 3.5 With explicit opt-in, an isolated Incus 7.0.1 project and private credentials, rerun the half-close script and an attached exec through the *packaged* bridge and the helper built from `priv/exec_bridge`. Record the result as real-Incus evidence for the packaged module, or record that it was not run. Whether this gates 0.2.0 is an open question in [design.md](design.md).

## 4. Telemetry

- [x] 4.1 Add `{:telemetry, "~> 1.3", optional: true}`, `Opsmaru.Containers.Telemetry` and the internal `Docker.Exchange` observer (design decision 7). Verify that:
  - each start has exactly one stop for a normal finish, a killed owner, a finish racing a kill, and a transfer to the relay followed by a kill;
  - no observer starts without a handler;
  - a handler attached mid-exchange yields no unpaired events;
  - a loaded but unstarted `:telemetry` never raises.
- [x] 4.2 Emit from `Docker.Plug`, `Raw.relay/4`, `Raw.open/3`, `Raw.run/4` and `Docker.CowboyHandler`. For each, verify:
  - the request event at the head for ordinary HTTP, a 101, a raw 200 and every refusal class;
  - stop byte counts for HTTP bodies and tunnelled bytes;
  - every documented `reason`, with no undocumented one;
  - the `outcome` for an interrupted mutation, which is `:uncertain` or `:sent` and never retried.
- [x] 4.3 Add a redaction test across the Docker fixture suites. It fails if any metadata value contains a query string, a header value (including `authorization` and `x-registry-auth`), a body or stream byte, the host identity or context, the Incus client or target, a bind source, an error message, or a refused path. Verify that `peer_fingerprint` is the SHA-256 of the presented certificate and `nil` without one.
- [x] 4.4 Verify that, with a raising handler and with a blocking handler, wire bytes, statuses and deadlines match runs without a handler, and backend streams close without waiting for the handler.
- [x] 4.5 Document the catalogue, closed value sets, emitting processes and exclusions in `docs/embedding.md` and the `Opsmaru.Containers.Telemetry` moduledoc. Verify with a test that every documented event is emitted and no undocumented `[:opsmaru_containers | _]` event is.

  - Verified by `test/opsmaru/docker_telemetry_test.exs` (observer, Plug and Raw emission, passivity, catalogue against `docs/embedding.md` and the source) and the Cowboy cases in `test/opsmaru/docker_cowboy_handler_test.exs` (refusals, takeover, half-close, `:handoff_timeout`, redaction and fingerprint). Redaction is asserted on every exchange in the telemetry suite and on a Cowboy upgrade carrying marked query, headers, body and stream bytes. The Plug reports `peer_port: nil`. A `start` handler runs in the adapter process, so only `request` and `stop` handlers are shown not to hold a backend stream.

## 5. Packaging, release and evidence

- [x] 5.1 Raise `opsmaru_incus` to `~> 0.2.10` in `mix.exs`. Extend `test/acceptance/hex_consumers.sh`:
  - the unpacked package contains `priv/exec_bridge/exec_socket_bridge.go` and `go.mod`, and no helper binary;
  - the headless consumer has no `Docker.CowboyHandler` and resolves no `:telemetry`;
  - the web consumer loads `Docker.CowboyHandler` and Ranch reports no listener after start.

  Run `mise run check:consumer`.
- [x] 5.2 Run `mise run check`, `mise run check:reference` and `mise exec -- openspec validate --all --strict --no-interactive`.
- [x] 5.3 Add the 0.2.0 `CHANGELOG.md` entry. List the split raw API, the Cowboy handler with its 101 reason phrase and TLS half-close limitation, the packaged exec bridge with its qualified stack and open stall, telemetry, and the dependency floor.
- [ ] 5.4 With user authorization, finish this feature into develop, cut `release/0.2.0` from develop after the `release/0.1.0` back-merge is on develop, and publish 0.2.0 to Hex through the existing release workflow. Do not tag, finish or publish without that authorization.
  - `opsmaru_incus ~> 0.2.10` is in `mix.exs`. `mise run check:consumer` passed on 2026-11-26 with both consumers verified.
  - `mise run check` passed on 2026-11-26: format, compile, strict Credo, 106 fixture tests including the Go TLS client, the reference check, strict OpenSpec validation and `check:bridge`. `check:reference` passed on its own as well.
  - The 0.2.0 entry is in `CHANGELOG.md` as unreleased. Per the release runbook, `@version` is bumped on `release/0.2.0`, not here.
- [x] 5.5 Record that this change adds fixture, TLS-fixture and packaged-consumer evidence, plus the task 3.5 real-Incus evidence only if it was run. Record that Macus consumer acceptance stays open as task 4.5 of `add-docker-engine-foundation`, to be recorded when Macus serves Docker on its gateway with its own listener, engine image, path mapping and docker context.
  - Recorded on 2026-11-26. This change adds:
    - fixture evidence (the split raw entry, the exec bridge against a scripted session, telemetry);
    - TLS-fixture evidence (the Cowboy handler on loopback TLS 1.3 with a Go TLS client);
    - Go unit tests and reproducible builds for the helper;
    - packaged-consumer evidence.
  - Task 3.5 was not run, so there is no real-Incus evidence for the packaged bridge. Task 2.5 was not run either.
  - Macus consumer acceptance stays open as task 4.5 of `add-docker-engine-foundation`.
  - No evidence-ledger entry changed.
