defmodule Opsmaru.Containers.Native.Exec do
  @moduledoc false
  # Docker exec for native containers (design decision 9). An exec record is
  # the JSON value of `user.opsmaru.containers.exec.<id>` on the instance; the
  # library keeps no other state. A start runs `/.opsmaru/init exec` through
  # Incus exec as root, and the shim sets up the user, cwd and environment
  # before it `execve`s the command.
  #
  # An attached start is served by a `Native.Pipe`, which owns the Incus
  # session. It registers under `:global` as `{Native.Exec, exec_id}` while
  # the exec runs, so a resize on another connection reaches it. The exit
  # code is written to the record before the stream ends, because the
  # Docker CLI inspects the exec as soon as its output ends.

  alias Opsmaru.Containers.Native.{Container, Lifecycle, Pipe, Shim}

  @keep 32
  @read_timeout 1_000
  @running ["Running", "Starting", "Stopping"]
  @lost_exit 137

  # -- Create ----------------------------------------------------------------------

  @doc "Docker exec create: validates and stores the record, then answers its ID."
  def create(context, container, body, deadline) do
    native = context.target.native

    with {:ok, config} <- decode(body),
         :ok <- validate(config),
         {:ok, state} <- Lifecycle.instance_state(native, container, deadline),
         :ok <- runnable(container, state["status"]) do
      id = Container.new_id()
      record = new_record(config, id)

      keys =
        container.execs
        |> Map.put(id, record)
        |> pruned()
        |> Map.new(fn exec_id -> {Container.exec_key(exec_id), ""} end)
        |> Map.put(Container.exec_key(id), Jason.encode!(record))

      with :ok <- Lifecycle.patch(native, container, keys, deadline),
           do: {:ok, 201, %{"Id" => id}}
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{} = config} -> {:ok, config}
      _ -> {:error, 400, "Invalid Docker JSON request"}
    end
  end

  defp validate(config) do
    cond do
      config["Privileged"] == true ->
        {:error, 400, "native engine cannot honour: Privileged"}

      not string_list?(config["Cmd"]) or config["Cmd"] == [] ->
        {:error, 400, "No exec command specified"}

      not (config["Env"] == nil or string_list?(config["Env"])) ->
        {:error, 400, "Invalid Docker JSON request"}

      not Enum.all?(["User", "WorkingDir", "DetachKeys"], &optional_string?(config[&1])) ->
        {:error, 400, "Invalid Docker JSON request"}

      true ->
        :ok
    end
  end

  defp runnable(container, "Frozen"),
    do: {:error, 409, "Container #{container.id} is paused, unpause the container before exec"}

  defp runnable(_, status) when status in @running, do: :ok
  defp runnable(container, _), do: {:error, 409, "container #{container.id} is not running"}

  defp new_record(config, id) do
    %{
      "ID" => id,
      "Cmd" => config["Cmd"],
      "Env" => config["Env"] || [],
      "User" => config["User"] || "",
      "WorkingDir" => config["WorkingDir"] || "",
      "Tty" => config["Tty"] == true,
      "ConsoleSize" => console_size(config["ConsoleSize"]),
      "AttachStdin" => config["AttachStdin"] == true,
      "AttachStdout" => config["AttachStdout"] == true,
      "AttachStderr" => config["AttachStderr"] == true,
      "DetachKeys" => config["DetachKeys"] || "",
      "Created" => DateTime.to_iso8601(DateTime.utc_now()),
      "Started" => false,
      "Running" => false,
      "ExitCode" => nil,
      "Operation" => nil
    }
  end

  # The records past the newest `@keep`, by creation time.
  defp pruned(execs) do
    execs
    |> Enum.sort_by(fn {id, record} -> {created(record), id} end, :desc)
    |> Enum.drop(@keep)
    |> Enum.map(&elem(&1, 0))
  end

  defp created(%{"Created" => created}) when is_binary(created) do
    case DateTime.from_iso8601(created) do
      {:ok, time, _} -> DateTime.to_unix(time, :microsecond)
      _ -> 0
    end
  end

  defp created(_), do: 0

  # -- Inspect -----------------------------------------------------------------------

  @doc "Docker exec inspect. A detached exec's exit is read from its Incus operation."
  def inspect(context, container, exec_id, deadline) do
    native = context.target.native
    record = refresh(native, container, exec_id, container.execs[exec_id], deadline)
    running = running?(exec_id, record)
    [entrypoint | arguments] = record["Cmd"]

    {:ok, 200,
     %{
       "ID" => exec_id,
       "Running" => running,
       "ExitCode" => if(running, do: nil, else: record["ExitCode"]),
       "ProcessConfig" => %{
         "tty" => record["Tty"],
         "entrypoint" => entrypoint,
         "arguments" => arguments,
         "privileged" => false,
         "user" => record["User"]
       },
       "OpenStdin" => record["AttachStdin"],
       "OpenStderr" => record["AttachStderr"],
       "OpenStdout" => record["AttachStdout"],
       "CanRemove" => false,
       "ContainerID" => container.id,
       "DetachKeys" => record["DetachKeys"],
       "Pid" => 0
     }}
  end

  defp refresh(
         native,
         container,
         exec_id,
         %{"Running" => true, "Operation" => url} = record,
         deadline
       )
       when is_binary(url) do
    case native.backend.operation_result(native.client, url, deadline) do
      {:ok, %{done: true, exit_code: code}} ->
        finished = %{record | "Running" => false, "ExitCode" => code}
        put_record(native, container, exec_id, finished, deadline)
        finished

      {:ok, _} ->
        record

      # Incus no longer holds the operation, so its exit code is gone.
      {:error, :not_found} ->
        finished = %{record | "Running" => false}
        put_record(native, container, exec_id, finished, deadline)
        finished

      {:error, _} ->
        record
    end
  end

  defp refresh(_, _, _, record, _), do: record

  # An attached exec runs only while its pipe does; a record a crashed
  # relay left running is reported as finished.
  defp running?(_, %{"Running" => false}), do: false
  defp running?(_, %{"Operation" => url}) when is_binary(url), do: true
  defp running?(exec_id, _), do: :global.whereis_name(name(exec_id)) != :undefined

  # -- Start ---------------------------------------------------------------------------

  @doc "Decodes an exec start body: `{:ok, %{detach: boolean, tty: boolean, console: [h, w] | nil}}`."
  def start_options(body) do
    case Jason.decode(if(body == "", do: "{}", else: body)) do
      {:ok, %{} = options} ->
        {:ok,
         %{
           detach: options["Detach"] == true,
           console: console_size(options["ConsoleSize"])
         }}

      _ ->
        {:error, 400, "Invalid Docker JSON request"}
    end
  end

  @doc "Docker exec start with `Detach: true`: an Incus exec without channels."
  def start_detached(context, container, exec_id, deadline) do
    native = context.target.native
    record = container.execs[exec_id]

    with :ok <- startable(exec_id, record),
         started = %{record | "Started" => true, "Running" => true},
         :ok <- put_record(native, container, exec_id, started, deadline) do
      body = exec_body(record, nil)

      case native.backend.exec_detached(native.client, container.instance, body, deadline) do
        {:ok, url} ->
          put_record(native, container, exec_id, %{started | "Operation" => url}, deadline)
          {:ok, 200}

        {:error, _} ->
          failed = %{started | "Running" => false, "ExitCode" => 126}
          put_record(native, container, exec_id, failed, deadline)
          {:error, 500, "native engine: Incus could not start exec #{exec_id}"}
      end
    end
  end

  @doc """
  Docker exec start with attached streams. Returns the pipe the raw adapter
  relays and whether the stream is a TTY (unframed).
  """
  def start_attached(context, container, exec_id, options, deadline) do
    native = context.target.native
    record = container.execs[exec_id]

    with :ok <- startable(exec_id, record),
         {:ok, stream} <-
           Pipe.open(source(native, container, exec_id, record, options, deadline), deadline) do
      {:ok, stream, record["Tty"]}
    else
      {:error, status, message} -> {:error, status, message}
      {:error, :running} -> {:error, 409, "exec command #{exec_id} is already running"}
      {:error, {:status, status, message}} -> {:error, status, message}
      {:error, _} -> {:error, 500, "native engine: Incus could not start exec #{exec_id}"}
    end
  end

  defp startable(exec_id, record) do
    cond do
      record["Running"] == true -> {:error, 409, "exec command #{exec_id} is already running"}
      record["Started"] == true -> {:error, 409, "exec command #{exec_id} has already run"}
      true -> :ok
    end
  end

  defp source(native, container, exec_id, record, options, deadline) do
    backend = native.backend
    tty = record["Tty"]
    console = options.console || record["ConsoleSize"]

    %{
      start: fn pipe ->
        with :yes <- :global.register_name(name(exec_id), self()),
             started = %{record | "Started" => true, "Running" => true},
             :ok <- status(put_record(native, container, exec_id, started, deadline)),
             {:ok, session} <-
               backend.exec_session(
                 native.client,
                 container.instance,
                 exec_body(record, console),
                 deadline
               ) do
          if not record["AttachStdin"], do: backend.session_close_input(session)

          finish = fn code ->
            put_record(
              native,
              container,
              exec_id,
              %{started | "Running" => false, "ExitCode" => code},
              deadline
            )

            :global.unregister_name(name(exec_id))
          end

          spawn_link(fn -> relay(pipe, backend, session, record, finish, deadline) end)
          {:ok, %{session: session}}
        else
          :no ->
            {:error, :running}

          {:error, _} = error ->
            failed = %{record | "Started" => true, "ExitCode" => 126}
            put_record(native, container, exec_id, failed, deadline)
            error
        end
      end,
      input: fn state, bytes ->
        if record["AttachStdin"], do: backend.session_input(state.session, bytes), else: :ok
      end,
      close_input: fn state ->
        if record["AttachStdin"], do: backend.session_close_input(state.session), else: :ok
      end,
      control: fn
        state, {:resize, width, height} when tty ->
          backend.session_resize(state.session, width, height)

        _, _ ->
          {:error, :not_tty}
      end,
      close: fn state -> backend.session_close(state.session) end
    }
  end

  defp status(:ok), do: :ok
  defp status({:error, status, message}), do: {:error, {:status, status, message}}

  # Reads every output channel until each ends, then records the exit code
  # before ending the stream.
  defp relay(pipe, backend, session, record, finish, deadline) do
    parent = self()

    channels =
      if record["Tty"],
        do: [{"0", :raw, record["AttachStdout"] or record["AttachStderr"]}],
        else: [{"1", 1, record["AttachStdout"]}, {"2", 2, record["AttachStderr"]}]

    readers =
      for {channel, stream, attached} <- channels do
        spawn_link(fn ->
          send(
            parent,
            {:channel, channel, read(pipe, backend, session, channel, stream, attached, deadline)}
          )
        end)
      end

    results = for _ <- readers, do: receive(do: ({:channel, _, result} -> result))

    code =
      case backend.session_exit(session, deadline) do
        {:ok, code} -> code
        _ -> @lost_exit
      end

    finish.(code)

    Pipe.finish(pipe, if(Enum.all?(results, &(&1 == :eof)), do: :eof, else: {:error, :exec}))
  end

  defp read(pipe, backend, session, channel, stream, attached, deadline) do
    timeout = min(@read_timeout, max(deadline - now(), 1))

    case backend.session_output(session, channel, timeout) do
      {:ok, ""} ->
        read(pipe, backend, session, channel, stream, attached, deadline)

      {:ok, bytes} ->
        if attached, do: Pipe.push(pipe, frame(stream, bytes))
        read(pipe, backend, session, channel, stream, attached, deadline)

      :timeout ->
        if now() < deadline,
          do: read(pipe, backend, session, channel, stream, attached, deadline),
          else: {:error, :deadline}

      :eof ->
        :eof

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "A Docker multiplexed-stream frame, or the bytes themselves for a TTY."
  def frame(:raw, bytes), do: bytes
  def frame(stream, bytes), do: [<<stream, 0, 0, 0, byte_size(bytes)::32>>, bytes]

  defp exec_body(record, console) do
    {environment, names, unset} = environment(record["Env"])

    {environment, names} =
      if record["Tty"] and not Map.has_key?(environment, "TERM"),
        do: {Map.put(environment, "TERM", "xterm"), names ++ ["TERM"]},
        else: {environment, names}

    environment =
      environment
      |> Map.put("OPSMARU_EXEC_ENV", Jason.encode!(names))
      |> Map.put("OPSMARU_EXEC_UNSET", Jason.encode!(unset))

    body = %{
      "command" => command(record),
      "environment" => environment,
      "interactive" => record["Tty"],
      "wait-for-websocket" => true,
      "record-output" => false,
      "user" => 0,
      "group" => 0
    }

    case {record["Tty"], console} do
      {true, [height, width]} -> Map.merge(body, %{"width" => width, "height" => height})
      _ -> body
    end
  end

  defp command(record) do
    user = if record["User"] in [nil, ""], do: [], else: ["--user", record["User"]]
    cwd = if record["WorkingDir"] in [nil, ""], do: [], else: ["--cwd", record["WorkingDir"]]
    [Shim.init_path(), "exec"] ++ user ++ cwd ++ ["--" | record["Cmd"]]
  end

  # Docker `Env`: `K=V` sets, a bare `K` removes. The last entry for a name wins.
  defp environment(entries) do
    Enum.reduce(entries, {%{}, [], []}, fn entry, {set, names, unset} ->
      case String.split(entry, "=", parts: 2) do
        [name, value] ->
          {Map.put(set, name, value), List.delete(names, name) ++ [name],
           List.delete(unset, name)}

        [name] ->
          {Map.delete(set, name), List.delete(names, name), List.delete(unset, name) ++ [name]}
      end
    end)
  end

  # -- Resize ------------------------------------------------------------------------

  @doc "Docker exec resize: the running exec's Incus control channel."
  def resize(exec_id, record, query) do
    with {:ok, height} <- dimension(query["h"], "h"),
         {:ok, width} <- dimension(query["w"], "w") do
      case :global.whereis_name(name(exec_id)) do
        pid when is_pid(pid) -> resized(Pipe.control(pid, {:resize, width, height}), exec_id)
        :undefined -> not_running(exec_id, record)
      end
    end
  end

  defp resized(:ok, _), do: {:ok, 200}
  defp resized({:error, :not_tty}, id), do: {:error, 409, "exec #{id} has no TTY to resize"}
  defp resized(_, id), do: {:error, 409, "exec #{id} is not running"}

  # dockerd answers a resize for an exec whose process has exited with
  # containerd's not-found error, so the CLI's late resize of a short TTY
  # exec gets the same answer from both engines.
  defp not_running(id, %{"Started" => true}),
    do: {:error, 404, "NotFound: process does not exist #{id}: not found"}

  defp not_running(id, _), do: {:error, 409, "exec #{id} has not started"}

  defp dimension(value, key) do
    case Integer.parse(value || "") do
      {size, ""} when size in 1..65_535 -> {:ok, size}
      _ -> {:error, 400, "invalid value for #{key}: #{value}"}
    end
  end

  # -- Shared ------------------------------------------------------------------------

  defp put_record(native, container, exec_id, record, deadline),
    do:
      Lifecycle.patch(
        native,
        container,
        %{Container.exec_key(exec_id) => Jason.encode!(record)},
        deadline
      )

  defp name(exec_id), do: {__MODULE__, exec_id}

  defp console_size([height, width])
       when is_integer(height) and height > 0 and is_integer(width) and width > 0,
       do: [height, width]

  defp console_size(_), do: nil

  defp string_list?(value), do: is_list(value) and Enum.all?(value, &is_binary/1)
  defp optional_string?(value), do: value == nil or is_binary(value)

  defp now, do: System.monotonic_time(:millisecond)
end
