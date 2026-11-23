#!/bin/sh
set -eu

workspace=$(mktemp -d "${TMPDIR:-/tmp}/opsmaru-containers-hex.XXXXXX")
trap 'rm -rf "$workspace"' EXIT
export PHX_SERVER=true
export PORT=not-a-port
export MIX_ENV=prod

mix hex.build --unpack --output "$workspace/package"

for file in priv/docker/reference.json priv/docker/routes.json priv/docker/coverage.json \
  priv/docker/openapi.yaml.gz priv/notices/moby-api-LICENSE priv/notices/moby-NOTICE
do
  test -s "$workspace/package/$file"
done

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
    mix run --no-start -e '
      web? = System.fetch_env!("OPSMARU_CONTAINERS_CONSUMER_PROFILE") == "web"
      true = Code.ensure_loaded?(Opsmaru.Containers.Nested)
      true = function_exported?(Opsmaru.Containers.Nested, :ensure, 3)
      ^web? = Code.ensure_loaded?(Opsmaru.Containers.Docker.Plug)
      ^web? = Code.ensure_loaded?(:cowboy_req)
      {:ok, _} = Application.ensure_all_started(:opsmaru_containers)
      [] = Application.spec(:opsmaru_containers, :mod)
      if web?, do: (true = Enum.empty?(:ranch.info()))
    '
    printf 'Verified %s Hex consumer\n' "$profile"
  )
done
