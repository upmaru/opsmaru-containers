defmodule Opsmaru.Containers do
  @moduledoc """
  Container engine APIs served from Incus.

  This library translates container engine APIs (the Docker Engine API first)
  into Incus calls made through `opsmaru_incus`. It is a pure library: it has
  no application callback and starts no process, listener, state or backend
  connection. Hosts such as Macus own the listener and pass their Incus
  connection, verified identity and readiness on every call.

  Nothing is implemented yet. The initial scope is planned in
  `openspec/changes/add-docker-engine-foundation`.
  """
end
