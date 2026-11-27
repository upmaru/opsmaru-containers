defmodule Opsmaru.Containers.Native.Backend do
  @moduledoc false
  # The Incus calls the native engine makes, all through opsmaru_incus. Each
  # takes a client (the native project's, or the nested engine's for work in
  # the engine instance) and an absolute monotonic deadline in milliseconds.
  # `Native.Target`'s backend field selects the implementation, so tests can
  # script Incus. Mutations are never retried here: a lost reply is
  # `{:error, :uncertain}`.

  alias Opsmaru.Incus

  @type deadline :: integer()
  @type result(value) :: {:ok, value} | {:error, term()}

  @callback list_instances(Incus.t(), deadline()) :: result([map()])
  @callback read_file(Incus.t(), String.t(), Path.t(), pos_integer(), deadline()) ::
              result(binary())
  @callback stream_file(Incus.t(), String.t(), Path.t(), (binary() -> :ok), deadline()) ::
              :ok | {:error, term()}
  @callback delete_instance(Incus.t(), String.t(), deadline()) :: :ok | {:error, term()}
  @callback exec(Incus.t(), String.t(), [String.t()], deadline()) ::
              result(%{status: integer(), stdout: binary(), stderr: binary()})
  @callback list_images(Incus.t(), deadline()) :: result([map()])
  @callback import_image(Incus.t(), map(), binary(), Enumerable.t(), deadline()) ::
              result(String.t())
  @callback delete_image(Incus.t(), String.t(), deadline()) :: :ok | {:error, term()}
end

defmodule Opsmaru.Containers.Native.Incus do
  @moduledoc false
  @behaviour Opsmaru.Containers.Native.Backend

  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Error, Files, Images, Model, Operation, RequestContext, Response, Session}

  @max_exec_output 1_048_576

  @impl true
  def list_instances(client, deadline) do
    with {:ok, client} <- scope(client, deadline),
         {:ok, %Response{metadata: models}} <-
           Incus.call(client, "GetInstances", %{"instance_type" => "container"}) do
      {:ok, Enum.map(models, fn %Model{data: data} -> data end)}
    end
  end

  @impl true
  def read_file(client, instance, path, limit, deadline) do
    {:ok, buffer} = Agent.start_link(fn -> {[], 0} end)

    sink = fn bytes -> Agent.get_and_update(buffer, &append(&1, bytes, limit)) end

    try do
      with :ok <- stream_file(client, instance, path, sink, deadline),
           do: {:ok, Agent.get(buffer, &collected/1)}
    after
      Agent.stop(buffer)
    end
  end

  defp append({parts, size}, bytes, limit) do
    size = size + byte_size(bytes)
    if size <= limit, do: {:ok, {[bytes | parts], size}}, else: {:too_large, {parts, size}}
  end

  defp collected({parts, _}), do: parts |> Enum.reverse() |> IO.iodata_to_binary()

  @impl true
  def stream_file(client, instance, path, sink, deadline) do
    with {:ok, client} <- scope(client, deadline) do
      case Files.read(client, instance, path, sink) do
        {:ok, %{type: "file"}} -> :ok
        {:ok, _} -> {:error, :not_a_file}
        {:error, %Error{http_status: 404}} -> {:error, :not_found}
        {:error, %Error{kind: :sink_failed}} -> {:error, :too_large}
        {:error, _} = error -> error
      end
    end
  end

  @impl true
  def delete_instance(client, instance, deadline) do
    with {:ok, client} <- scope(client, deadline) do
      client
      |> Incus.call("DeleteInstance", %{"name" => instance})
      |> await(client)
      |> ok()
    end
  end

  @impl true
  def exec(client, instance, command, deadline) do
    {:ok, output} = Agent.start_link(fn -> %{"1" => [], "2" => []} end)

    sink = fn channel ->
      &Agent.update(output, fn acc -> Map.update!(acc, channel, fn p -> [&1 | p] end) end)
    end

    body = %{"command" => command, "wait-for-websocket" => true, "interactive" => false}

    try do
      with {:ok, client} <- scope(client, deadline),
           timeout when timeout > 0 <- remaining(deadline),
           {:ok, %{exit_status: status}} <-
             Session.run(client, instance, body, "", sink.("1"), sink.("2"),
               timeout: min(timeout, client.connection.stream_timeout),
               max_output_bytes: min(@max_exec_output, client.connection.max_stream_bytes)
             ) do
        collected = Agent.get(output, & &1)

        {:ok,
         %{
           status: status,
           stdout: collected["1"] |> Enum.reverse() |> IO.iodata_to_binary(),
           stderr: collected["2"] |> Enum.reverse() |> IO.iodata_to_binary()
         }}
      else
        0 -> {:error, :deadline}
        {:error, _} = error -> error
        other -> {:error, other}
      end
    after
      Agent.stop(output)
    end
  end

  @impl true
  def list_images(client, deadline) do
    with {:ok, client} <- scope(client, deadline),
         {:ok, %Response{metadata: models}} <- Incus.call(client, "GetImages", %{}) do
      {:ok, Enum.map(models, fn %Model{data: data} -> data end)}
    end
  end

  @impl true
  def import_image(client, properties, metadata, rootfs, deadline) do
    image = %{"properties" => properties, "public" => false}

    options = [
      rootfs: rootfs,
      metadata_name: "metadata.tar",
      rootfs_name: "rootfs.tar.gz",
      type: "container"
    ]

    with {:ok, client} <- scope(client, deadline),
         {:ok, operation} <- client |> Images.import(image, [metadata], options) |> await(client) do
      fingerprint(Operation.data(operation))
    end
  end

  # A completed upload whose operation names no fingerprint is still uncertain.
  defp fingerprint(%{"metadata" => %{"fingerprint" => fingerprint}}) when is_binary(fingerprint),
    do: {:ok, fingerprint}

  defp fingerprint(_), do: {:error, :uncertain}

  @impl true
  def delete_image(client, fingerprint, deadline) do
    with {:ok, client} <- scope(client, deadline) do
      client
      |> Incus.call("DeleteImage", %{"fingerprint" => fingerprint})
      |> await(client)
      |> ok()
    end
  end

  defp scope(client, deadline) do
    case remaining(deadline) do
      0 ->
        {:error, :deadline}

      timeout ->
        context = RequestContext.new!(timeout: min(timeout, 3_600_000))
        {:ok, Incus.with_context(client, context)}
    end
  end

  # A mutation whose outcome is unknown is never replayed: it is reported as
  # uncertain for the caller to reconcile by reading Incus.
  defp await({:ok, %Response{} = response}, client) do
    with {:ok, operation} <- Operation.from_response(client, response),
         timeout when timeout > 0 <- remaining(client.connection.request_context.deadline),
         {:ok, operation} <- Operation.wait(operation, timeout: timeout) do
      {:ok, operation}
    else
      {:error, %Error{kind: :operation_failed} = error} -> {:error, error}
      _ -> {:error, :uncertain}
    end
  end

  defp await({:error, %Error{kind: :native, http_status: 409}}, _), do: {:error, :conflict}
  defp await({:error, %Error{kind: :native, http_status: 404}}, _), do: {:error, :not_found}

  defp await({:error, %Error{kind: :native, http_status: status}}, _) when status < 500,
    do: {:error, :rejected}

  defp await({:error, _}, _), do: {:error, :uncertain}

  defp ok({:ok, _}), do: :ok
  defp ok(error), do: error

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
