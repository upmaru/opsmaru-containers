# Spec Delta

## ADDED Requirements

### Requirement: Passive dependency

The library SHALL have no application callback. Loading or starting the `:opsmaru_containers` application SHALL NOT start a process, open a listener or socket, create state, read credentials or contact any backend.

#### Scenario: Host starts the dependency

- **WHEN** a host application lists `:opsmaru_containers` as a dependency and boots
- **THEN** no process, listener or connection exists that the host did not start itself

#### Scenario: Hostile web settings

- **WHEN** the dependency is loaded with `PHX_SERVER=true` and an invalid `PORT`
- **THEN** it ignores both and starts nothing

### Requirement: Explicit host context

Every operation and every handled request SHALL obtain its Incus connection, its `opsmaru_incus` host context and its engine instance reference from the host. The library SHALL NOT hold a global or default connection. When the host supplies no context, refuses, or reports the backend as not ready, the library SHALL fail before any backend access.

#### Scenario: Host refuses a context

- **WHEN** the host's context callback refuses a request
- **THEN** the request fails with the engine error shape and no Incus request is made

#### Scenario: Two hosts in one node

- **WHEN** two hosts in the same BEAM node serve requests with different connections
- **THEN** each request uses only the connection its own host supplied

### Requirement: Incus only through opsmaru_incus

The library SHALL reach Incus only through `opsmaru_incus` and the connection the host supplied. It SHALL NOT run a host command, probe for Incus or Docker sockets, or dial an address the host did not supply.

#### Scenario: No connection supplied

- **WHEN** an operation is called without a connection
- **THEN** it fails with an argument error and nothing is probed or dialed

### Requirement: No library-owned state

The library SHALL keep no database, file or long-lived in-memory record of engine objects. Metadata it needs across calls SHALL be stored on Incus objects under `user.opsmaru.containers.*` configuration keys.

#### Scenario: Host restarts

- **WHEN** the host restarts and calls the library again with the same connection
- **THEN** the library finds its engine instance from the Incus configuration keys alone

### Requirement: Optional web dependencies

`plug` and `cowboy` SHALL be optional dependencies. A consumer that does not depend on them SHALL compile the library and use the nested engine lifecycle operations; the Plug handler modules SHALL be absent.

#### Scenario: Consumer without a web stack

- **WHEN** a fresh consumer depends on the built Hex package without `plug` or `cowboy`
- **THEN** it compiles without warnings and can call the nested engine operations
