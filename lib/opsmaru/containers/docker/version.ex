defmodule Opsmaru.Containers.Docker.Version do
  @moduledoc false

  @reference_path Path.expand("../../../../priv/docker/reference.json", __DIR__)
  @external_resource @reference_path
  %{"engine" => %{"min_api_version" => minimum, "max_api_version" => maximum}} =
    @reference_path |> File.read!() |> Jason.decode!()

  @minimum minimum
  @maximum maximum

  def reference_range, do: {@minimum, @maximum}

  def parse(value) when is_binary(value) and byte_size(value) <= 11 do
    with [major, minor] <- String.split(value, "."),
         {major_value, ""} <- Integer.parse(major),
         {minor_value, ""} <- Integer.parse(minor),
         true <-
           major_value >= 0 and minor_value >= 0 and
             to_string(major_value) == major and to_string(minor_value) == minor do
      {:ok, {major_value, minor_value}}
    else
      _ -> :error
    end
  end

  def parse(_), do: :error

  def effective(minimum, maximum) do
    with {:ok, engine_min} <- parse(minimum),
         {:ok, engine_max} <- parse(maximum),
         {:ok, reference_min} <- parse(@minimum),
         {:ok, reference_max} <- parse(@maximum),
         floor = max(engine_min, reference_min),
         ceiling = min(engine_max, reference_max),
         true <- floor <= ceiling do
      {:ok, {floor, ceiling}}
    else
      _ -> {:error, :incompatible_engine}
    end
  end

  def format({major, minor}), do: "#{major}.#{minor}"
end
