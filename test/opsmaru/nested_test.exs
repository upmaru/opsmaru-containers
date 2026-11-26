defmodule Opsmaru.Containers.NestedTest do
  use ExUnit.Case, async: true

  alias Opsmaru.Containers.{Nested, Transport}
  alias Opsmaru.Containers.Nested.{Spec, Target}
  alias Opsmaru.Containers.Transport.Stream
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context, Error, RequestContext, Server}

  defmodule ReadyEngine do
    @moduledoc false
    @behaviour Transport
    @behaviour Stream

    @impl Transport
    def dial(_target, observer, _deadline) do
      {:ok, pid} = Agent.start_link(fn -> {observer, ""} end)
      {:ok, %Stream{adapter: __MODULE__, handle: pid}}
    end

    @impl Stream
    def send(pid, wire, _deadline) do
      case IO.iodata_to_binary(wire) do
        "GET /_ping " <> _ ->
          form_response(pid, "OK")

        "GET /version " <> _ ->
          form_response(pid, ~s({"MinAPIVersion":"1.40","ApiVersion":"1.57"}))
      end
    end

    defp form_response(pid, body) do
      bytes = "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(body)}\r\n\r\n#{body}"
      Agent.update(pid, fn {observer, _} -> {observer, bytes} end)
    end

    @impl Stream
    def recv(pid, _limit, _deadline) do
      Agent.get_and_update(pid, fn
        {observer, ""} -> {:eof, {observer, ""}}
        {observer, bytes} -> {{:ok, bytes}, {observer, ""}}
      end)
    end

    @impl Stream
    def close(pid), do: Agent.stop(pid)

    @impl Stream
    def shutdown_write(_, _), do: :ok
  end

  @instance %{
    "name" => "engine",
    "status" => "Running",
    "type" => "container",
    "config" => %{"user.opsmaru.containers.role" => "engine"}
  }
  @specification %Spec{source: %{"type" => "image", "alias" => "fixture-engine"}}
  @instance_path "/1.0/instances/engine?project=fixtures"
  @state_path "/1.0/instances/engine/state?project=fixtures"

  test "waits for an accepted create and start before probing the engine" do
    stopped = %{@instance | "status" => "Stopped"}

    {target, server} =
      scripted_incus([
        {404, native_error(404)},
        {202, accepted("create")},
        {200, sync(operation("create", 200))},
        {200, sync(stopped)},
        {202, accepted("start")},
        {200, sync(operation("start", 200))},
        {200, sync(%{"status" => "Running"})}
      ])

    assert {:ok, %{minimum: "1.40", maximum: "1.57"}} = ensure(target)

    assert {"GET", @instance_path, ""} = request()
    assert {"POST", "/1.0/instances?project=fixtures", _} = request()
    assert {"GET", "/1.0/operations/create?project=fixtures", ""} = request()
    assert {"GET", @instance_path, ""} = request()
    assert {"PUT", @state_path, _} = request()
    assert {"GET", "/1.0/operations/start?project=fixtures", ""} = request()
    assert {"GET", @state_path, ""} = request()
    assert Task.await(server) == :ok
  end

  test "converges after a definite create conflict and a repeat ensure performs reads only" do
    {target, server} =
      scripted_incus([
        {404, native_error(404)},
        {409, native_error(409)},
        {200, sync(@instance)},
        {200, sync(%{"status" => "Running"})},
        {200, sync(@instance)},
        {200, sync(%{"status" => "Running"})}
      ])

    assert {:ok, %{minimum: "1.40", maximum: "1.57"}} = ensure(target)
    assert {:ok, %{minimum: "1.40", maximum: "1.57"}} = ensure(target)
    assert {"GET", @instance_path, ""} = request()
    assert {"POST", "/1.0/instances?project=fixtures", body} = request()

    assert %{
             "config" => %{
               "security.nesting" => "true",
               "user.opsmaru.containers.role" => "engine"
             },
             "type" => "container",
             "source" => %{"alias" => "fixture-engine"}
           } = Jason.decode!(body)

    for path <- [@instance_path, @state_path, @instance_path, @state_path],
        do: assert({"GET", ^path, ""} = request())

    assert Task.await(server) == :ok
  end

  test "unknown create outcome is reported after a single submission" do
    {target, server} = scripted_incus([{404, native_error(404)}, :disconnect])

    assert {:error, %Error{kind: :uncertain}} = ensure(target)
    assert {"GET", @instance_path, ""} = request()
    assert {"POST", "/1.0/instances?project=fixtures", _} = request()
    assert Task.await(server) == :ok
    refute_received {:incus, _}
  end

  test "unknown start outcome is reported after a single submission" do
    {target, server} =
      scripted_incus([{200, sync(%{@instance | "status" => "Stopped"})}, :disconnect])

    assert {:error, %Error{kind: :uncertain}} = ensure(target)
    assert {"GET", @instance_path, ""} = request()
    assert {"PUT", @state_path, body} = request()
    assert %{"action" => "start"} = Jason.decode!(body)
    assert Task.await(server) == :ok
  end

  test "rejects a foreign instance before making changes" do
    {target, server} = scripted_incus([{200, sync(%{@instance | "config" => %{}})}])
    assert {:error, :foreign_instance} = ensure(target)
    assert {"GET", @instance_path, ""} = request()
    assert Task.await(server) == :ok
  end

  defp ensure(target) do
    Nested.ensure(target, @specification,
      request_context: RequestContext.new!(timeout: 2_000),
      dialer: {ReadyEngine, self()}
    )
  end

  defp scripted_incus(responses) do
    path = "/tmp/occ-#{Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)}"
    address = {:local, path}
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ifaddr: address])
    File.chmod!(path, 0o600)
    observer = self()

    server =
      Task.async(fn ->
        try do
          Enum.each(responses, &serve(listener, observer, &1))
        after
          :gen_tcp.close(listener)
          File.rm(path)
        end
      end)

    client = %Incus{
      connection: Connection.unix!(path, owner: :test, project: "fixtures"),
      context: Context.new!(owner: :test, identity: :fixture, ready?: fn -> true end),
      server: %Server{}
    }

    {%Target{client: client, instance: "engine"}, server}
  end

  defp serve(listener, observer, response) do
    {:ok, socket} = :gen_tcp.accept(listener, 2_000)

    try do
      send(observer, {:incus, read_request(socket, "")})
      write_response(socket, response)
    after
      :gen_tcp.close(socket)
    end
  end

  defp write_response(_, :disconnect), do: :ok

  defp write_response(socket, {status, envelope}) do
    body = Jason.encode!(envelope)

    :gen_tcp.send(socket, [
      "HTTP/1.1 #{status} Fixture\r\nContent-Type: application/json\r\nConnection: close\r\n",
      "Content-Length: #{byte_size(body)}\r\n\r\n",
      body
    ])
  end

  defp read_request(socket, buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [_] ->
        {:ok, bytes} = :gen_tcp.recv(socket, 0, 2_000)
        read_request(socket, buffer <> bytes)

      [head, rest] ->
        [request | _] = String.split(head, "\r\n")
        [method, path, _] = String.split(request)
        {method, path, read_body(socket, head, rest)}
    end
  end

  defp read_body(socket, head, rest) do
    case Regex.run(~r/^content-length: (\d+)$/im, String.replace(head, "\r\n", "\n")) do
      [_, length] -> read_rest(socket, rest, String.to_integer(length) - byte_size(rest))
      nil -> rest
    end
  end

  defp read_rest(socket, rest, amount) when amount > 0 do
    {:ok, bytes} = :gen_tcp.recv(socket, amount, 2_000)
    rest <> bytes
  end

  defp read_rest(_, rest, _), do: rest

  defp request do
    assert_receive {:incus, request}
    request
  end

  defp sync(metadata), do: %{"type" => "sync", "metadata" => metadata}
  defp native_error(code), do: %{"type" => "error", "error_code" => code, "error" => "fixture"}

  defp accepted(id),
    do: %{
      "type" => "async",
      "operation" => "/1.0/operations/#{id}",
      "metadata" => operation(id, 103)
    }

  defp operation(id, status), do: %{"id" => id, "status_code" => status}
end
