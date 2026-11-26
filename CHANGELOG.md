# Changelog

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
