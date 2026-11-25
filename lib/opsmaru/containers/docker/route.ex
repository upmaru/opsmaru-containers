defmodule Opsmaru.Containers.Docker.Route do
  @moduledoc false

  @route_path Path.expand("../../../../priv/docker/routes.json", __DIR__)
  @external_resource @route_path

  @routes @route_path
          |> File.read!()
          |> Jason.decode!()
          |> Enum.group_by(& &1["method"], fn route ->
            pattern =
              ~r/(\{[^}]+\})/
              |> Regex.split(route["path"], include_captures: true)
              |> Enum.map_join(fn
                "{anyroute:.*}" ->
                  ".*"

                "{" <> name ->
                  cond do
                    String.ends_with?(name, ":.*}") -> ".*"
                    String.ends_with?(name, ":.+}") -> ".+"
                    true -> "[^/]+"
                  end

                text ->
                  Regex.escape(text)
              end)

            {Regex.compile!("\\A" <> pattern <> "\\z"), route}
          end)

  def match(method, path) do
    @routes
    |> Map.get(method, [])
    |> Enum.find_value(fn {pattern, route} -> Regex.match?(pattern, path) && route end)
  end
end
