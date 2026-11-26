# Design

## Context

See [proposal.md](proposal.md) and the foundation change [add-docker-engine-foundation](../add-docker-engine-foundation/design.md). Today every admitted request is relayed to dockerd in the nested engine instance. The route table classes each route `nested` or `unsupported`, and reserves `native`.

```
docker CLI / compose / testcontainers
        │  Docker Engine API, on the host's listener
        ▼
opsmaru_containers ── admission, route table, host callbacks
   ├─ images, build, pull, push, volumes, networks, system ──► nested engine (dockerd)
   └─ containers ── owner? ── nested ──► nested engine
                           └─ native ──► Incus OCI application containers
                                            (native project, via opsmaru_incus)
```

**What Incus 7.0 offers.** These are from the Incus documentation, read 2026-11-27. Items marked *open* are not stated there and are qualified in task 1.

- OCI application containers (`instance_oci`), created from an image whose source protocol is `oci`. OCI remotes must use HTTPS. The Incus server does the pull. Macus's guest installs skopeo for it.
- Instance keys for OCI containers: `oci.entrypoint` (overrides the image entrypoint, format *open*), `oci.cwd`, `oci.uid`, `oci.gid`, and `oci.dns.nameservers`, `oci.dns.search` and `oci.dns.domain`. None of them is live-updatable.
- `environment.*` keys, which apply at boot and during exec.
- Exec with numeric user and group, a working directory and environment. Incus does not read `/etc/passwd`.
- The console log, readable through the console API. Whether stdout and stderr are separate, and how to follow the log live, are *open*.
- `boot.autorestart`: up to 10 restarts in one minute after an unexpected exit. That is not any Docker restart policy.
- *Open:* whether the entrypoint's exit status is recorded, which signal a graceful stop sends, whether the entrypoint is PID 1, whether freeze works on OCI containers, whether DNS on a managed bridge resolves OCI instance names, and whether an image can be imported from a local source rather than an HTTPS registry.

`opsmaru_incus` already models OCI image sources, including a pinned registry certificate passed to the target (`Opsmaru.Incus.OCI`), plus instance create, state, exec, console, events and image upload.

## Goals / Non-Goals

**Goals:**

- `docker run`, `docker ps`, `docker inspect`, `docker logs`, `docker exec`, `docker stop`, `docker kill`, `docker wait`, `docker rename` and `docker rm` work on native containers with the pinned CLI, for the workflows the translation table supports.
- Native containers are ordinary Incus instances that Incus tooling can list, limit, snapshot and audit.
- Images and builds keep the nested engine's exact behaviour, with no second image model for clients.
- A host opts in per container. A host that never opts in sees no change.
- Never silently different: a request native cannot honour is refused and names what it cannot do.

**Non-Goals:**

- Native pull, build or push, or one shared image store without copies.
- Published ports, user-defined networks, named volumes and native `docker events` (foundation follow-up 3).
- Compose projects on native containers. Compose needs user networks and events, so a host should keep Compose on nested.
- Moving an existing container between engines.
- Interactive TTY containers (`docker run -it`) until task 1 qualifies console attach. Non-TTY attach and TTY exec are in scope.

## Decisions

### 1. The nested engine stays the image store

Pull, build, tag, push, image listing, image removal, BuildKit sessions, volumes, networks and system routes are unchanged and go to dockerd. A native container's image always comes from the nested engine:

1. `containers/create` routed to native reads `GET /images/{ref}/json` from the nested engine. A missing image gets dockerd's own `404 No such image`, so the CLI pulls through the nested engine and retries, as it does today.
2. The library looks in the native project for an Incus image whose property `opsmaru.containers.image_id` equals the Docker image ID.
3. If none exists, it hands the image over once (decision 2) and records that property.
4. The instance is created from that Incus image by fingerprint.

The process configuration (entrypoint, command, environment, working directory, user) is computed from the nested engine's image config plus the create body, following Docker's merge rules. It is written explicitly to `oci.*` and `environment.*` keys. So the result does not depend on how Incus converted the image's own config.

