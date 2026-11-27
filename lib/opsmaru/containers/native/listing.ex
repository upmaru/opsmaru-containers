defmodule Opsmaru.Containers.Native.Listing do
  @moduledoc false
  # `GET /containers/json` and `POST /containers/prune` across both engines.
  #
  # The nested engine answers first, so it validates the query exactly as
  # dockerd does and its own errors reach the client unchanged. Native
  # entries are then built from instance keys and run records, filtered the
  # same way, and merged. Filters native cannot apply are refused while the
  # native project has containers, so a listing is never silently partial.

  alias Opsmaru.Containers.Docker.EngineRequest
  alias Opsmaru.Containers.Native.{Lifecycle, RunRecord}

  @list_filters ~w(id name label status ancestor exited)
  @prune_filters ~w(until label label!)
  @record_concurrency 8

  @doc "The query of a listing: `all`, `limit`, `size` and `filters`."
  def list_query(raw_query) do
    query = URI.decode_query(raw_query)

    with {:ok, filters} <- filters(query["filters"]),
         :ok <- supported(filters, @list_filters, "listing") do
      {:ok,
       %{
         all: truthy?(query["all"]),
         limit: limit(query["limit"]),
         filters: filters
       }}
    end
  end

  @doc "The filters of a prune."
  def prune_query(raw_query) do
    with {:ok, filters} <- filters(URI.decode_query(raw_query)["filters"]),
         :ok <- supported(filters, @prune_filters, "prune"),
         do: {:ok, filters}
  end

  @doc """
  Native entries for a listing, as Docker's `ContainerSummary`. Reads each
  candidate's run record and resolves `ancestor` values in the nested engine.
  """
  def entries(context, containers, query, api_version, deadline) do
    native = context.target.native
    candidates = Enum.filter(containers, &key_match?(&1, query.filters))

    with {:ok, ancestors} <- ancestors(context, query.filters, api_version, deadline),
         {:ok, states} <- states(native, candidates, deadline) do
      now = DateTime.utc_now()

      entries =
        for {container, record} <- states,
            state = state(container, record, now),
            listed?(state, query),
            exited_match?(state, query.filters),
            status_match?(state, query.filters),
            ancestor_match?(container, ancestors),
            do: summary(container, state)

      {:ok, entries}
    end
  end

  @doc "Merges both engines' entries newest first and applies the limit once."
  def merge(nested, native, %{limit: limit}) do
    merged = Enum.sort_by(nested ++ native, &(&1["Created"] || 0), :desc)
    if limit > 0, do: Enum.take(merged, limit), else: merged
  end

  @doc """
  Deletes the stopped native containers that match the prune filters, and
  returns their IDs. A container that cannot be deleted is skipped, as
  dockerd skips it.
  """
  def prune(context, containers, filters, deadline) do
    native = context.target.native
    now = DateTime.utc_now()

    with {:ok, until} <- until(filters["until"], now),
         {:ok, states} <-
           states(native, Enum.filter(containers, &labels_match?(&1, filters)), deadline) do
      deleted =
        for {container, record} <- states,
            state(container, record, now).state in ["created", "exited"],
            until == nil or DateTime.compare(container.created, until) == :lt,
            native.backend.delete_instance(native.client, container.instance, deadline) == :ok,
            do: container.id

      {:ok, deleted}
    end
  end

  @doc """
  A native container's Docker state: `state`, `status` (as `docker ps`
  shows it), `exit_code`, `started_at` and `finished_at`.
  """
  def state(container, record, now) do
    case {container.status, record} do
      {"Frozen", record} ->
        running(record, container, now, " (Paused)", "paused")

      {status, record} when status in ["Running", "Starting", "Stopping"] ->
        running(record, container, now, "", "running")

      {_, :missing} ->
        %{state: "created", status: "Created", exit_code: 0, started_at: nil, finished_at: nil}

      # The list keeps serving other containers; inspect names the fault.
      {_, :malformed} ->
        %{state: "dead", status: "Dead", exit_code: 0, started_at: nil, finished_at: nil}

      {_, %RunRecord{} = record} ->
        # A forced stop leaves no exit code: Docker's convention is 137.
        code = record.exit_code || 137
        finished = record.finished_at || record.started_at

        %{
          state: "exited",
          status:
            "Exited (#{code}) #{human_duration(DateTime.diff(now, finished, :millisecond))} ago",
          exit_code: code,
          started_at: record.started_at,
          finished_at: finished
        }
    end
  end

  defp running(record, container, now, suffix, state) do
    started = if match?(%RunRecord{}, record), do: record.started_at, else: container.created

    %{
      state: state,
      status: "Up #{human_duration(DateTime.diff(now, started, :millisecond))}#{suffix}",
      exit_code: 0,
      started_at: started,
      finished_at: nil
    }
  end

  @doc "go-units `HumanDuration`, which `docker ps` uses."
  def human_duration(milliseconds) do
    seconds = div(max(milliseconds, 0), 1000)

    cond do
      seconds < 1 -> "Less than a second"
      seconds == 1 -> "1 second"
      seconds < 60 -> "#{seconds} seconds"
      div(seconds, 60) == 1 -> "About a minute"
      seconds < 3600 -> "#{div(seconds, 60)} minutes"
      true -> human_hours(round(milliseconds / 3_600_000), seconds)
    end
  end

  defp human_hours(1, _), do: "About an hour"
  defp human_hours(hours, _) when hours < 48, do: "#{hours} hours"
  defp human_hours(hours, _) when hours < 24 * 7 * 2, do: "#{div(hours, 24)} days"
  defp human_hours(hours, _) when hours < 24 * 30 * 2, do: "#{div(hours, 24 * 7)} weeks"
  defp human_hours(hours, _) when hours < 24 * 365 * 2, do: "#{div(hours, 24 * 30)} months"
  defp human_hours(_, seconds), do: "#{div(div(seconds, 3600), 24 * 365)} years"

  defp summary(container, state) do
    config = container.config

    %{
      "Id" => container.id,
      "Names" => ["/" <> container.name],
      "Image" => container.image_ref,
      "ImageID" => container.image_id,
      "Command" => command(config["Path"], config["Args"]),
      "Created" => DateTime.to_unix(container.created),
      "Ports" => [],
      "Labels" => container.labels,
      "State" => state.state,
      "Status" => state.status,
      "HostConfig" => %{
        "NetworkMode" => get_in(config, ["HostConfig", "NetworkMode"]) || "bridge"
      },
      "NetworkSettings" => %{"Networks" => %{}},
      "Mounts" => if(is_list(config["Mounts"]), do: config["Mounts"], else: [])
    }
  end

  defp command(path, [_ | _] = args) when is_binary(path), do: Enum.join([path | args], " ")
  defp command(path, _) when is_binary(path), do: path
  defp command(_, _), do: ""

  defp states(native, containers, deadline) do
    containers
    |> Task.async_stream(&{&1, Lifecycle.record(native, &1, deadline)},
      max_concurrency: @record_concurrency,
      timeout: max(deadline - System.monotonic_time(:millisecond), 1),
      on_timeout: :kill_task
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {container, {:ok, record}}}, {:ok, acc} -> {:cont, {:ok, [{container, record} | acc]}}
      _, _ -> {:halt, {:error, 503, "native engine: Incus is not available"}}
    end)
    |> case do
      {:ok, states} -> {:ok, Enum.reverse(states)}
      error -> error
    end
  end

  # Docker shows stopped containers with `all`, a limit or a status filter.
  defp listed?(%{state: state}, query),
    do:
      state in ["running", "paused"] or query.all or query.limit > 0 or
        Map.has_key?(query.filters, "status")

  defp key_match?(container, filters) do
    regex_match?(filters["id"], [container.id]) and
      regex_match?(filters["name"], ["/" <> container.name]) and labels_match?(container, filters)
  end

  # Docker's `Args.Match`: any value, as a regular expression, matches.
  defp regex_match?(nil, _), do: true

  defp regex_match?(values, sources) do
    Enum.any?(values, fn value ->
      case Regex.compile(value) do
        {:ok, regex} -> Enum.any?(sources, &Regex.match?(regex, &1))
        _ -> false
      end
    end)
  end

  # Docker's `MatchKVList` for `label`, and its negation for `label!`.
  defp labels_match?(container, filters) do
    Enum.all?(filters["label"] || [], &label?(container.labels, &1)) and
      not Enum.any?(filters["label!"] || [], &label?(container.labels, &1))
  end

  defp label?(labels, filter) do
    case String.split(filter, "=", parts: 2) do
      [key] -> Map.has_key?(labels, key)
      [key, value] -> Map.get(labels, key) == value
    end
  end

  defp status_match?(state, filters),
    do: filters["status"] == nil or state.state in filters["status"]

  defp exited_match?(_, filters) when not is_map_key(filters, "exited"), do: true

  defp exited_match?(%{state: "exited", exit_code: code}, %{"exited" => values}),
    do: Integer.to_string(code) in values

  defp exited_match?(_, _), do: false

  defp ancestor_match?(_, nil), do: true
  defp ancestor_match?(container, ids), do: container.image_id in ids

  # dockerd resolves each `ancestor` value to an image and ignores values
  # that name no image. Descendant images are not matched natively.
  defp ancestors(context, %{"ancestor" => values}, api_version, deadline) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, ids} ->
      target = "/v#{api_version}/images/#{URI.encode(value, &URI.char_unreserved?/1)}/json"

      case EngineRequest.json(context, "GET", target, nil, deadline) do
        {:ok, 200, %{"Id" => id}} -> {:cont, {:ok, [id | ids]}}
        {:ok, 404, _} -> {:cont, {:ok, ids}}
        _ -> {:halt, {:error, 503, "Docker engine is not ready"}}
      end
    end)
  end

  defp ancestors(_, _, _, _), do: {:ok, nil}

  defp filters(nil), do: {:ok, %{}}
  defp filters(""), do: {:ok, %{}}

  defp filters(raw) do
    with {:ok, decoded} when is_map(decoded) <- Jason.decode(raw),
         {:ok, filters} <- normalise(decoded) do
      {:ok, filters}
    else
      _ -> {:error, 400, "invalid filter"}
    end
  end

  # Docker takes `{"key": ["value"]}` and the older `{"key": {"value": true}}`.
  defp normalise(decoded) do
    Enum.reduce_while(decoded, {:ok, %{}}, fn
      {key, values}, {:ok, acc} when is_list(values) ->
        if Enum.all?(values, &is_binary/1),
          do: {:cont, {:ok, Map.put(acc, key, values)}},
          else: {:halt, :error}

      {key, values}, {:ok, acc} when is_map(values) ->
        {:cont, {:ok, Map.put(acc, key, for({value, true} <- values, do: value))}}

      _, _ ->
        {:halt, :error}
    end)
  end

  defp supported(filters, allowed, operation) do
    case Map.keys(filters) -- allowed do
      [] ->
        :ok

      [key | _] ->
        {:error, 400,
         "native engine: the #{key} filter is not supported for a #{operation} while native containers exist"}
    end
  end

  # strconv.ParseBool, which dockerd uses for `all`.
  defp truthy?(value), do: value in ~w(1 t T true TRUE True)

  defp limit(value) do
    case Integer.parse(value || "") do
      {limit, ""} -> limit
      _ -> -1
    end
  end

  @doc false
  # dockerd's `until`: an RFC 3339 time, Unix seconds, or a Go duration
  # before now. The last value wins, as in dockerd.
  def until(nil, _), do: {:ok, nil}
  def until([], _), do: {:ok, nil}
  def until(values, now) when is_list(values), do: until(List.last(values), now)

  def until(value, now) when is_binary(value) do
    cond do
      time = time(value) ->
        {:ok, time}

      Regex.match?(~r/\A\d+(\.\d+)?\z/, value) ->
        {seconds, _} = Float.parse(value)
        {:ok, DateTime.from_unix!(round(seconds * 1_000_000), :microsecond)}

      duration = duration(value) ->
        {:ok, DateTime.add(now, -duration, :microsecond)}

      true ->
        {:error, 400, "invalid filter 'until=#{value}'"}
    end
  end

  defp time(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _} -> time
      _ -> nil
    end
  end

  @units %{
    "ns" => 0.001,
    "us" => 1,
    "µs" => 1,
    "ms" => 1_000,
    "s" => 1_000_000,
    "m" => 60_000_000,
    "h" => 3_600_000_000
  }

  defp duration(value) do
    parts = Regex.scan(~r/(\d+(?:\.\d+)?)(ns|us|µs|ms|s|m|h)/u, value)

    if parts != [] and Enum.map_join(parts, &hd/1) == value do
      parts
      |> Enum.map(fn [_, number, unit] ->
        {number, _} = Float.parse(number)
        number * @units[unit]
      end)
      |> Enum.sum()
      |> round()
    end
  end
end
