# Spec Delta

## ADDED Requirements

### Requirement: Packaged exec bridge transport

The library SHALL provide `Opsmaru.Containers.Transport.ExecBridge`, a `Transport` and `Transport.Stream` implementation that reaches dockerd through a non-interactive Incus exec of the installed bridge helper on the host-supplied Incus connection. It SHALL be used only when the host selects it as the context dialer.

It SHALL validate its options at dial time, before any exec is created:

- absolute helper and socket paths;
- an optional `Opsmaru.Incus.RequestContext`; without one, the bridge uses the target's client as supplied and the relay's stream deadline bounds the stream;
- per-connection input and output byte limits, capped by the connection's stream limit;
- an optional keepalive interval of 1 to 3,600,000 ms;
- an optional observer PID.

Exceeding a limit SHALL fail the stream visibly without truncating. Closing a stream SHALL signal an incomplete helper and wait a bounded time, then close the session channels. It MUST NOT send an Incus DELETE or retry. The module documentation SHALL state the qualified stack and the open stdin write stall.

#### Scenario: Invalid options

- **WHEN** a host supplies a relative helper path
- **THEN** the dial fails, the request gets the Docker-shaped 503 for an engine that is not ready, and no exec operation is created

#### Scenario: Duplex EOF

- **WHEN** a client ends its input on an attached exec relayed through the bridge
- **THEN** the engine receives EOF and the client still receives the remaining output and the output EOF

#### Scenario: No default selection

- **WHEN** a host context supplies its own dialer
- **THEN** no bridge exec is created for any request

### Requirement: Bridge helper protocol

The helper SHALL connect to the absolute Unix socket path it is given and pass stdin bytes to it unchanged, closing the socket's write side when stdin ends. It SHALL write the header `OCB1` on stdout, followed by frames of a 1-byte type and a 4-byte big-endian length. Type 0 carries 1 to 16,384 data bytes. Type 1 carries no bytes and ends output only. The dialer SHALL deliver only peer bytes and directional EOF to the relay, and SHALL treat a missing header, an unknown type or an out-of-range length as a stream error.

#### Scenario: Wrong header

- **WHEN** the helper's stdout does not begin with `OCB1` before the dial deadline
- **THEN** the dial fails with a handshake error and the session is closed

#### Scenario: Output ends before input

- **WHEN** the engine closes its write side while the client is still sending
- **THEN** the dialer reports EOF to the relay and later client bytes still reach the engine

### Requirement: Packaged helper source

The Hex package SHALL include the helper's Go source, a pinned `go.mod` and build instructions under `priv/exec_bridge`, and SHALL include no helper binary. The repository check SHALL build the helper for linux/amd64 and linux/arm64 with the pinned toolchain, and SHALL fail if two clean builds differ.

#### Scenario: Engine image build

- **WHEN** an engine image pipeline unpacks the released package and runs the documented build command with the pinned Go toolchain
- **THEN** it produces a static helper whose SHA-256 matches the digest recorded for that release and architecture
