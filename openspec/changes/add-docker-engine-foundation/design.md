# Design

## Context

See [proposal.md](proposal.md). The library sits between a container engine client and Incus:

```
docker CLI / compose / testcontainers
        │  Docker Engine API, on a listener the host owns
        ▼
opsmaru_containers
  ├─ Docker   Plug handler: negotiation, errors, authorization, route table
  ├─ Core     host context, bind-path decisions, relay
  └─ Nested   engine instance: ensure, readiness, transport
        │  opsmaru_incus only
        ▼
Incus ── system container running dockerd
```

`opsmaru_incus` already provides what this change needs from Incus: typed instance create, start and state calls, and native exec channels (`Opsmaru.Incus.Session.exec/3`). It is pinned to Incus v7.0.1.

Two facts shape the design. First, Macus reaches Incus in its guest over a relay where one busy stream has stalled others (head-of-line blocking), so long-lived Docker streams must not share a connection. Second, the library has the same embedding rules as `opsmaru_incus`: it starts nothing and holds nothing.

## Goals / Non-Goals

**Goals:** a Docker socket supporting the pinned clients on the verified nested routes; no code path that reaches Incus except through `opsmaru_incus` and the host's connection; a route table and evidence ledger that later changes can extend one route at a time; identical behavior for Macus and for a remote Incus target.

**Non-Goals:** the native engine, a shared image store, libpod, published-port forwarding, engine installation inside the instance, rootless or multi-tenant isolation between Docker clients, and any Macus code.

## Decisions

### 1. One package, role-named, with per-API frontends

The package is `opsmaru_containers` and the namespace is `Opsmaru.Containers`. The Docker frontend lives under `Opsmaru.Containers.Docker`. A later libpod frontend would sit beside it and share the core. Naming the package for a vendor or for OCI would describe only part of it.

### 2. The host owns the listener and decides every request

The library exposes a Plug for ordinary HTTP and a raw HTTP/1.1 handoff contract for hijacks. Both paths use the same request admission and route classification. The host mounts the adapter on its existing listener. First prove the handoff over a host-owned Unix listener with a scripted backend, including buffered bytes and EOF. Check HTTP 101 upgrades and Docker's HTTP 200 raw-stream form against the pinned router. A Cowboy switch-protocol callback is a candidate for 101, with a capable host adapter required for any handshake it cannot emit. The host chooses the socket, its file permissions and its supervisor. `plug` and `cowboy` are optional dependencies, so a host that uses only the nested lifecycle operations compiles without a web stack.

The Docker socket grants root-equivalent control of the engine, and the API itself has no authentication. So the handler calls a host behaviour, `Opsmaru.Containers.Host`, before any backend access:

- `context/1` returns the Incus connection, the `opsmaru_incus` host context verified identity, engine instance reference, readiness and a capability snapshot for that target, or refuses. The snapshot carries the daemon API minimum and maximum and a host-selected monotonic expiry. Obtaining the context and authorization decision performs no backend access.
- `authorize/2` allows or denies the classified request. A missing, failing or late answer denies.
- `map_bind_source/2` (optional) maps or denies one bind mount source path.

This follows the gateway's host behaviour in `opsmaru_incus`: the library classifies, the host decides.

### 3. A pinned Docker Engine reference

The library pins one Docker Engine release and records it in `priv/docker/reference.json`: the release, its source commit, its maximum and minimum API versions and the SHA-256 of its published API description. `priv/docker/routes.json` is generated from that description and lists every method and path.

The reference is Docker Engine and CLI 29.10.0 with API 1.40 through 1.57. Pin Compose 5.8.0 and Buildx 0.39.1 for acceptance, including the integrated Docker builder. Generate routes from the OpenAPI document and reconcile it against the daemon's registered routes and client protocol use. Record any conditional route, alias or protocol detail in a checked supplement.

Admission computes the intersection of the reference and the engine snapshot. A missing, invalid, expired or disjoint snapshot yields 503 with no backend call. Out-of-range requests yield Docker's version error using the effective bounds. The relay caps API-version headers and the version fields in `/version` to those bounds where required. Unversioned requests use the effective maximum if the daemon's own default would differ. Authorization runs before an admitted request opens a connection.

