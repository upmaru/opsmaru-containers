defmodule Opsmaru.Release.HexStagedStateTest do
  # Regression tests for .github/scripts/hex-staged-state.exs. They exercise
  # argument checks and the interpretation of Hex answers without a workload
  # identity exchange or any network access.
  use ExUnit.Case, async: false

  # The script's module is loaded in setup_all, after this file compiles.
  @compile {:no_warn_undefined, HexStagedState}

  @script Path.expand("../../.github/scripts/hex-staged-state.exs", __DIR__)
  @dashboard "https://hex.pm/dashboard/staged-releases"
  @sha String.duplicate("a1", 32)

  setup_all do
    unless Code.ensure_loaded?(HexStagedState) do
      System.put_env("HEX_STAGED_STATE_LOAD_ONLY", "1")

      try do
        Code.require_file(@script)
      after
        System.delete_env("HEX_STAGED_STATE_LOAD_ONLY")
      end
    end

    :ok
  end

  describe "parse_args/1" do
    test "accepts a semantic version and a known suffix" do
      assert parse_args(["0.2.0", "staged"]) == {:ok, {"0.2.0", "staged"}}

      assert parse_args(["0.2.0", "docs/staged"]) ==
               {:ok, {"0.2.0", "docs/staged"}}
    end

    test "refuses a non-semantic version, an unknown suffix or a wrong arity" do
      assert {:error, _} = parse_args(["latest", "staged"])
      assert {:error, _} = parse_args(["0.2.0", "../staged"])
      assert {:error, "usage:" <> _} = parse_args(["0.2.0"])
      assert {:error, "usage:" <> _} = parse_args([])
    end
  end

  describe "interpret/1" do
    test "staged and approved records keep their URL and checksum" do
      for status <- ["staged", "approved"] do
        body = %{
          "status" => status,
          "html_url" => "https://hex.pm/packages/opsmaru_containers/staged/1",
          "checksum" => @sha
        }

        assert interpret({:ok, {200, [], body}}) ==
                 {:ok,
                  [
                    "status=#{status}",
                    "html_url=https://hex.pm/packages/opsmaru_containers/staged/1",
                    "checksum=#{@sha}"
                  ]}
      end
    end

    test "rejected, expired and absent records are missing and eligible to upload" do
      missing = {:ok, ["status=missing", "html_url=#{@dashboard}", "checksum="]}

      for status <- ["rejected", "expired"] do
        body = %{"status" => status, "html_url" => "https://hex.pm/x", "checksum" => @sha}
        assert interpret({:ok, {200, [], body}}) == missing
      end

      assert interpret({:ok, {404, [], %{}}}) == missing
    end

    test "a URL off hex.pm falls back to the dashboard and a malformed checksum is dropped" do
      body = %{
        "status" => "staged",
        "html_url" => "https://example.com/approve",
        "checksum" => "not-a-sha"
      }

      assert interpret({:ok, {200, [], body}}) ==
               {:ok, ["status=staged", "html_url=#{@dashboard}", "checksum="]}
    end

    test "unknown statuses and unexpected answers fail closed" do
      assert {:error, _} = interpret({:ok, {200, [], %{"status" => "pending"}}})
      assert {:error, _} = interpret({:ok, {200, [], %{}}})
      assert {:error, _} = interpret({:ok, {200, [], "not json"}})
      assert {:error, _} = interpret({:ok, {401, [], %{}}})
      assert {:error, _} = interpret({:ok, {500, [], %{}}})
      assert {:error, _} = interpret({:error, :timeout})
    end
  end

  defp parse_args(argv), do: HexStagedState.parse_args(argv)
  defp interpret(answer), do: HexStagedState.interpret(answer)
end
