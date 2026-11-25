# opsmaru-containers

Container engine APIs served from [Incus](https://linuxcontainers.org/incus/),
for Elixir hosts such as [Macus](https://github.com/upmaru/macus) and central
[Opsmaru](https://github.com/upmaru/opsmaru). The Docker Engine API comes first,
so that `docker`, `docker compose` and tools that use `DOCKER_HOST` can work
against an Incus backend.

**Status: Docker foundation in development.** Host embedding, nested engine
lifecycle, and HTTP and raw relay paths have fixture coverage. Real-engine,
real-Incus and Macus acceptance are tracked in the
[OpenSpec change](openspec/changes/add-docker-engine-foundation).

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
  container. A later native engine based on Incus OCI application containers
  can take over selected routes.

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
