# Spec Delta

## ADDED Requirements

### Requirement: Split raw entry

The raw adapter SHALL provide `Raw.open/3` and `Raw.run/4` beside `Raw.relay/4`.

`open` SHALL admit the request, dial the transport, send the upstream request and read the engine's response head. On a raw handshake it SHALL return `{:upgrade, response, backend, tail}`, where `response` carries the status, protocol and normalized headers that `relay/4` would write. Otherwise it SHALL return `{:http, status, headers, body}` with the backend already closed.

`run` SHALL first deliver the engine tail to the frontend and the frontend's request tail to the backend, each exactly once and before later bytes. It SHALL then relay both directions with independent write EOF, write no response head, and close both streams on return.

`relay/4` SHALL keep its return values and wire bytes. `open` and `run` for one exchange MUST be called from the same process.

#### Scenario: Host that owns the socket from the start

- **WHEN** a host calls `Raw.relay/4` for an attach upgrade
- **THEN** the bytes written to its stream are identical to the 0.1.0 relay's, including the `101 UPGRADED` head

#### Scenario: Host that sends the 101 itself

- **WHEN** a host calls `Raw.open/3`, sends the returned status and headers itself, and calls `Raw.run/4` with its buffered bytes
- **THEN** the engine receives the buffered bytes once and in order, and the client receives the engine tail before later output

#### Scenario: Rejected before dial

- **WHEN** `Raw.open/3` is called for a request the host denies
- **THEN** it returns `{:http, 403, headers, body}` and no transport is dialed

### Requirement: Docker exchange telemetry

When a host has attached a handler, every request that reaches `Docker.Plug`, `Raw.relay/4`, `Raw.open/3` or `Docker.CowboyHandler` SHALL emit:

- one `[:opsmaru_containers, :docker, :exchange, :start]` event;
- at most one `[:opsmaru_containers, :docker, :request]` event, when a response head is committed or the request is refused;
- exactly one `[:opsmaru_containers, :docker, :exchange, :stop]` event, when the exchange really ends, including when its owning process is killed.

Requests the Cowboy handler passes to its fallback SHALL emit nothing from that handler. Emission SHALL be optional at compile time, start no process when no handler is attached, never raise into a request and never change a decision, deadline or wire byte.

#### Scenario: Long-lived attach

- **WHEN** an attach upgrade is relayed for an hour and the client then disconnects
- **THEN** the request event is emitted when the 101 is committed, and one stop event is emitted at disconnect with the tunnelled byte counts and `outcome: :ok`

#### Scenario: Refused request

- **WHEN** the host denies a request
- **THEN** one start, one request and one stop event are emitted with status 403, `outcome: :not_sent` and `reason: :denied`

#### Scenario: Relay killed

- **WHEN** the relay process for a raw stream is killed
- **THEN** exactly one stop event is emitted with `reason: :killed` and the bytes moved until then

#### Scenario: No handler attached

- **WHEN** no handler is attached to the `[:opsmaru_containers, :docker]` prefix
- **THEN** no observer process is started and responses are byte-identical to runs with a handler

### Requirement: Bounded secret-free Docker event metadata

Docker event metadata SHALL contain only the documented keys: span context, adapter, host module, mode, method, route template, accepted path, requested API version, peer address and port, the SHA-256 fingerprint of a presented client certificate, status, outcome and reason from a closed set. It MUST NOT contain the query string, any header (including `authorization` and `x-registry-auth`), request or response bodies, stream bytes, the host identity or context, the Incus client or target, bind sources, error messages, or a path that admission refused.

#### Scenario: Registry credentials

- **WHEN** a client pulls an image with an `x-registry-auth` header
- **THEN** no event value contains the header or any part of its value

#### Scenario: Build arguments in the query

- **WHEN** a client starts a build whose query carries `buildargs`
- **THEN** the events carry the route and path but not the query string
