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
                                            entrypoint: /.opsmaru/init ──► the Docker process
```

### What Incus 7.0.1 does, measured

The first qualification spike ([report](../../../docs/native-oci-spike.md), 2026-11-27) settled what the documentation left open. The first design depended on Incus for argv, exit status and logs, and failed on all three:

| Need | Incus 7.0.1 |
| --- | --- |
| Exact argv | `oci.entrypoint` is one shell-like string. Some arguments containing `$ \ \| [ * ~ '` gain backslashes. |
| Exit status | Not recorded. Exits 0, 3 and 137 leave the same state, config, events and `lxc.log`. |
| Logs | The console log merges stdout and stderr, has no timestamps, is empty or partial while running, and is cleared on restart. |
| Graceful stop | SIGTERM to the entrypoint, which is PID 4 under `{incusd} init` (PID 1). |
| Freeze, exec, DNS by instance name, `NetworkMode=none` | Work. Exec has separate streams, stdin EOF, exit codes, numeric user and group, cwd, env and TTY. |
| Files | The files API can push into a created, never-started OCI container, and read from a stopped one. A file pushed that way ran as the entrypoint on first start. |
| Image handoff | Export from dockerd, convert with skopeo and umoci in the engine, and upload as a split image: works. An `oci` source with a pinned registry certificate: fails, because Incus runs `skopeo inspect` without the certificate. |
| Storage | With `volume.zfs.reserve_space=true`, each instance reserves its full root size up front. |

### What changes in this design

The library supplies the container's entrypoint: a small static **init shim**, built and released like the exec bridge helper. It runs as PID 4 in place of the Docker process and does what Incus does not:

- It starts the exact argv from a file.
- It records the exit status.
- It writes stdout and stderr as separate, timestamped log records that survive restarts.

Incus still provides the container, its lifecycle, limits, network, freeze and exec. The library reads what the shim wrote through `opsmaru_incus`'s files API and SFTP session, which reads files at an offset.

The second spike (task 2, 2026-11-27) qualified the shim against the same Incus 7.0.1 runtime and passed both gates. See the [spike report](../../../docs/native-oci-spike.md). Its findings are folded into decisions 6, 8, 9, 13 and 14 below.

## Goals / Non-Goals

**Goals:**

- `docker run` (with and without `-d` and `--rm`), `ps`, `inspect`, `logs` (with `-f`, `-t`, `--since`, `--until` and `--tail`), `exec` (with `-i` and `-t`), `stop`, `kill` (with any signal), `pause`, `unpause`, `wait`, `restart`, `rename` and `rm` work on native containers with the pinned CLI. They report the exit codes and output a nested container would, except for the differences recorded in decision 12.
- Native containers are ordinary Incus instances that Incus tooling can list, limit, snapshot and audit.
- Images and builds keep the nested engine's exact behaviour, with no second image model for clients.
- A host opts in per container. A host that never opts in sees no change.
- Never silently different: a request native cannot honour is refused and names what it cannot do.

**Non-Goals:**

- Native pull, build or push, or one shared image store without copies.
- Published ports, user-defined networks, named volumes and native `docker events` (foundation follow-up 3).
- Compose projects on native containers. Compose needs user networks and events, so a host should keep Compose on nested.
- Moving an existing container between engines.
- Stdin attach and TTY for the main process (`docker run -i`, `-it`, `docker attach` with stdin). The shim's design leaves room for an attach socket in a follow-up. TTY and stdin for exec are in scope.
- Restart policies other than `no`. The shim could restart its child later, but this change does not.

## Decisions

### 1. The nested engine stays the image store

Pull, build, tag, push, image listing, image removal, BuildKit sessions, volumes, networks and system routes are unchanged and go to dockerd. A native container's image always comes from the nested engine:

1. `containers/create` routed to native reads `GET /images/{ref}/json` from the nested engine. A missing image gets dockerd's own `404 No such image`, so the CLI pulls through the nested engine and retries, as it does today.
2. The library looks in the native project for an Incus image whose property `opsmaru.containers.image_id` equals the Docker image ID.
3. If none exists, it hands the image over once (decision 2) and records that property.
4. The instance is created from that Incus image by fingerprint.

The process configuration (argv, environment, working directory, user, groups, stop signal) is computed from the nested engine's image config plus the create body, following Docker's merge rules. It goes into the shim's spec (decision 5), not into `oci.*` keys. So the result does not depend on how Incus converted the image's own config.

- **Why:** clients see one image list, one build cache and one registry login, as today. `docker build -t app . && docker run app` works with nothing new to learn.
- **Rejected: native pull straight from registries through Incus OCI remotes.** Those images are invisible to `docker images`. Incus OCI remotes take a token, not Docker's `X-Registry-Auth`. Private registries also hit the certificate problem the spike found.
- **Cost:** each image is stored twice, once in dockerd and once in Incus. `Native.prune_images/2` (host-invoked) removes Incus copies that no native instance uses. Removing an image from dockerd does not remove its Incus copy.

### 2. Image handoff: export, convert in the engine, upload

The spike chose candidate B:

1. The library runs a fixed conversion through Incus exec in the engine instance:
   - `skopeo copy docker-daemon:<image-id> oci:<dir>:img`
   - `umoci unpack`
   - a `metadata.yaml` with `type: oci`, the image's architecture, and the property `opsmaru.containers.image_id`
   - a metadata tarball (`metadata.yaml` plus the bundle's `config.json`) and a gzip-1 rootfs tarball

   The work directory is under `/var/lib/opsmaru-containers/handoff/<image-id>` and is removed afterwards.
2. It streams both tarballs out of the engine through the files API and into `Opsmaru.Incus.Images.import/4` as a split upload, with no host files.
3. It reads the native project for the image ID before converting, and again after an uncertain upload. An uncertain handoff is never replayed blindly.

The engine image must include skopeo and umoci. The host installs them with dockerd, at versions it pins. The library checks for both before the first handoff and fails with a named error if either is missing. Handoffs of the same image ID are serialized per target. Measured cost: 2.0 s for 10 MiB and 31.1 s for 500 MiB, with the bytes crossing the host path twice.

- **Rejected: candidate A** (a registry in the engine as an `oci` source). Incus does not pass the pinned certificate to skopeo.
- **Rejected: a library-written converter.** skopeo and umoci are maintained converters. A Go converter could replace them later without changing the contract.

### 3. Engine choice is a host decision at create

`Opsmaru.Containers.Host` gains an optional callback:

```elixir
@callback select_engine(Context.t(), create_request :: map()) :: :nested | :native
```

It runs during admission for `POST /containers/create` only, under the same deadline. It gets the classified request with `:route`, and the decoded create body under `:body`. Without the callback, on a body that is not a JSON object, or on a failing or late answer, the choice is `nested`. Hosts without the callback pay nothing: the body is not decoded for them.

`Opsmaru.Containers.Native.eligibility/1` returns `:ok` or the fields that native cannot honour, so a host can implement "native when eligible". When the host returns `native` for an ineligible request, the request is refused with a Docker-shaped 400 naming each field. It is never sent to nested instead.

- **Why the host decides:** the host knows its policy (a label, a per-project setting, a Compose project kept nested). An automatic fallback would put one `docker run` in a different engine than the next, with different visibility and isolation, without the user asking.

### 4. The init shim

`priv/native_init/` holds the shim's Go source, unit tests and README, as `priv/exec_bridge/` does:

- The package ships source only. The host builds the binary with the pinned Go toolchain and recipe (static, `CGO_ENABLED=0`, `-trimpath`, no build ID).
- The README lists SHA-256 digests for linux/arm64 and linux/amd64.
- `mise run check:init` vets and tests it, then builds both architectures twice from clean caches and fails if the builds differ.

The host passes the binaries as `%{"aarch64" => path, "x86_64" => path}` to `Opsmaru.Containers.Native.Target.new/2`, with the native project's client. It reads each file once and checks its SHA-256 against the README's table, compiled into that library version. A mismatch, a relative path or a missing file is a configuration error. The result goes in the nested target's optional `native` field. Per-request validation then checks the recorded digests without reading the files again, and the bytes are hashed again when they are pushed. Pushing a binary the library does not know would make every exit status and log line untrustworthy. A create whose image architecture has no shim is refused with a named error.

**Modes.** One binary has four modes, chosen by its first argument. With no argument it runs as init.

| Mode | Invoked by | Does |
| --- | --- | --- |
| *(none)* | Incus, as `oci.entrypoint` | runs the container's process (decision 6) |
| `exec` | the library, through Incus exec | sets up user, groups, cwd and environment for a Docker exec, then `execve`s the command (decision 9) |
| `kill SIGNAL` | the library, through Incus exec | sends a signal to the current process |
| `stop TIMEOUT` | the library, through Incus exec | asks init to stop its process within a timeout |

**Files in the container.** All shim files live under `/.opsmaru`, which is root-owned and mode 0700:

| Path | Written by | Content |
| --- | --- | --- |
| `/.opsmaru/init` | the library, at create | the shim binary, 0755 |
| `/.opsmaru/spec.json` | the library, at create | the process spec (decision 5) |
| `/.opsmaru/state/run.json` | the shim | the current or last run record (decision 7) |
| `/.opsmaru/state/control.sock` | the shim | a Unix socket used by `kill` and `stop` |
| `/.opsmaru/logs/NNNNNNNNNN.log` | the shim | log records (decision 8) |

The instance is created with these keys, all fixed strings that the entrypoint parser leaves alone:

- `oci.entrypoint=/.opsmaru/init`
- `oci.uid=0` and `oci.gid=0`
- `oci.cwd=/`

The library pushes the files after create and before the first start. This is the order the spike confirmed. If the image already contains `/.opsmaru`, the create is refused with a named error and the instance is deleted. The instance records the shim's digest in `user.opsmaru.containers.init`. A container keeps its shim for life. Shim file formats carry a version, and a library release reads every format version its supported shims write.

**What the shim's output is worth.** Everything under `/.opsmaru` is written inside the container. A root process in the container can rewrite its own exit status and logs. The library therefore treats these files as untrusted:

- strict parsing, with size bounds on every file and record;
- a malformed file gives the route a Docker-shaped error naming the native engine, never a crash or a guess;
- nothing read there grants access or selects another container.

That is the same trust as the container's own output in Docker. A process that runs as a non-root `User` cannot reach `/.opsmaru`.

- **Why a shim and not Incus changes:** it works with Incus 7.0.1 as deployed, and the spike confirmed every Incus feature it relies on.
- **Rejected: a shared read-only custom volume holding the shim.** That would keep one copy and make it tamper-proof, but it adds a volume per shim version per project, and it was not qualified. Pushing about 2 MiB per container was qualified and costs little next to the root reservation.
- **Cost:** every native container runs a library-supplied process as PID 4, and its logs use the container's own disk.

### 5. The process spec

`/.opsmaru/spec.json`, version 1, is fully computed by the library at create:

```json
{
  "version": 1,
  "argv": ["/docker-entrypoint.sh", "nginx", "-g", "daemon off;"],
  "env": ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "NGINX_VERSION=1.29.3"],
  "cwd": "/",
  "user": "nginx",
  "group_add": [],
  "hostname": "3f1c0a9b2d4e",
  "stop_signal": "SIGQUIT",
  "log": {"driver": "local", "max_size": 20971520, "max_files": 5}
}
```

- `argv` is Docker's `Entrypoint` followed by `Cmd`, after the image-config merge. Each string is carried exactly, so arguments that `oci.entrypoint` would alter arrive unchanged.
- `env` is the merged image and create environment. The shim adds Docker's defaults where unset: `PATH`, `HOSTNAME`, and `HOME` from the user's passwd entry.
- `user` is Docker's `User`, as a name or number, with an optional group. The shim resolves names from the container's `/etc/passwd` and `/etc/group`, as runc does, and sets the supplementary groups plus `group_add`. Names therefore translate, which the first design had to refuse.
- `argv[0]` is resolved against the child's `PATH`, as Docker does.

### 6. Init: starting and running the process

As init, the shim:

1. Reads and validates the spec.
2. Opens the next run (decision 7).
3. Sets the hostname to `hostname` (the container's UTS namespace allows it).
4. Becomes a child subreaper.
5. Starts the child with stdout and stderr on pipes, and stdin on `/dev/null`.

It detects whether `execve` succeeded through a close-on-exec pipe. A failed `execve` is recorded as Docker records it: exit 127 for not found and 126 for not executable, with the message as the run's `error`.

While the child runs, the shim:

- copies its output into log records;
- reaps orphaned descendants;
- serves `kill` and `stop` requests on the control socket;
- on SIGTERM from Incus (a graceful `incus stop`), sends the spec's `stop_signal` to the child.

A graceful `incus stop` is not Docker's stop. The spike showed that Incus sends SIGTERM to every process in the container, not only to the entrypoint. A child that traps both signals saw SIGTERM from Incus and the stop signal from the shim. Docker's stop therefore always goes through `init stop` (decision 13). An administrator's `incus stop` behaves as Incus documents it.

When the child exits, the shim drains the pipes, writes the exit record, and exits. Incus then stops the instance, as it does when any entrypoint exits.

### 7. Run records and exit status

`/.opsmaru/state/run.json` is replaced atomically: written to a temporary file, synced, then renamed.

```json
{"version": 1, "run": 3, "pid": 5, "started_at": "2026-11-27T10:00:00.123456789Z",
 "finished_at": "2026-11-27T10:00:04.5Z", "exit_code": 3, "signal": null,
 "oom_killed": false, "error": null}
```

- `run` increases with each start of the container. Log records carry it, so attach and wait can tell one run from the next. `RestartCount` stays 0, because no restart policy runs.
- It is written once when the child has started (or failed to start), and again with `finished_at` and `exit_code` when it exits.
- A child killed by a signal gets `exit_code` 128 plus the signal number, and `signal` set.
- `oom_killed` compares the cgroup's `memory.events` `oom_kill` count before and after the run. Task 2.7 confirmed that this is visible inside the container.

**No exit record.** If the instance stops while the record has no `finished_at`, the shim was killed before it could write one. That happens on a forced stop after the timeout, an administrator's `incus stop --force`, or a crash. The library reports exit code 137 (Docker's SIGKILL code), the finish time of the instance's `instance-shutdown` event, and `State.Error` = `native: exit status not recorded`. Docker reports 137 when a container is killed, so the code is accurate in the cases the library causes. The error string says it was inferred.

### 8. Log records

The shim writes stdout and stderr to numbered files `/.opsmaru/logs/0000000001.log`, `0000000002.log`, and so on. Files are never renamed. The shim starts the next file when the current one passes `max_size`, and deletes the oldest when more than `max_files` exist. Each file starts with the magic `OCL1`, then holds records:

| Field | Size | Meaning |
| --- | --- | --- |
| stream | 1 byte | 1 stdout, 2 stderr |
| flags | 1 byte | bit 0: partial (no trailing newline) |
| run | 4 bytes, big-endian | the run that wrote it |
| time | 8 bytes, big-endian | nanoseconds since the Unix epoch, taken when the bytes were read |
| length | 4 bytes, big-endian | 1 to 16,384 |
| data | length bytes | the output, exactly |

Records split output at newlines and at 16 KiB. Bytes with no newline are flushed as a partial record after 100 ms or at exit. Records from both streams go into one file in the order the shim read them, so their relative order is kept.

**Reading.** The library reads records through an `opsmaru_incus` SFTP session on the instance: list `/.opsmaru/logs`, then positioned reads from a file and offset. A reader's position is the pair (file number, offset), so rotation never invalidates it. A position older than the oldest kept file continues from the oldest. That is the record loss rotation implies, as in Docker's own drivers. The spike saw it once, with a 64 KiB × 3 rotation and a 160 KB burst against a 250 ms poll.

SFTP sessions follow three rules the spike established:

- **A session ends when the instance stops under it.** The next request fails with a deadline or channel error. The reader opens a new session, retrying every 200 ms while the instance is stopping. That took about 86–300 ms in the spike.
- **A session on a stopped instance holds up its start.** A start made while one was open did not return until the session closed (about 55 s, when the probe was killed). Reads of a stopped instance therefore open a session, read, and close it. The library never keeps a session on a stopped instance, and it closes its own sessions on an instance before starting it.
- **SFTP works on stopped and frozen instances.** A 100 MiB log read at about 32 MiB/s.

**Driver.** `HostConfig.LogConfig.Type` must be empty, `json-file`, `local` or `none`. The first three use the shim's files, with Docker's `max-size` and `max-file` options translated. Without options, the host's configured default applies, and the library's default is 20 MiB × 5, as Docker's `local` driver. `none` discards output, and `docker logs` then gets Docker's own "configured logging driver does not support reading" error. Other drivers are refused.

### 9. Exec

`POST /containers/{id}/exec` validates the request (`Privileged` is refused) and stores it as `user.opsmaru.containers.exec.<exec-id>` on the instance. It returns a 64-hex exec ID. `POST /exec/{id}/start` runs an Incus exec as root of:

```
/.opsmaru/init exec --user U --cwd D -- ARGV...
```

The command array passes through the exec API exactly. Only the exec's own `Env` goes in the Incus exec `environment` field, plus `OPSMARU_EXEC_ENV` (a JSON array of its names, in order) and `OPSMARU_EXEC_UNSET` (names that a Docker `Env` entry without `=` removes). The container's environment is already in the spec. In `exec` mode the shim:

1. takes only the variables named in `OPSMARU_EXEC_ENV`. That drops the ones Incus adds itself, which the spike listed: `HOME`, `LANG`, `PATH`, `TERM`, `USER`, `container` and `CREDENTIALS_DIRECTORY`;
2. builds the environment as for the main process (decision 5): Docker's base, then the spec's `env`, then the exec's variables, then `HOME`;
3. resolves `U` (default: the spec's user) from the container's passwd and group files, with the spec's `group_add`;
4. changes to `D` (default: the spec's working directory);
5. `execve`s. No shim process stays behind, so the exit code and TTY are the command's own.

The library adds `TERM=xterm` for a TTY exec when the exec does not set it, as dockerd does.

Docker's exec user defaults to the container's user. Exec channels are as the spike qualified:

- **Without TTY:** stdout and stderr arrive on separate Incus channels. The library frames them as Docker's multiplexed raw stream. Client write EOF closes Incus stdin, and output keeps flowing until both channels end.
- **With TTY:** the stream is unframed, and `POST /exec/{id}/resize` maps to the Incus control channel.
- **Detached** (`Detach: true`): the exec runs without attached channels.
- **Afterwards:** the exit code is written back to the exec record, so `GET /exec/{id}/json` reports `Running` and `ExitCode`. Exec records older than the newest 32 on an instance are deleted when a new one is created.

### 10. Native identity lives on the Incus instance

A native container is an Incus instance in the host-specified native project. That project is a field of the context target, separate from the nested engine's project. The library keeps no other state.

- **Docker ID:** 64 lowercase hex characters from a CSPRNG, generated at create.
- **Instance name:** `oc-` plus the first 12 hex characters of the ID. A name collision is a definitive conflict, and the library makes a new ID within the deadline.
- **Keys:**
  - `user.opsmaru.containers.role=container`, `.id`, `.name` (the Docker name, `/` stripped) and `.created`;
  - `.image_id` and `.image_ref`;
  - `.labels` (one JSON object, because Docker label keys are arbitrary);
  - `.config` (the normalised create body that inspect needs);
  - `.init` (the shim digest) and `.autoremove`.
- **Ownership:** only instances with `role=container` in the native project are native containers. Other instances there are ignored by every route.
- **Root size:** the library sets none. The host's native project profile chooses it. On ZFS with `reserve_space`, that reservation is per container, so a small root size or a different pool policy is the host's responsibility, documented in `docs/embedding.md`.

### 11. Per-container routing and listing

Container-scoped routes carry a container reference: a full ID, a unique ID prefix or a name. After admission, both adapters resolve it with one list of the native project (filtered on the role key), in Docker's order: full ID, then name, then unique ID prefix. A native full ID or name is final, because IDs are random and names are unique across engines. Only a native prefix match asks the nested engine, where an exact match wins.

- Exactly one match routes to its engine.
- No match gets dockerd's `404 No such container`.
- A name cannot match in both engines (below). An ID prefix that matches in both gets Docker's ambiguous-reference error.

Exec IDs route the same way: a native exec ID is an exec record on the container (decision 9).

`GET /containers/json` merges the nested response with translated native entries, applying `all`, `limit`, `size` and the filters `id`, `name`, `label`, `status`, `ancestor` and `exited`. Native status and exit codes come from run records. Any other filter is refused with a Docker-shaped 400 while the native project has containers, so filtering is never silently partial. `POST /containers/prune` prunes both engines and sums the results.

- **Nested answers first,** so it validates the query as dockerd does, and its errors reach the client unchanged. With no native containers, the request is relayed as before.
- **Listing differences:** native entries carry no `SizeRw` or `SizeRootFs`, and `ancestor` values are resolved to image IDs in the nested engine without matching descendant images. Prune's `SpaceReclaimed` counts only the nested engine.

**Name uniqueness across engines.** A create with a name checks both engines before creating. The host serializes container creates per target, as it serializes engine lifecycle mutations. So the check and the create cannot interleave with another create from the same host. A nested create, and a nested rename, also checks the native project first, with dockerd's own conflict message. A native name is checked against the nested engine by exact name, not by reference lookup, which would also match ID prefixes.

### 12. A checked translation table for create

`priv/docker/native-create.json` lists every field of `ContainerConfig`, `HostConfig` and `NetworkingConfig` in the pinned API description, with one class:

- `translated`: what it becomes (a spec field, an Incus key or device)
- `ignored`: accepted with no effect, with a reason
- `refused`: rejected when set to a non-default value, with a reason

The table also records its API version, what counts as a default value, and the recorded differences. `mix docker.reference` fails on a missing, extra or duplicate field, an unknown class, a missing reason or a different API version, so a new reference release cannot add fields silently. The JSON is authoritative. The summary below covers the fields that matter most.

| Docker field | Native translation |
| --- | --- |
| `Image` | decision 1 |
| `Entrypoint`, `Cmd` | merged with the image config into spec `argv` |
| `Env` | merged with the image environment into spec `env` |
| `WorkingDir` | spec `cwd` |
| `User`, `HostConfig.GroupAdd` | spec `user` and `group_add`, resolved by the shim |
| `Hostname` | spec `hostname`. The default is the 12-hex short ID, as Docker's |
| `StopSignal`, `StopTimeout` | spec `stop_signal`, and the default stop timeout in `.config` |
| `Labels` | `user.opsmaru.containers.labels` |
| `HostConfig.Binds`, `Mounts` of type `bind` | each source mapped by `map_bind_source/2`, then an Incus `disk` device with `path` and `readonly`. Without the callback, refused as today. A target under `/.opsmaru` is refused |
| `HostConfig.Memory` | `limits.memory` |
| `HostConfig.NanoCpus`, `CpuQuota`/`CpuPeriod` | `limits.cpu.allowance` |
| `HostConfig.CpusetCpus` | `limits.cpu` |
| `HostConfig.PidsLimit` | `limits.processes` |
| `HostConfig.Dns`, `DnsSearch` | `oci.dns.nameservers`, `oci.dns.search` |
| `HostConfig.NetworkMode` | `default` or `bridge`: the native project's default network. `none`: an `eth0` device of type `none`. Others refused |
| `HostConfig.LogConfig` | spec `log` (decision 8) |
| `HostConfig.AutoRemove` | `.autoremove`, honoured by wait and reap (decision 13) |
| `HostConfig.Init` | ignored: native containers always run under an init, as with `--init` (below) |
| `HostConfig.RestartPolicy` | `no` only. Others refused |
| `Tty`, `OpenStdin`, `AttachStdin`, `StdinOnce` | refused (non-goal) |
| `ExposedPorts` | ignored: image metadata only, nothing is published |
| `HostConfig.PortBindings`, `PublishAllPorts` | refused (follow-up 3) |
| `Domainname`, `HostConfig.Privileged`, `CapAdd`, `Devices`, `SecurityOpt`, `ExtraHosts`, `ReadonlyRootfs`, volume mounts, `VolumesFrom`, `Links` | refused |

Translation happens before any Incus mutation. A refused field never leaves a half-created instance.

**Recorded differences.** The table's `differences` list records these, and the differential cases normalise them:

- **Init:** the Docker process is not PID 1 (the spike saw PIDs 12 to 14), so default signal dispositions apply. Under Docker without `--init`, a PID 1 with no SIGTERM handler ignores `docker stop` and is killed after the timeout (exit 137). Natively it exits on SIGTERM (exit 143), as under `docker run --init`.
- **Hostname files:** the kernel hostname is set, but `/etc/hostname` and `/etc/hosts` are the image's or Incus's, not Docker's generated files.
- **Image health checks, image volumes and `/dev/shm`:** an image `HEALTHCHECK` is not run, image `VOLUME` paths stay in the root filesystem, and `/dev/shm` is Incus's rather than Docker's 64 MiB tmpfs.
- **Generated names:** a create without a name gets its instance name (`oc-` and 12 hex characters), not one of Docker's `adjective_surname` names.

**Order of checks.** A native create checks, in order: the body (refused fields, values a translated field cannot honour, a missing `Image`), each bind source through `map_bind_source/2`, the name in both engines, then the image handoff and the shim for the image's architecture. Only then is the instance created and the shim pushed. A failed push deletes the instance. `Opsmaru.Containers.Native.eligibility/1` runs the body checks alone, so a host's `select_engine/2` can route only eligible bodies to native.

### 13. Lifecycle, wait and auto-remove

| Route | Native behaviour |
| --- | --- |
| `POST /containers/{id}/start` | close the library's SFTP sessions on the instance (decision 8), then Incus state `start` (about 0.25–0.3 s in the spike). Then read the new run record until it shows the child started or failed, within the deadline. A failed `execve` is answered as dockerd answers it (400 with the exec error), and the container is left exited with 127 or 126. A missing working directory is reported with runc's wording and 127 |
| `POST /containers/{id}/stop?t=&signal=` | through exec, `init stop T` with the signal. The shim sends it, waits up to `T`, sends SIGKILL, records the exit and exits. The library waits for the instance to stop, with an Incus forced stop as a backstop at `T` + 10 s. A paused container is unfrozen first, because Incus refuses exec into a frozen instance (`Instance is frozen`) |
| `POST /containers/{id}/kill?signal=` | through exec, `init kill SIGNAL`. The default SIGKILL kills the child, and the shim records 137. If the exec fails, SIGKILL falls back to an Incus forced stop and no record (decision 7) |
| `POST /containers/{id}/restart?t=` | stop then start, with the same rules |
| `POST /containers/{id}/pause`, `unpause` | Incus `freeze` and `unfreeze` |
| `POST /containers/{id}/rename` | rewrites `.name`. The instance name stays |
| `DELETE /containers/{id}?force=` | stop (`kill` when `force`), then delete. A running container without `force` gets dockerd's conflict error |
| `GET /containers/{id}/json` | synthesised from the instance, its state, `.config` and the run record, in the pinned API's shape |
| `POST /containers/{id}/wait?condition=` | below |

**Wait.** The library subscribes to Incus lifecycle events for the instance, then reads its state, so a stop between the two is not missed. Once the instance has stopped after the run being waited for, it reads the run record and answers `{"StatusCode": N}`. A missing exit record gives 137, as decision 7 says, with `Error.Message` set. `condition=next-exit`, `not-running` and `removed` follow Docker's meanings.

As dockerd does, the status line and headers are sent before the wait begins, and the result is the only body chunk. An Incus failure after the headers is answered as `{"StatusCode": -1, "Error": {...}}`. The library re-reads the instance on each lifecycle event for it and at least once a second, so a missed event only delays the answer. A wait whose instance ran and stopped without the shim recording the awaited run also answers 137.

**Auto-remove.** The library starts no processes, so nothing watches containers in the background. For an `AutoRemove` container, a `wait` with `condition=removed` (which the CLI sends for `--rm`) reads the exit status, deletes the stopped instance, then answers. `Native.reap/2`, which the host calls on its own schedule, deletes stopped `AutoRemove` instances that no wait removed, for example after a client disconnect. It keeps an instance that has no run record yet, because `docker run --rm` creates, then waits, then starts. A wait checks for a client disconnect immediately before it deletes, so a gone client never causes a removal.

### 14. Logs and attach

`GET /containers/{id}/logs` reads log records (decision 8) and writes them as Docker's multiplexed stream:

- `stdout` and `stderr` select by stream.
- `timestamps` prefixes each record's time in RFC 3339 with nanoseconds.
- `since` and `until` filter by record time.
- `tail` counts records from the end, as Docker's drivers do.
- `follow` polls the SFTP position every 250 ms while the instance runs. After the instance stops, it opens a new session and reads to the end once more, so output written just before exit is delivered, then ends. In the spike, a 250 ms poll delivered records within about 600 ms of being written. All 300 lines written in the instant before exit arrived through the session reopened after the stop.
- `details` is refused, because native containers carry no log attributes.

**Attach.** `POST /containers/{id}/attach` with `stream=1`, output only and no stdin is what `docker run` without `-d` or `-i` sends, before it starts the container. It is served from the log records of the next run, from its first record. So nothing written between start and the attach reading is lost:

1. On attach, the library notes the end of the logs as the position, and closes that SFTP session.
2. When the start has returned, it reopens a session, retrying while a short-lived process is already stopping, and follows from the position.
3. It answers once that run's exit record exists and the instance has stopped.

The spike ran this three times with a command that printed two lines and exited at once. Both lines arrived every time, and the attach ended 0.3–0.6 s after the start returned. Stdin attach is refused (non-goal).

### 15. Route table and evidence

The foundation's `native` class assumed whole routes would move. Container routes instead serve both engines, chosen per container. So container-scoped routes keep class `nested` and gain a `native` field: `{"class": "translated"}` or `{"class": "refused", "reason": ...}`. `mix docker.reference` requires it on every nested `/containers` and `/exec/` route and forbids it elsewhere. Admission uses it only when the container resolves to native. A route moves to class `native` only when nested no longer serves it at all, which this change does not do.

Still refused for native containers, with a Docker-shaped error naming the native engine: `docker cp` (`/archive`), `export`, `changes`, `top`, `stats`, `update` and container `resize`. SFTP could serve `/archive` and exec could serve `top` in later changes.

Evidence for a native route needs:

- **Fixture:** translation against a scripted Incus backend, plus shim unit tests for its file formats.
- **Real Incus:** the workflow against isolated Incus 7.0.1 with `instance_oci`.
- **Differential:** the same pinned CLI workflow against a nested container and a native container from the same image. Compare exit codes, output and the fields the translation table marks `translated`, with normalisers for IDs, timestamps, addresses and the recorded differences.
- **Consumer:** host acceptance.

## Risks / Trade-offs

- **[Container-written state]** → Exit status and logs are written inside the container, so its root user can falsify them. The library parses them as untrusted, bounded input. Docker keeps the same data outside the container, so this is a real difference, recorded in `docs/embedding.md`.
- **[Log disk use]** → Logs use the container's root disk, bounded by rotation. A container whose disk is full may lose log records. The shim keeps running its child and records the loss as a partial record when it can.
- **[Init differences]** → Every native container runs under an init. Programs that rely on being PID 1, or that ignore SIGTERM under Docker, behave as they would with `--init`.
- **[Forced stops]** → A forced Incus stop leaves no exit record. The library reports 137 and says so in `State.Error`, rather than guessing a cleaner code.
- **[Shim supply chain]** → Hosts build the shim. The library refuses binaries whose digest it does not list, and the README's digests come from a reproducible build check.
- **[Double image storage]** → Every image a native container uses is stored in dockerd and in Incus. `prune_images/2` bounds it. Handoff of a large image takes tens of seconds on first use.
- **[Two engines, one namespace]** → Names and ID prefixes must stay unique across engines. Host-serialized creates make that safe for one host. Two hosts on one target need the same serialization they already need for lifecycle mutations.
- **[Translation drift]** → A new Docker release can add create fields. The table check fails on unknown fields, and unknown non-default values are refused.
- **[Incus key limits]** → `oci.*` keys are not live-updatable, so `docker update` stays refused for native containers.
- **[Larger trust boundary for the host]** → Native containers are full Incus instances in a host-chosen project. The host's authorization and its project configuration (profiles, limits, network, root size) bound what a Docker client can create there.

## Planning history

- **2026-11-27, first design:** argv in `oci.entrypoint`, exit status from Incus, logs from the console log. The first spike failed its exit-status gate and showed that the other two would not work either. See the [spike report](../../../docs/native-oci-spike.md).
- **2026-11-27, this design:** the init shim, with image handoff fixed to candidate B. Gated on the second spike (task 2).
- **2026-11-27, second spike:** passed. Exact argv and exit status (the gates), logs, signals, process setup, push and the foreground run all qualified. The design was updated for SFTP session rules, Incus's graceful stop and the exec environment. linux/amd64 was not run.
