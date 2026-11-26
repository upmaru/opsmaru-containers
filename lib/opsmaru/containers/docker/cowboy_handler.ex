if Code.ensure_loaded?(:cowboy_req) do
  defmodule Opsmaru.Containers.Docker.CowboyHandler do
    @moduledoc """
    Same-listener Cowboy handler for Docker raw streams.

    Mount it as a Cowboy handler on a host-owned listener. It opens no
    listener, configures no TLS and starts no process before it receives a
    request. Options, as a map or a keyword list:

      * `:host` (required) - the `Opsmaru.Containers.Host` policy module.
      * `:fallback` (required) - `{handler_module, handler_opts}` for every
        request this handler does not take, normally
        `{Plug.Cowboy.Handler, {YourRouter, router_opts}}`. Without it, such
        requests get a Docker-shaped 404.
      * `:host_peer` - an optional term passed to the host's callbacks as
        `request.host_peer`, the Cowboy-side counterpart of the Plug's
        `conn.private[:opsmaru_containers_peer]`.
      * `:admission_timeout` - ms, default `1_000`: host policy, admission
        and reading the small request body.
      * `:dial_timeout` - ms, default `30_000`: the transport dial and the
        upstream handshake. Policy, admission, the dial and the handshake
        together end `admission_timeout + dial_timeout` after the request
        reached the handler.
      * `:stream_timeout` - ms, default `86_400_000`: lifetime of one raw
        exchange.
      * `:handoff_timeout` - ms, default `5_000`: from the 101 cast to
        Cowboy's call of `takeover/7`.

    Timeouts must be integers from 1 to 86,400,000.

    ## Dispatch

    A request is a Docker raw attempt only when its path, with any `/vX.Y`
    prefix stripped, matches a route-table entry whose takeover is
    `docker_stream`, `h2c_upgrade` or `websocket` (`Route.match/2` on the
    pinned table). Then:

      * no match, including detached exec and every ordinary route, and
        WebSocket upgrades on other paths: the fallback handles the request
        untouched. This handler performs no admission, dial or telemetry for
        it. Fallback results are wrapped so `upgrade/4,5` and `terminate/3`
        delegate, as `Opsmaru.Incus.Gateway.CowboyHandler` does.
      * a matched route arriving over anything but HTTP/1.1 (HTTP/2 in
        practice): a Docker-shaped 400, with no admission, dial or fallback.
        Cowboy's `switch_protocol` exists only on HTTP/1.1 connections.
      * `POST /exec/{id}/start` without an `upgrade` header: the fallback.
        Detached exec is sent without an upgrade, and `Docker.Plug` serves
        it.
      * any other matched route without an `upgrade` header (attach,
        WebSocket attach, `/grpc`, `/session`): a Docker-shaped 400, with no
        admission, dial or fallback. Cowboy cannot emit Docker's hijacked
        HTTP 200.
      * a matched route with an `upgrade` header: the host policy and
        admission run first, then the dial and the upstream handshake, all
        through `Raw.open/3` in one relay process.

    ## Handoff

    One unlinked, monitored relay process per raw attempt calls
    `Raw.open/3` and so owns the backend. On `{:upgrade, ...}` the handler
    casts `{:switch_protocol, headers, Docker.CowboyTunnel, relay}` with the
    headers `Raw.relay/4` would write. Cowboy then writes
    `HTTP/1.1 101 Switching Protocols` (dockerd writes `101 UPGRADED`; the
    headers are identical) and calls `CowboyTunnel.takeover/7`, which hands
    the socket and Cowboy's buffered bytes to the relay. The relay calls
    `Raw.run/4` with those bytes as the request tail. The connection never
    returns to Cowboy's HTTP parser afterwards.

    If the handler process dies before the cast, or the takeover does not
    arrive within `:handoff_timeout`, the relay closes the backend. The
    upstream request may have been accepted, so nothing is retried.
    """

    @behaviour :cowboy_handler

    alias Opsmaru.Containers.Docker.{CowboyTunnel, Exchange, Raw, Route}
    alias Opsmaru.Containers.Transport.{CowboyStream, Stream}

    @max_body 1_048_576
    @max_timeout 86_400_000
    @takeovers %{"docker_stream" => "tcp", "h2c_upgrade" => "h2c", "websocket" => "websocket"}
    @exec_start "/exec/{name:.*}/start"

    @impl true
    def init(req, opts) do
      opts = options(opts)

      case classify(req) do
        :fallback -> fallback(req, opts)
        :raw -> raw(req, opts)
        {:reject, message} -> refuse(req, opts, message)
      end
    end

    # Cowboy dispatch passes handler options as written, and keyword lists
    # are the usual form there.
    defp options(opts) when is_map(opts), do: opts

    defp options(opts) when is_list(opts) do
      if Keyword.keyword?(opts),
        do: Map.new(opts),
        else: raise(ArgumentError, "Docker Cowboy handler options must be a map or keyword list")
    end

    defp options(_),
      do: raise(ArgumentError, "Docker Cowboy handler options must be a map or keyword list")

    # --- Dispatch -------------------------------------------------------------

    defp classify(req) do
      with {:ok, path} <- route_path(req.path),
           %{"takeover" => takeover} = route when is_map_key(@takeovers, takeover) <-
             Route.match(req.method, path) do
        classify_matched(req, route, Map.fetch!(@takeovers, takeover))
      else
        _ -> :fallback
      end
    end

    defp classify_matched(%{version: :"HTTP/1.1"} = req, route, protocol) do
      cond do
        Map.has_key?(:cowboy_req.headers(req), "upgrade") -> :raw
        route["path"] == @exec_start -> :fallback
        true -> {:reject, missing_upgrade(protocol)}
      end
    end

    defp classify_matched(_req, _route, protocol), do: {:reject, missing_upgrade(protocol)}

    defp missing_upgrade(protocol),
      do: "Docker stream requires an HTTP/1.1 request with an Upgrade: #{protocol} header"

    defp route_path(path) do
      path =
        case Regex.run(~r/\A\/v(\d+\.\d+)(\/.*)\z/, path, capture: :all_but_first) do
          [_version, rest] -> rest
          nil -> path
        end

      {:ok, URI.decode(path)}
    rescue
      ArgumentError -> :error
    end

    # --- Fallback -------------------------------------------------------------

    defp fallback(req, %{fallback: {handler, opts}}) do
      case handler.init(req, opts) do
        {:ok, req, state} ->
          {:ok, req, {:fallback, handler, state}}

        {protocol, req, state} ->
          {__MODULE__, req, {protocol, handler, state}}

        {protocol, req, state, upgrade_opts} ->
          {__MODULE__, req, {protocol, handler, state}, upgrade_opts}
      end
    end

    defp fallback(req, _opts) do
      {:ok, json(req, 404, "page not found"), :no_fallback}
    end

    @doc false
    def upgrade(req, env, __MODULE__, {protocol, handler, state}),
      do: protocol.upgrade(req, env, handler, state)

    @doc false
    def upgrade(req, env, __MODULE__, {protocol, handler, state}, opts),
      do: protocol.upgrade(req, env, handler, state, opts)

    @impl true
    def terminate(reason, req, {:fallback, handler, state}) do
      if function_exported?(handler, :terminate, 3),
        do: handler.terminate(reason, req, state),
        else: :ok
    end

    def terminate(_, _, _), do: :ok

    # --- Refusal without admission --------------------------------------------

    defp refuse(req, opts, message) do
      exchange = start_exchange(req, Map.get(opts, :host))
      reply_refusal(req, exchange, 400, message, :invalid_request)
    end

    defp reply_refusal(req, exchange, status, message, reason) do
      Exchange.commit(exchange, status, reason)
      req = json(req, status, message)
      Exchange.response_bytes(exchange, byte_size(Jason.encode!(%{message: message})))
      Exchange.finish(exchange, :ended)
      {:ok, req, :refused}
    end

    defp json(req, status, message) do
      :cowboy_req.reply(
        status,
        %{"content-type" => "application/json"},
        Jason.encode!(%{message: message}),
        req
      )
    end

    # --- Raw path -------------------------------------------------------------

    defp raw(req, opts) do
      host = Map.fetch!(opts, :host)

      limits = %{
        admission: timeout(opts, :admission_timeout, 1_000),
        dial: timeout(opts, :dial_timeout, 30_000),
        stream: timeout(opts, :stream_timeout, @max_timeout),
        handoff: timeout(opts, :handoff_timeout, 5_000)
      }

      started = now()
      exchange = start_exchange(req, host)

      try do
        case read_body(req, started + limits.admission) do
          {:ok, body, req} ->
            open(req, opts, host, body, exchange, limits, started)

          {:too_large, req} ->
            reply_refusal(req, exchange, 413, "Docker JSON request is too large", :too_large)

          {:invalid, req} ->
            reply_refusal(req, exchange, 400, "Invalid Docker request body", :invalid_request)
        end
      catch
        kind, reason ->
          Exchange.interrupt(exchange, :killed)
          Exchange.finish(exchange, :ended)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    end

    defp timeout(opts, key, default) do
      case Map.get(opts, key, default) do
        value when is_integer(value) and value in 1..@max_timeout -> value
        _ -> raise ArgumentError, "invalid Docker #{key}"
      end
    end

    defp start_exchange(req, host) do
      {address, port} = :cowboy_req.peer(req)

      Exchange.start(%{
        adapter: :cowboy,
        host: host,
        method: req.method,
        peer_address: address,
        peer_port: port,
        certificate: :cowboy_req.cert(req)
      })
    end

    # Attach and exec start carry a small JSON body. Read it within the
    # admission deadline and the same cap `Raw` applies.
    defp read_body(req, deadline) do
      cond do
        not :cowboy_req.has_body(req) -> {:ok, "", req}
        (:cowboy_req.body_length(req) || 0) > @max_body -> {:too_large, req}
        true -> read_body(req, deadline, [], 0)
      end
    catch
      :exit, _ -> {:invalid, req}
    end

    defp read_body(req, deadline, acc, size) do
      remaining = deadline - now()

      if remaining <= 0 do
        {:invalid, req}
      else
        result =
          :cowboy_req.read_body(req, %{
            length: @max_body + 1 - size,
            period: remaining,
            timeout: remaining + 100
          })

        case result do
          {status, data, req}
          when byte_size(data) + size > @max_body and status in [:ok, :more] ->
            {:too_large, req}

          {:ok, data, req} ->
            {:ok, IO.iodata_to_binary(Enum.reverse([data | acc])), req}

          {:more, data, req} ->
            read_body(req, deadline, [data | acc], size + byte_size(data))
        end
      end
    end

    defp open(req, opts, host, body, exchange, limits, started) do
      request = %{
        method: req.method,
        path: req.path,
        query: :cowboy_req.qs(req),
        headers: Map.to_list(:cowboy_req.headers(req)),
        body: body,
        peer: elem(:cowboy_req.peer(req), 0),
        host_peer: Map.get(opts, :host_peer)
      }

      relay_opts = %{
        caller: self(),
        holder: req.pid,
        ref: make_ref(),
        host: host,
        exchange: exchange,
        admission_deadline: started + limits.admission,
        # Measured from the request's start, like the admission deadline, so
        # the body read does not extend the open phase.
        open_deadline: started + limits.admission + limits.dial,
        deadline: started + limits.stream,
        handoff: limits.handoff
      }

      {relay, monitor} = spawn_monitor(fn -> relay(request, relay_opts) end)
      ref = relay_opts.ref

      receive do
        {^ref, {:http, status, headers, response_body}} ->
          Process.demonitor(monitor, [:flush])
          req = :cowboy_req.reply(status, header_map(headers), response_body, req)
          {:ok, req, :replied}

        {^ref, {:upgrade, response}} ->
          Process.demonitor(monitor, [:flush])
          switch(req, exchange, relay, ref, response)

        {^ref, :caller_closed} ->
          Process.demonitor(monitor, [:flush])
          caller_closed(req, exchange)

        {:DOWN, ^monitor, :process, ^relay, _} ->
          receive do
            {^ref, :caller_closed} -> caller_closed(req, exchange)
          after
            0 -> upstream_failure(req, exchange, :upstream_failed)
          end
      after
        max(relay_opts.open_deadline - now(), 0) + 100 ->
          # The upstream request may already have been sent: record what the
          # relay saw and never retry.
          Process.exit(relay, :kill)
          Process.demonitor(monitor, [:flush])
          upstream_failure(req, exchange, :deadline)
      end
    end

    defp switch(req, exchange, relay, ref, response) do
      Exchange.transfer(exchange, relay)
      send(relay, {ref, :handoff})

      :cowboy_req.cast(
        {:switch_protocol, header_map(response.headers), CowboyTunnel, relay},
        req
      )

      {:ok, req, :switched}
    catch
      kind, reason ->
        Process.exit(relay, :kill)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end

    # The connection died while the relay was opening: no response can reach
    # the client, so none is recorded. The watcher already recorded
    # `:caller_closed`.
    defp caller_closed(req, exchange) do
      Exchange.finish(exchange, :ended)
      {:ok, req, :caller_closed}
    end

    defp upstream_failure(req, exchange, reason) do
      message = "Docker engine connection failed"
      Exchange.commit(exchange, 502, reason)
      Exchange.interrupt(exchange, reason)
      req = json(req, 502, message)
      Exchange.response_bytes(exchange, byte_size(Jason.encode!(%{message: message})))
      Exchange.finish(exchange, :ended)
      {:ok, req, :replied}
    end

    # --- Relay process ----------------------------------------------------------

    # Owns the backend from the dial to the end of the tunnel: `Raw.open/3`
    # and `Raw.run/4` both run here.
    defp relay(request, state) do
      caller = Process.monitor(state.caller)
      holder = if is_pid(state.holder), do: Process.monitor(state.holder)
      state = Map.merge(state, %{caller_monitor: caller, holder_monitor: holder})

      watcher = watch_open(self(), state)

      result =
        Raw.open(state.host, request,
          admission_deadline: state.admission_deadline,
          deadline: state.open_deadline,
          exchange: state.exchange
        )

      send(watcher, :opened)

      case result do
        {:upgrade, response, backend, tail} ->
          send(state.caller, {state.ref, {:upgrade, response}})
          await_handoff(Map.merge(state, %{backend: backend, tail: tail}))

        {:http, _, _, _} = http ->
          send(state.caller, {state.ref, http})
      end
    end

    # `Raw.open/3` runs synchronously here and cannot read the mailbox. A
    # watcher ends the relay if the handler or the connection dies while it
    # opens, so a lost client neither dials late nor holds a stalled
    # handshake until the open deadline. Killing the relay closes the backend
    # it owns. After `Raw.open/3` returns, the relay handles those monitors.
    defp watch_open(relay, state) do
      spawn(fn ->
        relay_monitor = Process.monitor(relay)
        caller = Process.monitor(state.caller)
        holder = if is_pid(state.holder), do: Process.monitor(state.holder)

        receive do
          :opened ->
            :ok

          {:DOWN, ^relay_monitor, :process, _, _} ->
            :ok

          {:DOWN, ^caller, :process, _, _} ->
            Exchange.interrupt(state.exchange, :killed)
            Process.exit(relay, :kill)

          {:DOWN, ^holder, :process, _, _} ->
            # Tell the handler before the relay's `:DOWN` reaches it, so it
            # records no response for a connection that is gone.
            Exchange.interrupt(state.exchange, :caller_closed)
            send(state.caller, {state.ref, :caller_closed})
            Process.exit(relay, :kill)
        end
      end)
    end

    defp await_handoff(%{ref: ref, caller_monitor: caller} = state) do
      receive do
        {^ref, :handoff} ->
          Process.demonitor(caller, [:flush])
          await_attach(state)

        {:DOWN, ^caller, :process, _, _} ->
          # The handler died before the cast; the observer already reported
          # the exchange it owned.
          abandon(state, :killed)
      after
        state.handoff -> abandon(state, :handoff_timeout)
      end
    end

    defp await_attach(%{holder_monitor: holder} = state) do
      receive do
        {:attach, socket, transport, buffer} ->
          if holder, do: Process.demonitor(holder, [:flush])
          attach(state, socket, transport, buffer)

        {:DOWN, ^holder, :process, _, _} ->
          abandon(state, :caller_closed)
      after
        state.handoff -> abandon(state, :handoff_timeout)
      end
    end

    defp attach(state, socket, transport, buffer) do
      frontend =
        try do
          %Stream{
            adapter: CowboyStream,
            handle: CowboyStream.start(transport, socket, self(), state.deadline)
          }
        catch
          _, _ -> nil
        end

      if frontend do
        Raw.run(frontend, state.backend, state.tail,
          deadline: state.deadline,
          request_tail: buffer,
          exchange: state.exchange
        )
      else
        transport.close(socket)
        abandon(state, :caller_closed)
      end
    end

    defp abandon(state, reason) do
      Exchange.interrupt(state.exchange, reason)
      close(state.backend)
      Exchange.finish(state.exchange, :ended)
    end

    defp close(stream) do
      Stream.close(stream)
    catch
      _, _ -> :ok
    end

    # --- Helpers ----------------------------------------------------------------

    defp header_map(headers) do
      Enum.reduce(headers, %{}, fn
        {"set-cookie", value}, acc -> Map.update(acc, "set-cookie", [value], &(&1 ++ [value]))
        {name, value}, acc -> Map.update(acc, name, value, &[&1, ", ", value])
      end)
    end

    defp now, do: System.monotonic_time(:millisecond)
  end
end
