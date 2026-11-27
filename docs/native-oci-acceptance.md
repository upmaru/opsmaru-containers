# Native OCI engine acceptance (task 7)

Task 7 of [add-native-oci-engine](../openspec/changes/add-native-oci-engine/tasks.md), run on 2026-11-27 with explicit opt-in. It is real-Incus and differential evidence. It is not host acceptance: no consumer ran it.

**Environment**
- An isolated Macus runtime: Incus 7.0.1 with `instance_oci`, LXC 7.0.0, a ZFS pool with `volume.zfs.reserve_space=true`, with its own client configuration and state directory. arm64 only.
- The nested engine from the Docker spike: Docker Engine 29.10.0 with `skopeo` and `umoci`, in project `macus-docker-spike`.
- A new native project `native-oci-accept` with its own images and profiles. Its default profile had a 256 MiB root on the default pool and `eth0` on `incusbr0`.
- Shim: linux/arm64 `30d1d3ab…`, the README digest, built by the README recipe.
- Client: the pinned Docker CLI 29.10.0 with a fresh configuration. Image: `alpine:3.22` (`49340b34…`), already in the nested engine.
- Listener: [`scripts/acceptance/native_listener.exs`](../scripts/acceptance/native_listener.exs) served this checkout on two owner-private Unix sockets. Creates on `nested.sock` stayed nested, and creates on `native.sock` ran native. Every bind source mapped to one directory that both servers could see.
- **Dependency patch:** `opsmaru_incus` 0.2.10 was patched locally to open an exec session's `control` websocket first (see findings). Without it, the image handoff failed every time. Native containers need an `opsmaru_incus` release with that fix before they ship.
- Raw logs, reports and telemetry are kept in the consumer's ignored spike directory.

**Verdict:** on the final code, the differential passed 21 of 21 runs (7 cases, 3 runs each), plus 24 more runs of the two foreground cases, with native timings close to nested. The native-only checks below passed. Reaching that took fixes for the real-Incus findings below. Fixes in the library's own modules have fixture tests that fail without them. Fixes inside `Native.Incus`, the adapter over `opsmaru_incus`, are exercised only against real Incus, as before.

## Differential

[`test/acceptance/native_differential.mjs`](../test/acceptance/native_differential.mjs) runs each case's CLI workflow against both sockets with the same image and compares exit codes, stdout, stderr and inspect fields. It normalises only container IDs, generated names and its own run tag.

| Case | What it compares | Nested | Native |
| --- | --- | --- | --- |
| `run --rm` with exit 3 | exit code, output, removal | 3.9 s | 4.6 s |
| Foreground run with a name | exit code, output, `State` fields, `rm` | 3.4 s | 4.3 s |
| Detached run, stop with a trapped TERM | exit 7, logs, `rm` | 6.2 s | 6.0 s |
| `kill -s USR1`, then the default kill | wait gives 9, then 137 after a new start | 8.5 s | 7.6 s |
| Exec | stdin EOF, `--user nobody`, `-w`, `-e`, exit 5, a missing binary | 13.0 s | 8.8 s |
| Logs | all, `--tail 2`, `--timestamps --tail 3`, follow until stop | 8.9 s | 7.9 s |
| Create fields, limits and a bind mount | env, label, workdir, hostname, user, `-m 64m`, `--cpus 0.5`, `--pids-limit 50`, a read-only bind, entrypoint, then `Config`, `HostConfig` and `Mounts`, the same checks inside the container, and rename | 7.8 s | 6.9 s |

Times are medians of the three runs. Inside the container, both engines reported the same cgroup limits: memory 67108864, PIDs 50 and CPU `50000 100000`. The logs case pauses 0.3 s around its stderr write, because the order across stdout and stderr is not deterministic in either engine.

Before the SFTP fix below, every case already passed, but a native foreground run took 34 s and the logs case 67 s.

## Native-only checks

These ran against the native socket alone, after the differential, on the final code.

