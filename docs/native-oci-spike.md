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
