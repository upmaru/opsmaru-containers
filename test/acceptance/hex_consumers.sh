#!/bin/sh
set -eu

workspace=$(mktemp -d "${TMPDIR:-/tmp}/opsmaru-containers-hex.XXXXXX")
trap 'rm -rf "$workspace"' EXIT
export PHX_SERVER=true
export PORT=not-a-port
export MIX_ENV=prod

mix hex.build --unpack --output "$workspace/package"

for file in priv/docker/reference.json priv/docker/routes.json priv/docker/coverage.json \
  priv/docker/openapi.yaml.gz priv/notices/moby-api-LICENSE priv/notices/moby-NOTICE \
  priv/exec_bridge/exec_socket_bridge.go priv/exec_bridge/go.mod priv/exec_bridge/README.md
do
  test -s "$workspace/package/$file"
done

# The exec bridge helper ships as source only: no built binary.
extra=$(find "$workspace/package/priv/exec_bridge" -type f ! -name '*.go' ! -name go.mod ! -name README.md)
if [ -n "$extra" ]; then
  printf 'Unexpected files in priv/exec_bridge:\n%s\n' "$extra" >&2
  exit 1
fi

for profile in headless web; do
  mkdir "$workspace/$profile"
  (
    cd "$workspace/$profile"

    cat > mix.exs <<'ELIXIR'
defmodule PackagedConsumer.MixProject do
  use Mix.Project

  def project do
    [app: :packaged_consumer, version: "0.0.1", deps: dependencies()]
  end

  defp dependencies do
    package = {:opsmaru_containers, path: "../package"}

    case System.fetch_env!("OPSMARU_CONTAINERS_CONSUMER_PROFILE") do
      "headless" -> [package]
      "web" -> [package, {:plug, "~> 1.16"}, {:cowboy, "~> 2.12"}]
    end
  end
end
ELIXIR

    export OPSMARU_CONTAINERS_CONSUMER_PROFILE="$profile"
    mix deps.get
    mix compile --warnings-as-errors

    # The headless consumer resolves no optional telemetry or web stack.
    if [ "$profile" = headless ] && grep -Eq '^  "(telemetry|cowboy|plug)":' mix.lock; then
      echo "The headless consumer resolved an optional dependency" >&2
      exit 1
    fi
    mix run --no-start -e '
      web? = System.fetch_env!("OPSMARU_CONTAINERS_CONSUMER_PROFILE") == "web"
      true = Code.ensure_loaded?(Opsmaru.Containers.Nested)
      true = function_exported?(Opsmaru.Containers.Nested, :ensure, 3)
      ^web? = Code.ensure_loaded?(Opsmaru.Containers.Docker.Plug)
      ^web? = Code.ensure_loaded?(:cowboy_req)
      ^web? = Code.ensure_loaded?(Opsmaru.Containers.Docker.CowboyHandler)
      ^web? = Code.ensure_loaded?(Opsmaru.Containers.Docker.CowboyTunnel)
      ^web? = Code.ensure_loaded?(Opsmaru.Containers.Transport.CowboyStream)
      ^web? = Code.ensure_loaded?(:telemetry)
      true = Code.ensure_loaded?(Opsmaru.Containers.Transport.ExecBridge)
      :ok = Opsmaru.Containers.Telemetry.execute([:opsmaru_containers, :probe], %{}, %{})
      {:ok, _} = Application.ensure_all_started(:opsmaru_containers)
      [] = Application.spec(:opsmaru_containers, :mod)
      if web?, do: (true = Enum.empty?(:ranch.info()))
    '
    printf 'Verified %s Hex consumer\n' "$profile"
  )
done
