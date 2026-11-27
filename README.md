# opsmaru-containers

Container engine APIs served from [Incus](https://linuxcontainers.org/incus/),
for Elixir hosts such as [Macus](https://github.com/upmaru/macus) and central
[Opsmaru](https://github.com/upmaru/opsmaru). The Docker Engine API comes first,
so that `docker`, `docker compose` and tools that use `DOCKER_HOST` can work
against an Incus backend.

**Status: Docker foundation in development.** Host embedding, nested engine
lifecycle, and HTTP and raw relay paths have fixture coverage. Real-engine,
real-Incus and Macus acceptance are tracked in the
[OpenSpec change](openspec/changes/add-docker-engine-foundation). Native
containers have fixture, real-Incus and differential evidence on arm64 and
are tracked in
[add-native-oci-engine](openspec/changes/add-native-oci-engine); host
acceptance has not been run.

## Design in brief

- **Pure library.** OTP application `:opsmaru_containers`, modules
  `Opsmaru.Containers.*`. There is no application callback: depending on it
  starts no process, listener, state or backend connection.
- **Host-owned listener.** The host mounts the engine API on its own socket and
  passes its [opsmaru_incus](https://github.com/upmaru/opsmaru-incus) connection,
  verified identity and readiness on every call.
- **Incus is the only backend.** Everything goes through `opsmaru_incus`. The
  library keeps no database; engine metadata lives on Incus objects.
- **Nested Docker first.** The relay targets dockerd inside an Incus system
  container. That engine stays the image store and serves everything the
  native engine does not.
- **Native containers, opt in.** A host can run selected containers as Incus
  OCI application containers instead, visible to Incus tooling. A small init
  shim, which the host builds, runs inside each one: it starts the exact
  Docker argv, records exit status and writes the logs. Images are copied
  from dockerd with `skopeo` and `umoci` in the engine. Fields and routes the
  native engine cannot honour are refused by name, never sent to nested
  instead, and Compose projects should stay nested. See
  [native containers](docs/embedding.md#route-containers-to-the-native-engine)
  for the translation, the refusals and the recorded differences from Docker.

## Development

```sh
mise trust && mise install
mix deps.get
mise run check   # format, compile, strict Credo, tests, OpenSpec
mise run check:consumer
```

Planning lives in [openspec/](openspec). See [AGENTS.md](AGENTS.md) for the
project rules.

See the [embedding guide](docs/embedding.md) for host callbacks, lifecycle,
and the raw socket handoff.
