# Spec Delta

## ADDED Requirements

### Requirement: Native container placement and identity

A container routed to the native engine SHALL be an Incus OCI application container in the native project named by the host's context target, created only through `opsmaru_incus`. Its Docker ID SHALL be 64 lowercase hex characters from a cryptographically secure generator. Its instance name SHALL be `oc-` followed by the first 12 characters of the ID. The instance SHALL carry `user.opsmaru.containers.role=container` and keys recording the Docker ID, name, creation time, image ID, image reference, labels, normalised create configuration, auto-remove flag and init shim digest. The library SHALL keep no other record of native containers. Instances in the native project without the role key SHALL be ignored by every route.

#### Scenario: Native container visible to Incus

- **WHEN** a client runs `docker run -d IMAGE` and the host selects the native engine
- **THEN** `incus list --project NATIVE` shows an instance `oc-<12 hex>` whose `user.opsmaru.containers.id` equals the ID the client printed

#### Scenario: Unmarked instance in the native project

- **WHEN** the native project also holds an instance without the role key
- **THEN** it is absent from `docker ps -a` and no container route resolves to it

### Requirement: Images come from the nested engine

A native create SHALL resolve its image in the nested engine. A missing image SHALL produce the nested engine's own not-found response. The library SHALL create the instance from an Incus image in the native project whose property `opsmaru.containers.image_id` equals the Docker image ID. When none exists, it SHALL export the image from dockerd, convert it inside the engine instance with skopeo and umoci, and upload it as a split image through `opsmaru_incus`, without host files, recording the property. Handoffs of one image ID SHALL be serialized per target. An uncertain handoff outcome SHALL be reconciled by reading the native project and MUST NOT be replayed. The native engine MUST NOT pull from a registry by itself. A missing skopeo or umoci in the engine instance SHALL produce a named error before any conversion.

#### Scenario: Locally built image

- **WHEN** a client builds `app:dev` through the nested engine and runs it natively
- **THEN** the native instance runs that exact image ID with the argv and environment that a nested run would use

#### Scenario: Image not present

- **WHEN** a native create names an image the nested engine does not have
- **THEN** the client receives the nested engine's `No such image` response and no Incus image or instance is created

#### Scenario: Image already handed over

- **WHEN** a second native container uses the same image ID
- **THEN** no transfer happens and the existing Incus image is used

### Requirement: Native init shim

The library SHALL ship the source of an init shim with unit tests, a reproducible build recipe and SHA-256 digests for linux/arm64 and linux/amd64, and SHALL NOT ship a binary. A check SHALL fail when two clean builds of either architecture differ or when the digests do not match the recipe. The host SHALL supply shim binaries per architecture in its context. The library SHALL refuse a target whose shim binary is missing or whose digest is not listed for its version. It SHALL refuse a create whose image architecture has no shim. For each native container the library SHALL set the entrypoint to `/.opsmaru/init` with user and group 0 and working directory `/`. Before the first start it SHALL push the shim and the process spec to `/.opsmaru`. A create whose image already contains `/.opsmaru` SHALL be refused and its instance deleted. Every file the shim writes SHALL be parsed as untrusted input with size bounds, and a malformed file SHALL produce a Docker-shaped error naming the native engine.

#### Scenario: Unknown shim binary

- **WHEN** the host's context names a shim binary whose SHA-256 is not in the library's digest table
- **THEN** target validation fails with a configuration error and no native container can be created

#### Scenario: Exact argv

- **WHEN** a client runs natively `docker run IMAGE printf '%s|' '$HOME' 'a b' 'x\y' '*'`
- **THEN** the output is `$HOME|a b|x\y|*|`, as in a nested run

#### Scenario: Tampered run record

- **WHEN** a container process overwrites `/.opsmaru/state/run.json` with malformed content and a client runs `docker inspect C`
- **THEN** the client receives an error naming the native engine and the library keeps serving other containers

### Requirement: Checked create translation

