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
  @callback create_instance(Incus.t(), map(), deadline()) :: :ok | {:error, term()}
  @callback instance_state(Incus.t(), String.t(), deadline()) :: result(map())
  @doc "An Incus state change: `start`, `stop`, `freeze` or `unfreeze`."
  @callback update_state(Incus.t(), String.t(), String.t(), boolean(), deadline()) ::
              :ok | {:error, term()}
  @doc "Merges keys into the instance config. An empty value removes a key."
  @callback patch_config(Incus.t(), String.t(), map(), deadline()) :: :ok | {:error, term()}
  @callback head_file(Incus.t(), String.t(), Path.t(), deadline()) :: result(map())
  @doc "Writes a file (iodata) or creates a directory (`:directory`) owned by root."
  @callback push_file(
              Incus.t(),
              String.t(),
              Path.t(),
              iodata() | :directory,
              integer(),
              deadline()
            ) ::
              :ok | {:error, term()}
  @doc "Subscribes to the client project's lifecycle events."
  @callback subscribe(Incus.t(), deadline()) :: result(term())
  @doc "The next event (`{:ok, map}`), `:timeout`, or an error once the stream is gone."
  @callback next_event(term(), non_neg_integer()) :: {:ok, map()} | :timeout | {:error, term()}
  @callback close_events(term()) :: :ok

  @doc "Starts an Incus exec with open channels, owned by the calling process."
  @callback exec_session(Incus.t(), String.t(), map(), deadline()) :: result(term())
  @doc "The next bytes on a channel, `:timeout` while it stays open, or `:eof`."
  @callback session_output(term(), String.t(), pos_integer()) ::
              {:ok, binary()} | :timeout | :eof | {:error, term()}
  @callback session_input(term(), binary()) :: :ok | {:error, term()}
  @callback session_close_input(term()) :: :ok | {:error, term()}
  @callback session_resize(term(), pos_integer(), pos_integer()) :: :ok | {:error, term()}
  @doc "The exec's exit status, once Incus reports the operation complete."
  @callback session_exit(term(), deadline()) :: result(integer())
  @callback session_close(term()) :: :ok
  @doc "Starts an Incus exec without channels and returns its operation URL."
  @callback exec_detached(Incus.t(), String.t(), map(), deadline()) :: result(String.t())
  @doc "Whether a detached exec's operation finished, and its exit status."
  @callback operation_result(Incus.t(), String.t(), deadline()) ::
              result(%{done: boolean(), exit_code: integer() | nil})
  @doc "Opens an SFTP session on an instance, owned by the calling process."
  @callback sftp_open(Incus.t(), String.t(), deadline()) :: result(term())
  @doc "A directory's entries; a missing directory has none."
  @callback sftp_list(term(), Path.t()) ::
              result([%{name: String.t(), size: non_neg_integer()}])
  @doc "Up to `count` bytes of a file from `offset`; fewer at its end."
  @callback sftp_read(term(), Path.t(), non_neg_integer(), pos_integer()) :: result(binary())
  @callback sftp_close(term()) :: :ok
end

