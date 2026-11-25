defmodule Opsmaru.Containers.Docker.BindPolicy do
  @moduledoc false

  alias Jason.OrderedObject
  alias Opsmaru.Containers.Host

  @type rejection :: {:error, 400, String.t()}

  @spec apply(module(), map(), binary(), integer()) :: {:ok, binary()} | rejection()
  def apply(host, %{route: %{"path" => "/containers/create"}, context: context}, body, deadline) do
    mapper = fn source -> map_bind(host, context, source, deadline) end
    inspect_body(body, &container(&1, mapper))
  end

  def apply(_, %{route: %{"path" => "/volumes/create"}}, body, _) do
    inspect_body(body, fn object ->
      with :ok <- no_driver_options(field(object, "driveropts")), do: {:ok, object}
    end)
  end

  def apply(_, _, body, _), do: {:ok, body}

  defp inspect_body(body, transform) do
    with {:ok, decoded} <- Jason.decode(body, objects: :ordered_objects),
         {:ok, object} <- object(decoded),
         {:ok, result} <- transform.(object) do
      if result == object, do: {:ok, body}, else: {:ok, Jason.encode!(result)}
    else
      {:error, 400, _} = error -> error
      _ -> invalid()
    end
  end

  defp container(object, mapper) do
    update(object, "hostconfig", &host_config(&1, mapper))
  end

  defp host_config(value, mapper) do
    handle_bind = &bind(&1, mapper)
    handle_mount = &mount(&1, mapper)

    with {:ok, config} <- optional_object(value),
         {:ok, config} <- update(config, "binds", &list(&1, handle_bind)) do
      update(config, "mounts", &list(&1, handle_mount))
    end
  end

  defp bind(bind, mapper) when is_binary(bind) do
    case :binary.split(bind, ":") do
      ["/" <> _ = source, destination] ->
        with {:ok, mapped} <- mapper.(source), do: {:ok, mapped <> ":" <> destination}

      [_] ->
        {:ok, bind}

      [_name, _destination] ->
        {:ok, bind}
    end
  end

  defp bind(_, _), do: invalid()

  defp mount(value, mapper) do
    with {:ok, mount} <- object(value) do
      case field(mount, "type") do
        "bind" -> replace_source(mount, mapper)
        "volume" -> check_volume(mount)
        _ -> {:ok, mount}
      end
    end
  end

  defp replace_source(mount, mapper) do
    case field(mount, "source") do
      "/" <> _ -> update(mount, "source", mapper)
      _ -> invalid()
    end
  end

  defp check_volume(mount) do
    with {:ok, options} <- optional_object(field(mount, "volumeoptions")),
         {:ok, driver} <- optional_object(field(options, "driverconfig")),
         :ok <- no_driver_options(field(driver, "options")) do
      {:ok, mount}
    end
  end

  defp no_driver_options(options) when options in [nil, %OrderedObject{values: []}], do: :ok
  defp no_driver_options(_), do: {:error, 400, "Custom volume driver options are unsupported"}

  defp map_bind(host, context, source, deadline) do
    case Host.decide(host, :map_bind_source, [context, source], deadline) do
      {:ok, {:ok, "/" <> _ = mapped}} ->
        if Regex.match?(~r/[[:cntrl:]:]/, mapped), do: denied(source), else: {:ok, mapped}

      _ ->
        denied(source)
    end
  end

  defp denied(source) do
    {:error, 400, "Host denied bind mount source #{inspect(source, printable_limit: 256)}"}
  end

  defp list(nil, _), do: {:ok, nil}

  defp list(items, transform) when is_list(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, accumulator} ->
      case transform.(item) do
        {:ok, result} -> {:cont, {:ok, [result | accumulator]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp list(_, _), do: invalid()

  defp optional_object(nil), do: {:ok, nil}
  defp optional_object(value), do: object(value)

  defp object(%OrderedObject{values: values} = object) do
    keys = Enum.map(values, &elem(&1, 0))

    if Enum.all?(keys, &Regex.match?(~r/\A[\x20-\x7E]*\z/, &1)) and
         length(keys) == keys |> Enum.map(&String.downcase/1) |> Enum.uniq() |> length() do
      {:ok, object}
    else
      invalid()
    end
  end

  defp object(_), do: invalid()

  defp field(nil, _), do: nil

  defp field(%OrderedObject{values: values}, name) do
    Enum.find_value(values, fn {key, value} -> if String.downcase(key) == name, do: {value} end)
    |> case do
      {value} -> value
      nil -> nil
    end
  end

  defp update(nil, _, _), do: {:ok, nil}

  defp update(%OrderedObject{values: values} = object, name, transform) do
    case Enum.split_while(values, fn {key, _} -> String.downcase(key) != name end) do
      {before, [{key, value} | after_field]} ->
        with {:ok, rewritten} <- transform.(value),
             do: {:ok, %{object | values: before ++ [{key, rewritten} | after_field]}}

      {_, []} ->
        {:ok, object}
    end
  end

  defp invalid, do: {:error, 400, "Invalid Docker JSON request"}
end
