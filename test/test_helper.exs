# The TLS half-close fixtures need a Go TLS client (Go is pinned in mise.toml).
exclude = if System.find_executable("go"), do: [], else: [:go]
ExUnit.start(exclude: exclude)
