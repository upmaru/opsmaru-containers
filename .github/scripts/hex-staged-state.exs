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
  # Hex is loaded at run time by Mix.Local.append_archives/0, after this file
  # compiles.
  @compile {:no_warn_undefined, [Hex, Hex.WorkloadIdentity, Hex.API.Release]}

  @package "opsmaru_containers"
  @suffixes ["staged", "docs/staged"]
  @dashboard "https://hex.pm/dashboard/staged-releases"

  def run do
    case parse_args(System.argv()) do
      {:ok, {version, suffix}} -> read(version, suffix)
      {:error, message} -> fail(message)
    end
  end

  @doc false
  def parse_args([version, suffix]) do
    with {:ok, _} <- Version.parse(version),
         true <- suffix in @suffixes do
      {:ok, {version, suffix}}
    else
      _ -> {:error, "invalid arguments: expected VERSION (semver) SUFFIX"}
    end
  end

  def parse_args(_), do: {:error, "usage: hex-staged-state.exs VERSION SUFFIX"}

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
      case interpret(Hex.API.Release.get_staged(url, auth)) do
        {:ok, lines} -> Enum.each(lines, &IO.puts/1)
        {:error, message} -> fail(message)
      end
    rescue
      _ -> fail("staged read failed")
    end
  end

  @doc false
  def interpret({:ok, {200, _headers, %{"status" => status} = body}})
      when status in ["staged", "approved", "rejected", "expired"] do
    {:ok, output(status, Map.get(body, "html_url"), Map.get(body, "checksum"))}
  end

  def interpret({:ok, {200, _headers, _body}}), do: {:error, "staged record has no readable status"}
  def interpret({:ok, {404, _headers, _body}}), do: {:ok, output("missing", nil, nil)}
  def interpret(_), do: {:error, "unexpected Hex answer"}

  defp output(status, html_url, checksum) do
    {status, html_url, checksum} =
      if status in ["rejected", "expired"] do
        {"missing", nil, nil}
      else
        {status, html_url, checksum}
      end

    [
      "status=#{status}",
      "html_url=#{validate_url(html_url) || @dashboard}",
      "checksum=#{validate_checksum(checksum) || ""}"
    ]
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

# The regression tests set HEX_STAGED_STATE_LOAD_ONLY=1 to load the module
# without running it. With it set, the script reads no credentials and prints
# nothing, which the upload-state helper treats as an empty answer and fails
# closed.
if System.get_env("HEX_STAGED_STATE_LOAD_ONLY") != "1" do
  HexStagedState.run()
end