Every field of the pinned API's container create body SHALL have exactly one recorded class in the packaged translation table: translated, ignored with a reason, or refused with a reason. A check SHALL fail when a field of the pinned API description is missing from the table. A native create that sets a refused field to a non-default value SHALL be refused with a Docker-shaped 400 that names each such field, before any Incus mutation. The process argv, environment, working directory, user, supplementary groups, hostname and stop signal SHALL be computed by Docker's merge rules and carried in the shim's spec, with user and group names resolved inside the container. Bind sources SHALL be mapped by the host's bind callback before becoming Incus disk devices, and refused without it or when the target is under `/.opsmaru`. The documented differences from a nested container SHALL be listed with the table.

#### Scenario: Published port on a native container

- **WHEN** a native create sets `HostConfig.PortBindings`
- **THEN** the client receives a 400 naming `HostConfig.PortBindings` and the native engine, and no instance or image transfer occurs

#### Scenario: Translated limits

- **WHEN** a native create sets `HostConfig.Memory` and `HostConfig.NanoCpus`
- **THEN** the instance has the corresponding `limits.memory` and `limits.cpu.allowance`

#### Scenario: Named user

- **WHEN** a native create sets `User` to `nginx` and the image's `/etc/passwd` maps it to uid 101
- **THEN** the process runs as uid 101 with that user's groups

### Requirement: Native lifecycle

Start, stop, kill, restart, pause, unpause, rename, remove and inspect SHALL be served for native containers as the design's lifecycle table states, with Docker's status codes and error shapes. Start SHALL report a failed `execve` as dockerd does and leave the container exited with 127 or 126. Stop SHALL send the requested or configured stop signal through the shim, then SIGKILL after the timeout, with an Incus forced stop only as a backstop. Kill SHALL deliver any requested signal to the container's process through the shim. `docker cp`, `export`, `changes`, `top`, `stats`, `update` and `resize` on a native container SHALL be refused with a Docker-shaped error naming the native engine. Removing a running container without `force` SHALL produce the engine's conflict error.

#### Scenario: Stop and remove

- **WHEN** a client runs `docker stop C` then `docker rm C` on a running native container
- **THEN** the instance stops within the timeout and is then deleted from the native project

#### Scenario: Custom signal

- **WHEN** a client runs `docker kill -s HUP C` on a native container whose process traps SIGHUP
- **THEN** the process receives SIGHUP and keeps running

#### Scenario: Command not found

- **WHEN** a client runs natively `docker run IMAGE no-such-command`
- **THEN** the client receives dockerd's start error and `docker inspect` reports exit code 127

#### Scenario: Unsupported route

- **WHEN** a client runs `docker cp C:/etc/hostname .` on a native container
- **THEN** the client receives an error naming the native engine and no file transfer occurs

### Requirement: Native wait and exit status

The exit status of a native container SHALL come from the shim's run record, written atomically when the process exits. A process killed by a signal SHALL be recorded as 128 plus the signal number. When the instance has stopped and the current run has no exit record, the library SHALL report exit code 137 and an error stating that the exit status was not recorded. Wait SHALL serve the conditions `next-exit`, `not-running` and `removed`, reading the instance state after subscribing to its events so an exit between the two is reported. For a container created with `AutoRemove`, a wait with `condition=removed` SHALL delete the stopped instance before answering. A host-invoked reap operation SHALL delete stopped auto-remove instances that no wait removed.

#### Scenario: Exit code reaches the CLI

- **WHEN** a client runs `docker run --rm IMAGE sh -c 'exit 3'` natively
- **THEN** the CLI exits with status 3 and the instance no longer exists

#### Scenario: Forced stop without a record

- **WHEN** an administrator force-stops a running native container with Incus
- **THEN** `docker inspect` reports exit code 137 and a `State.Error` saying the exit status was not recorded

#### Scenario: Client gone before removal

