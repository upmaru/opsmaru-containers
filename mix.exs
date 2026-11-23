defmodule OpsmaruContainers.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/upmaru/opsmaru-containers"

  def project do
    [
      app: :opsmaru_containers,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: false,
      deps: deps(),
      description: "Container engine APIs (Docker first) served from Incus through opsmaru_incus",
      source_url: @source_url,
      homepage_url: @source_url,
      package: package(),
      docs: docs()
    ]
  end

  # A pure library: no application callback, so loading or starting it
  # never creates processes, listeners, state or backend connections.
  def application do
    [extra_applications: [:logger]]
  end

  # Hex is the only distribution route.
  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url, "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"},
      files: ~w(lib priv docs mix.exs README.md CHANGELOG.md LICENSE NOTICE)
    ]
  end

  defp docs do
    [main: "readme", source_ref: "v#{@version}", extras: ["README.md", "CHANGELOG.md"]]
  end

  # Ranges, not exact pins: consumers (Macus, central Opsmaru) resolve the
  # exact versions in their own lockfiles.
  defp deps do
    [
      # The only route to Incus. This library never opens its own backend
      # connection; hosts pass opsmaru_incus connections on every call.
      {:opsmaru_incus, "~> 0.2.9"},
      {:jason, "~> 1.4"},
      {:yamerl, "~> 0.10"},
      {:plug, "~> 1.16", optional: true, runtime: false},
      {:cowboy, "~> 2.12", optional: true, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end
end