### 4. A route table with exactly one class per route

Each route in `routes.json` has one class:

| Class | Meaning in this change |
|---|---|
| `nested` | Relayed to the nested engine |
| `unsupported` | Refused with the engine error shape and a reason |
| `native` | Reserved for later changes; no route uses it yet |

A route missing from the table fails the reference check, so a new reference release cannot add routes silently. A request that matches no route gets the engine's `page not found` error. Swarm, plugin and other routes that make no sense for a single nested engine may be classified `unsupported`; each needs a recorded reason.

### 5. The nested engine is a marked Incus instance from a host specification

The host supplies a specification: instance name, project, image source, profiles, and extra config and devices. The library adds what the engine needs (`security.nesting=true`) and the marker `user.opsmaru.containers.role=engine`. It does not choose a distribution or install packages; the image must already run dockerd. Macus has an appliance image pipeline for that, and central Opsmaru can use its own.

`Opsmaru.Containers.Nested.ensure/3` is explicit and idempotent: create if absent, start if stopped, then wait for readiness. The Plug never calls it. When the engine is not ready, the handler answers 503 with the engine error shape, and the host decides whether to ensure on first use or at boot.

A host serializes lifecycle mutations for the same backend, project and name, including concurrent callers from different nodes. After a definitive name conflict, ensure may read the winning instance, validate its marker and continue within the same deadline. After an unknown outcome it returns uncertainty and the accepted operation reference when available. The host reconciles that outcome before initiating another lifecycle mutation for the target. Unmarked instances are rejected. Stop and removal are host operations in this slice.

### 6. Qualify the engine transport

The engine listens on a Unix socket inside the instance. The candidate default transport runs `docker system dial-stdio` in the instance through a non-interactive Incus exec and treats its stdin and stdout channels as one byte stream to the engine. This is the helper the Docker CLI itself uses for `ssh://` hosts.

Alternatives considered:

- **Incus proxy device to a socket on the Incus host.** The library cannot dial a socket on the Incus host through the Incus API, so every host would need its own way in. For Macus that is a second path through the guest boundary.
- **Expose dockerd on the instance's network address.** Needs routing from the host to the instance network and TLS for dockerd, and is unreachable for a remote Incus target behind a gateway.

Exec needs only the connection the host already has, and behaves the same for Macus and for a remote target. Its costs are one exec operation per engine connection and a dependency on half-close working across the exec channels. The real-Incus transport spike must confirm half-close, independent requests, long idle streams, large payloads and cleanup after disconnect or partial setup. Incus stream time and byte limits are part of the host transport configuration. A brief read timeout and stderr are separate from stdout EOF. The stdio helper must have an independently verified termination path because closing local session channels alone does not cancel its remote operation.

The transport is a behaviour. The host-supplied dialer is the baseline during fixture implementation and remains the supported path if Incus exec fails qualification. The library still never dials anything the host did not supply.

The [2026-11-23 live run](../../../docs/docker-live-acceptance.md) exercised
the candidate through an authenticated Incus 7.0.1 gateway. The pinned stdio
helper closed both directions after receiving peer output EOF. The run also
observed a partial large upload and BuildKit teardown errors. Host-supplied
dialers remain the supported transport. The differential and pinned CLI
results apply to the tested workflows.

