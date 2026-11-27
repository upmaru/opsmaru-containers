defmodule Opsmaru.Containers.Native.RunRecord do
  @moduledoc false
  # The shim's `/.opsmaru/state/run.json`. It is written inside the container,
  # so its root user can change it: it is read as bounded, untrusted input,
  # and a record that does not parse is treated as missing.

  @path "/.opsmaru/state/run.json"
  @limit 65_536

  defstruct [
    :run,
    :pid,
    :started_at,
    :finished_at,
    :exit_code,
    :signal,
    :error,
    oom_killed: false
  ]

  @type t :: %__MODULE__{}

  def path, do: @path
  def limit, do: @limit

  @doc "Reads a container's run record: `{:ok, record}`, `:missing` or an error."
  def read(native, container, deadline) do
    case native.backend.read_file(native.client, container.instance, @path, @limit, deadline) do
      {:ok, data} -> {:ok, parse(data)}
      {:error, :not_found} -> {:ok, :missing}
      {:error, _} = error -> error
    end
  end

  @doc "Parses a record, or returns `:missing` for one that is not valid."
  def parse(data) when is_binary(data) do
    with {:ok, %{"version" => 1, "run" => run} = record} <- Jason.decode(data),
         true <- is_integer(run) and run in 1..4_294_967_295,
         {:ok, started_at} <- time(record["started_at"]),
         {:ok, finished_at} <- optional_time(record["finished_at"]),
         true <- optional?(record["pid"], &(is_integer(&1) and &1 > 0)),
         true <- optional?(record["exit_code"], &(is_integer(&1) and &1 in 0..255)),
         true <- optional?(record["signal"], &(is_binary(&1) and byte_size(&1) <= 16)),
         true <- optional?(record["error"], &(is_binary(&1) and byte_size(&1) <= 4_096)),
         true <- is_boolean(Map.get(record, "oom_killed", false)) do
      %__MODULE__{
        run: run,
        pid: record["pid"],
        started_at: started_at,
        finished_at: finished_at,
        exit_code: record["exit_code"],
        signal: record["signal"],
        error: record["error"],
        oom_killed: Map.get(record, "oom_killed", false)
      }
    else
      _ -> :missing
    end
  end

  defp time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _} -> {:ok, time}
      _ -> :error
    end
  end

  defp time(_), do: :error

  defp optional_time(nil), do: {:ok, nil}
  defp optional_time(value), do: time(value)

  defp optional?(nil, _), do: true
  defp optional?(value, valid?), do: valid?.(value)
end
