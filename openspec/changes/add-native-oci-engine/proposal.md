# Proposal

## Why

Containers started through the nested engine are dockerd's containers inside one Incus system container. Incus sees only the engine instance: `incus list` cannot show, limit, snapshot or audit what a developer started with `docker run`, and every container shares the nested engine's trust domain. The foundation change named the fix as its first follow-up: a native engine on Incus OCI application containers that takes over routes one at a time.

Docker's image work (pull, build, tag, push, BuildKit) has no Incus equivalent, and the nested engine already does it well. Running a container does map onto Incus: an OCI application container with an entrypoint, environment, working directory, user, limits, disk devices and a network. This change translates only the running part and leaves images and builds where they are.

## What Changes

- **Native containers.** A container that the host chooses to run natively is created as an Incus OCI application container in a host-specified native project, through `opsmaru_incus`. `incus list --project <native>` shows it, with its Docker ID and name on `user.opsmaru.containers.*` keys.
- **The nested engine stays the image store.** Pull, build, tag, push, image listing and BuildKit sessions keep going to dockerd. A native create resolves its image in the nested engine and hands that exact image (by image ID) to Incus once, caching it as an Incus image marked with the Docker image ID. Native containers never pull from a registry on their own.
- **Engine choice is per container, at create.** A new optional host callback chooses `nested` or `native` for each `POST /containers/create`. The default is `nested`, so existing hosts see no change. A request routed to native that uses a field native cannot honour is refused with a Docker-shaped error that names the field. There is no silent fallback to nested.
- **Per-container routing.** Every container-scoped route (`/containers/{id}/…`, `/exec/{id}/…`) is resolved to the engine that owns that container. Native containers get translated responses. Container listing merges both engines.
- **A checked translation table.** Every `containers/create` field has one recorded class: translated to an Incus key or device, ignored with a reason, or refused. Unknown fields with non-default values are refused. Container routes record whether they are translated or refused for native containers.
- **Qualification before translation.** A spike against Incus 7.0.1 settles what the docs leave open: the entrypoint format, whether the entrypoint's exit status is observable, how its output is captured, stop signals, freeze, exec half-close, and how an image moves from dockerd to Incus. If the exit status cannot be observed, `docker run` and `docker wait` cannot report exit codes, and this change returns to planning.

- **Back in planning (2026-11-27).** The task 1 spike found that Incus 7.0.1 does not record the entrypoint's exit status. It also found that `oci.entrypoint` does not carry arbitrary argv exactly, and that the console log cannot serve `docker logs`. Image handoff by export, convert and upload works. The spike also tested the pieces a packaged init shim would need, and they work. A revised design chooses that next. See [the spike report](../../../docs/native-oci-spike.md).

Not in this change:

- Native image pull, build or push, and a single image store shared without copies.
- Published ports (`-p`), user-defined networks, named volumes, and native `docker events`. Those are follow-up 3 of the foundation change.
- `docker cp` (`/archive`), `export`, `changes`, `top`, `stats` and `update` for native containers. They are refused with a Docker-shaped error naming the native engine.
- Restart policies other than `no`, privileged containers, added capabilities, devices and host networking.
- Any Macus code. Macus chooses native containers through the new callback in its own change.

## Capabilities

### New Capabilities

- `native-engine`: native container placement, identity and metadata, image handoff, create translation, lifecycle, wait, logs, attach and exec on Incus OCI application containers, and their evidence.

### Modified Capabilities

- `docker-engine-api`: an optional engine-selection host callback, per-container engine routing, merged container listing and name uniqueness across engines.

## Impact

- **New modules** under `Opsmaru.Containers.Native` (placement, resolver, image handoff, create translation, lifecycle, exec, logs) and a translation table in `priv/docker/native-create.json`.
- **Changed:** `Opsmaru.Containers.Host` (optional `select_engine/2`), `Nested.Target` or a sibling target carrying the native project, admission and route dispatch (per-container resolution), `priv/docker/routes.json` (a `native` field on container routes) and the evidence ledger.
- **Dependencies:** `opsmaru_incus ~> 0.2.10` stays the only route to Incus. The Incus server needs `instance_oci` and skopeo, as Macus's guest already has.
- **Hosts** opt in per container. Hosts that never implement `select_engine/2` keep today's behaviour exactly.
- **Evidence:** fixture, real-Incus and consumer evidence per native route. A native route also needs a differential case that runs the same workflow against nested and native containers and compares results. Nested passthrough evidence never counts for a native route.