- **WHEN** the client disconnects after an auto-remove container stopped and before its wait answered
- **THEN** the next reap deletes the stopped instance

### Requirement: Native exec

Exec create SHALL record the request on the instance under `user.opsmaru.containers.exec.<id>` and return a 64-hex exec ID. Exec start SHALL run the shim's `exec` mode through Incus exec, which SHALL apply the requested user (name or number), working directory and exactly the container and exec environment plus Docker's defaults, then replace itself with the command. Without a TTY, stdout and stderr SHALL be framed as Docker's multiplexed stream. The client's write EOF SHALL close Incus stdin while output continues until both output channels end. With a TTY, the stream SHALL be unframed and resize SHALL reach the Incus control channel. The exit code SHALL be written back so exec inspect reports it. An instance SHALL keep at most the newest 32 exec records.

#### Scenario: Stdin EOF

- **WHEN** a client runs `docker exec -i C sh -c 'cat; echo done' < file` on a native container
- **THEN** the file's content and `done` are printed and the command exits 0

#### Scenario: Exit code

- **WHEN** a client runs `docker exec C sh -c 'exit 7'` on a native container
- **THEN** the CLI exits with status 7

#### Scenario: Environment is exact

- **WHEN** a client runs `docker exec -e A=1 C env` on a native container
- **THEN** the output lists the container's environment, `A=1` and Docker's defaults, and no variable that only Incus adds

### Requirement: Native logs and attach

The shim SHALL write stdout and stderr as separate records in arrival order, each with its run number and a nanosecond timestamp, to numbered files that are never renamed. It SHALL rotate them by the translated size and count, defaulting to the host's setting. Logs SHALL keep records across restarts. `docker logs` on a native container SHALL honour `stdout`, `stderr`, `timestamps`, `since`, `until`, `tail` and `follow`. A follow SHALL deliver every record written before the instance stopped, then end. `details` SHALL be refused. The `none` log driver SHALL make logs answer with Docker's own error for a driver that cannot be read. Output-only attach SHALL stream the records of the next run from its first record. Stdin attach and TTY containers SHALL be refused.

#### Scenario: Separate streams

- **WHEN** a native container ran `sh -c 'echo out; echo err >&2'` and a client runs `docker logs C 2>/dev/null`
- **THEN** only `out` is printed

#### Scenario: Output survives restart

- **WHEN** a native container printed `first`, was restarted and printed `second`
- **THEN** `docker logs C` prints `first` then `second`

#### Scenario: Foreground run sees all output

- **WHEN** a client runs natively `docker run IMAGE sh -c 'echo a; echo b'` without `-d`
- **THEN** the CLI prints `a` and `b` and exits 0

### Requirement: Native qualification gates

Native work SHALL be gated by two spikes against isolated Incus 7.0.1, each recorded in the spike report. The first, recorded on 2026-11-27, qualified Incus's own behaviour and found that Incus records no exit status. Translation work SHALL start only after the second spike qualifies the init shim. It covers exact argv, exit status for normal exits, signal deaths, stop and failed `execve`; log separation, order, timestamps, restart persistence, rotation and follow through SFTP; signal delivery and stop; user, group, hostname and environment setup; push and collision handling; and out-of-memory detection. If the shim cannot carry exact argv or record exit status, the change SHALL return to planning.

#### Scenario: Shim cannot record exit status

- **WHEN** the second spike finds that the shim's exit record cannot be read after the instance stops
- **THEN** the change returns to planning and no native wait is implemented

### Requirement: Native evidence

A native route SHALL be recorded as verified only with fixture evidence, real-Incus evidence, and a differential case that runs the same pinned CLI workflow against a nested and a native container from the same image and compares exit codes, output and translated fields, normalising only the documented differences. Nested passthrough evidence MUST NOT count for a native route.

#### Scenario: Passthrough is not native evidence

- **WHEN** a container route has differential evidence only as nested passthrough
- **THEN** the ledger does not record it as verified for native containers
