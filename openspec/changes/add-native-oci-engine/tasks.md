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

**Result (2026-11-27): both gates pass.** Every item qualified except linux/amd64, which had no host. The design is updated for what the spike found. Tasks 3 to 7 may start.

- [x] 2.1 Write the shim in `priv/native_init/` (Go, standard library only):
  - init mode: spec parsing, run records, child start with `execve` detection, log records and rotation, signal forwarding, subreaper, the control socket;
  - the `exec`, `kill` and `stop` modes.

  Add unit tests for the spec, run record and log record formats, rotation, partial-record flushing and `execve` failure codes.
  - Done: `priv/native_init/`, Go standard library only. Tests also cover exact argv, `kill` and `stop` through the control socket, OOM detection, exec-mode environment filtering, and the drain limit when a descendant holds a pipe. They pass with `-race`.
- [x] 2.2 Add the README with the formats, the build recipe and digests. Add `scripts/check_init.sh` and `mise run check:init` (vet, test, two clean builds per architecture, digest comparison), and add them to `mise run check`.
  - Done. The check also fails when the README's digests don't match the build. The Hex consumer check now requires the shim's source and rejects any built file under `priv/native_init`.
- [x] 2.3 **Gate: exact argv.** Push the shim and a spec into a created OCI container, as the design does. Verify that argv containing `$ \ | [ * ~ '`, spaces, quotes, an empty string, a newline and non-ASCII UTF-8 arrives unchanged. Docker's API and the spec are JSON, so argv is always valid UTF-8.
  - **Pass.** 14 arguments, including `$HOME`, `x\y`, `*`, an empty string, an embedded newline, quotes, `$(id)`, a backtick form, `a;b&&c` and `héllo ✓`, reached `printf` byte for byte, with `printf` found through `PATH`.
