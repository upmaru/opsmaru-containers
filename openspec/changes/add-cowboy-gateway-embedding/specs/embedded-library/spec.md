# Spec Delta

## ADDED Requirements

### Requirement: Passive Cowboy handler, transport and telemetry

Compiling, loading or starting the library MUST NOT start a Cowboy listener, a Ranch acceptor, an exec bridge session, a telemetry handler or any observer process. `Docker.CowboyHandler` SHALL compile only when `:cowboy_req` is loaded. The telemetry emitter SHALL compile to no-ops when `:telemetry` is absent. `telemetry` SHALL be an optional dependency.

#### Scenario: Consumer without a web stack

- **WHEN** a Hex consumer depends on the library without Plug, Cowboy or `:telemetry`
- **THEN** it compiles with warnings as errors, `Docker.CowboyHandler` is not loaded and starting the application creates no process

#### Scenario: Consumer with the web stack

- **WHEN** a Hex consumer depends on the library with Plug and Cowboy and starts the application
- **THEN** `Docker.CowboyHandler` is loaded and Ranch reports no listener

### Requirement: Qualified dependency floor

The library SHALL require `opsmaru_incus` at or above the version the packaged exec bridge was qualified with (0.2.10). The Hex package SHALL ship the bridge helper source and its notices with the reference data.

#### Scenario: Packaged artifact

- **WHEN** the Hex artifact is built and unpacked
- **THEN** it contains the reference data, the notices, `priv/exec_bridge/exec_socket_bridge.go` and `priv/exec_bridge/go.mod`, and it declares `opsmaru_incus ~> 0.2.10`
