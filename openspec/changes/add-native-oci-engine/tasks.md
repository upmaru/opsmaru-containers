# Tasks

## 1. Qualification spike (isolated Incus 7.0.1, explicit opt-in)

Run every item against an isolated Incus 7.0.1 project with `instance_oci` and skopeo, using images built and pulled by the pinned nested engine. Record commands, outputs and verdicts in `docs/native-oci-spike.md`. Translation tasks 3 to 6 start only after these are recorded.

**Result (2026-11-27): gate 1.2 failed, and this change is back in planning.** Tasks 2 to 6 below describe the original design and do not start until a revised design passes task 1 again.

- [x] 1.1 Entrypoint: the format of `oci.entrypoint` (single string or list, quoting), whether it and `oci.cwd`, `oci.uid`, `oci.gid` and `environment.*` set at create override the image config, and how Docker's `Entrypoint` plus `Cmd` arrays survive arguments with spaces and quotes.
  - Run 2026-11-27 ([spike report](../../../docs/native-oci-spike.md)). One shell-like string with no variable expansion, overriding the image, and create-time `oci.cwd`, `oci.uid`, `oci.gid` and `environment.*` override too. Arguments containing `$ \ | [ * ~ '` can gain backslashes, so Docker's argv cannot be carried exactly.
- [x] 1.2 **Gate:** whether Incus records the entrypoint's exit status (instance state, a volatile key, a lifecycle event or operation metadata) for exit codes 0, 3 and 137, and how soon after exit. If it does not, return this change to planning.
  - **Gate fails** (2026-11-27). Exits 0, 3 and 137 are indistinguishable in instance state, config, lifecycle events and `lxc.log`. This change returns to planning.
- [x] 1.3 Image handoff: try candidate A (an HTTPS registry in the engine instance with a pinned certificate, as an `oci` source) and candidate B (export from dockerd, convert in the engine instance, upload through `POST /1.0/images`). Record the time and bytes over the host path for a 10 MiB and a 500 MiB image, and the resulting image's config. Choose one in the design.
  - Candidate B works: 10 MiB in 2.0 s, 500 MiB in 31.1 s, an OCI container running the image's own command. Candidate A fails: the Incus server's `skopeo inspect` ignores the pinned certificate.
- [x] 1.4 Output and console: whether the console log separates stdout and stderr, carries timestamps, survives restart, and can be followed without taking the console. Whether a console attach can carry stdin and a TTY for `docker run -it`.
  - The console log merges stdout and stderr, has no timestamps, is empty or partial while running, complete after stop, and cleared on restart. Console attach needs a terminal. Not usable for `logs` or `attach`.
- [x] 1.5 Stop and signals: the signal a graceful Incus stop sends to an OCI container, whether the entrypoint is PID 1, and whether `kill -TERM 1` through exec reaches it.
  - `incus stop` sends SIGTERM to the entrypoint, which is PID 4 under `{incusd} init` (PID 1). `kill` through exec must target the entrypoint's PID, not 1.
- [x] 1.6 Freeze and unfreeze on a running OCI container.
  - Freeze and unfreeze work.
- [x] 1.7 Exec: half-close of Incus exec stdin with output continuing, separate stdout and stderr, exit codes, TTY resize, and numeric user and working directory.
  - Pass: stdin EOF, separate stdout and stderr, exit code, numeric user and group, cwd, env, 1 MiB stdin and TTY size.
- [x] 1.8 Networking: whether a managed bridge's DNS resolves OCI instance names, and what `NetworkMode=none` needs (no `nic` device, or a profile without one).
  - The bridge resolves OCI instance names. An `eth0` device of type `none` leaves only `lo`.

## 2. Route table and host contract

- [ ] 2.1 Add the optional `select_engine/2` callback with the shared deadline. Default to `nested`. Verify that hosts without it behave exactly as before (the full existing suite).
- [ ] 2.2 Add the native project to the context target and validate it apart from the nested engine's project.
- [ ] 2.3 Add the `native` field (`translated` or `refused`, with a reason) to every container-scoped route in `priv/docker/routes.json`, and extend the reference check to require it.
- [ ] 2.4 Generate `priv/docker/native-create.json` from the pinned API description with one class per field and a reason for each `ignored` or `refused`. Add the check that fails on a missing field.

## 3. Placement, routing and images

- [ ] 3.1 Add native identity: ID and instance-name generation, the `user.opsmaru.containers.*` keys, and ownership checks. Verify collision retry and that unmarked instances are ignored.
- [ ] 3.2 Add per-container resolution by full ID, unique prefix and name across both engines, with not-found and ambiguous errors. Add merged listing with the supported filters, refusal of others, and combined prune. Verify with a scripted nested engine and a scripted Incus backend.
- [ ] 3.3 Add cross-engine name checks on nested and native create. Document the host's create serialization.
- [ ] 3.4 Add the image handoff chosen in task 1.3, with the image-ID property, reconciliation of uncertain outcomes and `prune_images/2`. Verify first transfer, reuse, an image missing from the nested engine, and no replay after an uncertain upload.

## 4. Create and lifecycle

- [ ] 4.1 Add create translation from the table: process config merged from the image config, environment, user, limits, DNS, network mode, bind devices through `map_bind_source/2`, and named refusals before any mutation. Add `eligibility/1`. Verify each translated field against a scripted backend and each refused field.
- [ ] 4.2 Add start, stop, kill, restart, rename, remove and inspect, and pause and unpause where task 1.6 confirmed them. Verify Docker status codes and error shapes, including removing a running container without `force`.
- [ ] 4.3 Add wait over Incus events with a state read after subscribing, the three conditions, exit status from task 1.2, auto-remove on `condition=removed`, and `reap/2`. Verify an exit between subscribe and read, and a client disconnect before removal.

## 5. Exec, logs and attach

- [ ] 5.1 Add exec create, start, inspect and resize with exec records on the instance, multiplexed framing without a TTY, half-close, TTY resize, detached start and the 32-record bound.
- [ ] 5.2 Add logs and output-only attach from the console log, with a named refusal for each option that task 1.4 found unsupported.

## 6. Evidence and documentation

- [ ] 6.1 Add differential cases that run the same pinned CLI workflow against a nested and a native container from the same image: run with an exit code, `--rm`, detached run with stop and rm, exec with stdin EOF, logs, inspect fields, rename, a bind mount and limits.
- [ ] 6.2 With explicit opt-in, run the native workflows against isolated Incus 7.0.1 and record them in the ledger as real-Incus evidence. Leave unchecked until run.
- [ ] 6.3 Document native containers in the README and `docs/embedding.md`: how to opt in, the translation table, what is refused and why, double image storage and pruning, and that Compose should stay nested.
- [ ] 6.4 Run `mise run check`.