defmodule Opsmaru.Containers.Native.Incus do
  @moduledoc false
  @behaviour Opsmaru.Containers.Native.Backend

  alias Opsmaru.Incus

  alias Opsmaru.Incus.{
    Error,
    Events,
    Files,
    Images,
    Model,
    Operation,
    RequestContext,
    Response,
    Session,
    SFTP
  }

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

  @impl true
  def create_instance(client, body, deadline) do
    with {:ok, client} <- scope(client, deadline) do
      client
      |> Incus.call("CreateInstance", %{}, body: body)
      |> await(client)
      |> ok()
    end
  end

  @impl true
  def instance_state(client, instance, deadline) do
    with {:ok, client} <- scope(client, deadline) do
      case Incus.call(client, "GetInstanceState", %{"name" => instance}) do
        {:ok, %Response{metadata: %Model{data: state}}} -> {:ok, state}
        {:error, %Error{http_status: 404}} -> {:error, :not_found}
        {:error, _} = error -> error
      end
    end
  end

  @impl true
  def update_state(client, instance, action, force, deadline) do
    body = %{"action" => action, "timeout" => -1, "force" => force, "stateful" => false}

    with {:ok, client} <- scope(client, deadline) do
      client
      |> Incus.call("UpdateInstanceState", %{"name" => instance}, body: body)
      |> await(client)
      |> ok()
    end
  end

  @impl true
  def patch_config(client, instance, config, deadline) do
    with {:ok, client} <- scope(client, deadline) do
      case Incus.call(client, "PatchInstance", %{"name" => instance}, body: %{"config" => config}) do
        {:ok, _} ->
          :ok

        {:error, %Error{http_status: 404}} ->
          {:error, :not_found}

        {:error, %Error{kind: :native, http_status: status}} when status < 500 ->
          {:error, :rejected}

        {:error, _} ->
          {:error, :uncertain}
      end
    end
  end

  @impl true
  def head_file(client, instance, path, deadline) do
    with {:ok, client} <- scope(client, deadline) do
      case Files.head(client, instance, path) do
        {:ok, %{result: metadata}} -> {:ok, metadata}
        {:error, %Error{http_status: 404}} -> {:error, :not_found}
        {:error, _} = error -> error
      end
    end
  end

  @impl true
  def push_file(client, instance, path, content, mode, deadline) do
    {type, source} =
      if content == :directory,
        do: {"directory", []},
        else: {"file", [IO.iodata_to_binary(content)]}

    with {:ok, client} <- scope(client, deadline) do
      case Files.create(client, instance, path, source, type: type, mode: mode, uid: 0, gid: 0) do
        {:ok, _} ->
          :ok

        {:error, %Error{kind: :native, http_status: status}} when status < 500 ->
          {:error, :rejected}

        {:error, _} ->
          {:error, :uncertain}
      end
    end
  end

  @impl true
  def subscribe(client, deadline) do
    with {:ok, client} <- scope(client, deadline),
         do: Events.subscribe(client, types: ["lifecycle"])
  end

  @impl true
  def next_event(channel, timeout) do
    case Events.next(channel, timeout) do
      {:ok, %Model{data: event}} -> {:ok, event}
      {:error, %Error{kind: kind}} when kind in [:timeout, :deadline] -> :timeout
      :eof -> {:error, :closed}
      {:error, _} = error -> error
    end
  end

  @impl true
  def close_events(channel) do
    Events.close(channel)
    :ok
  end

  @impl true
  def exec_session(client, instance, body, deadline) do
    with {:ok, client} <- scope(client, deadline),
         do: Session.exec(client, instance, body)
  end

  @impl true
  def session_output(session, channel, timeout) do
    case Session.output(session, channel, timeout) do
      {:ok, {:binary, data}} -> {:ok, data}
      {:ok, _frame} -> {:ok, ""}
      :eof -> :eof
      {:error, %Error{kind: kind}} when kind in [:deadline, :timeout] -> :timeout
      {:error, _} = error -> error
    end
  end

  @impl true
  def session_input(session, bytes), do: ok(Session.input(session, bytes))

  @impl true
  def session_close_input(session), do: ok(Session.close_input(session))

  @impl true
  def session_resize(session, width, height), do: ok(Session.resize(session, width, height))

  @impl true
  def session_exit(session, deadline) do
    case Session.exit_status(session) do
      {:ok, status} ->
        {:ok, status}

      {:error, %Error{kind: :operation_pending}} = pending ->
        if remaining(deadline) > 50 do
          Process.sleep(50)
          session_exit(session, deadline)
        else
          pending
        end

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def session_close(session) do
    Session.close(session)
    :ok
  end

  @impl true
  def exec_detached(client, instance, body, deadline) do
    body = Map.merge(body, %{"wait-for-websocket" => false, "interactive" => false})

    with {:ok, client} <- scope(client, deadline),
         {:ok, response} <-
           Incus.call(client, "ExecInstance", %{"instanceName" => instance}, body: body),
         {:ok, operation} <- Operation.from_response(client, response) do
      {:ok, operation.url}
    end
  end

  @impl true
  def operation_result(client, url, deadline) do
    with {:ok, client} <- scope(client, deadline) do
      case Operation.poll(%Operation{client: client, url: url}) do
        {:ok, current} ->
          code = get_in(Operation.data(current), ["metadata", "return"])
          {:ok, %{done: Operation.completed?(current), exit_code: if(is_integer(code), do: code)}}

        {:error, %Error{http_status: 404}} ->
          {:error, :not_found}

        {:error, _} = error ->
          error
      end
    end
  end

  @impl true
  def sftp_open(client, instance, deadline) do
    with {:ok, client} <- scope(client, deadline), do: SFTP.instance(client, instance)
  end

  @impl true
  def sftp_list(session, dir) do
    case SFTP.read_dir(session, dir) do
      {:ok, entries} -> {:ok, Enum.map(entries, &%{name: &1.name, size: &1.size})}
      {:error, %Error{response: %{class: :not_exist}}} -> {:ok, []}
      {:error, _} = error -> error
    end
  end

  @impl true
  def sftp_read(session, path, offset, count) do
    with {:ok, file} <- SFTP.open(session, path) do
      try do
        case SFTP.File.read_at(file, offset, count) do
          {:ok, data} -> {:ok, data}
          {:eof, data} -> {:ok, data}
          {:error, _} = error -> error
        end
      after
        SFTP.File.close(file)
      end
    end
  end

  @impl true
  def sftp_close(session) do
    SFTP.close(session)
    :ok
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
