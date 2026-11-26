# Exec socket bridge helper

`exec_socket_bridge.go` is the guest-side helper for
`Opsmaru.Containers.Transport.ExecBridge`. The package ships its source only.
No binary is built at compile time or included in the Hex package. A host
that selects the bridge builds the helper itself and installs it in its
engine image.

## Protocol

The helper takes one argument, the absolute path of dockerd's Unix socket.

- **Stdin** carries raw bytes to the socket peer. Stdin EOF half-closes the
  peer's write side.
- **Stdout** starts with `OCB1`. Frames follow, each a one-byte type and a
  four-byte big-endian length.
  - Type 0 carries 1 to 16,384 data bytes.
  - Type 1 has length 0 and ends output only.
- **Stderr** carries diagnostics.
- **Exit codes:** 0 when both directions end cleanly, 1 for a dial or stream
  failure, and 2 for a usage error.

## Build

Use Go 1.25.14, which `mise.toml` pins. Build from this directory:

```bash
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -buildvcs=false -ldflags='-s -w -buildid=' -o exec-socket-bridge .
```

Use `GOARCH=amd64` for x86-64 guests. `mise run check:bridge` runs `go vet` and
the unit tests. It then builds both architectures twice from clean caches and
fails if the two builds differ.

These SHA-256 digests come from that recipe with go1.25.14:

| Target | SHA-256 |
| --- | --- |
| linux/amd64 | `8528f9a4a9bfb451083c147558628088c421751f4b6a00d5aea305746054c991` |
| linux/arm64 | `b689ab9763aeff61206d020469a724b37596e1b221780b2c99a3c29f42610253` |

If you change the source, `go.mod` or the toolchain, update this table.

## Install

Copy the binary into the engine image at a root-owned absolute path, for
example `/usr/local/libexec/opsmaru/exec-socket-bridge`, mode `0755`. Pass
that path as the bridge's `:helper` option and dockerd's socket path as
`:socket`.