- [x] 2.4 **Gate: exit status.** Read the run record through the files API and SFTP after the instance stops, for:
  - exits 0 and 3;
  - a child killed by `init kill KILL` (137) and by `init kill TERM` (143);
  - `init stop` with a child that ignores SIGTERM (137 after the timeout);
  - a missing command (127) and a non-executable one (126);
  - a forced Incus stop (no record).

  Record the time from exit to a readable record and to the `instance-shutdown` event.
  - **Pass.** Every case recorded the expected code, readable through the files API and SFTP after stop: 0, 3, 137, 143, 4 (a trapped HUP), 137 after a 2 s stop timeout, 5 (the spec's SIGQUIT), 127, 126, and 128 for an unknown user. A forced stop left a record without `finished_at`. Exit to `Stopped` took about 0.8 s, and the record was readable by then. The event stream was not used, because of the consumer's gateway fault.
- [x] 2.5 Logs:
  - stream separation and relative order under interleaved writes;
  - timestamps, partial records, and persistence across a restart;
  - rotation at a small `max_size`;
  - a 250 ms SFTP follow while running, and that the last records written before exit are readable after stop;
  - SFTP on a stopped and on a frozen instance;
  - the read throughput of a 100 MiB log through SFTP.
  - **Pass.**
    - Per-stream order is kept and times are monotonic. Partial records are flagged. Logs persist across nine restarts with run numbers. Rotation keeps the newest files.
    - Follow delivered records within about 600 ms at a 250 ms poll, including 300 lines written just before exit.
    - SFTP works on stopped and frozen instances. 100 MiB was written in 1.2 s and read in 3.3 s.
    - **New:** an SFTP session ends when the instance stops, and one held on a stopped instance holds up its start. Both are now in design decision 8.
- [x] 2.6 Signals and stop: a graceful `incus stop` reaching the child as the spec's `stop_signal`; `init kill` with HUP to a trapping child; `init stop` on a frozen container after unfreeze; the forced-stop backstop.
  - **Pass with a finding:** a graceful `incus stop` sends SIGTERM to every process in the container, so Docker stop must use `init stop`. Exec into a frozen instance fails at once (`Instance is frozen`), and works after unfreeze. A forced stop leaves no exit record, as the 137 rule expects.
- [x] 2.7 Process setup:
  - user and group names from `/etc/passwd` and `/etc/group`, supplementary groups and `group_add`;
  - `cwd`, and `sethostname`;
  - the main process's environment, and Docker's `HOME`, `PATH` and `HOSTNAME` defaults;
  - in `exec` mode, which variables Incus adds and that `OPSMARU_EXEC_ENV` removes them;
  - whether the cgroup's `memory.events` `oom_kill` count is readable in the container and increases on an out-of-memory kill.
  - **Pass.**
    - `daemon` resolved to uid 2, gid 2, groups 1, 4, 10 and 1234 (through `group_add`), with `HOME=/sbin`. `daemon:nogroup` and `4242:4243` (`HOME=/`) also resolved.
    - Hostname and cwd were set. The environment came out in Docker's order.
    - In `exec` mode, Incus's own variables were dropped and `DROP` was unset. The user and cwd defaults, exit codes, stdin EOF and TTY all worked through the shim.
    - A non-root process cannot read `/.opsmaru`.
    - `oom_kill` is readable in the container, and an OOM kill of a child set `oom_killed`, as Docker reports any OOM kill in the container.
- [x] 2.8 Push: time and bytes to push the shim and spec per create; an image that already contains `/.opsmaru`; a bind target under `/.opsmaru`; the shim on linux/arm64 and linux/amd64 if an amd64 host is available, otherwise recorded as not run.
  - **Pass for arm64.**
    - Create took 0.55–0.6 s. Pushing the 3.0 MB shim and the spec took 0.27–0.42 s through the CLI (three requests).
    - `GET /files?path=/.opsmaru` is 404 on a fresh instance and a listing when the path exists, so the collision check works. A bind target under `/.opsmaru` is library validation and needs no Incus test.
    - **linux/amd64 not run:** no amd64 host was available.
- [x] 2.9 Foreground run: the `docker run` sequence (attach, start, wait) served from log records and run records, with a command that prints and exits within 10 ms of start.
  - **Pass**, three runs. The attach noted its position, closed its session, then reopened after the start returned (0.27–0.31 s). Both lines and exit code 4 were delivered 0.3–0.6 s after the start returned.
- [x] 2.10 Record the verdicts. Update the design where a result differs from what it assumes.
  - Recorded in the spike report. The design is updated in decisions 6, 8, 9, 12, 13 and 14 and in its planning history.

## 3. Route table and host contract

- [x] 3.1 Add the optional `select_engine/2` callback with the shared deadline. Default to `nested`. Verify that hosts without it behave exactly as before (the full existing suite).
  - Result: `Docker.EngineSelection` runs it in `Docker.Plug` for `POST /containers/create`, after the body is read and before bind mapping. Hosts without the callback skip it, and the body is not decoded. A non-object body, a raise, a late answer or any value other than `:native` selects `nested`. Until task 5, a native choice gets a 501 and is never sent to nested. New Plug tests cover each case, and the existing suite passes unchanged.
- [x] 3.2 Add the native project and `native_init` binaries to the context target. Validate them apart from the nested engine's project, including the shim digest check and per-architecture lookup.
  - Result: `Native.Target.new/2` takes the native project's client and `%{"aarch64" => path, "x86_64" => path}`. It reads each file once and refuses unknown digests, unknown architectures, relative paths and unreadable files. The digests are compiled from the README table. `Nested.Target` gains an optional `native` field. Context validation requires the same owner and identity, a different non-empty project, and recorded digests that match the table. `Native.Target.shim/2` accepts Docker and Incus architecture names.
- [x] 3.3 Add the `native` field (`translated` or `refused`, with a reason) to every container-scoped route in `priv/docker/routes.json`, and extend the reference check to require it.
  - Result: 29 routes: 19 translated, and 10 refused (the three `/archive` routes, `export`, `changes`, `top`, `stats`, `attach/ws`, container `resize` and `update`). The check also forbids the field on other routes and on unsupported routes, and rejects a refusal without a reason.
- [x] 3.4 Generate `priv/docker/native-create.json` from the pinned API description, with one class per field, a reason for each `ignored` or `refused`, and the recorded differences. Add the check that fails on a missing field.
  - Result: 95 fields from API 1.57: 27 translated, 9 ignored, 59 refused, plus five recorded differences. `mix docker.reference` derives the field list from the create request schema (`ContainerConfig`, with `HostConfig`, including `Resources`, and `NetworkingConfig` expanded). It fails on a missing, extra or duplicate field, an unknown class, a missing reason or a different API version.

## 4. Placement, routing and images

- [x] 4.1 Add native identity: ID and instance-name generation, the `user.opsmaru.containers.*` keys, and ownership checks. Verify collision retry and that unmarked instances are ignored.
  - Result: `Native.Container` generates IDs and instance names, writes and reads the keys and exec records, and ignores an instance without the role key or with keys that do not parse (bad ID, ID not matching the instance name, bad name, time, labels or config). `Container.create/2` retries a name collision with a fresh ID until the deadline. The Incus calls go through a `Native.Backend` behaviour, implemented over `opsmaru_incus` by `Native.Incus`. Tests script it with `TestSupport.ScriptedIncus`.
- [x] 4.2 Add per-container resolution by full ID, unique prefix and name across both engines, with not-found and ambiguous errors. Add merged listing with the supported filters, refusal of others, and combined prune. Verify with a scripted nested engine and a scripted Incus backend.
  - Result: `Docker.Routing` runs after admission in both adapters when the target has a native project and the route has a `native` field. A native container or exec gets the route's refusal, or a 501 until its route is translated (tasks 5 to 7). It is never relayed to nested. `Native.Listing` merges `GET /containers/json` (Docker's `all`, `limit` and status defaults, regular-expression `id` and `name`, `label`, `status`, `exited`, and `ancestor` resolved in nested), and prunes both engines. Run records are parsed as untrusted input. 15 routing tests and 3 helper tests run against the scripted engine and backend.
