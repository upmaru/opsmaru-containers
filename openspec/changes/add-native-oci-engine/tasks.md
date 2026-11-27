# Tasks

## 1. First qualification spike: Incus behaviour (isolated Incus 7.0.1, explicit opt-in)

Recorded in `docs/native-oci-spike.md`.

**Result (2026-11-27): gate 1.2 failed.** The first design was replaced by the init-shim design, which task 2 qualifies.

- [x] 1.1 Entrypoint: the format of `oci.entrypoint` (single string or list, quoting), whether it and `oci.cwd`, `oci.uid`, `oci.gid` and `environment.*` set at create override the image config, and how Docker's `Entrypoint` plus `Cmd` arrays survive arguments with spaces and quotes.
  - Run 2026-11-27 ([spike report](../../../docs/native-oci-spike.md)). It is one shell-like string with no variable expansion, and it overrides the image. Create-time `oci.cwd`, `oci.uid`, `oci.gid` and `environment.*` override too. Arguments containing `$ \ | [ * ~ '` can gain backslashes, so Docker's argv cannot be carried exactly.
- [x] 1.2 **Gate:** whether Incus records the entrypoint's exit status (instance state, a volatile key, a lifecycle event or operation metadata) for exit codes 0, 3 and 137, and how soon after exit. If it does not, return this change to planning.
  - **Gate fails** (2026-11-27). Exits 0, 3 and 137 are indistinguishable in instance state, config, lifecycle events and `lxc.log`. The change returned to planning.
- [x] 1.3 Image handoff: try candidate A (an HTTPS registry in the engine instance with a pinned certificate, as an `oci` source) and candidate B (export from dockerd, convert in the engine instance, upload through `POST /1.0/images`). Record the time and bytes over the host path for a 10 MiB and a 500 MiB image, and the resulting image's config. Choose one in the design.
  - Candidate B works: 10 MiB in 2.0 s and 500 MiB in 31.1 s, and the result is an OCI container running the image's own command. Candidate A fails: the Incus server's `skopeo inspect` ignores the pinned certificate. The design chooses B.
- [x] 1.4 Output and console: whether the console log separates stdout and stderr, carries timestamps, survives restart, and can be followed without taking the console. Whether a console attach can carry stdin and a TTY for `docker run -it`.
  - The console log merges stdout and stderr and has no timestamps. It is empty or partial while running, complete after stop, and cleared on restart. Console attach needs a terminal. It cannot serve `logs` or `attach`.
- [x] 1.5 Stop and signals: the signal a graceful Incus stop sends to an OCI container, whether the entrypoint is PID 1, and whether `kill -TERM 1` through exec reaches it.
  - `incus stop` sends SIGTERM to the entrypoint, which is PID 4 under `{incusd} init` (PID 1). `kill` through exec must target the entrypoint's PID, not 1.
- [x] 1.6 Freeze and unfreeze on a running OCI container.
  - Freeze and unfreeze work.
- [x] 1.7 Exec: half-close of Incus exec stdin with output continuing, separate stdout and stderr, exit codes, TTY resize, and numeric user and working directory.
  - Pass: stdin EOF, separate stdout and stderr, exit code, numeric user and group, cwd, env, 1 MiB of stdin and TTY size.
- [x] 1.8 Networking: whether a managed bridge's DNS resolves OCI instance names, and what `NetworkMode=none` needs (no `nic` device, or a profile without one).
  - The bridge resolves OCI instance names. An `eth0` device of type `none` leaves only `lo`.

## 2. Init shim and its qualification spike

Tasks 2.1 and 2.2 are library code with unit tests. Tasks 2.3 to 2.10 run with explicit opt-in against an isolated Incus 7.0.1 project with `instance_oci`, using images from the pinned nested engine and the shim built by task 2.2. Record each result in `docs/native-oci-spike.md` under a second-spike section. **Tasks 2.3 and 2.4 are gates:** if either fails, this change returns to planning. Tasks 3 to 7 start only after tasks 2.3 to 2.10 are recorded.

- [ ] 2.1 Write the shim in `priv/native_init/` (Go, standard library only):
  - init mode: spec parsing, run records, child start with `execve` detection, log records and rotation, signal forwarding, subreaper, the control socket;
  - the `exec`, `kill` and `stop` modes.

  Add unit tests for the spec, run record and log record formats, rotation, partial-record flushing and `execve` failure codes.
- [ ] 2.2 Add the README with the formats, the build recipe and digests. Add `scripts/check_init.sh` and `mise run check:init` (vet, test, two clean builds per architecture, digest comparison), and add them to `mise run check`.
- [ ] 2.3 **Gate: exact argv.** Push the shim and a spec into a created OCI container, as the design does. Verify that argv containing `$ \ | [ * ~ '`, spaces, quotes, an empty string, a newline and non-UTF-8 bytes arrives unchanged.
- [ ] 2.4 **Gate: exit status.** Read the run record through the files API and SFTP after the instance stops, for:
  - exits 0 and 3;
  - a child killed by `init kill KILL` (137) and by `init kill TERM` (143);
  - `init stop` with a child that ignores SIGTERM (137 after the timeout);
  - a missing command (127) and a non-executable one (126);
  - a forced Incus stop (no record).

  Record the time from exit to a readable record and to the `instance-shutdown` event.
