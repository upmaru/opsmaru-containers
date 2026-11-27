defmodule Opsmaru.Containers.TestSupport.ScriptedIncus do
  @moduledoc """
  A scripted `Native.Backend`. Its state lives in an Agent whose pid is the
  scripted client's `server` field, so calls from any process reach it. Every
  call is reported to the observer as `{:incus, call}`. No Incus server,
  socket or network is used.

  State:

    * `:instances` - instance maps, as `GetInstances` returns them
    * `:files` - `%{{instance, path} => binary | {:error, reason}}`
    * `:images` - image maps, as `GetImages` returns them
    * `:exec` - `fn instance, command -> result end`
    * `:import` - `fn properties, metadata, rootfs_bytes -> result end`
    * `:on_state` - `fn instance, action, state -> state end`, run after a
      state change is applied, so a test can play the shim (write a run
      record, stop the instance)
    * `:events` - queued lifecycle events, delivered in order by `next_event/2`
    * `:on_subscribe` - `fn state -> state end`, run when a subscription
      starts, so a test can change the instance between subscribe and read
    * `:image_files` - paths every created instance's image holds
    * `:session` - `fn instance, body -> script end` for an exec session,
      where a script is `%{output: [{channel, bytes}], exit: code}` and
      `echo: true` echoes stdin to channel 1 (0 when interactive) until
      stdin closes
    * `:operations` - `%{url => %{done: boolean, exit_code: code}}`
    * `:delete_refusals` - how many deletes Incus refuses as running first,
      as it does just after an OCI instance stops
    * `:read_failures` - how many file reads fail first, as they do while an
      instance starts or stops
    * `:after_state` - `fn state -> state end`, run after each instance state
      read, so a test can change the instance between that read and the next
  """

  @behaviour Opsmaru.Containers.Native.Backend

  alias Opsmaru.Containers.Native
  alias Opsmaru.Incus

  @doc "A scripted client for `project`, reporting calls to `observer`."
  def client(project, state, observer \\ self()) do
    defaults = %{
      instances: [],
      files: %{},
      images: [],
      exec: nil,
      import: nil,
      on_state: fn _, _, state -> state end,
      on_subscribe: & &1,
      events: [],
      image_files: [],
      session: fn _, _ -> %{output: [], exit: 0} end,
      operations: %{},
      delete_refusals: 0,
      read_failures: 0,
      after_state: & &1
    }

    {:ok, agent} =
      Agent.start(fn -> Map.merge(defaults, Map.new(state)) |> Map.put(:observer, observer) end)

    ExUnit.Callbacks.on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    %Incus{
      connection: Incus.Connection.unix!("/unused", owner: :fixture, project: project),
      context: Incus.Context.new!(owner: :fixture, identity: :host, ready?: fn -> true end),
      server: agent
    }
  end

  @doc "A native target in `project` over a scripted client."
  def target(state, observer \\ self()) do
    shim = %{path: "/opt/shim/init-arm64", sha256: Native.Target.digests()["aarch64"]}

    %Native.Target{
      client: client("native", state, observer),
      init: %{"aarch64" => shim},
      backend: __MODULE__
    }
  end

  @doc "Change the scripted state."
  def update(%Incus{server: agent}, fun), do: Agent.update(agent, fun)
  def update(%Native.Target{client: client}, fun), do: update(client, fun)

  @impl true
  def list_instances(client, _deadline) do
    report(client, :list_instances)
    {:ok, get(client, :instances)}
  end

  @impl true
  def read_file(client, instance, path, limit, _deadline) do
    report(client, {:read_file, instance, path})

    case take(client, :read_failures) do
      :refused -> {:error, :unavailable}
      :ok -> read_scripted(client, instance, path, limit)
    end
  end

  defp read_scripted(client, instance, path, limit) do
    case Map.get(get(client, :files), {instance, path}, {:error, :not_found}) do
      bytes when is_binary(bytes) and byte_size(bytes) <= limit -> {:ok, bytes}
      bytes when is_binary(bytes) -> {:error, :too_large}
      error -> error
    end
  end

  @impl true
  def stream_file(client, instance, path, sink, _deadline) do
    report(client, {:stream_file, instance, path})

    case Map.get(get(client, :files), {instance, path}, {:error, :not_found}) do
      bytes when is_binary(bytes) -> deliver_elsewhere(chunks(bytes, 4096), sink)
      error -> error
    end
  end

  # opsmaru_incus calls a download sink from its transfer worker, not from the
  # caller, so the scripted backend does too.
  defp deliver_elsewhere(chunks, sink) do
    task = Task.async(fn -> deliver(chunks, sink) end)
    Task.await(task, :infinity)
  end

  defp deliver([], _), do: :ok

  defp deliver([chunk | rest], sink) do
    if sink.(chunk) == :ok, do: deliver(rest, sink), else: {:error, :too_large}
  end

  @impl true
  def delete_instance(client, instance, _deadline) do
    report(client, {:delete_instance, instance})

    case take(client, :delete_refusals) do
      :refused ->
        {:error, :running}

      :ok ->
        update(client, fn state ->
          %{state | instances: Enum.reject(state.instances, &(&1["name"] == instance))}
        end)

        :ok
    end
  end

  # Counts down a scripted failure: `:refused` while any remain.
  defp take(%Incus{server: agent}, key) do
    Agent.get_and_update(agent, fn state ->
      case Map.fetch!(state, key) do
        0 -> {:ok, state}
        n -> {:refused, Map.put(state, key, n - 1)}
      end
    end)
  end

  @impl true
  def exec(client, instance, command, _deadline) do
    report(client, {:exec, instance, command})
    get(client, :exec).(instance, command)
  end

  @impl true
  def list_images(client, _deadline) do
    report(client, :list_images)
    {:ok, get(client, :images)}
  end

  @impl true
  def import_image(client, properties, metadata, rootfs, _deadline) do
    bytes = rootfs |> Enum.to_list() |> IO.iodata_to_binary()
    report(client, {:import_image, properties, metadata, bytes})
    get(client, :import).(properties, metadata, bytes)
  end

  @impl true
  def delete_image(client, fingerprint, _deadline) do
    report(client, {:delete_image, fingerprint})

    update(client, fn state ->
      %{state | images: Enum.reject(state.images, &(&1["fingerprint"] == fingerprint))}
    end)

    :ok
  end

  @doc "Queue a lifecycle event for subscribers."
  def event(target, event), do: update(target, &%{&1 | events: &1.events ++ [event]})

  @doc "A lifecycle event for an instance."
  def lifecycle(instance, action),
    do: %{
      "type" => "lifecycle",
      "metadata" => %{"action" => action, "source" => "/1.0/instances/" <> instance}
    }

  @impl true
  def create_instance(client, body, _deadline) do
    report(client, {:create_instance, body})

    Agent.get_and_update(client.server, fn state ->
      if Enum.any?(state.instances, &(&1["name"] == body["name"])) do
        {{:error, :conflict}, state}
      else
        config = Map.put(body["config"], "volatile.base_image", body["source"]["fingerprint"])

        instance = %{
          "name" => body["name"],
          "status" => "Stopped",
          "config" => config,
          "devices" => body["devices"]
        }

        {:ok, %{state | instances: state.instances ++ [instance]}}
      end
    end)
  end

  @impl true
  def instance_state(client, instance, _deadline) do
    report(client, {:instance_state, instance})

    result =
      case Enum.find(get(client, :instances), &(&1["name"] == instance)) do
        nil ->
          {:error, :not_found}

        found ->
          {:ok,
           Map.merge(%{"status" => found["status"], "network" => %{}}, found["state"] || %{})}
      end

    Agent.update(client.server, fn state -> state.after_state.(state) end)
    result
  end

  @impl true
  def update_state(client, instance, action, force, _deadline) do
    report(client, {:update_state, instance, action, force})

    status = %{
      "start" => "Running",
      "stop" => "Stopped",
      "freeze" => "Frozen",
      "unfreeze" => "Running"
    }

    Agent.update(client.server, fn state ->
      state = put_status(state, instance, status[action])
      state.on_state.(instance, action, state)
    end)
  end

  @doc "Set an instance's status in a state map."
  def put_status(state, instance, status) do
    put_instance(state, instance, &%{&1 | "status" => status})
  end

  @doc "Write a file in a state map."
  def put_file(state, instance, path, content),
    do: %{state | files: Map.put(state.files, {instance, path}, content)}

  @doc "Change one instance in a state map."
  def put_instance(state, instance, fun) do
    instances =
      Enum.map(state.instances, fn
        %{"name" => ^instance} = found -> fun.(found)
        other -> other
      end)

    %{state | instances: instances}
  end

  @impl true
  def patch_config(client, instance, config, _deadline) do
    report(client, {:patch_config, instance, config})

    update(client, fn state ->
      instances =
        Enum.map(state.instances, fn
          %{"name" => ^instance} = found ->
            merged = Map.merge(found["config"], config)
            %{found | "config" => for({k, v} <- merged, v != "", into: %{}, do: {k, v})}

          other ->
            other
        end)

      %{state | instances: instances}
    end)
  end

  @impl true
  def head_file(client, instance, path, _deadline) do
    report(client, {:head_file, instance, path})

    if Map.has_key?(get(client, :files), {instance, path}) or path in get(client, :image_files),
      do: {:ok, %{type: "file"}},
      else: {:error, :not_found}
  end

  @impl true
  def push_file(client, instance, path, content, mode, _deadline) do
    content = if content == :directory, do: :directory, else: IO.iodata_to_binary(content)
    report(client, {:push_file, instance, path, mode, content})
    update(client, &%{&1 | files: Map.put(&1.files, {instance, path}, content)})
  end

  @impl true
  def subscribe(client, _deadline) do
    report(client, :subscribe)
    Agent.update(client.server, fn state -> state.on_subscribe.(state) end)
    {:ok, client.server}
  end

  @impl true
  def next_event(agent, timeout) do
    case Agent.get_and_update(agent, fn
           %{events: [event | rest]} = state -> {{:ok, event}, %{state | events: rest}}
           state -> {:none, state}
         end) do
      {:ok, event} ->
        {:ok, event}

      :none when timeout <= 0 ->
        :timeout

      :none ->
        Process.sleep(min(timeout, 10))
        next_event(agent, timeout - 10)
    end
  end

  @impl true
  def close_events(_agent), do: :ok

  # -- Exec sessions -----------------------------------------------------------

  @impl true
  def exec_session(client, instance, body, _deadline) do
    report(client, {:exec_session, instance, body})
    script = get(client, :session).(instance, body)
    observer = get(client, :observer)

    {:ok, session} =
      Agent.start(fn ->
        queues =
          Enum.reduce(script[:output] || [], %{"0" => [], "1" => [], "2" => []}, fn {ch, bytes},
                                                                                    q ->
            Map.update!(q, ch, &(&1 ++ [bytes]))
          end)

        %{
          queues: queues,
          open: script[:echo] == true,
          echo: script[:echo] == true,
          echo_to: if(body["interactive"], do: "0", else: "1"),
          exit: script[:exit] || 0,
          observer: observer
        }
      end)

    {:ok, session}
  end

  @impl true
  def session_output(session, channel, timeout) do
    case Agent.get_and_update(session, &take_output(&1, channel)) do
      :wait when timeout <= 10 ->
        :timeout

      :wait ->
        Process.sleep(10)
        session_output(session, channel, timeout - 10)

      result ->
        result
    end
  end

  defp take_output(state, channel) do
    case state.queues[channel] do
      [bytes | rest] -> {{:ok, bytes}, put_in(state.queues[channel], rest)}
      [] -> {if(state.open, do: :wait, else: :eof), state}
    end
  end

  @impl true
  def session_input(session, bytes) do
    Agent.update(session, fn state ->
      send(state.observer, {:incus, {:session_input, bytes}})
      if state.echo, do: update_in(state.queues[state.echo_to], &(&1 ++ [bytes])), else: state
    end)
  end

  @impl true
  def session_close_input(session) do
    Agent.update(session, fn state ->
      send(state.observer, {:incus, :session_close_input})
      %{state | open: false}
    end)
  end

  @impl true
  def session_resize(session, width, height) do
    Agent.get(session, fn state ->
      send(state.observer, {:incus, {:session_resize, width, height}})
    end)

    :ok
  end

  @impl true
  def session_exit(session, _deadline), do: {:ok, Agent.get(session, & &1.exit)}

  @impl true
  def session_close(session) do
    if Process.alive?(session) do
      Agent.get(session, fn state -> send(state.observer, {:incus, :session_close}) end)
      Agent.stop(session)
    end

    :ok
  end

  @impl true
  def exec_detached(client, instance, body, _deadline) do
    report(client, {:exec_detached, instance, body})
    {:ok, "/1.0/operations/detached-" <> instance}
  end

  @impl true
  def operation_result(client, url, _deadline) do
    case Map.fetch(get(client, :operations), url) do
      {:ok, result} -> {:ok, result}
      :error -> {:error, :not_found}
    end
  end

  # -- SFTP --------------------------------------------------------------------

  @impl true
  def sftp_open(client, instance, _deadline) do
    report(client, {:sftp_open, instance})
    {:ok, {client, instance}}
  end

  @impl true
  def sftp_list({client, instance}, dir) do
    entries =
      for {{^instance, path}, content} <- get(client, :files),
          is_binary(content),
          Path.dirname(path) == dir,
          do: %{name: Path.basename(path), size: byte_size(content)}

    {:ok, Enum.sort_by(entries, & &1.name)}
  end

  @impl true
  def sftp_read({client, instance}, path, offset, count) do
    case Map.get(get(client, :files), {instance, path}) do
      content when is_binary(content) and offset <= byte_size(content) ->
        {:ok, binary_part(content, offset, min(count, byte_size(content) - offset))}

      content when is_binary(content) ->
        {:ok, ""}

      _ ->
        {:error, :not_found}
    end
  end

  @impl true
  def sftp_close({client, instance}) do
    report(client, {:sftp_close, instance})
    :ok
  end

  defp get(%Incus{server: agent}, key), do: Agent.get(agent, &Map.fetch!(&1, key))

  defp report(client, call), do: send(get(client, :observer), {:incus, call})

  defp chunks(<<chunk::binary-size(4096), rest::binary>>, 4096), do: [chunk | chunks(rest, 4096)]
  defp chunks("", _), do: []
  defp chunks(rest, _), do: [rest]
end
