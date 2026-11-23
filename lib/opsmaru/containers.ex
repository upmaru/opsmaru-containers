defmodule Opsmaru.Containers do
  @moduledoc """
  Container engine APIs served from Incus.

  This library embeds container engine APIs (the Docker Engine API first)
  backed by Incus through `opsmaru_incus`. It is a pure library: it has
  no application callback and starts no process, listener, state or backend
  connection. Hosts such as Macus own the listener and pass their Incus
  connection, verified identity and readiness on every call.

  See `Opsmaru.Containers.Nested`, `Opsmaru.Containers.Host` and
  `Opsmaru.Containers.Docker.Raw` for the host entry points.
  """
end
