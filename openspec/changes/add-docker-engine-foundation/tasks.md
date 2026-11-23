# Tasks

## 1. Reference and transport spike

- [ ] 1.1 Choose the Docker Engine release to pin. Record the release, source commit, minimum and maximum API versions and the SHA-256 of its API description in `priv/docker/reference.json`, with the upstream licence notice in `priv/notices`. Pin the matching `docker` CLI for acceptance.
- [ ] 1.2 Spike the default transport against a real Incus v7.0.1 and the pinned dockerd: run the engine's stdio dial helper over a non-interactive `opsmaru_incus` exec and confirm a plain request, half-close in both directions, an interactive exec, a followed log stream and a BuildKit build through `/session` and `/grpc`. Measure connection setup time and throughput. Record the result in `design.md`; if half-close or the BuildKit upgrade fails, revise decision 6 before continuing.
- [ ] 1.3 Generate `priv/docker/routes.json` from the pinned API description with a Mix task that has a `--check` mode, and add `mise run check:reference`.

## 2. Embedding contract

- [ ] 2.1 Add `Opsmaru.Containers.Host` with `context/1`, `authorize/2` and the optional `map_bind_source/2`, and the context struct carrying the Incus connection, the `opsmaru_incus` host context and the engine instance reference. Verify that a missing, refused or not-ready context fails before any backend access.
- [ ] 2.2 Add `jason`, and `plug` and `cowboy` as optional dependencies. Verify that the library compiles without them and that the handler modules are then absent.
- [ ] 2.3 Add `mise run check:consumer`: build the Hex package and verify it in two fresh consumers, one without a web stack and one mounting the handler, with hostile `PHX_SERVER` and `PORT` settings.

## 3. Nested engine

- [ ] 3.1 Add the engine specification and its validation: required nesting key and marker, rejection of conflicting configuration, no image default.
- [ ] 3.2 Add `Opsmaru.Containers.Nested.ensure/3`, `stop/3` and `remove/3`. Verify idempotence for a ready engine, one instance under concurrent callers, the conflict error for an unmarked instance of the same name, and that an interrupted create or start is reported as uncertain and never repeated.
- [ ] 3.3 Add the transport behaviour, the default exec transport and support for a host dialer. Verify one exec operation per engine connection, half-close in both directions, and that the exec operation ends and its channels close when either side goes away.
- [ ] 3.4 Add the readiness check: instance running, engine ping through the transport, and API range covering the reference minimum, with distinct not-ready and incompatible errors.

## 4. Docker Engine API handler

- [ ] 4.1 Add the Plug handler with the route table, `/_ping`, versioned and unversioned paths, the advertised maximum (the lower of reference and engine) and refusal of out-of-range versions with the reference engine's messages.
- [ ] 4.2 Add the engine error shape for every handler-made error (400, 403, 404, 501, 503) and verify that no message contains credentials, registry tokens or connection details.
- [ ] 4.3 Call `authorize/2` with the classified request before any backend access. Verify that denial, a missing callback, a raising callback and a late answer all answer 403 with no backend request.
- [ ] 4.4 Classify every inventory route as `nested` or `unsupported` with a reason, and make the reference check fail on an unclassified route or on any `native` class.
- [ ] 4.5 Relay plain requests and responses unchanged apart from hop-by-hop headers, one engine connection per request, with bounded buffering and backpressure. Verify that a failure after request bytes were sent on a non-GET/HEAD request is returned to the client and never retried.
- [ ] 4.6 Relay hijacked and upgraded connections (attach, exec start, `/session`, `/grpc`) and long-lived responses (followed logs, events, stats, build, pull and push progress). Verify half-close, client disconnect cleanup, and that a stalled stream does not delay a concurrent short request.
- [ ] 4.7 Extract bind sources from `HostConfig.Binds` and bind-type `HostConfig.Mounts` on container create, apply `map_bind_source/2`, and refuse with 400 when a source is denied or no callback exists. Verify that named volumes and tmpfs mounts pass unchanged and that only the mapped sources differ in the relayed body.
- [ ] 4.8 Answer 503 when the engine is absent, stopped, not ready or incompatible, and verify that the handler never creates or starts the instance.

## 5. Evidence

- [ ] 5.1 Add `priv/docker/coverage.json` with one entry per inventory route (class, fixture, differential, consumer) and a check that it matches the inventory and never counts nested evidence for a native class.
- [ ] 5.2 Add the opt-in differential suite: against an isolated Incus project with the pinned engine, send each `nested` route's request directly and through the handler and compare status and body. Record results in the ledger.
- [ ] 5.3 Add the opt-in CLI acceptance with the unmodified pinned `docker` CLI through the handler: `version`, `pull`, `run`, interactive `exec`, `logs -f`, `build` with BuildKit, `compose up` and `down`, and `rm`.

## 6. Documentation and release readiness

- [ ] 6.1 Write `docs/embedding.md` (host behaviour, context, mounting the handler, engine specification and ensure) and `docs/docker-engine-api.md` (route classes, unsupported routes with reasons, bind mounts, published ports reachable only inside the engine instance, the single trust domain).
- [ ] 6.2 Update `README.md`, `AGENTS.md` and `CHANGELOG.md`, add the Hex publish workflow, and run `mise run check`, `mise run check:reference` and `mise run check:consumer`.
- [ ] 6.3 Hand over to Macus for consumer acceptance: its socket, docker context, engine image, path mapping and a measurement of concurrent streams over its guest relay. Record the result as consumer evidence; this library does not claim it.