- [x] 4.3 Add cross-engine name checks on nested and native create. Document the host's create serialization.
  - Result: `Native.Names` refuses a nested create or rename whose name a native container holds, with dockerd's conflict message, before dialing. It checks a native name against nested by exact name. The serialization is documented in `docs/embedding.md`.
- [x] 4.4 Add the image handoff from decision 2: the tool check, conversion through engine exec, the streamed split upload, the image-ID property, per-image serialization, reconciliation of uncertain outcomes and `prune_images/2`. Verify first transfer, reuse, an image missing from the nested engine, missing tools, and no replay after an uncertain upload.
  - Result: `Native.Images.ensure/4` resolves the reference in nested (a missing image gets dockerd's 404), reuses an image with the property, and otherwise hands it over under a per-target, per-image lock. The conversion script takes the image ID, architecture and work directory as arguments, never interpolated. The rootfs streams from the engine's files API into the upload through a pull-based producer, and a failed download fails the upload rather than truncating it. The work directory is always removed. `Opsmaru.Containers.Native.prune_images/2` deletes handed-off images no instance was created from. 9 tests also cover concurrent handoffs (one upload) and a reconciled uncertain upload. `Native.Incus` itself is exercised only against real Incus, in task 7.

## 5. Create and lifecycle

- [x] 5.1 Add create translation from the table:
  - the process spec from the image config and create body by Docker's merge rules;
  - limits, DNS, network mode, log config, and bind devices through `map_bind_source/2`;
  - named refusals before any mutation, and `eligibility/1`.

  Verify each translated field against a scripted backend, and each refused field.
  - Result: `Native.Translate` loads the table at compile time and matches field names without case, as Go's decoder does in dockerd. A duplicate name is a 400. `prepare/2` refuses, in one sorted 400, every refused or unknown field off its default and every translated field whose value native cannot honour (network modes other than default, bridge and none; restart policies other than `no`; log drivers and options beyond `local`, `json-file`, `none`, `max-size` and `max-file`; named volumes, non-bind mounts and targets of `/` or under `/.opsmaru`; NanoCpus with a quota; invalid env, hostname or stop signal). It maps bind sources through `map_bind_source/2` before any fetch. `finish/2` applies moby's merge rules for entrypoint, command, env, labels, user, working directory and stop signal, and produces the spec, the `oci.*` and `limits.*` keys, disk and `eth0` devices, and the stored inspect config. `Opsmaru.Containers.Native.eligibility/1` runs the body checks alone. A create without a name gets its instance name, recorded as a table difference. 11 tests cover every one of the 59 refused fields, a zero-valued docker CLI body, each translated field and the merge rules.
- [x] 5.2 Add the shim push after create, the `/.opsmaru` collision check, and the run-record and log-record parsers with size bounds and malformed-input errors.
  - Result: `Native.Shim.push/5` checks `/.opsmaru` is absent, re-reads and re-hashes the host's shim file, then pushes the directory (0700), the shim (0755) and `spec.json` (0600) as root. Any failure deletes the instance. `RunRecord` now reports `:malformed` for a record that does not parse or exceeds 64 KiB: inspect answers a 500 naming the native engine, and the listing shows that container as dead and keeps serving the rest. `Native.LogRecord` decodes the `OCL1` format, refusing a bad magic, stream, flag or length and leaving a trailing partial record for the next read. Tests cover a collision, a changed shim file, an architecture without a shim, and malformed records of both kinds.
- [x] 5.3 Add start (with `execve` failure reporting), stop and kill through the shim, the forced-stop backstop, restart, pause, unpause, rename, remove and inspect. Verify Docker status codes and error shapes, including removing a running container without `force`.
  - Result: `Native.Lifecycle` serves start (304 when running, 409 when paused, then a poll for the shim's new run that ends with an error if the instance stops first; a failed `execve` is a 400 with the shim's error, and inspect then shows exit 127), stop (`init stop` with `t`, the container's `StopTimeout` or 10, and the signal; a paused container is unfrozen first; an Incus forced stop at `t` + 10 s, or 2 s after a failed `init stop`), kill (any signal through `init kill`; SIGKILL falls back to a forced stop; dockerd's 400 and 409 messages), restart, pause, unpause, rename (both engines checked; the instance name stays), remove (dockerd's 409 without `force`; `force` kills first) and inspect (from the instance, its state and address, the stored config and the run record, with exit 137 and `native: exit status not recorded` when the run has no exit record). The Plug dispatches native routes by path; logs, attach and exec answer 501 until task 6, and the raw adapter refuses every native container. 26 tests drive these through the Plug against the scripted engine and backend.
- [x] 5.4 Add wait over Incus events with a state read after subscribing, the three conditions, exit status from run records, the 137 rule for a missing record, auto-remove on `condition=removed`, and `reap/2`. Verify an exit between subscribe and read, and a client disconnect before removal.
  - Result: `Native.Wait` subscribes to the native project's lifecycle events, reads the instance and run record, and chooses the run whose exit answers (`not-running`: the current state; `next-exit` and `removed`: the run in progress or the next one). It re-reads on each event for the instance and at least once a second. A stopped instance whose awaited run has no exit record answers 137 with the error. The Plug sends the 200 headers before waiting, as dockerd does. `removed` deletes an auto-remove container, after checking that the client is still there, and otherwise waits for the deletion. `Opsmaru.Containers.Native.reap/2` deletes stopped auto-remove containers that have a run record. 10 tests cover an exit after subscribing with no event, `next-exit` on a created container, the 137 rule, both `removed` cases, a disconnect before removal followed by reap, a disconnect through the Plug's client monitor, and an unknown condition.

## 6. Exec, logs and attach

- [x] 6.1 Add exec create, start, inspect and resize through the shim's `exec` mode. Cover exec records on the instance, multiplexed framing without a TTY, half-close, TTY resize, detached start and the 32-record bound.
  - Result: `Native.Exec` validates a create (`Privileged` and an empty `Cmd` are 400s; a stopped or paused container gets dockerd's 409s), stores the record under `user.opsmaru.containers.exec.<id>` and deletes records past the newest 32 by creation time in the same patch. A start runs `/.opsmaru/init exec [--user U] [--cwd D] -- CMD` as root with only the exec's `Env` plus `OPSMARU_EXEC_ENV` and `OPSMARU_EXEC_UNSET`, and `TERM=xterm` for a TTY without one. An attached start goes through the raw adapter: a new `Native.Pipe` (a `Transport.Stream` the existing tunnel relays) owns the Incus session, frames channels 1 and 2 as Docker's multiplexed stream (channel 0 unframed for a TTY), closes Incus stdin at once without `AttachStdin` and on the client's write EOF otherwise, and writes the exit code to the record before the stream ends, because the CLI inspects the exec as soon as its output ends. The pipe registers under `:global` while the exec runs, so resize on another connection reaches the Incus control channel. A detached start (Plug or raw) uses an Incus exec without channels and reads the exit code from the operation on inspect. A second start gets dockerd's 409s. 11 tests cover the record and inspect shape, the 32-record bound, the refusals, framing and exit recording, half-close with echoed stdin, TTY size, `TERM` and resize, a concurrent start, the Plug's refusal of an attached start, and detached starts including an operation Incus no longer holds. `Native.Incus` itself is exercised only against real Incus, in task 7.
- [x] 6.2 Add logs from log records through SFTP, with every option in the design, follow until stop with the final read, and output-only attach from the next run's first record. Add the refusals for `details`, the `none` driver, stdin attach and TTY.
  - Result: `Native.Logs` reads records from a `{file, offset}` position across numbered files (a rotated-away position continues from the oldest file; a file deleted mid-read is skipped), folding them without holding the whole log. The Plug streams them as Docker's multiplexed stream with `stdout`, `stderr`, `timestamps` (Docker's nine-digit `RFC3339NanoFixed`), `since` and `until` (`seconds[.fraction]`, inclusive), and `tail` (records of both streams, then the stream filter, as Docker's drivers do). The status line goes out with the first record, so malformed logs before any output are a 500 naming the native engine. `follow` polls every 250 ms while the instance runs, then reads once more through a new session after the stop. Output-only attach notes the end of the logs, closes that session before answering 101, then follows the next run (or the current one) through a pipe that holds no SFTP session while the instance is stopped, and ends after a final read once that run's record exists and the instance stopped. `details` is a 400, the `none` driver is dockerd's 501, no stream is dockerd's 400, and stdin attach, `logs=1` and a request without `stream` are 501s naming the native engine (TTY containers are already refused at create). 11 tests cover every option, rotation, the refusals, follow with output written in the instant before the stop, attach to a run that starts and exits between polls and to a running one, and attach relayed through `Raw.relay/4` to a TCP client that half-closes at once. A wait test from task 5.4 that raced its status change against the wait's first read now waits for the subscription and read.

## 7. Evidence and documentation

- [x] 7.1 Add differential cases that run the same pinned CLI workflow against a nested and a native container from the same image:
  - run with an exit code, foreground and `--rm`;
  - detached run with stop and rm, and kill with a signal;
  - exec with stdin EOF and with a named user;
  - logs with timestamps, tail and follow;
  - inspect fields, rename, a bind mount and limits.

  Normalise only the recorded differences.
  - Result: `test/acceptance/native_differential.mjs` runs seven cases through the pinned CLI against two sockets of one listener (`scripts/acceptance/native_listener.exs`), which differ only in the engine chosen at create. It compares exit codes, stdout, stderr, the `State`, `Config`, `HostConfig` and `Mounts` fields the table translates, and in-container checks of identity, hostname, cwd, env, the bind and cgroup limits. It normalises only container IDs, generated names (a recorded difference) and its run tag. The trapped-TERM stop keeps the Init difference out of the comparison.
- [x] 7.2 With explicit opt-in, run the native workflows against isolated Incus 7.0.1 and record them in the ledger as real-Incus evidence. Leave unchecked until run.
  - Run 2026-11-27 ([acceptance report](../../../docs/native-oci-acceptance.md)) on arm64 with Docker 29.10.0 and shim `30d1d3ab…`. The differential passed 21 of 21 runs on the final code, with native timings within a second or two of nested. Native-only checks passed for pause, unpause, restart, `logs --since`, listing filters, output-only `docker attach`, `start -a`, prune, TTY exec size and resize, and the refusals of `cp`, `stats`, `top`, `export`, `diff`, `update`, `run -i` and `run -p`. A resize that reached an exec after it ended got 409 natively and 404 from dockerd, so native now gives dockerd's answer. Real-Incus findings were fixed along the way: a held SFTP session blocking stops (34 s foreground runs and 67 s log follows before), flapping stop state, delete and file-read refusals around state changes, the start window, file-retrieved event storms, mapped bind sources in inspect and the image producer's cross-process sink each have a fixture test that fails without the fix. Conditional patches, 64 KiB chunked pushes, the `Invalid PID` 500 and the download result's shape are fixed in `Native.Incus`, which is exercised only against real Incus. `priv/docker/coverage.json` now keeps a `native` evidence object on every route with a `native` field, checked by `mix docker.reference`, and records fixture, differential and real-Incus evidence there from the routes the listener's telemetry saw: 14 translated routes have all three; pause, unpause, restart, prune and exec resize lack a differential case, so they are not verified for native. **The run used `opsmaru_incus` 0.2.10 patched locally** to open exec sessions' `control` channel first. Unpatched, the image handoff failed every time. A fixed `opsmaru_incus` release is a precondition for shipping native containers. linux/amd64 and host acceptance were not run.
- [x] 7.3 Document native containers in the README and `docs/embedding.md`:
  - how to opt in, and how to build and pass the shim;
  - the engine's skopeo and umoci requirement, and root size on ZFS;
  - the translation table, what is refused and why, and the recorded differences, including container-written logs and exit status;
  - double image storage and pruning;
  - that Compose should stay nested.
  - Result: the README's design summary and status cover native containers. `docs/embedding.md` has opt-in, shim, engine and project preparation, translation and refusals, recorded differences (container-written logs and exit status, forced stops, init, hostname files, health checks, volumes, `/dev/shm`, names, listing), images and auto-remove, keeping Compose nested, and how to run the native acceptance.
- [x] 7.4 Run `mise run check`.
  - Result: passed, with 263 tests, the reference and ledger check, strict OpenSpec validation and both Go helper checks.
