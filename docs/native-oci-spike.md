# Native OCI engine qualification spike (task 1)

Task 1 of [add-native-oci-engine](../openspec/changes/add-native-oci-engine/tasks.md), run on 2026-11-27 with explicit opt-in.

**Environment**
- An isolated Macus runtime: Incus 7.0.1, guest kernel 6.18.62, LXC 7.0.0, ZFS pool. It had its own client configuration and state directory, a scratch project `native-oci-spike`, and the nested engine from the Docker spike (Docker Engine 29.10.0, project `macus-docker-spike`).
- Client: `incus` 7.5.1.
- Images: `docker.io/library/alpine@sha256:49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f`, through an Incus OCI remote, plus two images built in the nested engine from it, with 10 MiB and 500 MiB random payloads.
- Raw logs are kept in the consumer's ignored spike directory.

**Verdict:** gate 1.2 fails. Incus 7.0.1 does not record the OCI entrypoint's exit status. Per the change, it returns to planning. The other items are recorded below for the re-plan.

| Item | Verdict | Finding |
| --- | --- | --- |
| 1.1 Entrypoint | Partial | `oci.entrypoint` is one string, split with shell-like quoting (no variable expansion), and it overrides the image. `oci.cwd`, `oci.uid`, `oci.gid` and `environment.*` set at create override the image too. **Arguments do not round-trip:** some arguments containing `$ \ | [ * ~ '` reach the process with extra backslashes. Docker's argv cannot be carried in this key exactly. |
| 1.2 Exit status (**gate**) | **Fail** | Exits 0, 3 and 137 leave identical results: status `Stopped`, status code 102, `volatile.last_state.power=STOPPED`, an `instance-shutdown` lifecycle event with no context, and nothing in `lxc.log`. |
| 1.3 Image handoff | **B works, A fails** | **B** (skopeo export from dockerd, `umoci unpack`, a split image whose `metadata.yaml` has `type: oci`, upload through `POST /1.0/images`) produced an OCI container (`volatile.container.oci=true`) running the image's own command. Incus derived `oci.entrypoint` from the bundle's `config.json`. Timings: 10 MiB took 2.0 s (convert 1.1, copy to host 0.5, upload 0.3). 500 MiB took 31.1 s (15.2, 10.9, 4.9), with 528 MB crossing the host path twice. **A** (an HTTPS registry in the engine as an `oci` source with a pinned `certificate`) fails: the Incus server runs `skopeo inspect` without the certificate, so the TLS verification fails. A private registry would have to be trusted by the guest's system CA store, which the Incus API cannot set. |
| 1.4 Output and console | Fail for logs | The console log merges stdout and stderr and has no timestamps. While the container runs, reads were empty or partial. After stop it was complete and could be read repeatedly. A restart clears it. Console attach needs a terminal (`incus console` fails with `inappropriate ioctl for device`), and the API console websocket was not tested. Docker `logs` and `attach` cannot be built on it. |
| 1.5 Stop and signals | Pass, with a caveat | PID 1 is `{incusd} init`, and the entrypoint runs as PID 4. A graceful `incus stop` delivered SIGTERM to the entrypoint, which exited within 1 s. `kill -TERM 1` through exec reaches Incus's init, not the entrypoint, and the container kept running. Other signals must target the entrypoint's PID. |
| 1.6 Freeze | Pass | `pause` gave `FROZEN`, and output stopped. `start` resumed it at the next tick. |
| 1.7 Exec | Pass | Stdin EOF: `cat; echo done` printed both lines and `done`. stdout and stderr are separate channels. Exit code 7 propagated. Numeric `--user`, `--group`, `--cwd` and `--env` applied. 1 MiB of stdin matched by SHA-256. A TTY exec reported its size. |
| 1.8 Networking | Pass | The managed bridge resolves OCI instance names (`n-sig2.incus` resolved and answered ping). An `eth0` device of type `none` leaves only `lo`. |

**Probes for the re-plan**
- A wrapper entrypoint that wrote `$?` to a file on the rootfs, read through the files API after the container stopped, returned `3` as expected.
- A file pushed through the files API into a created, never-started OCI container ran as its entrypoint (`/oc-helper`) on first start.

Together these support a packaged init shim. The library would push it into each native container before first start and make it the entrypoint. It would read the exact argv from a file, forward signals, record exit status and time, and write stdout and stderr to separate timestamped files. That would cover gates 1.1, 1.2 and 1.4 without Incus changes. The re-planned [design](../openspec/changes/add-native-oci-engine/design.md) adopts it, and task 2 of the change qualifies it in a second spike.

**Other observations**
- On a ZFS pool with `volume.zfs.reserve_space=true`, each native container reserves its full root size (2 GiB by default) up front. About a dozen probe containers exhausted a 29.5 GiB pool, and creates then failed (`size is greater than available space`). A native project needs a small root size or a different pool policy.
- The consumer's gateway (Macus) intermittently refused the trusted client (`403 unauthorized` after 1–2 s instead of a 3–8 ms answer). It closed an events stream as `revoked`. Afterwards it stopped relaying `operation` events while lifecycle and logging events still arrived, so CLI creates hung even though they had succeeded. A server restart restored it once, and it degraded again. That is a consumer issue, reported there. The spike worked around it by polling operations through the API.

