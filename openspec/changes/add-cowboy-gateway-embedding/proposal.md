# Proposal

## Why

Macus plans to serve the Docker Engine API on its existing authenticated HTTPS gateway. That gateway is Cowboy with TLS 1.3 on `127.0.0.1:8443` (Macus change `add-docker-engine`, upmaru/macus#36). Central Opsmaru also hosts on Cowboy and needs the same pieces. Neither host can consume 0.1.0 as released:

- **Plug cannot take over a socket.** Every request on the Macus gateway goes through `Opsmaru.Incus.Gateway.CowboyHandler`. That handler takes only Incus SFTP/NBD raw upgrades and passes everything else to `Plug.Cowboy.Handler`. Docker attach, attached exec and BuildKit's `h2c` sessions need a Cowboy handler chained as that fallback.
- **`Raw.relay/4` writes the 101 itself.** It completes the upstream handshake and then writes the response head on a stream the host has already handed over. Cowboy sends the 101 itself when the handler casts `switch_protocol`. Only afterwards does it hand the socket to `takeover/7`, in a different process. A Cowboy host therefore needs the upstream handshake and the stream relay as two calls.
- **The qualified exec transport is not in the package.** The exec bridge dialer and its Go helper qualified on 2026-11-25 with opsmaru_incus 0.2.10, Incus 7.0.1 and Docker 29.10.0 ([report](../../../docs/docker-live-acceptance.md#exec-qualification-rerun-on-opsmaru_incus-0210)). They exist only as acceptance scripts under `scripts/acceptance`, outside the Hex `files`. Macus will not vendor them.
- **A host cannot log what the Docker API relays.** The library emits no events. Raw streams never enter the host's Plug pipeline, so Plug telemetry cannot cover them. The Macus gateway already keeps an access log from `opsmaru_incus`'s `[:opsmaru_incus, :gateway, :exchange, _]` events.

TLS, the listener, trust and enrollment stay with the host.

## What Changes

- **Split raw entry.** Add `Opsmaru.Containers.Docker.Raw.open/3` and `Raw.run/4` beside `Raw.relay/4`.
  - `open` admits the request, dials the transport and completes the upstream handshake. It returns `{:upgrade, response, backend, tail}` or `{:http, status, headers, body}`.
  - `run` relays both streams once the host owns the frontend socket. It first delivers the bytes the frontend already buffered and the engine bytes read past its response head.
  - `relay/4` keeps its contract and wire output, and becomes `open`, then writing the head, then `run`.
- **Optional same-listener Cowboy handler.** Add `Opsmaru.Containers.Docker.CowboyHandler`, compiled only when `:cowboy_req` is loaded. It follows the pattern of `Opsmaru.Incus.Gateway.CowboyHandler`.
  - It opens no listener.
  - It takes only Docker raw upgrades on HTTP/1.1:
    - `Upgrade: tcp` on attach and exec start;
    - `h2c` on `POST /grpc` and `POST /session`;
    - WebSocket on attach.
  - Host policy and admission run before any backend dial.
  - It casts `switch_protocol` with the engine's normalized response headers. `takeover/7` builds a frontend `Transport.Stream` from Cowboy's transport, socket and buffer, then calls `Raw.run`.
  - Every other request goes to a configured `fallback` handler (normally `Plug.Cowboy.Handler`), so a host can chain this handler behind the Incus handler.
  - A raw-stream request without `Upgrade` gets a Docker-shaped 400.
- **Packaged exec bridge transport.** Promote the acceptance dialer to `Opsmaru.Containers.Transport.ExecBridge`, with bounded, validated options:
  - the helper and engine socket paths;
  - an optional `Opsmaru.Incus.RequestContext`;
  - per-connection Incus stream limits;
  - an optional keepalive.

  The Go helper source moves under `priv/exec_bridge` with a pinned Go module and reproducible build instructions, so engine images can build the helper from the release. The bridge is never selected by default. Hosts pass it explicitly as the context dialer. The open stdin write stall stays documented in the module and the acceptance report.
- **Docker exchange telemetry.** Emit optional `:telemetry` events per request (`[:opsmaru_containers, :docker, :exchange, :start | :stop]`). Also emit a `[:opsmaru_containers, :docker, :request]` event when the response head is committed or refused. A long-lived stream can therefore be logged when it starts and again when it ends. Metadata is a bounded, secret-free map like opsmaru_incus's gateway exchange events.
- **Release.** Raise the `opsmaru_incus` floor to `~> 0.2.10`, add the optional `telemetry` dependency and publish 0.2.0 to Hex through the existing Git Flow release workflow, with user authorization.

Not in this change:

- A listener, TLS configuration, trust, enrollment or a docker context. These remain Macus- and Opsmaru-owned.
- Docker's hijacked HTTP 200 raw-stream form on Cowboy. Cowboy can emit a hijack only as 101, and the Docker CLI always sends `Upgrade: tcp`.
- HTTP/2 raw streams. Cowboy's `switch_protocol` exists only on HTTP/1.1 connections.
- Native engine routes, published-port forwarding, bind-mount path mapping or a default exec transport.
- Macus consumer acceptance. That stays task 4.5 of `add-docker-engine-foundation`, owned by Macus.

## Capabilities

### New Capabilities

- `docker-cowboy-gateway`: the optional same-listener Cowboy handler, its dispatch rules, the Cowboy frontend stream and its TLS half-close behaviour.

### Modified Capabilities

- `docker-engine-api`: adds the split raw entry, exchange and request telemetry, and the bounded metadata contract.
- `nested-engine`: adds the packaged exec bridge transport, its helper protocol and its packaged helper source.
- `embedded-library`: adds the passivity of the Cowboy handler and of telemetry, and the packaging of the helper source.

## Impact

- **Code:**
  - `Raw` gains `open/3` and `run/4`, and `relay/4` is refactored onto them.
  - New modules:
    - `Docker.CowboyHandler` and an internal `Docker.CowboyTunnel` (the `takeover/7` module);
    - an internal frontend stream adapter `Transport.CowboyStream`;
    - `Transport.ExecBridge`;
    - an internal `Opsmaru.Containers.Telemetry` emitter and `Docker.Exchange` observer.
  - `Docker.Plug`, `Raw` and `RawTunnel` gain emission points.
  - `Host`, `Context`, `Admission` and the route table are unchanged.
- **Wire behaviour:** unchanged for `Docker.Plug` and `Raw.relay/4`. On the Cowboy handler, the 101 status line carries Cowboy's reason phrase `Switching Protocols` instead of dockerd's `UPGRADED`. The headers are the ones `relay/4` would send.
- **Dependencies:**
  - `{:opsmaru_incus, "~> 0.2.10"}`;
  - `{:telemetry, "~> 1.3", optional: true}`, which `mix.lock` already resolves through Plug;
  - Go 1.25.14 pinned in `mise.toml` for the helper build check only. Hex consumers never need Go.
- **Package:** `priv/exec_bridge` (Go source, `go.mod`, build notes) joins the Hex `files` through the existing `priv` entry. No helper binary is packaged.
- **Acceptance scripts:** `scripts/acceptance/exec_socket_bridge.ex` is removed. The half-close script uses the packaged module.
- **Documentation:** `docs/embedding.md` gains the Cowboy chain, the split raw API, the exec bridge and the event catalogue. `docs/docker-live-acceptance.md` points at the packaged helper. `CHANGELOG.md` records 0.2.0.
- **Evidence:** fixture checks, a TLS Cowboy fixture listener and packaged-consumer checks. Optionally, a real-Incus rerun of the packaged bridge. This change records no Macus consumer acceptance and adds no ledger entry beyond what its runs verify.
- **Macus:** Macus can chain `Docker.CowboyHandler` as the Incus handler's fallback, and `Plug.Cowboy.Handler` as this handler's own fallback. It must weigh the TLS half-close limitation recorded in [design.md](design.md) decision 4 against its gateway plan.
