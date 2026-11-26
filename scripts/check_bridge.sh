#!/bin/sh
# Vet and test the packaged exec bridge helper, then build it twice for each
# release architecture from clean caches and fail unless the builds match.
# Binaries go to a temporary directory; none is written under priv/.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
source_dir="$root/priv/exec_bridge"
work=$(mktemp -d "${TMPDIR:-/tmp}/ocb-build.XXXXXX")
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT INT TERM

export GOTOOLCHAIN=local GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off

cd "$source_dir"
go version | grep -q 'go1.25.14 ' || { echo "check:bridge requires go1.25.14" >&2; exit 1; }
GOCACHE="$work/test-cache" go vet ./...
GOCACHE="$work/test-cache" go test -count=1 ./...

build() {
  GOCACHE="$work/cache-$1-$2" CGO_ENABLED=0 GOOS=linux GOARCH="$1" \
    go build -trimpath -buildvcs=false -ldflags='-s -w -buildid=' \
    -o "$work/exec-socket-bridge-$1-$2" .
  if command -v sha256sum >/dev/null; then sum=sha256sum; else sum='shasum -a 256'; fi
  $sum "$work/exec-socket-bridge-$1-$2" | cut -d' ' -f1
}

for arch in amd64 arm64; do
  first=$(build "$arch" 1)
  second=$(build "$arch" 2)
  if [ "$first" != "$second" ]; then
    echo "linux/$arch builds differ: $first $second" >&2
    exit 1
  fi
  echo "linux/$arch sha256 $first"
done
