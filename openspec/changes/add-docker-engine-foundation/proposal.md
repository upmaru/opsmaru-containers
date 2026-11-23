# Proposal

## Why

Developers and their tools expect a Docker socket. `docker`, `docker compose`, testcontainers and most CI tooling speak the Docker Engine HTTP API and find it through `DOCKER_HOST` or a docker context. Macus and central Opsmaru run workloads on Incus, which has no such API, so none of that tooling works against them today.

Incus can run OCI images as application containers, but it has no image build, and its model differs from Docker's in networking, image storage and lifecycle. Translating the whole Engine API to native Incus calls is a long tail of work. Running dockerd inside an Incus system container delegates Docker behavior to Docker and keeps its workloads within one Incus instance.

This change starts with the second and leaves room for the first. It adds a library that serves the Docker Engine API from a host's own listener and relays supported requests to dockerd inside an Incus system container. Provisioning uses `opsmaru_incus`. The host supplies the transport, with Incus exec as a candidate default pending qualification. The pinned engine also supplies a reference for later native endpoints.

## What Changes

- Add the library's passive-embedding contract: no application callback, no listener, no state, and an explicit host context on every call.
- Add an optional Plug handler for HTTP and a host-mounted raw HTTP/1.1 adapter for Docker hijacks. It implements Docker's version negotiation and error shape, asks the host to authorize each request, and classifies every route of a pinned Docker Engine reference release as nested or unsupported.
- Add the nested engine: an explicit, idempotent operation that creates or starts a marked Incus system container from a host-supplied specification, a readiness check against the engine inside it, and a transport that dials the engine through the host's Incus connection.
- Relay requests and responses unchanged, including hijacked and upgraded streams (attach, exec, BuildKit sessions) and long-lived responses (logs, events, build and pull progress), each on its own engine connection.
- Add one host decision for bind mounts: the host maps each container bind source path or denies it. Local-driver named volumes with custom mount options are refused in this slice. Without that decision, a container create that names a host path is refused before the engine sees it.
- Record evidence per route in a ledger: fixture checks, real-engine differential checks, real-Incus acceptance, and host-owned consumer acceptance.

Not in this change:

- Library operations for stopping or removing the engine instance.
- The native engine (Incus OCI application containers) and the per-route move to it.
- A shared image store between the nested and native engines.
- Podman's libpod API.
- Forwarding published ports to the host. Ports published by nested containers are reachable inside the engine instance's network only, and the host documents that.
- Any Macus code: the socket, the docker context, path sharing and the guest transport belong to `upmaru/macus`.

## Capabilities

### New Capabilities

- `embedded-library`: how hosts embed the library, what they must supply, and what the library never does on its own.
- `docker-engine-api`: the Docker Engine API surface the host mounts: negotiation, errors, authorization, routing, streams and bind-mount path decisions.
- `nested-engine`: the Incus system container that runs the real engine, its lifecycle, readiness, transport and relay fidelity.

## Impact

- New modules under `Opsmaru.Containers`: the host behaviour and context, `Opsmaru.Containers.Docker` (Plug handler, route table, negotiation, errors) and `Opsmaru.Containers.Nested` (specification, ensure, readiness, transport, relay).
- New optional dependencies `plug` and `cowboy`, and `jason`. `opsmaru_incus` stays the only route to Incus.
- Packaged reference data under `priv/docker`: the pinned Engine API route inventory and the evidence ledger.
- Macus must supply the listener, the host callbacks, an engine image with dockerd installed, and connections that do not stall each other for long-lived streams.
