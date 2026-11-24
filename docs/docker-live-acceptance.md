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

## Replacement exec helper on 2026-11-24

The follow-up reused the same isolated Incus project and engine instance.
It built a static Linux arm64 [guest bridge](../scripts/acceptance/exec_socket_bridge.go)
with Go 1.25.14 and uploaded it through the Incus file API. The
[acceptance dialer](../scripts/acceptance/exec_socket_bridge.ex) passes
stdin through to the Unix socket and decodes bounded stdout frames. An
explicit output EOF frame preserves the writable direction on the exec
session. Docker clients receive the original bytes.

Both [half-close cases](../scripts/acceptance/exec_socket_bridge_half_close.ex)
passed over authenticated Incus exec. When client input ended first, the
peer received it and the client received the peer's response afterward.
When peer output ended first, the client observed EOF and successfully
sent a marker afterward. The guest peer verified the exact input in each
case, and both bridge processes exited with status zero. The pinned
Docker CLI also received output after stdin EOF on an attached exec
through the full relay.

To reproduce, build the helper for the fixture architecture from a pinned
Go toolchain, install it inside the disposable engine and pass the approved
connected target to the acceptance module.

```sh
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -buildvcs=false \
  -o /tmp/exec-socket-bridge scripts/acceptance/exec_socket_bridge.go
```

```elixir
Code.require_file("scripts/acceptance/exec_socket_bridge.ex")
Code.require_file("scripts/acceptance/exec_socket_bridge_half_close.ex")

Opsmaru.Containers.Acceptance.ExecSocketBridgeHalfClose.run(
  target,
  "/absolute/guest/path/to/exec-socket-bridge"
)
```

### Separate upload investigation

The matrix sent the same 8,388,608-byte file in nine archive requests,
using a fresh destination for each trial. Both direct paths bypassed the
library's HTTP handler. The full relay used the same replacement helper
behind the library. The disposable Plug listener buffered its request
body before forwarding, so the full-relay result applies to that host
adapter and its write pacing.

| Path | HTTP 200 and matching SHA-256 | Partial destinations on disconnect |
| --- | --- | --- |
| Docker stdio helper, direct | 2 of 3 | 6,856,192 bytes, client observed a socket hang-up |
| Replacement helper, direct | 1 of 3 | 4,169,192 and 4,914,688 bytes, client observed write `EPIPE` |
| Replacement helper, full relay | 3 of 3 | None observed |

The investigation reproduced the partial write with both helpers. The
reverse half-close fix leaves upload reliability as a separate
qualification item. The original upload and the later failures used
distinct destination paths.

A Docker-free Incus exec control sent the same payload in 16 KiB pieces
to a fresh file. All 8,388,608 bytes arrived and matched SHA-256 in
50.8 seconds. An earlier checksum-only control accepted all input writes
but timed out waiting for its output, so it could not establish what
reached the guest. The file-backed control verified delivery for that
trial.

### Traced direct and streaming uploads

A follow-up reused the same Incus 7.0.1 project, authenticated TLS
gateway, and Docker Engine 29.10.0. Each request used a fresh destination
and contained an 8,390,144-byte fixed-length tar with the same
8,388,608-byte file. The listener traced client reads, writes to the
Incus exec channels, WebSocket closes, and the backend HTTP response.
The incremental listener passed the request to the library as soon as
it had parsed the headers. The first write to the bridge followed only
8,192 bytes read from the client, including the headers. The first
64 KiB body read still left 8,324,608 bytes unread. The buffered
control read the entire request before starting the same relay.

| Upload path | HTTP 200 and matching SHA-256 | Failed request and bytes found in the workload |
| --- | --- | --- |
| Direct bridge | 3 of 3 | None in the unpaced trials |
| Full relay, incremental listener | 2 of 3 | HTTP 502, 212,480 bytes |
| Full relay, buffered listener | 2 of 3 | HTTP 502, 200,184 bytes |
| Direct bridge, paced | 0 of 1 | Client write `EPIPE`, 196,096 bytes |
| Full relay, incremental listener, paced | 0 of 1 | HTTP 502, 6,749,696 bytes |
| Full relay, buffered listener, paced | 1 of 1 | None observed |

The paced client sent 16 KiB at a time with a 160 ms interval. Its direct
upload failed about 26 seconds after connection. The first failure was
a TLS write timeout reported by Mint on exec stdin WebSocket channel
`0`, using the acceptance client's 8-second socket write timeout.
At that point, writes for 1,859,762 request bytes had returned success
locally. The exec operation was still running when cleanup began. The
other WebSockets closed during cleanup, and the local client then
received `EPIPE`. The local write count measures bytes accepted by the
TLS sender. The file size measures bytes that reached the destination.

The unpaced incremental and buffered relay failures also began with
stdin WebSocket write timeouts while the exec operation was running.
Both relays returned a Docker-shaped 502 and each left a partial
destination. The paced buffered control succeeded after about 82
seconds receiving the tar followed by 27 seconds forwarding it. The
unpaced buffered failure shows that the write stall can occur after
the listener has already received the whole body. Each trial used a
fresh destination.

The paced incremental relay had a different event order. Its stdout
WebSocket closed with code 1000 about 66 seconds after connection,
before stdin closed and the relay returned 502. The operation was
already terminal when the relay checked it, and the payload was
incomplete. A separate guest-local archive upload to the same dockerd
socket produced all 8,388,608 bytes and a matching SHA-256. The exec
session used to launch that control timed out collecting its result,
so the file was verified in a separate read.

A Docker-free control piped 8 KiB pieces through the same Incus stdin
WebSocket into a guest file. Individual TLS writes took up to 5.1
seconds. The operation exited zero and the full file matched SHA-256
after 56 seconds. The long write stalls also occurred without the
guest bridge or dockerd in the data path.

The cause of the early stdout close and the cause of the underlying
write stalls farther downstream remain unverified. The exec transport
qualification remains open.
