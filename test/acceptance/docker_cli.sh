#!/bin/sh
set -eu

if [ "${OPSMARU_DOCKER_ACCEPTANCE:-}" != isolated ]; then
  printf '%s\n' 'Opt in with OPSMARU_DOCKER_ACCEPTANCE=isolated for a disposable engine.' >&2
  exit 1
fi

docker_bin=${OPSMARU_DOCKER_CLI:?Supply the pinned Docker CLI executable}
socket=${OPSMARU_DOCKER_RELAY_SOCKET:?Supply the hosted Docker Unix socket}
plugins=${OPSMARU_DOCKER_PLUGIN_DIR:?Supply the pinned Docker plugin directory}
test_image=${OPSMARU_DOCKER_TEST_IMAGE:?Supply a disposable shell-capable image by digest}

case "$socket" in /*) ;; *) exit 1 ;; esac
case "$docker_bin" in /*) ;; *) exit 1 ;; esac
case "$plugins" in /*) ;; *) exit 1 ;; esac
printf '%s' "$test_image" | grep -Ex '[a-zA-Z0-9][a-zA-Z0-9/._:-]*@sha256:[0-9a-f]{64}' >/dev/null

workspace=$(mktemp -d "${TMPDIR:-/tmp}/opsmaru-containers-cli.XXXXXX")
tag=$(basename "$workspace" | tr '.[:upper:]' '-[:lower:]')
image="$tag:fixture"
container="$tag-exec"
compose="$workspace/compose.yaml"

docker_host() {
  "$docker_bin" --config "$workspace/config" --host "unix://$socket" "$@"
}

cleanup() {
  if [ -f "$compose" ]; then
    docker_host compose --project-name "$tag" -f "$compose" down >/dev/null 2>&1 || :
  fi
  docker_host rm -f "$container" >/dev/null 2>&1 || :
  docker_host image rm "$image" >/dev/null 2>&1 || :
  rm -rf "$workspace"
}

mkdir "$workspace/config" "$workspace/context"
node -e 'process.stdout.write(JSON.stringify({cliPluginsExtraDirs: [process.argv[1]]}))' \
  "$plugins" > "$workspace/config/config.json"
trap 'rm -rf "$workspace"' EXIT

versions=$(docker_host version --format '{{.Client.Version}}/{{.Server.Version}}')
test "$versions" = 29.10.0/29.10.0

compose_version=$(docker_host compose version --short)
test "${compose_version#v}" = 5.8.0

buildx_version=$(docker_host buildx version)
case "$buildx_version" in
  *' v0.39.1 '*) ;;
  *) printf '%s\n' 'Buildx 0.39.1 is required.' >&2; exit 1 ;;
esac

driver=$(docker_host buildx inspect default)
printf '%s\n' "$driver" | grep -E '^Driver:[[:space:]]+docker[[:space:]]*$' >/dev/null

trap cleanup EXIT

docker_host pull "$test_image"
docker_host run -d --name "$container" --entrypoint /bin/sh "$test_image" -c 'echo fixture-ready; sleep 600'
output=$(printf '%s' fixture-stdin | docker_host exec -i "$container" cat)
test "$output" = fixture-stdin

docker_host logs -f "$container" > "$workspace/followed.log" &
logs_pid=$!
docker_host stop --timeout 2 "$container"
wait "$logs_pid"
grep -Fx fixture-ready "$workspace/followed.log"
docker_host rm "$container"

printf 'FROM %s\nCOPY probe /probe\n' "$test_image" > "$workspace/context/Dockerfile"
printf '%s\n' fixture-build > "$workspace/context/probe"
docker_host buildx build --builder default --load --tag "$image" "$workspace/context"
docker_host image inspect "$image" >/dev/null

printf 'services:\n  fixture:\n    image: "%s"\n    entrypoint: ["/bin/sh", "-c", "sleep 600"]\n' \
  "$test_image" > "$compose"
docker_host compose --project-name "$tag" -f "$compose" up -d
docker_host compose --project-name "$tag" -f "$compose" down
docker_host image rm "$image"
