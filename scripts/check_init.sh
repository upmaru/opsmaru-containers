#!/bin/sh
# Vet and test the packaged native init shim, then build it twice for each
# release architecture from clean caches and fail unless the builds match.
# It also fails unless README.md lists those digests. Binaries go to a
# temporary directory; none is written under priv/.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
source_dir="$root/priv/native_init"
work=$(mktemp -d "${TMPDIR:-/tmp}/oci-build.XXXXXX")
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT INT TERM

export GOTOOLCHAIN=local GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off

cd "$source_dir"
go version | grep -q 'go1.25.14 ' || { echo "check:init requires go1.25.14" >&2; exit 1; }
GOCACHE="$work/test-cache" go vet ./...
GOCACHE="$work/test-cache" go test -count=1 ./...

if command -v sha256sum >/dev/null; then sum=sha256sum; else sum='shasum -a 256'; fi

build() {
  GOCACHE="$work/cache-$1-$2" CGO_ENABLED=0 GOOS=linux GOARCH="$1" \
    go build -trimpath -buildvcs=false -ldflags='-s -w -buildid=' \
    -o "$work/native-init-$1-$2" .
  $sum "$work/native-init-$1-$2" | cut -d' ' -f1
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

# The README's digest table must match these builds.
readme="$source_dir/README.md"
for arch in amd64 arm64; do
  built=$($sum "$work/native-init-$arch-1" | cut -d' ' -f1)
  grep -q "| linux/$arch | \`$built\` |" "$readme" || {
    echo "README digest for linux/$arch does not match the build ($built)" >&2
    exit 1
  }
done