- **Why:** clients see one image list, one build cache and one registry login, as today. `docker build -t app . && docker run app` works with nothing new to learn.
- **Rejected: native pull straight from registries through Incus OCI remotes.** Images pulled that way are invisible to `docker images`, and Incus OCI remotes take a token, not Docker's `X-Registry-Auth`. It is a later optimisation for images the nested engine does not have.
- **Cost:** each image is stored twice, once in dockerd and once in Incus. `Native.prune_images/2` (host-invoked) removes Incus copies that no native instance uses. Removing an image from dockerd does not remove its Incus copy.

### 2. Image handoff is a qualified choice

Two candidates. Task 1.3 picks one, and the other stays recorded as rejected.

- **A. Registry in the engine instance.** The engine image also runs an OCI distribution registry bound to the engine instance's address, with HTTPS from a certificate the host supplies. The library pushes the image from dockerd into it, using the engine's own push, and creates the native instance from an `oci` source naming that registry, with the certificate pinned through `Opsmaru.Incus.OCI`. Incus does its own pull and conversion. The data never passes through the host.
- **B. Export and upload.** The library streams `GET /images/{id}/get` from dockerd and converts it inside the engine instance with a packaged helper, as the exec bridge helper is packaged. It then uploads the result through `POST /1.0/images`. The data passes through the host twice, and the conversion is the library's own code.

A is preferred if Incus 7.0.1 pulls from it reliably. It reuses Incus's conversion and keeps bulk data off the host path. Either way, the Incus image carries the Docker image ID, and the handoff is never replayed after an uncertain outcome: the library reads the native project for the image ID first.

### 3. Engine choice is a host decision at create

`Opsmaru.Containers.Host` gains an optional callback:

```elixir
@callback select_engine(Context.t(), create_request :: map()) :: :nested | :native
```

It runs during admission for `POST /containers/create` only, under the same deadline, and gets the classified request plus the decoded create body. Without the callback, or on a failing or late answer, the choice is `nested`.

`Opsmaru.Containers.Native.eligibility/1` returns `:ok` or the fields that native cannot honour, so a host can implement "native when eligible". When the host returns `native` for an ineligible request, the request is refused with a Docker-shaped 400 naming each field. It is never sent to nested instead.

- **Why the host decides:** the host knows its policy (a label, a per-project setting, a Compose project kept nested). An automatic fallback would put one `docker run` in a different engine than the next, with different visibility and isolation, without the user asking.

### 4. Native identity lives on the Incus instance

A native container is an Incus instance in the host-specified native project. That project is a field of the context target, separate from the nested engine's project. The library keeps no other state.

- **Docker ID:** 64 lowercase hex characters from a CSPRNG, generated at create.
- **Instance name:** `oc-` plus the first 12 hex characters of the ID. That meets Incus's name rules and stays readable in `incus list`. A name collision is a definitive conflict, and the library makes a new ID within the deadline.
- **Keys:** `user.opsmaru.containers.role=container`, `.id`, `.name` (the Docker name, `/` stripped), `.created`, `.image_id`, `.image_ref`, `.labels` (one JSON object, because Docker label keys are arbitrary) and `.config` (the normalised create body that inspect needs).
- **Ownership:** only instances with `role=container` in the native project are native containers. Other instances there are ignored by every route.

### 5. Per-container routing and listing

Container-scoped routes carry a container reference: a full ID, a unique ID prefix or a name. Admission resolves it in both engines: one list of the native project with recursion (filtered on the role key), and the nested engine's own lookup.

- Exactly one match routes to its engine.
- No match gets dockerd's `404 No such container`.
- A match in both is impossible for names (below), and for ID prefixes it gets Docker's ambiguous-reference error.

Exec IDs route the same way: a native exec ID is the container's exec record (decision 8).

`GET /containers/json` merges the nested response with translated native entries, applying `all`, `limit`, `size` and the filters `id`, `name`, `label`, `status` and `ancestor`. Any other filter is refused with a Docker-shaped 400 when the native project has containers, so filtering is never silently partial. `POST /containers/prune` prunes both engines and sums the results.

**Name uniqueness across engines.** A create with a name checks both engines before creating. The host serializes container creates per target, as it serializes engine lifecycle mutations, so the check and the create cannot interleave with another create from the same host. A nested create also checks the native project first.

