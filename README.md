# opsmaru-containers

Container engine APIs served from [Incus](https://linuxcontainers.org/incus/),
for Elixir hosts such as [Macus](https://github.com/upmaru/macus) and central
[Opsmaru](https://github.com/upmaru/opsmaru). The Docker Engine API comes first,
so that `docker`, `docker compose` and tools that use `DOCKER_HOST` can work
against an Incus backend.

**Status: scaffold only.** No container engine API is implemented yet. The
initial scope is planned in
[openspec/changes/add-docker-engine-foundation](openspec/changes/add-docker-engine-foundation).

## Design in brief

- **Pure library.** OTP application `:opsmaru_containers`, modules
  `Opsmaru.Containers.*`. There is no application callback: depending on it
  starts no process, listener, state or backend connection.
- **Host-owned listener.** The host mounts the engine API on its own socket and
  passes its [opsmaru_incus](https://github.com/upmaru/opsmaru-incus) connection,
  verified identity and readiness on every call.
- **Incus is the only backend.** Everything goes through `opsmaru_incus`. The
  library keeps no database; engine metadata lives on Incus objects.
- **Two engines behind one API.** A nested engine (dockerd inside an Incus
  system container) gives full compatibility and handles builds. A native
  engine (Incus OCI application containers) is planned to take over endpoints
  one at a time.

## Development

```sh
mise trust && mise install
mix deps.get
mise run check   # format, compile, strict Credo, tests, OpenSpec
```

Planning lives in [openspec/](openspec). See [AGENTS.md](AGENTS.md) for the
project rules.
