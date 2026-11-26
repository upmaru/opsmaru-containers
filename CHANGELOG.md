# Changelog

## 0.2.0 — unreleased

- Split `Raw.relay/4` into `Raw.open/3` and `Raw.run/4` for listeners that
  write the frontend handshake themselves. Both must run in the same process,
  and `relay/4` keeps its return values and wire bytes.
- Add `Docker.CowboyHandler`, compiled only when the host includes Cowboy, to
  serve Docker raw streams on a host-owned Cowboy listener with a fallback
  for everything else. Cowboy writes `101 Switching Protocols` where dockerd
  writes `101 UPGRADED`; the headers are identical. On TLS, output the engine
  sends after the client's `close_notify` is lost: OTP does not deliver it,
  so the relay refuses those writes and reports `:caller_closed`. How the
  pinned Docker CLI half-closes its hijacked TLS connection is not yet
  measured.
- Package the exec bridge as `Transport.ExecBridge`, an explicit opt-in
  dialer with validated options, visible byte limits, optional keepalive and
  a bounded close that never deletes or retries. The Go helper ships as
  source in `priv/exec_bridge` with a reproducible build and recorded
  digests. The bridge qualified on Incus 7.0.1, opsmaru_incus 0.2.10, Docker
  29.10.0 and arm64 as an acceptance script. The packaged module has fixture
  evidence only, and the intermittent stdin write stall stays open.
- Emit optional `:telemetry` exchange events (`start`, `request`, `stop`)
  from `Docker.Plug`, `Raw` and `Docker.CowboyHandler`, with bounded,
  secret-free metadata. The catalogue is in `docs/embedding.md`.
- Require `opsmaru_incus ~> 0.2.10` and add the optional `telemetry ~> 1.3`
  dependency.

## 0.1.0 — 2026-11-26

- Add the fixture-tested Docker relay foundation, the host embedding and
  nested lifecycle contracts, and the pinned Docker 29.10.0 route inventory.
  On the pinned stack (opsmaru_incus 0.2.10, isolated Incus 7.0.1, Docker
  Engine 29.10.0) the replacement bridge passed the exec qualification gates:
  six read-only differential cases, plus pinned Docker CLI 29.10.0, Compose
  5.8.0 and Buildx 0.39.1 checks (pull, run, attached exec, logs, build,
  image inspection, Compose up/down, BuildKit). The intermittent stdin write
  stall remains open, and Macus consumer acceptance is separate.
- Wire the release workflow for staged Hex publishing: keyless Workload
  Identity via the release environment, an initial 0.1.0 bootstrap wait,
  staged-release resume, and public checksum/docs verification before the
  GitHub Release.