The follow-up qualification tested a replacement helper inside the
host-provided engine instance. The helper copies exec stdin to dockerd and
half-closes the dockerd socket's write side on stdin EOF. It sends bounded
data frames and an explicit output EOF frame on exec stdout. The host
adapter consumes those frames before passing Docker bytes to the relay.
The helper continued forwarding input after output EOF in the live
half-close test. Separate upload trials reproduced disconnects on the
direct path with both helpers. The [0.2.10 rerun](../../../docs/docker-live-acceptance.md#exec-qualification-rerun-on-opsmaru_incus-0210)
qualified the replacement helper for the tested gateway and fixture.
The intermittent stdin write stall remains open. The supported library
entry point continues to use the dialer supplied by the host.

### 7. Relay, do not interpret

For `nested` routes the handler forwards method, path, query, headers and body, and returns status, headers and body as the engine sent them. It handles hop-by-hop headers, transfer framing, version caps and mapped bind sources as specified. Preserve end-to-end headers, including repeated values. The relay carries the negotiated upgrade headers across the handshake and preserves raw bytes already read by either side. Hijacked and upgraded connections (`attach`, `exec/start`, `/session`, `/grpc`) are relayed in both directions with half-close preserved.

Each client request uses its own engine connection for its whole life. There is no multiplexing and no pool in this change, so one stalled stream cannot block another inside the library. Whether the host's path to Incus keeps streams independent is the host's responsibility, and Macus consumer acceptance measures it.

Backpressure follows the sockets: the relay reads from one side only as fast as the other side accepts, with a bounded buffer.

### 8. Never replay a possibly accepted mutation

If the engine connection fails after any request byte was sent on a non-GET/HEAD request, the handler reports an error without retrying. Before the downstream response is committed it can send a Docker-shaped 502. After HTTP headers or raw handshake bytes are committed it terminates the stream. A failure before any byte was sent may be reported as the engine being unavailable. GET and HEAD are not retried either in this change; there is no need yet.

### 9. Bind mounts need a host decision

`POST /containers/create` can name bind mount sources in `HostConfig.Binds` and in `HostConfig.Mounts` entries of type `bind`. Those paths are the client's, not the engine instance's. Relaying them unchanged would make dockerd create an empty directory inside the instance and start the container with the wrong content, without an error.

So the handler extracts each bind source and calls `map_bind_source/2`. The host returns the path as the engine instance sees it, or denies. Without the callback, a create that names any bind source is refused with a 400 engine error before the engine is contacted. Ordinary named volumes and tmpfs mounts pass unchanged. Reject custom volume-driver options on volume creation and inline volume mounts, including local-driver bind-backed named volumes, before backend access. Existing volumes are part of the host-provisioned engine trust domain. Compare JSON values outside changed sources and preserve bytes for bodies requiring no rewrite.

Making a host directory visible inside the engine instance (for Macus, a shared directory attached as an Incus disk device) is host work.

### 10. Evidence levels

`priv/docker/coverage.json` records evidence per route:

- **Fixture:** the handler against a scripted engine connection.
- **Differential:** the same request sent to equivalent starting state on real pinned dockerd directly and through the library. Compare status, relevant headers and body or stream framing, with explicit normalizers for volatile fields and separate assertions for intentional proxy behavior. Needs an explicit opt-in and an isolated Incus project.
- **Real Incus:** the pinned image and selected transport against isolated Incus v7.0.1, including cleanup and concurrency.
- **Consumer:** acceptance run by the host, such as Macus on hardware.

A `nested` route with differential evidence is verified as passthrough. That never counts as evidence for a later `native` implementation of the same route.

## Risks / Trade-offs

- **Exec as a transport may be slow or lose half-close.** The listener and backend spikes run independently before qualifying the combined path. If it fails, the fallback is a host-supplied dialer as the only transport, which moves work to each host.
- **One exec per connection adds latency to short requests.** Accepted for now; a keep-alive pool is a later change with its own safety rules.
- **Containers in the nested engine are invisible to Incus tooling.** That is the reason for the later native engine, and the README says so.
- **The engine image is the host's.** Readiness requires an API range that overlaps the reference. Qualification uses the exact pinned engine.
- **Docker socket access is root on the engine instance, and nesting weakens isolation.** The host authorizes every request, and the documentation states that the engine instance is one trust domain.

## Open Questions

- Whether the chosen host listener and Incus exec transport preserve the handshakes and stream lifetimes required by the pinned clients. The transport gates in the task list own this decision. Host callbacks authorize access within one engine trust domain.

## Follow-up Changes

1. Native engine for container lifecycle, exec and logs on Incus OCI application containers.
2. A shared image store, so an image built by the nested engine can run natively.
3. Published-port reporting to the host and native networks and volumes.
4. A libpod frontend, if the `podman` CLI is a target.