# Second spike: the init shim (task 2)

Task 2 of the change, run on 2026-11-27 with explicit opt-in, against the same isolated runtime and the cached `alpine` OCI image. Each probe container had a 256 MiB root and the shim as its entrypoint. Log reads went through `opsmaru_incus` 0.2.10's SFTP client, the library's own path. Other reads went through the files API.

- **Shim:** linux/arm64, built by the README recipe. The gates and logs ran on `817ab1d1…`. The final build, `30d1d3ab…`, differs only in how a missing working directory is reported, and was confirmed with exact argv, that case, exit 3 and `kill HUP`.
- **Raw logs and probe scripts:** kept in the consumer's ignored spike directory.

**Verdict:** both gates pass, and every item qualified on arm64. linux/amd64 was not run, because no amd64 host was available.

| Item | Verdict | Finding |
| --- | --- | --- |
| 2.3 Exact argv (**gate**) | **Pass** | Arguments containing `$HOME`, `x\y`, `*`, an empty string, an embedded newline, single and double quotes, `$(id)`, a backtick form, `a;b&&c` and `héllo ✓` reached `printf` byte for byte. `printf` was found through the child's `PATH`. Docker's API and the spec are JSON, so argv is always valid UTF-8. |
| 2.4 Exit status (**gate**) | **Pass** | The run record gave 0; 3; 137 for a self-SIGKILL and for `init kill KILL`; 143 for `init kill TERM`; 4 for a trapped HUP; 137 for `init stop --timeout 2` on a child ignoring SIGTERM (about 2.4 s); and 5 for the spec's `stop_signal` SIGQUIT. Failed starts gave 127 (missing command or cwd), 126 (not executable) and 128 (unknown user), each with Docker's message. A forced Incus stop left a record without `finished_at`. Exit to `Stopped` took about 0.8 s, and the record was readable by then. |
| 2.5 Logs | Pass | Streams are separate, per-stream order is kept, and times are monotonic. Partial records are flagged. Records carry run numbers across nine restarts. Rotation keeps the newest files. A 250 ms SFTP follow delivered records within about 600 ms. With a 64 KiB × 3 rotation, a 160 KB burst outran it once, which is the loss rotation implies. All 300 lines written in the instant before exit arrived, read after the stop. SFTP works on stopped and frozen instances. 100 MiB was written in 1.2 s and read through SFTP in 3.3 s (about 32 MiB/s). |
| 2.6 Signals and stop | Pass, with a finding | `init kill` and `init stop` behave as designed. **A graceful `incus stop` sends SIGTERM to every process**, not only the entrypoint: a child trapping both signals ran its TERM handler and then the shim's QUIT. Exec into a frozen instance fails at once with `Instance is frozen` and works after unfreeze. |
| 2.7 Process setup | Pass | **User:** `daemon` → uid 2, gid 2, groups 1, 4, 10 and 1234 (with `group_add: ["wheel", "1234"]`), `HOME=/sbin`. `daemon:nogroup` → gid 65533. `4242:4243` → `HOME=/`. **Hostname, cwd and environment:** set, with the environment in Docker's order. **Exec mode:** raw Incus exec adds `HOME`, `LANG`, `PATH`, `TERM`, `USER`, `container` and `CREDENTIALS_DIRECTORY`. Through the shim, only the named variables appeared, `DROP` was removed, and the container's user and cwd were the defaults. Exit codes, stdin EOF and a TTY all worked. **Permissions:** a non-root process cannot read `/.opsmaru`. **OOM:** `memory.events` `oom_kill` is readable inside the container. With `limits.memory=64MiB`, a child's OOM kill set `oom_killed: true`, while the main process exited 0. Docker also reports any OOM kill in the container. |
| 2.8 Push | Pass (arm64) | Create took 0.55–0.6 s. Pushing the 3.0 MB shim and the spec took 0.27–0.42 s with the CLI's three requests. `GET /files?path=/.opsmaru` is 404 on a fresh instance and a listing when the path exists, so the collision check works. |
| 2.9 Foreground run | Pass | Three times, a reader noted its log position, closed its session, then started the container: a start of 0.27–0.31 s, a command that printed two lines and exited 4. The reader then reopened a session (retrying once while the container was stopping) and delivered both lines and exit code 4, 0.3–0.6 s after the start returned. |

**SFTP session rules** (new, now in design decision 8)
- A session ends when its instance stops, and the next request fails with a deadline or channel error. A new session opens about 86–300 ms later, once the stop completes.
- **A session held on a stopped instance holds up that instance's start.** A start made while the probe's session was open returned only after about 55 s, when the probe was killed. With the session closed first, starts took 0.27–0.31 s. The library must close its sessions on an instance before starting it, and must never keep one on a stopped instance.

**Other observations**
- The Docker process ran as PID 12 to 14, not PID 1, so native containers behave as with `--init`. That is recorded as a difference.
- The probes saw no 403s or hung requests from the consumer's gateway during this run. They didn't rely on event streams, which were affected in the first spike: stops were observed by polling instance state, and creates and state changes used `incus query --wait`.
