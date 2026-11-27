defmodule Opsmaru.Containers.Docker.Admission do
  @moduledoc """
  Shared backend-free route classification, host authorization and version
  selection for HTTP and raw listener adapters.
  """

  alias Opsmaru.Containers.{Context, Host}
  alias Opsmaru.Containers.Docker.{Route, Version}

  @type rejection :: {:error, pos_integer(), String.t()}

  @doc """
  Authorize an origin-form request using a host callback module. The request
  includes its method, original encoded path and raw query. The listener can
  include peer information for the host to authenticate.
  """
  @spec admit(module(), map(), integer()) :: {:ok, map()} | rejection()
  def admit(host, %{method: method, path: path, query: query} = request, deadline)
      when is_binary(method) and is_binary(path) and is_binary(query) do
    with :ok <- origin_form(path, query),
         {version, path} <- split_version(path),
         {:ok, decoded_path} <- decode_path(path),
         {:ok, route} <- lookup(method, decoded_path),
         classified = Map.merge(request, %{route: route, version: version}),
         {:ok, context} <- authorize(host, classified, deadline),
         :ok <- supported(route),
         {:ok, {minimum, maximum}} <- available(context),
         :ok <- check_version(version, minimum, maximum),
         :ok <- check_route_version(version || Version.format(maximum), route) do
      {:ok,
       %{
         route: route,
         context: context,
         minimum: Version.format(minimum),
         maximum: Version.format(maximum),
         decoded_path: decoded_path,
         path: upstream_path(request.path, path, version, maximum, context)
       }}
    end
  end

  def admit(_, _, _), do: {:error, 400, "invalid request target"}

  defp origin_form("/" <> _ = path, query) do
    if byte_size(path) + byte_size(query) <= 16_384 and
         not String.starts_with?(path, "//") and
         not Regex.match?(~r/[[:cntrl:] ?#]/, path) and
         not Regex.match?(~r/[[:cntrl:] #]/, query) do
      :ok
    else
      {:error, 400, "invalid request target"}
    end
  end

  defp origin_form(_, _), do: {:error, 400, "invalid request target"}

  defp decode_path(path) do
    decoded = URI.decode(path)

    if Regex.match?(~r/[[:cntrl:]]/, decoded),
      do: {:error, 400, "invalid request target"},
      else: {:ok, decoded}
  rescue
    ArgumentError -> {:error, 400, "invalid request target"}
  end

  defp split_version(path) do
    case Regex.run(~r/\A\/v(\d+\.\d+)(\/.*)\z/, path, capture: :all_but_first) do
      [version, rest] -> {version, rest}
      nil -> {nil, path}
    end
  end

  defp lookup(method, path) do
    case Route.match(method, path) do
      nil -> {:error, 404, "page not found"}
      route -> {:ok, route}
    end
  end

  defp authorize(host, request, deadline) do
    with {:ok, {:ok, %Context{} = context}} <- Host.decide(host, :context, [request], deadline),
         :ok <- Context.validate(context),
         {:ok, :allow} <- Host.decide(host, :authorize, [context, request], deadline) do
      {:ok, context}
    else
      _ -> {:error, 403, "request denied"}
    end
  end

  defp supported(%{"class" => "nested"}), do: :ok

  defp supported(%{"class" => "unsupported", "path" => path, "reason" => reason}),
    do: {:error, 501, "#{path}: #{reason}"}

  defp available(context) do
    case Context.range(context) do
      {:ok, range} -> {:ok, range}
      {:error, _} -> {:error, 503, "Docker engine is not ready"}
    end
  end

  defp check_version(nil, _, _), do: :ok

  defp check_version(version, minimum, maximum) do
    case Version.parse(version) do
      {:ok, requested} when requested < minimum ->
        {:error, 400,
         "client version #{version} is too old. Minimum supported API version is #{Version.format(minimum)}, please upgrade your client to a newer version"}

      {:ok, requested} when requested > maximum ->
        {:error, 400,
         "client version #{version} is too new. Maximum supported API version is #{Version.format(maximum)}"}

      {:ok, _} ->
        :ok

      :error ->
        {:error, 400, "invalid API version"}
    end
  end

  defp check_route_version(version, %{"min_api_version" => route_minimum}) do
    with {:ok, requested} <- Version.parse(version),
         {:ok, minimum} <- Version.parse(route_minimum),
         true <- requested >= minimum do
      :ok
    else
      _ -> {:error, 404, "page not found"}
    end
  end

  defp check_route_version(_, _), do: :ok

  defp upstream_path(original, path, nil, maximum, context) do
    effective = Version.format(maximum)
    if context.capabilities.maximum == effective, do: original, else: "/v#{effective}#{path}"
  end

  defp upstream_path(original, _, _, _, _), do: original
end
