# Native init shim

The init shim is the entrypoint of every native container, so it runs inside each one. It starts the Docker process exactly as specified, records each run's exit status, and writes stdout and stderr as separate, timestamped log records. The library reads those files through `opsmaru_incus`. See the [add-native-oci-engine design](../../openspec/changes/add-native-oci-engine/design.md).

The package ships its source only. No binary is built at compile time or included in the Hex package. A host that runs native containers builds the shim itself and passes the binaries in its context.

## Modes

| Invocation | Run by | Does |
| --- | --- | --- |
| `init` | Incus, as `oci.entrypoint` | runs the process in `spec.json` and records it |
| `init exec [--user U] [--cwd D] -- ARGV...` | the library, through Incus exec | sets up a Docker exec, then replaces itself with `ARGV` |
| `init kill SIGNAL` | the library, through Incus exec | signals the process through the control socket |
| `init stop [--signal S] [--timeout SECONDS]` | the library, through Incus exec | sends the stop signal, then SIGKILL after the timeout (default 10 s, negative waits forever) |

`kill` and `stop` exit 0 when init accepted the request, 1 when it refused or is not running, and 2 for a usage error. `exec` exits with the command's code. When the command cannot start, it exits 127 for a missing file, 126 for permission, and 128 for anything else, with the reason on stderr. Init's own diagnostics go to its stderr, which is the Incus console log.

## Files

Everything is under `/.opsmaru`, a root-owned directory with mode 0700.

### `spec.json` (written by the library)

```json
{
  "version": 1,
  "argv": ["/docker-entrypoint.sh", "nginx", "-g", "daemon off;"],
  "env": ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],
  "cwd": "/",
  "user": "nginx",
  "group_add": [],
  "hostname": "3f1c0a9b2d4e",
  "stop_signal": "SIGQUIT",
  "log": {"driver": "local", "max_size": 20971520, "max_files": 5}
}
```

- Unknown fields are rejected, and the file may be at most 1 MiB.
- `argv` is executed exactly. A first element without `/` is looked up in the process's `PATH`.
- `env` is applied the way dockerd and runc apply it:
  1. the environment starts with `PATH` (a default) and `HOSTNAME`;
  2. each `env` entry replaces a variable or appends a new one, and an entry without `=` removes that variable;
  3. `HOME` is added from the user's passwd entry if still unset, or `/` without an entry.
- `user` takes `name`, `uid`, `name:group` or `uid:gid`, resolved from the container's `/etc/passwd` and `/etc/group` as runc resolves it. Supplementary groups come from `/etc/group` when no group is given. `group_add` entries are always added.
- `log.driver` is `local` (`json-file` and an empty value mean the same) or `none`. The defaults are 20 MiB × 5, and `max_size` must be at least 4,096.

### `state/run.json` (written by init)

```json
{"version": 1, "run": 3, "pid": 5, "started_at": "2026-11-27T10:00:00.123456789Z",
 "finished_at": "2026-11-27T10:00:04.5Z", "exit_code": 3, "signal": null,
 "oom_killed": false, "error": null}
```

Each write replaces the file atomically: a synced temporary file is renamed over it, then the directory is synced.

- `run` is one more than the previous record's, or one more than the newest run in the logs if that is higher.
- Init writes the file once after the process starts, without `finished_at`, then again when the process exits.
- A process killed by a signal has `exit_code` 128 plus the signal number, and `signal` set.
- A process that could not start has no `pid` and has an `error`.
- `oom_killed` is true when the cgroup's `memory.events` `oom_kill` count rose during the run.
- Log records are synced before the final record is written. So once a record has `finished_at`, every log record of that run is on disk.

### `logs/NNNNNNNNNN.log` (written by init)

Files are numbered from `0000000001.log` and never renamed. A file that reaches `max_size` is closed, and the next record starts the next file. When more than `max_files` files exist, the oldest is deleted. Each file starts with the 4 bytes `OCL1`, followed by records:

| Field | Size | Meaning |
| --- | --- | --- |
| stream | 1 byte | 1 stdout, 2 stderr |
| flags | 1 byte | bit 0: partial, with no trailing newline; other bits are 0 |
| run | 4 bytes, big-endian | the run that wrote it |
| time | 8 bytes, big-endian | nanoseconds since the Unix epoch, when the bytes were read |
| length | 4 bytes, big-endian | 1 to 16,384 |
| data | length bytes | the output, exactly |

- Output is split at each newline and at 16 KiB.
- Bytes with no newline are written as a partial record after 100 ms, or when the stream ends.
- Both streams go into one file in the order init read them.
- After the process exits, init reads its pipes for up to 1 s more, so a descendant that keeps a pipe open cannot hold init.
- A write that fails is cut back to the last whole record. Records that cannot be written are counted and reported on init's stderr.
- When init starts, it continues the newest file if that file is whole and below `max_size`.

### `state/control.sock` (served by init)

A Unix socket, mode 0600, open while the process runs. Each connection carries one JSON request line and gets one reply line:

- requests: `{"op":"kill","signal":"SIGHUP"}` or `{"op":"stop","signal":"SIGTERM","timeout":10}`
- replies: `{"ok":true}` or `{"ok":false,"error":"..."}`

Signals are names with or without `SIG`, or numbers. When Incus stops the container gracefully, init gets SIGTERM and sends the spec's `stop_signal` to the process. Init forwards SIGINT, SIGHUP, SIGQUIT, SIGUSR1, SIGUSR2 and SIGWINCH unchanged.

### Exec environment

The exec's own environment comes from the Incus exec environment, but `exec` mode does not take all of it:

- It reads the JSON array of names in `OPSMARU_EXEC_ENV` and takes only those variables, in that order. Variables that Incus adds itself are therefore dropped.
- `OPSMARU_EXEC_UNSET` is a JSON array of names to remove, as a Docker `Env` entry without `=` does.

The result is applied on top of the spec's `env`, using the rules above. `--user` and `--cwd` default to the spec's `user` and `cwd`, and the spec's `group_add` always applies.

## Build

Use Go 1.25.14, which `mise.toml` pins. Build from this directory:

```bash
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -buildvcs=false -ldflags='-s -w -buildid=' -o native-init .
```

Use `GOARCH=amd64` for x86-64 guests. `mise run check:init` runs `go vet` and the unit tests. It then builds both architectures twice from clean caches, and fails if the two builds differ or if they don't match this table.

These SHA-256 digests come from that recipe with go1.25.14:

| Target | SHA-256 |
| --- | --- |
| linux/amd64 | `428664c6067db8d43120a9ea42664c57d578db8580fa4c3aa524a7c9b8edf1db` |
| linux/arm64 | `30d1d3ab803522a908d7348caaf776a1ed967a71958728b55dd05818f6a2d299` |

If you change the source, `go.mod` or the toolchain, update this table. The library refuses a shim binary whose digest it does not list.

## Install

Build one binary per guest architecture and pass both in the context as `native_init: %{"aarch64" => path, "x86_64" => path}`. The library copies the right one into each new native container at `/.opsmaru/init`, mode 0755.