### 6. A checked translation table for create

`priv/docker/native-create.json` lists every field of `ContainerConfig`, `HostConfig` and `NetworkingConfig` in the pinned API description, with one class:

- `translated`: the Incus key or device it becomes
- `ignored`: accepted with no effect, with a reason
- `refused`: rejected when set to a non-default value, with a reason

A check fails when a field is missing from the table, so a new reference release cannot add fields silently. Initial classes, subject to task 1:

| Docker field | Native translation |
| --- | --- |
| `Image` | decision 1 |
| `Entrypoint`, `Cmd` | merged with the image config, written to `oci.entrypoint` in the format task 1.1 qualifies |
| `Env` | merged with the image environment, written to `environment.*` |
| `WorkingDir` | `oci.cwd` |
| `User` | `oci.uid` and `oci.gid` when numeric. Names are refused, because Incus does not read `/etc/passwd` |
| `Labels` | `user.opsmaru.containers.labels` |
| `HostConfig.Binds`, `Mounts` of type `bind` | each source mapped by `map_bind_source/2`, then an Incus `disk` device with `path` and `readonly`. Without the callback, refused as today |
| `HostConfig.Memory` | `limits.memory` |
| `HostConfig.NanoCpus`, `CpuQuota`/`CpuPeriod` | `limits.cpu.allowance` |
| `HostConfig.CpusetCpus` | `limits.cpu` |
| `HostConfig.PidsLimit` | `limits.processes` |
| `HostConfig.Dns`, `DnsSearch` | `oci.dns.nameservers`, `oci.dns.search` |
| `HostConfig.NetworkMode` | `default` or `bridge`: the native project's default network. `none`: no `nic` device. Others refused |
| `HostConfig.AutoRemove` | `.autoremove` key, honoured by wait and reap (decision 7) |
| `HostConfig.RestartPolicy` | `no` only. Others refused, because `boot.autorestart` is not a Docker policy |
| `Tty`, `OpenStdin`, `AttachStdin` | refused until task 1.4 qualifies console attach |
| `ExposedPorts` | ignored: image metadata only, nothing is published |
| `HostConfig.PortBindings`, `PublishAllPorts` | refused (follow-up 3) |
| `Hostname`, `Domainname` | refused when set. The default hostname is the instance name, not the short ID |
| `HostConfig.Privileged`, `CapAdd`, `Devices`, `SecurityOpt`, `ExtraHosts`, `Init`, volume mounts, `VolumesFrom`, `Links` | refused |

Translation happens before any Incus mutation. A refused field never leaves a half-created instance.

### 7. Lifecycle, wait and auto-remove

| Route | Native behaviour |
| --- | --- |
| `POST /containers/{id}/start` | Incus state `start` |
| `POST /containers/{id}/stop?t=` | Incus state `stop` with that timeout, then forced. The graceful signal is what task 1.5 finds. `StopSignal` is refused unless it matches |
| `POST /containers/{id}/kill?signal=` | `SIGKILL` (the default): forced stop. Other signals go to PID 1 through exec `kill`, only if task 1.5 confirms the entrypoint is PID 1. Otherwise refused |
| `POST /containers/{id}/restart` | stop then start, with the same rules |
| `POST /containers/{id}/pause`, `unpause` | Incus `freeze` and `unfreeze` if task 1.6 confirms them on OCI containers. Otherwise refused |
| `POST /containers/{id}/rename` | rewrites `.name`. The instance name stays |
| `DELETE /containers/{id}?force=` | stop (forced when `force`), then delete. A running container without `force` gets dockerd's conflict error |
| `GET /containers/{id}/json` | synthesised from the instance, its state and `.config`, in the pinned API's shape |
| `POST /containers/{id}/wait?condition=` | decision below |

**Wait.** The library watches Incus lifecycle events for the instance, with a fresh state read after subscribing so a stop between the two is not missed. It answers `{"StatusCode": N}` once the entrypoint has exited. `condition=next-exit`, `not-running` and `removed` follow Docker's meanings. The exit status must come from Incus. If task 1.2 finds that Incus does not expose it, wait cannot be honest, and this change returns to planning rather than report 0.

