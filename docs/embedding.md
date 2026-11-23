# Embedding the Docker Engine API

The host owns the listener, authenticated peer, Incus connection, readiness
and path mapping. Starting the library does not mount an endpoint.

## Provision and publish readiness

Supply a connected `Opsmaru.Incus` client scoped to an explicit project and
an instance name in `Opsmaru.Containers.Nested.Target`. The client remains
host-owned. `Opsmaru.Containers.Nested.ensure/3` accepts the target, a
`Nested.Spec` naming a prepared Docker image, and options containing a bounded
`Opsmaru.Incus.RequestContext` and a host dialer. The host serializes
lifecycle calls for each backend, project and instance. Reconcile uncertain
create and start outcomes before making another lifecycle mutation.

`ensure/3` returns the engine's observed minimum and maximum API versions.
Use `Nested.readiness/2` for a fresh observation of a running instance. The
host publishes those values in `Docker.Capabilities` bound to the same
target and a monotonic expiry in milliseconds, and supplies the snapshot
with a ready `Opsmaru.Containers.Context`. Admission consumes that snapshot
locally.

Implement `Opsmaru.Containers.Transport` to open an independent connection
to dockerd on the host's private transport. Its `Transport.Stream` adapter
supports one concurrent reader and writer, independent write EOF, bounded
reads and explicit closure. The owner of the request defines the lifetime of
that connection. The
[live acceptance report](docker-live-acceptance.md) records the qualification
results for the candidate Incus exec transport.

## Mount ordinary HTTP and raw streams

Implement `Opsmaru.Containers.Host`. Its callbacks resolve the verified
identity and target, authorize the classified request and optionally map
bind paths. Keep these callbacks local and bounded. This policy covers
access to one Docker engine trust domain.

For ordinary HTTP, explicitly include Plug in the host, then mount
`Opsmaru.Containers.Docker.Plug` with `host: YourPolicy`. The host may pass
verified listener data in `conn.private[:opsmaru_containers_peer]`. The
library's Plug path also handles detached exec.

For attaches, attached exec, and requests upgrading to WebSocket or h2c, the
host's HTTP/1.1 listener hands off its stream to
`Opsmaru.Containers.Docker.Raw.relay/4`. Pass the parsed method, origin-form
path, query, lowercase headers, bounded request body and any already-read
connection bytes. The adapter keeps the listener outside the library and
gives the relay ownership of the connection after a valid upstream
handshake. A returned `{:http, status, headers, body}` is an ordinary HTTP
response for the host to send. A returned `{:relayed, result}` means the
relay owned and closed both streams. The host chooses the listeners and
transport adapters for these handoff semantics.

## Scope

The reference tracks Docker Engine and CLI 29.10.0, Buildx 0.39.1 with the
Docker driver, and Compose 5.8.0. See the route inventory and evidence ledger
under `priv/docker` for supported routes and recorded checks. The ledger
distinguishes scripted fixtures, real-engine differential checks, real-Incus
acceptance and consumer acceptance.

Container bind mounts require a host path mapping. Custom volume-driver
options are refused, including named volumes with local-driver bind
options. Host port forwarding belongs to the consumer. Swarm, daemon plugin
management and diagnostics are excluded from the relay profile.

## Live differential checks

The read-only differential harness expects separately supplied Unix socket
paths to direct and relayed access to pinned Docker 29.10.0 with equivalent
initial state. Run it only against an isolated project with private
connections and disposable fixtures.

```sh
OPSMARU_DOCKER_ACCEPTANCE=isolated \
OPSMARU_DOCKER_DIRECT_SOCKET=/path/to/direct.sock \
OPSMARU_DOCKER_RELAY_SOCKET=/path/to/relay.sock \
mise exec -- node test/acceptance/docker_differential.mjs
```

The harness checks version, ping, and container, image, volume and network
list responses. IDs and configured objects must match across the two views.
Mutation, streaming and CLI acceptance require their own fixtures and
evidence.

Run the CLI acceptance harness against a disposable relay target with the
same opt-in. Supply the absolute Docker CLI path in `OPSMARU_DOCKER_CLI`,
the pinned Buildx and Compose directory in `OPSMARU_DOCKER_PLUGIN_DIR`,
the listener in `OPSMARU_DOCKER_RELAY_SOCKET`, and a shell-capable public
fixture image by digest in `OPSMARU_DOCKER_TEST_IMAGE`. Run
`mise exec -- sh test/acceptance/docker_cli.sh`. The harness uses a fresh
Docker CLI configuration and run-scoped container and image names.