- [ ] 2.5 Logs:
  - stream separation and relative order under interleaved writes;
  - timestamps, partial records, and persistence across a restart;
  - rotation at a small `max_size`;
  - a 250 ms SFTP follow while running, and that the last records written before exit are readable after stop;
  - SFTP on a stopped and on a frozen instance;
  - the read throughput of a 100 MiB log through SFTP.
- [ ] 2.6 Signals and stop: a graceful `incus stop` reaching the child as the spec's `stop_signal`; `init kill` with HUP to a trapping child; `init stop` on a frozen container after unfreeze; the forced-stop backstop.
- [ ] 2.7 Process setup:
  - user and group names from `/etc/passwd` and `/etc/group`, supplementary groups and `group_add`;
  - `cwd`, and `sethostname`;
  - the main process's environment, and Docker's `HOME`, `PATH` and `HOSTNAME` defaults;
  - in `exec` mode, which variables Incus adds and that `OPSMARU_EXEC_ENV` removes them;
  - whether the cgroup's `memory.events` `oom_kill` count is readable in the container and increases on an out-of-memory kill.
- [ ] 2.8 Push: time and bytes to push the shim and spec per create; an image that already contains `/.opsmaru`; a bind target under `/.opsmaru`; the shim on linux/arm64 and linux/amd64 if an amd64 host is available, otherwise recorded as not run.
- [ ] 2.9 Foreground run: the `docker run` sequence (attach, start, wait) served from log records and run records, with a command that prints and exits within 10 ms of start.
- [ ] 2.10 Record the verdicts. Update the design where a result differs from what it assumes.

## 3. Route table and host contract

- [ ] 3.1 Add the optional `select_engine/2` callback with the shared deadline. Default to `nested`. Verify that hosts without it behave exactly as before (the full existing suite).
- [ ] 3.2 Add the native project and `native_init` binaries to the context target. Validate them apart from the nested engine's project, including the shim digest check and per-architecture lookup.
- [ ] 3.3 Add the `native` field (`translated` or `refused`, with a reason) to every container-scoped route in `priv/docker/routes.json`, and extend the reference check to require it.
- [ ] 3.4 Generate `priv/docker/native-create.json` from the pinned API description, with one class per field, a reason for each `ignored` or `refused`, and the recorded differences. Add the check that fails on a missing field.

## 4. Placement, routing and images

- [ ] 4.1 Add native identity: ID and instance-name generation, the `user.opsmaru.containers.*` keys, and ownership checks. Verify collision retry and that unmarked instances are ignored.
- [ ] 4.2 Add per-container resolution by full ID, unique prefix and name across both engines, with not-found and ambiguous errors. Add merged listing with the supported filters, refusal of others, and combined prune. Verify with a scripted nested engine and a scripted Incus backend.
- [ ] 4.3 Add cross-engine name checks on nested and native create. Document the host's create serialization.
- [ ] 4.4 Add the image handoff from decision 2: the tool check, conversion through engine exec, the streamed split upload, the image-ID property, per-image serialization, reconciliation of uncertain outcomes and `prune_images/2`. Verify first transfer, reuse, an image missing from the nested engine, missing tools, and no replay after an uncertain upload.

## 5. Create and lifecycle

- [ ] 5.1 Add create translation from the table:
  - the process spec from the image config and create body by Docker's merge rules;
  - limits, DNS, network mode, log config, and bind devices through `map_bind_source/2`;
  - named refusals before any mutation, and `eligibility/1`.

  Verify each translated field against a scripted backend, and each refused field.
- [ ] 5.2 Add the shim push after create, the `/.opsmaru` collision check, and the run-record and log-record parsers with size bounds and malformed-input errors.
- [ ] 5.3 Add start (with `execve` failure reporting), stop and kill through the shim, the forced-stop backstop, restart, pause, unpause, rename, remove and inspect. Verify Docker status codes and error shapes, including removing a running container without `force`.
- [ ] 5.4 Add wait over Incus events with a state read after subscribing, the three conditions, exit status from run records, the 137 rule for a missing record, auto-remove on `condition=removed`, and `reap/2`. Verify an exit between subscribe and read, and a client disconnect before removal.

## 6. Exec, logs and attach

- [ ] 6.1 Add exec create, start, inspect and resize through the shim's `exec` mode. Cover exec records on the instance, multiplexed framing without a TTY, half-close, TTY resize, detached start and the 32-record bound.
- [ ] 6.2 Add logs from log records through SFTP, with every option in the design, follow until stop with the final read, and output-only attach from the next run's first record. Add the refusals for `details`, the `none` driver, stdin attach and TTY.

## 7. Evidence and documentation

- [ ] 7.1 Add differential cases that run the same pinned CLI workflow against a nested and a native container from the same image:
  - run with an exit code, foreground and `--rm`;
  - detached run with stop and rm, and kill with a signal;
  - exec with stdin EOF and with a named user;
  - logs with timestamps, tail and follow;
  - inspect fields, rename, a bind mount and limits.

  Normalise only the recorded differences.
- [ ] 7.2 With explicit opt-in, run the native workflows against isolated Incus 7.0.1 and record them in the ledger as real-Incus evidence. Leave unchecked until run.
- [ ] 7.3 Document native containers in the README and `docs/embedding.md`:
  - how to opt in, and how to build and pass the shim;
  - the engine's skopeo and umoci requirement, and root size on ZFS;
  - the translation table, what is refused and why, and the recorded differences, including container-written logs and exit status;
  - double image storage and pruning;
  - that Compose should stay nested.
- [ ] 7.4 Run `mise run check`.
