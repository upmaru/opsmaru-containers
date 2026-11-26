if Code.ensure_loaded?(:cowboy_req) do
  defmodule Opsmaru.Containers.Docker.CowboyTunnel do
    @moduledoc false
    # Cowboy calls `takeover/7` in the connection process after it has
    # written the 101. Hand the socket and Cowboy's buffered bytes to the
    # relay that owns the backend, then wait for it. The connection never
    # returns to Cowboy's HTTP parser after opaque traffic.

    def takeover(_parent, _ref, socket, transport, _opts, buffer, relay) do
      monitor = Process.monitor(relay)

      try do
        with :ok <- transport.setopts(socket, active: false),
             :ok <- transport.controlling_process(socket, relay) do
          send(relay, {:attach, socket, transport, buffer})

          receive do
            {:DOWN, ^monitor, :process, ^relay, _} -> :ok
          end
        end
      catch
        _, _ -> :ok
      after
        Process.exit(relay, :kill)
        transport.close(socket)
      end

      exit(:normal)
    end
  end
end
