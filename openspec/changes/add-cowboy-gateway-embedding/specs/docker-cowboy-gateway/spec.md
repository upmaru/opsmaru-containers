# Spec Delta

## ADDED Requirements

### Requirement: Same-listener Cowboy handler

The library SHALL provide `Opsmaru.Containers.Docker.CowboyHandler`, compiled only when `:cowboy_req` is loaded, for mounting on a host-owned Cowboy listener with a host policy module and a `fallback` Cowboy handler. The handler MUST NOT open a listener, configure TLS or start any process before it receives a request. It SHALL take only HTTP/1.1 requests whose path matches a route-table entry with `docker_stream`, `h2c_upgrade` or `websocket` takeover. Every other request SHALL go to the fallback handler unchanged. The fallback's `upgrade` and `terminate` callbacks SHALL be delegated, so the handler can sit behind or in front of another chained handler.

#### Scenario: Ordinary request on the chained listener

- **WHEN** a client sends `GET /v1.57/containers/json` through the handler with `Plug.Cowboy.Handler` as fallback
- **THEN** the host's Plug pipeline serves it and this handler performs no admission, dial or telemetry for it

#### Scenario: Foreign WebSocket upgrade

- **WHEN** a client sends a WebSocket upgrade to a path that is not a Docker takeover route
- **THEN** the fallback handler receives the request with its headers and body unread

#### Scenario: Chained behind the Incus handler

- **WHEN** a host mounts `Opsmaru.Incus.Gateway.CowboyHandler` with this handler as its fallback
- **THEN** Incus SFTP/NBD upgrades, Docker raw upgrades and ordinary Plug requests are each served by their own handler on the same listener

### Requirement: Policy before any dial

The handler SHALL run the host policy and Docker admission before any backend dial. A request that is denied, unsupported, out of version range or not ready SHALL receive the Docker-shaped error that `Raw.relay/4` would return, and no transport SHALL be dialed.

#### Scenario: Host denies an attach

- **WHEN** the host policy denies `POST /containers/abc/attach` carrying `Upgrade: tcp`
- **THEN** the client receives 403 with `{"message": "request denied"}` and the dialer is never called

#### Scenario: Engine not ready

- **WHEN** the host context reports no ready capability snapshot for an exec start upgrade
- **THEN** the client receives 503 with the engine error shape and the dialer is never called

### Requirement: Raw requests without an upgrade

A `POST /exec/{id}/start` request without an `Upgrade` header SHALL go to the fallback handler unchanged, because detached exec is sent without an upgrade and the Plug serves it. Any other request on a Docker takeover route without an `Upgrade` header, and any request on a Docker takeover route arriving over HTTP/2, SHALL receive HTTP 400 with the Docker error shape and a message that names the missing upgrade. Such a request MUST NOT be admitted, dialed or passed to the fallback.

#### Scenario: Detached exec

- **WHEN** a client sends `POST /exec/abc/start` with body `{"Detach": true}` and no `Upgrade` header
- **THEN** the fallback handler receives the request with its body unread, and this handler performs no admission or dial

#### Scenario: Attach without Upgrade

- **WHEN** a client sends `POST /containers/abc/attach?stream=1&stdout=1` with no `Upgrade` header
- **THEN** the client receives 400 with a JSON `message`, no dial occurs and the fallback handler is not invoked

#### Scenario: BuildKit session without h2c

- **WHEN** a client sends `POST /session` without `Upgrade: h2c`
- **THEN** the client receives 400 with the Docker error shape

### Requirement: Cowboy switch-protocol handoff

For an admitted raw upgrade, a relay process owned by the handler SHALL call `Raw.open/3`. On `{:upgrade, response, backend, tail}`, the handler SHALL cast `{:switch_protocol, headers, Module, state}` with headers equal to the response headers `Raw.relay/4` would write. Its `takeover/7` callback SHALL transfer the client socket to that relay process. The relay SHALL call `Raw.run/4` with a frontend `Transport.Stream` over Cowboy's transport and socket, and with Cowboy's buffered bytes as the request tail. After takeover the connection MUST NOT return to Cowboy's HTTP parser. On `{:http, status, headers, body}`, the handler SHALL reply with that response through Cowboy.

#### Scenario: Attached exec with buffered stdin

- **WHEN** a client sends `POST /exec/abc/start` with `Upgrade: tcp` and stdin bytes in the same TCP segment as the request
- **THEN** the client receives one 101 response, the engine receives the buffered stdin bytes exactly once and before any later stdin, and output flows back

#### Scenario: Engine refuses the upgrade

- **WHEN** the engine answers an attach upgrade with 404 and a JSON body
- **THEN** the client receives that status and body through Cowboy and the backend stream is closed

#### Scenario: Takeover never arrives

- **WHEN** the 101 has been cast but Cowboy does not call `takeover/7` within the handoff timeout
- **THEN** the relay closes the backend, reports `reason: :handoff_timeout` and `outcome: :sent`, and does not retry the request

#### Scenario: Status line

- **WHEN** an upgrade completes through Cowboy
- **THEN** the response status code is 101 with the same headers `Raw.relay/4` would send, and the documentation records that the reason phrase is Cowboy's

### Requirement: Half-close over Cowboy transports

The Cowboy frontend stream SHALL map write EOF to the transport's write shutdown, which on TLS sends `close_notify`. It SHALL report a transport closed notification as read EOF, and the relay SHALL forward that EOF to the backend. Over TCP, both directions SHALL keep the opposite direction open after one side's EOF. Over TLS, engine-first EOF SHALL keep the client's write direction open. When the client's `close_notify` ends the TLS session, the relay SHALL still forward EOF to the engine. A later failed frontend write SHALL end the exchange with `reason: :caller_closed`, never with a reported success. This limitation SHALL be documented.

#### Scenario: Engine closes output first over TLS

- **WHEN** the engine ends its output on a TLS raw stream while the client keeps writing
- **THEN** the client reads all output followed by EOF, and bytes the client sends afterwards reach the engine

#### Scenario: Client closes input first over TLS

- **WHEN** the client sends `close_notify` after its stdin on a TLS raw stream
- **THEN** the engine observes EOF on its input, and any engine output that cannot then be written ends the exchange with `reason: :caller_closed`

#### Scenario: Client closes input first over TCP

- **WHEN** the client half-closes a plain TCP raw stream
- **THEN** the engine observes EOF and the client still receives the engine's remaining output