**Auto-remove.** The library starts no processes, so nothing watches containers in the background. For an `AutoRemove` container, a `wait` with `condition=removed` (which the CLI sends for `--rm`) deletes the stopped instance before it answers. `Native.reap/2`, which the host calls on its own schedule, deletes stopped `AutoRemove` instances that no wait removed, for example after a client disconnect.

### 8. Exec

`POST /containers/{id}/exec` validates the request: `User` must be numeric, and `Privileged` is refused. It stores the request as `user.opsmaru.containers.exec.<exec-id>` on the instance, and returns the exec ID (64 hex). `POST /exec/{id}/start` runs it with Incus exec:

- **Without TTY:** stdout and stderr arrive on separate Incus channels. The library frames them as Docker's multiplexed raw stream (8-byte headers) on the hijacked connection. Client write EOF closes Incus stdin, and output keeps flowing until both Incus output channels end. Task 1.7 qualifies that.
- **With TTY:** an interactive Incus exec. The raw stream is unframed, and `POST /exec/{id}/resize` maps to the Incus control channel.
- **Detached** (`Detach: true`): the Incus exec runs without attached channels, and start answers as dockerd does.
- **Afterwards:** the exit code from the Incus operation is written back to the exec record, so `GET /exec/{id}/json` reports `Running` and `ExitCode`. Exec records older than the newest 32 on an instance are deleted when a new one is created.

### 9. Logs and attach

- **Logs:** `GET /containers/{id}/logs` reads the Incus console log. Task 1.4 decides what it can carry. If stdout and stderr arrive mixed, native logs report everything as stdout, and `stderr=1&stdout=0` is refused rather than returning nothing. `timestamps`, `since` and `until` are refused unless Incus records times. `follow=1` is served only if task 1.4 finds a way to follow the log without taking over the console. Otherwise it is refused. Every refusal names the native engine.
- **Attach:** non-TTY `POST /containers/{id}/attach` with `stream=1` and output only (what `docker run` without `-i` uses) streams the same source as `follow`. Stdin attach waits for task 1.4.

### 10. Route table and evidence

The foundation's `native` class assumed whole routes would move. Container routes instead serve both engines, chosen per container. So container-scoped routes keep class `nested` and gain a `native` field: `translated` or `refused` with a reason. Admission uses it only when the container resolves to native. A route moves to class `native` only when nested no longer serves it at all, which this change does not do.

Evidence for a native route needs:

- **Fixture:** translation against a scripted Incus backend.
- **Real Incus:** the workflow against isolated Incus 7.0.1 with `instance_oci`.
- **Differential:** the same pinned CLI workflow against a nested container and a native container from the same image. Compare exit codes, output and the fields the translation table marks `translated`, with normalisers for IDs, timestamps and addresses.
- **Consumer:** host acceptance.

## Risks / Trade-offs

- **[Exit status]** → If Incus does not record the entrypoint's exit status, native `wait` and `docker run` exit codes are impossible. Task 1.2 is a gate, and failing it returns this change to planning.
- **[Output capture]** → The console log may mix stdout and stderr, carry no timestamps, or be followable only by taking the console. Native logs then do less than Docker's, and every gap is a named refusal, not missing output.
- **[Double image storage]** → Every image a native container uses is stored in dockerd and in Incus. `prune_images/2` bounds it. A shared store is follow-up work.
- **[Two engines, one namespace]** → Names and ID prefixes must stay unique across engines. Host-serialized creates make that safe for one host. Two hosts on one target need the same serialization they already need for lifecycle mutations.
- **[Translation drift]** → A new Docker release can add create fields. The table check fails on unknown fields, and unknown non-default values are refused.
- **[Incus key limits]** → `oci.*` keys are not live-updatable, so `docker update` stays refused for native containers.
- **[Larger trust boundary for the host]** → Native containers are full Incus instances in a host-chosen project. The host's authorization and its project configuration (profiles, limits, network) bound what a Docker client can create there.

## Open Questions

Task 1 owns these: the entrypoint format, exit status, output capture and follow, console attach, stop signal and PID 1, freeze, DNS by instance name, and the image handoff choice.
