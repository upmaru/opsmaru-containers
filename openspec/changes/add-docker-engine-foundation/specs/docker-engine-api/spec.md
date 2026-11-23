# Spec Delta

## ADDED Requirements

### Requirement: Host-mounted handler

The Docker Engine API SHALL be provided as a Plug that the host mounts on a listener the host owns. The library SHALL NOT create the socket, set its permissions, register a docker context or supervise the listener.

#### Scenario: Unmodified CLI on the host's socket

- **WHEN** the host mounts the handler on a Unix socket and the unmodified pinned `docker` CLI runs `docker version` with `DOCKER_HOST` set to it
- **THEN** the CLI prints the client and server versions without error

### Requirement: Pinned engine reference

The library SHALL pin one Docker Engine release as its reference and record the release, its source commit, its minimum and maximum API versions and the SHA-256 of its API description. The route inventory SHALL be generated from that description, and a check SHALL fail when the inventory and the description differ.

#### Scenario: Reference description changes

- **WHEN** the recorded API description is replaced without regenerating the inventory
- **THEN** the reference check fails and names the differing routes

### Requirement: Version negotiation

The handler SHALL answer `GET` and `HEAD /_ping` with the advertised API version headers as the reference engine does, and SHALL accept both unversioned paths and paths prefixed with a supported `/v{version}`. The advertised maximum SHALL be the lower of the reference's maximum and the nested engine's. A request for a version above the maximum or below the minimum SHALL be refused with status 400 and the reference engine's message, before the engine is contacted.

#### Scenario: Client newer than the engine

- **WHEN** a client requests a path with an API version above the advertised maximum
- **THEN** the handler answers 400 with the engine's too-new message and no engine request is made

#### Scenario: Older supported client

- **WHEN** a client requests a path with a supported version below the maximum
- **THEN** the request is relayed with that version prefix unchanged

### Requirement: Engine error shape

Every error the handler produces itself SHALL be a JSON object with a single `message` string and the status code the reference engine uses for that condition. Messages SHALL NOT contain credentials, registry tokens or Incus connection details.

#### Scenario: Unknown path

- **WHEN** a request matches no route in the inventory
- **THEN** the handler answers 404 with `{"message": "page not found"}`

### Requirement: Host authorization

The handler SHALL classify each request by method, route and class, and SHALL ask the host to authorize it before any backend access. A denial, a missing callback, a raised error or an answer after the deadline SHALL deny the request with status 403 and the engine error shape.

#### Scenario: Host denies

- **WHEN** the host denies a classified request
- **THEN** the handler answers 403 and neither Incus nor the engine is contacted

#### Scenario: Host does not answer in time

- **WHEN** the host's authorization answer arrives after the deadline
- **THEN** the request is denied and the late answer is ignored

### Requirement: Exhaustive route classification

Every method and path in the route inventory SHALL have exactly one class: `nested`, `native` or `unsupported`. An `unsupported` route SHALL carry a recorded reason and SHALL be refused with status 501 and the engine error shape naming the route. In this change no route SHALL be classified `native`. The reference check SHALL fail when an inventory route has no class.

#### Scenario: Unsupported route

- **WHEN** a client calls a route classified `unsupported`
- **THEN** the handler answers 501 with a message naming the route, and the engine is not contacted

#### Scenario: New route in a new reference

- **WHEN** the reference is updated and its description adds a route that has no class
- **THEN** the reference check fails until the route is classified

### Requirement: Streaming and hijacked connections

Hijacked and upgraded connections (container attach, exec start, the BuildKit session and gRPC routes) SHALL be relayed in both directions without reframing, preserving half-close in each direction. Long-lived responses (logs with follow, events, stats, build, pull and push progress) SHALL be relayed as they arrive, without buffering the whole response. Each client request SHALL use its own engine connection for its whole life, and the relay SHALL apply backpressure with a bounded buffer.

#### Scenario: Interactive exec

- **WHEN** the unmodified `docker` CLI runs an interactive command in a container and the user closes stdin
- **THEN** the command sees end of input, its remaining output reaches the CLI and the CLI exits with the command's exit code

#### Scenario: A stalled stream beside a short request

- **WHEN** one client holds an open log stream whose reader has stopped reading, and another client lists containers
- **THEN** the list request completes without waiting for the stalled stream

#### Scenario: Client disconnects mid-stream

- **WHEN** a client closes its connection during a followed log stream
- **THEN** the engine connection for that request is closed and its resources are released

### Requirement: No replay of possibly accepted mutations

When the engine connection fails after any byte of a request other than GET or HEAD was sent, the handler SHALL return an error to the client and SHALL NOT send the request again.

#### Scenario: Connection lost during container create

- **WHEN** the engine connection closes after the create request body was sent and before a response arrives
- **THEN** the client receives an error and the engine receives exactly one create request

### Requirement: Bind mount source decisions

For `POST /containers/create`, the handler SHALL extract every bind mount source from `HostConfig.Binds` and from `HostConfig.Mounts` entries of type `bind`, and SHALL ask the host to map each one to a path inside the engine instance. A mapped source SHALL replace the original in the relayed body, with the rest of the body unchanged. When the host denies a source, or supplies no mapping callback, the create SHALL be refused with status 400 and the engine error shape naming the source, before the engine is contacted. Named volumes and tmpfs mounts SHALL be relayed unchanged.

#### Scenario: Host maps a source

- **WHEN** a create names a bind source that the host maps to another path
- **THEN** the engine receives the mapped path and every other field as the client sent it

#### Scenario: No mapping callback

- **WHEN** a create names a bind source and the host supplies no mapping callback
- **THEN** the handler answers 400 naming the source and the engine receives nothing

#### Scenario: Named volume

- **WHEN** a create mounts only a named volume
- **THEN** the body is relayed unchanged and the mapping callback is not called

### Requirement: Engine not ready

When the nested engine is absent, stopped or not ready, the handler SHALL answer requests that need it with status 503 and the engine error shape. The handler SHALL NOT create or start the engine instance.

#### Scenario: Engine instance stopped

- **WHEN** a client lists containers while the engine instance is stopped
- **THEN** the handler answers 503 and the instance stays stopped