- **Pause and unpause:** the status read `paused`, then `running`.
- **Restart** `-t 1`: running again, `RestartCount` 0 as in Docker.
- **Logs and listing:** `logs --since 2s` returned the recent lines. `ps` with a name filter found the container, and a label filter that matched nothing returned nothing.
- **Attach:** `docker attach` sent an output-only attach, because the CLI asks for stdin only when the container was created with `OpenStdin`, which native refuses. It followed the output, as Docker does. When the client was killed, the CLI proxied SIGTERM to the container (Docker's default `--sig-proxy`), and the following `stop` got 304.
- **`start -a`** on a command that printed a line and exited 4: the line, then exit 4. `docker wait` then answered 4.
- **Prune** with a run-label filter removed both stopped containers.
- **TTY exec:** the console size reached the container (`stty size` gave `40 100`), and a window change during the exec reached it too (`30 90`), as on nested. When the exec ended before the CLI's resize, dockerd answered 404 (`NotFound: process does not exist …`) and native answered 409. Native now gives dockerd's answer, confirmed against real Incus.
- **DNS:** `--dns` and `--dns-search` (two of each) gave the same nameservers and search line in `/etc/resolv.conf` as nested, apart from Docker's comment lines.
- **Refusals,** each a Docker-shaped error naming the native engine: `docker cp`, `stats`, `top`, `export`, `diff` and `update` (501), `run -i` (400 naming `AttachStdin, OpenStdin, StdinOnce`) and `run -p` (400 naming `HostConfig.PortBindings`).

## Ledger

`priv/docker/coverage.json` records native evidence in a separate `native` object on every route that has a `native` field. The routes come from the listener's telemetry for one more differential pass and the native-only checks, not from reasoning about the CLI.

- **Fixture, differential and real-Incus evidence:** create, list, inspect, start, stop, kill, wait, logs, attach, rename, remove, exec create, exec start and exec inspect.
- **Fixture and real-Incus evidence only,** so not verified for native: pause, unpause, restart, prune and exec resize. The differential has no case for them yet.
- **Refusals answered against real Incus:** `GET /archive`, `export`, `changes`, `top`, `stats` and `update`. The `top` refusal also has a fixture test.
- **No native evidence:** `HEAD` and `PUT /archive`, websocket attach and container resize. They share the refusal path, but no check sent them.

## Findings and fixes

Real Incus 7.0.1 behaved differently from the scripted backend in these ways. Each is fixed, and the design's risks record them. Those fixed in `Native.Incus` (the 500 read as Stopping, the power-key check, conditional patches, chunked pushes and the download result's shape) have no fixture test.

- **A held SFTP session holds up a stop.** `docker stop` with `logs -f` open took 60 s, and a foreground run's attach held one for about 31 s, until Incus gave up on the session. The follower and the attach now read the run record over their own session on every poll, close it once the followed run has finished, wait for the stop holding none, then read to the end with a new session. That brought both cases within a second of nested.
- **Stop state flaps.** While an OCI instance stopped, `GetInstance` and `GetInstanceState` both alternated between Running and Stopped, and `GetInstanceState` answered 500 `Invalid PID -1` for about 700 ms. `volatile.last_state.power` stays `RUNNING` until the stop hook finishes, together with the `instance-shutdown` event. The library reads a Stopped status with that key still `RUNNING`, and the 500, as Stopping.
- **Delete right after a stop.** `DeleteInstance` answered 400 `Instance is running` briefly after the status read Stopped. That refusal is retried within the deadline.
- **Start reads Stopped.** While a start was in flight, the instance read Stopped though the shim had already recorded the new run. A wait treats a missing exit status as final only once it has held for 2 s. In the last confirmation run, 1 of 21 differential runs showed a further race: a named foreground `docker run` returned, and inspect still said `running`. The wait had read the stale Stopped, then a record that the quick run had finished in between. Waits and attaches now read the state again after the record.
- **File reads fail around state changes.** The files API answered 500 (the fork helper's socket reset) while an instance started or stopped, and a failed read could take seconds. Run record reads are retried up to five times.
- **Event volume.** Every file read emits an `instance-file-retrieved` lifecycle event, including the wait's own reads. Waits wake only on state-change actions.
- **Conditional patches.** `opsmaru_incus` sends `PatchInstance` only with an ETag, so the library reads the instance first and retries a 412.
- **Late exec resize.** See the TTY exec check above.
- **Bind sources in inspect.** Native inspect reported the client's bind source, while nested reports the mapped one. Native now stores the mapped source.
- **Downloads from another process.** `opsmaru_incus` calls a file download's sink from its transfer worker, so the image producer's mailbox protocol lost chunks and the upload was reported uncertain after 61 s. The producer was rewritten to name every sender, and the scripted backend now calls sinks from another process too.
- **opsmaru_incus defects.** An exec session opens its websockets with `control` last, but Incus starts the command once channels 0 to 2 connect. A command that finishes quickly then ends the operation before `control` joins, and the session fails (`Only running operations can be connected`, or a closed channel). The image handoff failed 4 of 4 times unpatched and passed 12 of 12 with `control` first. Separately, a 3 MB single-chunk file upload was reported uncertain, so the library pushes in 64 KiB chunks.

## Not covered

- linux/amd64, because no amd64 host was available.
- Host (consumer) acceptance.
- A Compose project, which should stay nested.
- An image handoff of a large image under the library. The first spike timed the method by hand: 500 MB in 31 s.
