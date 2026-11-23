# Spec Delta

## ADDED Requirements

### Requirement: Engine instance from a host specification

The nested engine SHALL run in an Incus system container created from a host-supplied specification naming the instance, project, image source, profiles and any extra configuration and devices. The library SHALL add `security.nesting=true` and the marker `user.opsmaru.containers.role=engine`, and SHALL reject a specification that conflicts with either. The library SHALL NOT choose an image or install software in the instance.

#### Scenario: Specification disables nesting

- **WHEN** the host specification sets `security.nesting` to false
- **THEN** the specification is rejected before any Incus request

#### Scenario: Created instance

- **WHEN** the library creates the engine instance
- **THEN** the instance has the host's image, profiles and configuration plus the nesting key and the marker

### Requirement: Explicit, idempotent ensure

The library SHALL provide an ensure operation that creates the engine instance when absent, starts it when stopped and returns once the engine is ready or a deadline passes. Calling it for a ready engine SHALL make no mutation. Concurrent calls SHALL result in one instance. An instance creation or start whose outcome is unknown SHALL be reported as uncertain and SHALL NOT be sent again. Nothing in the library SHALL call ensure implicitly.

#### Scenario: Engine already ready

- **WHEN** ensure is called for a running, ready engine
- **THEN** it returns ready and sends no mutating Incus request

#### Scenario: Two concurrent callers

- **WHEN** two callers run ensure at the same time for an absent instance
- **THEN** one instance exists afterwards and both callers get ready or the same failure

#### Scenario: Create interrupted

- **WHEN** the Incus connection fails after the create request was sent
- **THEN** ensure reports an uncertain outcome and does not repeat the create

### Requirement: Foreign instances are never adopted

When an instance with the specified name exists without the marker, every lifecycle operation SHALL fail without changing it. The library's stop and remove operations SHALL act only on an instance that carries the marker, and remove SHALL run only when the host calls it.

#### Scenario: Name taken by another workload

- **WHEN** ensure finds an unmarked instance with the specified name
- **THEN** it fails with a conflict error and the instance is not started, stopped or reconfigured

#### Scenario: Remove on an unmarked instance

- **WHEN** remove is called for an unmarked instance
- **THEN** it fails and the instance is kept

### Requirement: Engine readiness

The engine SHALL count as ready only when the instance is running, the engine answers its ping route through the transport, and its API version range includes the reference's minimum version. An engine whose range does not SHALL be reported as incompatible with both ranges in the error.

#### Scenario: Engine older than the reference minimum

- **WHEN** the engine's maximum API version is below the reference's minimum
- **THEN** readiness fails as incompatible and the handler answers 503

#### Scenario: Instance running, engine not started yet

- **WHEN** the instance is running and the engine does not answer its ping route before the deadline
- **THEN** readiness fails as not ready and no request is relayed

### Requirement: Transport through the host's connection

The library SHALL reach the engine only through the host-supplied Incus connection, by default by running the engine's stdio dial helper in the instance over a non-interactive Incus exec, or through a dialer the host supplies. Each engine connection SHALL be one independent byte stream that supports half-close in both directions. When the client side ends, the library SHALL end the exec operation and close its channels.

#### Scenario: Default transport

- **WHEN** a request is relayed with the default transport
- **THEN** one exec operation is created for it in the engine instance and no address inside or outside the instance is dialed

#### Scenario: Host dialer

- **WHEN** the host supplies a dialer
- **THEN** the library uses it for every engine connection and creates no exec operation

#### Scenario: Client goes away

- **WHEN** the client connection closes while an engine connection is open
- **THEN** the exec operation for it ends and its channels are closed

### Requirement: Relay fidelity

For a `nested` route, the engine SHALL receive the client's method, path, query, headers and body unchanged except for hop-by-hop headers and host-mapped bind sources, and the client SHALL receive the engine's status, headers and body unchanged except for hop-by-hop headers. For each `nested` route with differential evidence, the same request sent to the pinned engine directly and through the library SHALL produce the same status and body.

#### Scenario: Differential check

- **WHEN** the differential suite sends a route's request to the pinned engine directly and through the handler
- **THEN** status and body match, and the result is recorded for that route in the evidence ledger

#### Scenario: Build with the unmodified CLI

- **WHEN** the unmodified pinned `docker` CLI builds an image from a context directory through the handler
- **THEN** the build completes and the image is listed by the engine

### Requirement: Truthful evidence ledger

The library SHALL keep a ledger with one entry per inventory route, recording its class and which evidence exists: fixture, differential and consumer. A route SHALL be described as verified only with differential evidence. Evidence for a `nested` route SHALL NOT be counted for a `native` class of the same route.

#### Scenario: Route with fixture evidence only

- **WHEN** a route has fixture evidence and no differential evidence
- **THEN** the ledger and the documentation list it as unverified

#### Scenario: Route moves to native later

- **WHEN** a later change reclassifies a route from `nested` to `native`
- **THEN** its nested evidence is not carried over and the route is unverified until native evidence exists
