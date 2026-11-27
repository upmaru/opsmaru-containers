defmodule Opsmaru.Containers.Native.Logs do
  @moduledoc false
  # Docker logs and output-only attach for native containers (design
  # decisions 8 and 14), read from the shim's log records through SFTP.
  #
  # A reader's position is `{file_number, offset}`, so rotation never
  # invalidates it: a position older than the oldest kept file continues
  # from the oldest. SFTP sessions follow the spike's rules: a session ends
  # when its instance stops, and the library never keeps one open on a
  # stopped instance, because that holds up the instance's next start.

  alias Opsmaru.Containers.Native.{Exec, Lifecycle, LogRecord, Pipe, RunRecord}

  @dir "/.opsmaru/logs"
  @chunk 262_144
  @follow_poll 250
  @attach_poll 100
  @reopen 200
  @log_file ~r/\A(\d{10})\.log\z/
  @running ["Running", "Starting", "Stopping", "Frozen"]
  @false_values ["", "0", "no", "false", "none"]

  # -- Options -------------------------------------------------------------------

  @doc "Parses Docker logs query options for a container, with dockerd's refusals."
  def options(container, query) do
    with {:ok, since} <- timestamp(query["since"], "since"),
         {:ok, until} <- timestamp(query["until"], "until"),
         options = %{
           stdout: truthy?(query["stdout"]),
           stderr: truthy?(query["stderr"]),
           timestamps: truthy?(query["timestamps"]),
           follow: truthy?(query["follow"]),
           since: since,
           until: until,
           tail: tail(query["tail"])
         },
         :ok <- streams(options),
         :ok <- details(query["details"]),
         :ok <- readable(container) do
      {:ok, options}
    end
  end

  defp streams(%{stdout: false, stderr: false}),
    do: {:error, 400, "Bad parameters: you must choose at least one stream"}

  defp streams(_), do: :ok

  defp details(value) do
    if truthy?(value),
      do: {:error, 400, "native engine cannot honour: details"},
      else: :ok
  end

  defp readable(container) do
    if get_in(container.config, ["HostConfig", "LogConfig", "Type"]) == "none",
      do: {:error, 501, "configured logging driver does not support reading"},
      else: :ok
  end

  # Docker's `timetypes.ParseTimestamps`: `seconds[.fraction]`, 0 for none.
  defp timestamp(value, _) when value in [nil, ""], do: {:ok, nil}

  defp timestamp(value, key) do
    {seconds, fraction} =
      case String.split(value, ".", parts: 2) do
        [seconds, fraction] -> {seconds, fraction}
        [seconds] -> {seconds, "0"}
      end

    with {seconds, ""} <- Integer.parse(seconds),
         true <- fraction =~ ~r/\A\d{1,9}\z/ do
      nanos = String.to_integer(String.pad_trailing(fraction, 9, "0"))

      case seconds * 1_000_000_000 + nanos do
        0 -> {:ok, nil}
        time -> {:ok, time}
      end
    else
      _ -> {:error, 400, "invalid value for #{key}: #{value}"}
    end
  end

  # Docker reads any tail it cannot parse, and a negative one, as all.
  defp tail(value) do
    case Integer.parse(value || "") do
      {count, ""} when count >= 0 -> count
      _ -> :all
    end
  end

  defp truthy?(value), do: is_binary(value) and String.downcase(value) not in @false_values

  # -- Logs ------------------------------------------------------------------------

  @doc """
  Streams a container's logs. `emit` receives `:begin` once before any data,
  `{:data, iodata}` for each record and `:poll` while following, and
  answers `:ok` or `:halt` once the client is gone. An error before `:begin`
  is returned for the caller to answer.
  """
  def stream(native, container, options, emit, deadline) do
    with {:ok, state} <- Lifecycle.instance_state(native, container, deadline),
         follow? = options.follow and state["status"] in @running,
         {:ok, options} <- followed_run(native, container, options, follow?, deadline),
         {:ok, session} <- open(native, container, deadline) do
      try do
        with {:ok, position} <- initial(native, container, session, options, emit),
             :ok <- emit.(:begin) do
          if follow?,
            do: follow(native, container, session, position, options, emit, deadline),
            else: :ok
        end
      after
        close(native, session)
      end
    end
    |> case do
      :halt -> :ok
      other -> other
    end
  end

  # A follow ends with the run in progress, or the next one when the shim
  # has not recorded it yet.
  defp followed_run(_, _, options, false, _), do: {:ok, options}

  defp followed_run(native, container, options, true, deadline) do
    with {:ok, record} <- Lifecycle.record(native, container, deadline) do
      {:ok, Map.put(options, :run, current_run(record))}
    end
  end

  defp current_run(%RunRecord{run: run, finished_at: nil, error: nil}), do: run
  defp current_run(%RunRecord{run: run}), do: run + 1
  defp current_run(_), do: 1

  # An SFTP session open on an instance holds up Incus's stop of it (and its
  # start) until the session ends. Followers therefore read the run record
  # over their own session on every poll, and close the session as soon as
  # the run they follow has finished, before Incus stops the instance.
  defp finished?(native, session, run) do
    case native.backend.sftp_read(session, RunRecord.path(), 0, RunRecord.limit()) do
      {:ok, data} ->
        case RunRecord.parse(data) do
          %RunRecord{run: recorded} when recorded > run -> true
          %RunRecord{run: ^run, finished_at: nil, error: nil} -> false
          %RunRecord{run: ^run} -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  # Waits, holding no session, until the instance has stopped.
  defp until_stopped(native, container, emit, deadline) do
    case Lifecycle.instance_state(native, container, deadline) do
      {:ok, %{"status" => status}} when status in @running ->
        with :ok <- wait(@attach_poll, emit, deadline),
             do: until_stopped(native, container, emit, deadline)

      _ ->
        :ok
    end
  end

  # The records already written, through `tail` when it is set.
  defp initial(native, container, session, %{tail: :all} = options, emit) do
    case read(native, session, {0, 0}, :ok, &emit_record(&1, &2, options, emit)) do
      {:ok, _, position} -> {:ok, position}
      {:halt, _} -> :halt
      error -> failed(error, container)
    end
  end

  defp initial(native, container, session, %{tail: count} = options, emit) do
    keep = fn record, {queue, size} ->
      queue = :queue.in(record, queue)

      if size + 1 > count,
        do: {:cont, {drop(queue, count), min(size + 1, count)}},
        else: {:cont, {queue, size + 1}}
    end

    case read(native, session, {0, 0}, {:queue.new(), 0}, keep) do
      {:ok, {queue, _}, position} ->
        case fold(:queue.to_list(queue), :ok, &emit_record(&1, &2, options, emit)) do
          {:cont, :ok} -> {:ok, position}
          {:halt, _} -> :halt
        end

      error ->
        failed(error, container)
    end
  end

  defp drop(_queue, 0), do: :queue.new()

  defp drop(queue, count) do
    if :queue.len(queue) > count, do: drop(:queue.drop(queue), count), else: queue
  end

  defp follow(native, container, session, position, options, emit, deadline) do
    with :ok <- wait(@follow_poll, emit, deadline),
         :ok <- past_until(options) do
      native
      |> read(session, position, :ok, &emit_record(&1, &2, options, emit))
      |> followed(native, container, session, position, options, emit, deadline)
    end
  end

  defp followed({:ok, _, position}, native, container, session, _, options, emit, deadline) do
    if finished?(native, session, options.run) do
      close(native, session)

      with :ok <- until_stopped(native, container, emit, deadline),
           do: final(native, container, nil, position, options, emit, deadline)
    else
      case Lifecycle.instance_state(native, container, deadline) do
        {:ok, %{"status" => status}} when status in @running ->
          follow(native, container, session, position, options, emit, deadline)

        _ ->
          final(native, container, session, position, options, emit, deadline)
      end
    end
  end

  defp followed({:halt, _}, _, _, _, _, _, _, _), do: :halt
  defp followed({:error, :malformed}, _, _, _, _, _, _, _), do: :ok

  # The session ends when the instance stops under it.
  defp followed({:error, _}, native, container, session, position, options, emit, deadline),
    do: final(native, container, session, position, options, emit, deadline)

  # After the stop, a new session reads to the end once more, so output
  # written just before the exit is delivered.
  defp final(native, container, session, position, options, emit, deadline) do
    close(native, session)

    case reopen(native, container, deadline) do
      {:ok, session} ->
        try do
          read(native, session, position, :ok, &emit_record(&1, &2, options, emit))
          :ok
        after
          close(native, session)
        end

      _ ->
        :ok
    end
  end

  defp past_until(%{until: nil}), do: :ok

  defp past_until(%{until: until}),
    do: if(System.os_time(:nanosecond) > until, do: :halt, else: :ok)

  defp wait(interval, emit, deadline) do
    cond do
      now() + interval >= deadline ->
        :halt

      emit.(:poll) == :halt ->
        :halt

      true ->
        Process.sleep(interval)
        :ok
    end
  end

  defp emit_record(record, acc, options, emit) do
    if selected?(record, options) and in_window?(record, options) do
      case emit.({:data, format(record, options)}) do
        :ok -> {:cont, acc}
        :halt -> {:halt, acc}
      end
    else
      {:cont, acc}
    end
  end

  defp selected?(%LogRecord{stream: :stdout}, options), do: options.stdout
  defp selected?(%LogRecord{stream: :stderr}, options), do: options.stderr

  defp in_window?(record, options) do
    (options.since == nil or record.time >= options.since) and
      (options.until == nil or record.time <= options.until)
  end

  @doc "A record as a Docker multiplexed frame, with its timestamp when asked."
  def format(record, options) do
    data =
      if options[:timestamps], do: [timestamp(record.time), " ", record.data], else: record.data

    Exec.frame(if(record.stream == :stdout, do: 1, else: 2), IO.iodata_to_binary(data))
  end

  @doc "RFC 3339 with nine fractional digits, as Docker's `RFC3339NanoFixed`."
  def timestamp(time) do
    seconds = Integer.floor_div(time, 1_000_000_000)
    nanos = Integer.mod(time, 1_000_000_000)
    base = seconds |> DateTime.from_unix!() |> Calendar.strftime("%Y-%m-%dT%H:%M:%S")
    base <> "." <> String.pad_leading(Integer.to_string(nanos), 9, "0") <> "Z"
  end

  defp failed({:error, :malformed}, container),
    do: {:error, 500, "native engine: the logs of container #{container.id} are malformed"}

  defp failed(_, _), do: {:error, 503, "native engine: Incus is not available"}

  # -- Attach ----------------------------------------------------------------------

  @doc """
  Output-only attach (design decision 14), served from the log records of
  the next run, or of the current one when the container runs. Returns the
  pipe the raw adapter relays. The end of the logs is noted now and the
  session closed, so a start that follows is never held up.
  """
  def attach(native, container, query, deadline) do
    with :ok <- attachable(query),
         {:ok, state} <- Lifecycle.instance_state(native, container, deadline),
         {:ok, record} <- Lifecycle.record(native, container, deadline),
         {:ok, position} <- end_position(native, container, deadline) do
      running? = state["status"] in @running
      run = if is_struct(record, RunRecord), do: record.run, else: 0

      follower = %{
        native: native,
        container: container,
        options: %{stdout: truthy?(query["stdout"]), stderr: truthy?(query["stderr"])},
        target: if(running?, do: max(run, 1), else: run + 1),
        deadline: deadline
      }

      Pipe.open(
        %{
          start: fn pipe ->
            {:ok, spawn_link(fn -> attached(pipe, follower, position, nil) end)}
          end
        },
        deadline
      )
    end
  end

  defp attachable(query) do
    cond do
      truthy?(query["stdin"]) ->
        {:error, 501, "native engine cannot honour: stdin attach"}

      truthy?(query["logs"]) ->
        {:error, 501, "native engine cannot honour: attach logs"}

      not truthy?(query["stream"]) ->
        {:error, 501, "native engine cannot honour: attach without stream"}

      true ->
        :ok
    end
  end

  defp end_position(native, container, deadline) do
    with {:ok, session} <- open(native, container, deadline) do
      try do
        case files(native, session) do
          {:ok, []} ->
            {:ok, {0, 0}}

          {:ok, files} ->
            {last, _} = List.last(files)

            case read(native, session, {last, 0}, :ok, fn _, acc -> {:cont, acc} end) do
              {:ok, _, position} -> {:ok, position}
              error -> failed(error, container)
            end

          error ->
            failed(error, container)
        end
      after
        close(native, session)
      end
    end
  end

  # Follows while the instance runs; holds no session while it is stopped.
  defp attached(pipe, follower, position, session) do
    %{native: native, container: container, deadline: deadline} = follower

    if now() >= deadline do
      close(native, session)
      Pipe.finish(pipe, {:error, :deadline})
    else
      native.backend.instance_state(native.client, container.instance, deadline)
      |> attach_step(pipe, follower, position, session)
    end
  end

  # Once the awaited run has finished, the session is closed and the attach
  # waits, holding none, for Incus to stop the instance.
  defp attach_step({:ok, %{"status" => status}}, pipe, %{exited: true} = follower, position, _)
       when status in @running do
    Process.sleep(@attach_poll)
    attached(pipe, follower, position, nil)
  end

  defp attach_step({:ok, %{"status" => status}}, pipe, follower, position, session)
       when status in @running do
    {position, session} = attach_read(pipe, follower, position, session)

    if session != nil and finished?(follower.native, session, follower.target) do
      close(follower.native, session)
      Process.sleep(@attach_poll)
      attached(pipe, Map.put(follower, :exited, true), position, nil)
    else
      Process.sleep(@attach_poll)
      attached(pipe, follower, position, session)
    end
  end

  defp attach_step({:ok, _}, pipe, follower, position, session) do
    close(follower.native, session)
    stopped(pipe, follower, position)
  end

  defp attach_step({:error, :not_found}, pipe, follower, _, session) do
    close(follower.native, session)
    Pipe.finish(pipe, :eof)
  end

  defp attach_step({:error, _}, pipe, follower, position, session) do
    Process.sleep(@attach_poll)
    attached(pipe, follower, position, session)
  end

  defp attach_read(pipe, follower, position, nil) do
    case open(follower.native, follower.container, follower.deadline) do
      {:ok, session} -> attach_read(pipe, follower, position, session)
      _ -> {position, nil}
    end
  end

  defp attach_read(pipe, follower, position, session) do
    case read(follower.native, session, position, :ok, &push(pipe, follower, &1, &2)) do
      {:ok, _, position} ->
        {position, session}

      _ ->
        close(follower.native, session)
        {position, nil}
    end
  end

  # Once the awaited run has a record and the instance is stopped, a new
  # session reads to the end, and the attach ends.
  defp stopped(pipe, follower, position) do
    %{native: native, container: container, deadline: deadline} = follower

    # The stop seen before this record could be the start's stale one (see
    # `Native.Wait`), so the state is read again after the record.
    with {:ok, %RunRecord{run: run}} when run >= follower.target <-
           Lifecycle.record(native, container, deadline),
         {:ok, %{"status" => status}} when status not in @running <-
           Lifecycle.instance_state(native, container, deadline) do
      case reopen(native, container, deadline) do
        {:ok, session} ->
          read(native, session, position, :ok, &push(pipe, follower, &1, &2))
          close(native, session)

        _ ->
          :ok
      end

      Pipe.finish(pipe, :eof)
    else
      _ ->
        Process.sleep(@attach_poll)
        attached(pipe, follower, position, nil)
    end
  end

  defp push(pipe, follower, record, acc) do
    if record.run >= follower.target and selected?(record, follower.options),
      do: Pipe.push(pipe, format(record, %{})),
      else: :ok

    {:cont, acc}
  end

  # -- Reading -----------------------------------------------------------------------

  @doc false
  # Reads every complete record from `position` to the end of the newest
  # file, folding `fun` (`{:cont, acc}` or `{:halt, acc}`) over them.
  # Returns `{:ok, acc, position}`, `{:halt, acc}` or an error.
  def read(native, session, {number, offset}, acc, fun) do
    with {:ok, files} <- files(native, session) do
      start = Enum.find(files, fn {n, _} -> n >= number end)

      files
      |> Enum.filter(fn {n, _} -> start != nil and n >= elem(start, 0) end)
      |> Enum.reduce_while({:ok, acc, {number, offset}}, fn {n, _}, {:ok, acc, _} ->
        read_next(
          read_file(native, session, n, start_offset(n, number, offset), acc, fun),
          n,
          acc
        )
      end)
    end
  end

  defp start_offset(number, number, offset), do: offset
  defp start_offset(_, _, _), do: 0

  defp read_next({:ok, acc, end_offset}, n, _), do: {:cont, {:ok, acc, {n, end_offset}}}
  # Rotated away since the listing: continue with the next file.
  defp read_next({:error, :not_found}, n, acc), do: {:cont, {:ok, acc, {n + 1, 0}}}
  defp read_next(other, _, _), do: {:halt, other}

  defp files(native, session) do
    case native.backend.sftp_list(session, @dir) do
      {:ok, entries} ->
        {:ok,
         entries
         |> Enum.flat_map(&log_file/1)
         |> Enum.sort()}

      error ->
        error
    end
  end

  defp log_file(%{name: name, size: size}) do
    case Regex.run(@log_file, name) do
      [_, number] -> [{String.to_integer(number), size}]
      nil -> []
    end
  end

  defp read_file(native, session, number, offset, acc, fun) do
    path = Path.join(@dir, String.pad_leading(Integer.to_string(number), 10, "0") <> ".log")
    read_chunks(native, session, path, %{consumed: offset, read: offset, rest: ""}, acc, fun)
  end

  defp read_chunks(native, session, path, cursor, acc, fun) do
    case native.backend.sftp_read(session, path, cursor.read, @chunk) do
      {:ok, ""} ->
        {:ok, acc, cursor.consumed}

      {:ok, chunk} ->
        read = cursor.read + byte_size(chunk)

        with {:ok, records, rest} <- decode(cursor, chunk),
             {:cont, acc} <- fold(records, acc, fun) do
          cursor = %{consumed: read - byte_size(rest), read: read, rest: rest}
          more(byte_size(chunk) == @chunk, native, session, path, cursor, acc, fun)
        end

      {:error, _} = error ->
        error
    end
  end

  # A short read is the end of the file for now.
  defp more(true, native, session, path, cursor, acc, fun),
    do: read_chunks(native, session, path, cursor, acc, fun)

  defp more(false, _, _, _, cursor, acc, _), do: {:ok, acc, cursor.consumed}

  # From the start of a file, the bytes begin with the magic.
  defp decode(%{consumed: 0, rest: rest}, chunk), do: LogRecord.decode_file(rest <> chunk)
  defp decode(%{rest: rest}, chunk), do: LogRecord.decode(rest <> chunk)

  defp fold(records, acc, fun) do
    Enum.reduce_while(records, {:cont, acc}, fn record, {:cont, acc} ->
      case fun.(record, acc) do
        {:cont, acc} -> {:cont, {:cont, acc}}
        {:halt, acc} -> {:halt, {:halt, acc}}
      end
    end)
  end

  defp open(native, container, deadline) do
    case native.backend.sftp_open(native.client, container.instance, deadline) do
      {:ok, session} -> {:ok, session}
      {:error, _} -> {:error, 503, "native engine: Incus is not available"}
    end
  end

  # A stopping instance refuses a session for a short while.
  defp reopen(native, container, deadline) do
    case native.backend.sftp_open(native.client, container.instance, deadline) do
      {:ok, session} ->
        {:ok, session}

      {:error, _} = error ->
        if now() + @reopen < deadline do
          Process.sleep(@reopen)
          reopen(native, container, deadline)
        else
          error
        end
    end
  end

  defp close(_, nil), do: :ok
  defp close(native, session), do: native.backend.sftp_close(session)

  defp now, do: System.monotonic_time(:millisecond)
end
