# Proposal

## Why

Containers started through the nested engine are dockerd's containers inside one Incus system container. Incus sees only the engine instance: `incus list` cannot show, limit, snapshot or audit what a developer started with `docker run`, and every container shares the nested engine's trust domain. The foundation change named the fix as its first follow-up: a native engine on Incus OCI application containers that takes over routes one at a time.

Docker's image work (pull, build, tag, push, BuildKit) has no Incus equivalent, and the nested engine already does it well. Running a container does map onto Incus: an OCI application container with limits, disk devices and a network. This change translates only the running part and leaves images and builds where they are.

The first qualification spike (2026-11-27) showed that Incus 7.0.1 cannot carry three things Docker needs:

- **Exact argv:** `oci.entrypoint` alters some arguments.
- **Exit status:** none is recorded.
- **Logs:** the console log mixes stdout and stderr, has no timestamps, and is cleared on restart.

So this change puts a small library-supplied init shim in each native container to do those three things.

## What Changes

- **Native containers.** A container that the host chooses to run natively is created as an Incus OCI application container in a host-specified native project, through `opsmaru_incus`. `incus list --project <native>` shows it, with its Docker ID and name on `user.opsmaru.containers.*` keys.
- **An init shim in every native container.**
  - The library ships the source of a static Go shim, with a reproducible build recipe and pinned digests, as it does for the exec bridge helper. The host builds and supplies the binaries. The library refuses binaries whose digest it does not list.
  - The library pushes the shim and a process spec into `/.opsmaru` in each new container and makes the shim the entrypoint.
  - The shim starts the exact argv as the requested user, and forwards stop signals. It records each run's exit status. It writes stdout and stderr as separate, timestamped, rotated log records that survive restarts.
  - Its `exec`, `kill` and `stop` modes give Docker exec, signals and stop their exact behaviour.
- **The nested engine stays the image store.**
  - Pull, build, tag, push, image listing and BuildKit sessions keep going to dockerd.
  - On a native container's first use of an image, the library exports that exact image from dockerd. It converts the image in the engine instance with skopeo and umoci, and uploads it to Incus once, marked with the Docker image ID.
  - Native containers never pull from a registry on their own.
- **Engine choice is per container, at create.** A new optional host callback chooses `nested` or `native` for each `POST /containers/create`. The default is `nested`, so existing hosts see no change. A request routed to native that uses a field native cannot honour is refused with a Docker-shaped error that names the field. There is no silent fallback to nested.
- **Per-container routing.** Every container-scoped route (`/containers/{id}/…`, `/exec/{id}/…`) is resolved to the engine that owns that container. Native containers get translated responses. Container listing merges both engines.
- **A checked translation table.** Every `containers/create` field has one recorded class: translated, ignored with a reason, or refused. Unknown fields with non-default values are refused. Container routes record whether they are translated or refused for native containers. Behaviour that differs from a nested container is listed with the table. For example, native containers always run under an init, as with `--init`.
- **Two qualification spikes before translation.**
  - The first, recorded, qualified Incus itself.
  - The second qualifies the shim: exact argv, exit status, log capture and follow, signals, process setup and push.
  - If the shim cannot carry exact argv or record exit status, the change returns to planning.
  - **The second spike passed (2026-11-27).** Both gates and every other item qualified on arm64; amd64 was not run. Implementation (tasks 3 to 7) may start.

Not in this change:

- Native image pull, build or push, and a single image store shared without copies.
- Published ports (`-p`), user-defined networks, named volumes, and native `docker events`. Those are follow-up 3 of the foundation change.
- Stdin attach and TTY for the main process (`docker run -i`, `-it`). TTY and stdin for `docker exec` are included.
- `docker cp` (`/archive`), `export`, `changes`, `top`, `stats` and `update` for native containers. They are refused with a Docker-shaped error naming the native engine.
- Restart policies other than `no`, privileged containers, added capabilities, devices and host networking.
- Any Macus code. Macus chooses native containers through the new callback, and builds the shim, in its own change.

## Capabilities

### New Capabilities

- `native-engine`: native container placement, identity and metadata, the init shim, image handoff, create translation, lifecycle, wait, logs, attach and exec on Incus OCI application containers, and their evidence.

### Modified Capabilities

- `docker-engine-api`: an optional engine-selection host callback, per-container engine routing, merged container listing and name uniqueness across engines.

## Impact

- **New modules** under `Opsmaru.Containers.Native` (placement, resolver, image handoff, create translation, shim files, lifecycle, exec, logs).
- **New files:** a translation table in `priv/docker/native-create.json`, and the shim's source in `priv/native_init/` with `mise run check:init`.
- **Changed:**
  - `Opsmaru.Containers.Host` (optional `select_engine/2`);
  - `Nested.Target` or a sibling target carrying the native project and shim binaries;
  - admission and route dispatch (per-container resolution);
  - `priv/docker/routes.json` (a `native` field on container routes) and the evidence ledger.
- **Dependencies:** `opsmaru_incus ~> 0.2.10` stays the only route to Incus. Native containers use its instance, exec, files, SFTP, events and split image upload. The Incus server needs `instance_oci`. The engine image needs skopeo and umoci.
- **Hosts** opt in per container. Hosts that never implement `select_engine/2` keep today's behaviour exactly. Hosts that do opt in build the shim for each guest architecture. They also choose the native project's root size and network.
- **Evidence:** fixture, real-Incus and consumer evidence per native route. A native route also needs a differential case that runs the same workflow against nested and native containers and compares results. Nested passthrough evidence never counts for a native route.
