# Tasks

## 1. Pinned reference and transport qualification

- [ ] 1.1 Record Docker Engine and CLI 29.10.0, Compose 5.8.0 and Buildx 0.39.1 for the Docker builder driver. Record source commits, API bounds and the SHA-256 and license of the pinned OpenAPI description.
- [ ] 1.2 Generate and check the route inventory from the pinned description and audited daemon route supplement. Classify every route with a reason for exclusion and record takeover semantics. Run the reference check in canonical CI.
- [ ] 1.3 Spike a host-owned Unix listener with a scripted backend. Prove handoff of already-read bytes, HTTP 101 and Docker raw 200 handshakes, independent write EOF and disconnect cleanup through the proposed host adapter.
- [ ] 1.4 With explicit opt-in and an isolated Incus v7.0.1 project, qualify the stdio helper. Measure setup and throughput and prove EOF, independent requests, cleanup after interruption or partial setup, and operation with large payloads and long idle periods. Record the result before enabling exec as a default.
- [ ] 1.5 Join the listener and chosen transport. Prove interactive exec and the pinned Buildx Docker driver against the pinned daemon and record the actual handshakes. If exec misses qualification, require the host dialer.

## 2. Passive embedding and lifecycle

- [ ] 2.1 Add the host contract, request context and expiring engine capability snapshot. Denial, invalid context, and absent or expired readiness fail before backend access. Keep verified identity and target selection host-owned.
- [ ] 2.2 Add a host-supplied dialer contract and scripted transport fixtures for independent bounded duplex connections. Enable an exec implementation only following task 1.4.
- [ ] 2.3 Add the validated nested engine specification and explicit `ensure/3`. Verify ownership, project selection, definite create conflict reconciliation, successful repeat calls, bounded waits and no replay after an unknown create or start outcome.
- [ ] 2.4 Implement readiness by checking running state, ping and API range, returning observed capabilities to the host for publication.
- [ ] 2.5 Add direct JSON and optional web dependencies. Check the built Hex package in two fresh consumers, one with the web stack and one without, with hostile `PHX_SERVER` and `PORT` settings. Verify reference data and notices are packaged.

## 3. HTTP and raw relay

- [ ] 3.1 Implement shared route admission, authorization and Docker-shaped rejections before any backend access. Use the effective version range for negotiation, preserve encoded targets, and reconcile ping, version reporting and unversioned paths.
- [ ] 3.2 Gate container bind sources with the host path callback. Reject custom volume-driver options on explicit and inline volume creation. Preserve pass-through bodies requiring no rewrite.
- [ ] 3.3 Relay ordinary HTTP with bounded request and response streaming, repeated end-to-end headers and one dial per forwarded request. Verify honest upstream failure before commitment and connection termination after commitment. Verify no request replay.
- [ ] 3.4 Implement the host-mounted raw adapter against the handoffs qualified in task 1.3. Verify attach, exec, logs, events, stats and build progress including client disconnect and stalled-reader independence.

## 4. Evidence and documentation

- [ ] 4.1 Track one ledger entry per route, including fixture, real-engine differential, real-Incus and consumer records.
- [ ] 4.2 Add opt-in differential cases against equivalent pinned-engine state for direct and relayed requests. Compare meaningful headers, body or stream framing and status. Record verified routes only after the cases run.
- [ ] 4.3 Run the pinned CLI and plugins against the hosted API in opt-in real-Incus acceptance, covering version, pull, run, interactive exec, followed logs, BuildKit, Compose up and down, and remove.
- [ ] 4.4 Document embedding, the raw adapter, the host lifecycle obligations and verified scope. Run the canonical and packaged-consumer checks.
- [ ] 4.5 Record consumer acceptance when Macus supplies its Unix listener, Docker context, engine image, path mapping and relay concurrency measurement.
