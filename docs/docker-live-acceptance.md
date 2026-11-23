# Live Docker acceptance

On 2026-11-23, the Docker foundation at `1b8c366` was exercised against
Incus 7.0.1 through an authenticated loopback TLS gateway. The run created a
dedicated Debian 13 arm64 system container in a new Incus project, using
Docker Engine and CLI 29.10.0 and Docker API 1.57. The disposable host
listener injected an experimental Incus exec dialer explicitly. It used
separate owner-private Unix sockets for the direct Docker byte baseline and
the library relay. The two sockets reached the same daemon through the
same exec transport. These results cover this test host and fixture. The
Macus consumer integration gate remains separate.

## Exec transport qualification

The default transport remains a host-supplied dialer. The pinned Docker
stdio helper closes the daemon socket when daemon-to-stdout copying ends.
A synthetic Unix peer inside the isolated instance sent output and then
closed only its own write side. The client observed stdout EOF, the Incus
stdin channel was closed, and the peer received no subsequent client
bytes. This confirms the reverse half-close limitation of
[Docker CLI 29.10.0's stdio helper](https://github.com/docker/cli/blob/fdd4b8e5da335e1d0d83d29af5045f57280cd694/cli/command/system/dial_stdio.go).

| Case | Observed result |
| --- | --- |
| Ping and version | Both passed. Two initial exec sessions opened in 108 ms and 118 ms. Full exchanges took 191 ms and 155 ms. |
| Attached exec | HTTP 101 carried stdin, stdout reached the caller after stdin EOF, and the command exited 0. |
| Idle stream | With stdin open, an events request stayed active for over 65 seconds. A short request completed during a separate open events request. An explicit signal ended the held helper and its operation reached a terminal state. |
| Stalled reader | A second request completed in 160 ms while a large-download reader was paused. The fixture had zero remaining `dial-stdio` helpers after the run. |
| Partial setup | With only stdin connected and then closed, the accepted operation reached Incus's websocket connection timeout before a helper started. Terminal failure was observed about 9.4 seconds after submission. |
| 8 MiB download | Direct and relayed HTTP 200 responses carried identical 8,390,144-byte tar bodies. Observed exchange times were 942 ms and 251 ms. |
| 8 MiB upload | The first direct helper exchange failed with channel I/O and left a 6,299,112-byte file. A separate upload to a fresh path through the library returned HTTP 200 in 19.9 seconds. The full 8,388,608-byte payload matched its SHA-256 in the workload. |

These timings are individual observations from one disposable fixture.
Large writes can leave partially applied state after an interrupted
exchange. The relay reports the failed exchange and the run used a new
destination for the successful upload.

## Differential and CLI checks

The read-only differential harness passed version, HEAD ping, and the
container, image, volume, and network list routes. It compared HTTP
status, protocol-relevant headers and decoded JSON. The network list
normalizer sorts by network ID because the same daemon enumerated networks
in different orders. All network fields are still compared.

Docker CLI 29.10.0, Buildx 0.39.1 with the integrated Docker driver, and
Compose 5.8.0 completed the live acceptance workflow. The second run
included a cold digest-pinned Alpine pull, container run, attached exec,
followed logs, image build and inspection, Compose up and down, and
removal of the workflow's container and built image. The listener observed
HTTP 101 for `Upgrade: tcp` on exec start and `Upgrade: h2c` on both
`POST /grpc` and `POST /session`. Several BuildKit tunnel teardown paths
reported stream failures after the upgrade, even though the build and
subsequent image inspection succeeded.
