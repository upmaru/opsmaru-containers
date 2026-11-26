# Spec Delta

## ADDED Requirements

### Requirement: Native container placement and identity

A container routed to the native engine SHALL be an Incus OCI application container in the native project named by the host's context target, created only through `opsmaru_incus`. Its Docker ID SHALL be 64 lowercase hex characters from a cryptographically secure generator. Its instance name SHALL be `oc-` followed by the first 12 characters of the ID. The instance SHALL carry `user.opsmaru.containers.role=container` and keys recording the Docker ID, name, creation time, image ID, image reference, labels and normalised create configuration. The library SHALL keep no other record of native containers. Instances in the native project without the role key SHALL be ignored by every route.

#### Scenario: Native container visible to Incus

- **WHEN** a client runs `docker run -d IMAGE` and the host selects the native engine
- **THEN** `incus list --project NATIVE` shows an instance `oc-<12 hex>` whose `user.opsmaru.containers.id` equals the ID the client printed

#### Scenario: Unmarked instance in the native project

- **WHEN** the native project also holds an instance without the role key
- **THEN** it is absent from `docker ps -a` and no container route resolves to it

### Requirement: Images come from the nested engine

A native create SHALL resolve its image in the nested engine. A missing image SHALL produce the nested engine's own not-found response. The library SHALL create the instance from an Incus image in the native project whose property `opsmaru.containers.image_id` equals the Docker image ID. When none exists, it SHALL transfer that image once by the qualified handoff method and record the property. An uncertain handoff outcome SHALL be reconciled by reading the native project and MUST NOT be replayed. The native engine MUST NOT pull from a registry by itself. The process configuration SHALL be computed from the nested engine's image config and the create body, following Docker's merge rules, and written explicitly to instance keys.

#### Scenario: Locally built image

- **WHEN** a client builds `app:dev` through the nested engine and runs it natively
- **THEN** the native instance runs that exact image ID with the entrypoint and environment that a nested run would use

#### Scenario: Image not present

- **WHEN** a native create names an image the nested engine does not have
- **THEN** the client receives the nested engine's `No such image` response and no Incus image or instance is created

#### Scenario: Image already handed over

- **WHEN** a second native container uses the same image ID
- **THEN** no transfer happens and the existing Incus image is used

### Requirement: Checked create translation

Every field of the pinned API's container create body SHALL have exactly one recorded class in the packaged translation table: translated, ignored with a reason, or refused with a reason. A check SHALL fail when a field of the pinned API description is missing from the table. A native create that sets a refused field to a non-default value SHALL be refused with a Docker-shaped 400 that names each such field, before any Incus mutation. A non-numeric `User` SHALL be refused. Bind sources SHALL be mapped by the host's bind callback before becoming Incus disk devices, and refused without it.

#### Scenario: Published port on a native container

- **WHEN** a native create sets `HostConfig.PortBindings`
- **THEN** the client receives a 400 naming `HostConfig.PortBindings` and the native engine, and no instance or image transfer occurs

#### Scenario: Translated limits

- **WHEN** a native create sets `HostConfig.Memory` and `HostConfig.NanoCpus`
- **THEN** the instance has the corresponding `limits.memory` and `limits.cpu.allowance`

### Requirement: Native lifecycle

Start, stop, kill, restart, rename, remove and inspect SHALL be served for native containers as the design's lifecycle table states, with Docker's status codes and error shapes. Pause, unpause, signals other than `SIGKILL`, and stop signals other than the qualified one SHALL be refused unless qualification confirmed them. `docker cp`, `export`, `changes`, `top`, `stats`, `update` and `resize` on a native container SHALL be refused with a Docker-shaped error naming the native engine. Removing a running container without `force` SHALL produce the engine's conflict error.

#### Scenario: Stop and remove

- **WHEN** a client runs `docker stop C` then `docker rm C` on a running native container
- **THEN** the instance stops within the timeout and is then deleted from the native project

#### Scenario: Unsupported route

- **WHEN** a client runs `docker cp C:/etc/hostname .` on a native container
- **THEN** the client receives an error naming the native engine and no file transfer occurs

### Requirement: Native wait and exit status

Wait SHALL report the entrypoint's exit status as recorded by Incus, for the conditions `next-exit`, `not-running` and `removed`. It SHALL read the instance state after subscribing to its events, so an exit between the two is reported. When Incus cannot provide the exit status, wait MUST NOT report a status. For a container created with `AutoRemove`, a wait with `condition=removed` SHALL delete the stopped instance before answering. A host-invoked reap operation SHALL delete stopped auto-remove instances that no wait removed.

#### Scenario: Exit code reaches the CLI

- **WHEN** a client runs `docker run --rm IMAGE sh -c 'exit 3'` natively
- **THEN** the CLI exits with status 3 and the instance no longer exists

#### Scenario: Client gone before removal

- **WHEN** the client disconnects after an auto-remove container stopped and before its wait answered
- **THEN** the next reap deletes the stopped instance

### Requirement: Native exec

Exec create SHALL record the request on the instance under `user.opsmaru.containers.exec.<id>` and return a 64-hex exec ID. Exec start SHALL run it with Incus exec. Without a TTY, stdout and stderr SHALL be framed as Docker's multiplexed stream. The client's write EOF SHALL close Incus stdin while output continues until both output channels end. With a TTY, the stream SHALL be unframed and resize SHALL reach the Incus control channel. The exit code SHALL be written back so exec inspect reports it. An instance SHALL keep at most the newest 32 exec records.

#### Scenario: Stdin EOF

- **WHEN** a client runs `docker exec -i C sh -c 'cat; echo done' < file` on a native container
- **THEN** the file's content and `done` are printed and the command exits 0

#### Scenario: Exit code

- **WHEN** a client runs `docker exec C sh -c 'exit 7'` on a native container
- **THEN** the CLI exits with status 7

### Requirement: Native logs and attach

Logs and output-only attach SHALL be served from the Incus console log as qualification allows. Each option that the source cannot honour, including stream separation, timestamps, time bounds and follow, SHALL be refused with a Docker-shaped error naming the native engine, never answered with partial or empty output. Stdin attach and TTY containers SHALL be refused until qualification confirms console attach.

#### Scenario: Output of a finished container

- **WHEN** a native container ran `echo hello` and a client runs `docker logs C`
- **THEN** `hello` is printed

#### Scenario: Unsupported option

- **WHEN** Incus provides no timestamps and a client runs `docker logs -t C` on a native container
- **THEN** the client receives an error naming the native engine and the option

### Requirement: Native qualification gate

Translation work SHALL start only after a spike against isolated Incus 7.0.1 records: the entrypoint format and override behaviour, the availability of the entrypoint's exit status, output capture and follow, console attach, the graceful stop signal and whether the entrypoint is PID 1, freeze on OCI containers, DNS by instance name, exec half-close, and the image handoff method. If the exit status is unavailable, the change SHALL return to planning.

#### Scenario: Exit status unavailable

- **WHEN** the spike finds that Incus records no exit status for the entrypoint
- **THEN** the change returns to planning and no native wait is implemented

### Requirement: Native evidence

A native route SHALL be recorded as verified only with fixture evidence, real-Incus evidence, and a differential case that runs the same pinned CLI workflow against a nested and a native container from the same image and compares exit codes, output and translated fields. Nested passthrough evidence MUST NOT count for a native route.

#### Scenario: Passthrough is not native evidence

- **WHEN** a container route has differential evidence only as nested passthrough
- **THEN** the ledger does not record it as verified for native containers
