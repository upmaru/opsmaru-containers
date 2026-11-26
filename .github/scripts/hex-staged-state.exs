#!/usr/bin/env elixir
# Reads the staged state of one opsmaru_containers release through the Hex
# workload identity, for the release workflow's staged-resume path.
#
# Usage (from the repository root):
#   mix run --no-start --no-compile .github/scripts/hex-staged-state.exs VERSION SUFFIX
#
#   VERSION  e.g. 0.1.0 (must be a semantic version)
#   SUFFIX   "staged" (package) or "docs/staged" (docs)
#
# Prints three lines on stdout:
#   status=staged|approved|missing
#   html_url=<https://hex.pm/... URL, or the dashboard link>
#   checksum=<outer archive checksum, or empty>
#
# "missing" means the record was 404, rejected or expired: the release is
# eligible to upload in a new run. Any other answer stops with an error
# (exit non-zero) without printing outputs. Credentials are never printed.

defmodule HexStagedState do
  @package "opsmaru_containers"
  @suffixes ["staged", "docs/staged"]
  @dashboard "https://hex.pm/dashboard/staged-releases"

  def run do
    case System.argv() do
      [version, suffix] ->
        with {:ok, _} <- Version.parse(version),
             true <- suffix in @suffixes do
          read(version, suffix)
        else
          _ -> fail("invalid arguments: expected VERSION (semver) SUFFIX")
        end

      _ ->
        fail("usage: hex-staged-state.exs VERSION SUFFIX")
    end
  end

  defp read(version, suffix) do
    Mix.Local.append_archives()
    Hex.start()

    auth =
      try do
        Hex.WorkloadIdentity.auth!("hexpm", @package)
      rescue
        _ -> fail("workload identity exchange failed")
      catch
        _kind, _reason -> fail("workload identity exchange failed")
      end

    case auth do
      [key: token, oauth: true] when is_binary(token) and token != "" ->
        :ok

      _ ->
        fail("workload identity auth returned no key")
    end

    url = "https://hex.pm/api/packages/#{@package}/releases/#{version}/#{suffix}"

    try do
      case Hex.API.Release.get_staged(url, auth) do
        {:ok, {200, _headers, %{"status" => status} = body}}
        when status in ["staged", "approved", "rejected", "expired"] ->
          output(status, Map.get(body, "html_url"), Map.get(body, "checksum"))

        {:ok, {200, _headers, _body}} ->
          fail("staged record has no readable status")

        {:ok, {404, _headers, _body}} ->
          output("missing", nil, nil)

        _ ->
          fail("unexpected Hex answer")
      end
    rescue
      _ -> fail("staged read failed")
    end
  end

  defp output(status, html_url, checksum) do
    {status, html_url, checksum} =
      if status in ["rejected", "expired"] do
        {"missing", nil, nil}
      else
        {status, html_url, checksum}
      end

    IO.puts("status=#{status}")
    IO.puts("html_url=#{validate_url(html_url) || @dashboard}")
    IO.puts("checksum=#{validate_checksum(checksum) || ""}")
  end

  defp validate_url(url) when is_binary(url) do
    url = String.trim(url)

    if String.starts_with?(url, "https://hex.pm/") do
      url
    else
      nil
    end
  end

  defp validate_url(_), do: nil

  defp validate_checksum(sha) when is_binary(sha) do
    sha = String.trim(sha)

    if Regex.match?(~r/^[0-9a-f]{64}$/, sha) do
      sha
    else
      nil
    end
  end

  defp validate_checksum(_), do: nil

  defp fail(message) do
    IO.puts(:stderr, "::error::#{message}")
    System.halt(1)
  end
end

HexStagedState.run()
