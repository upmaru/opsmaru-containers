defmodule Opsmaru.Containers.Native.ListingTest do
  use ExUnit.Case, async: true

  alias Opsmaru.Containers.Native.{Listing, RunRecord}

  test "durations read as docker ps shows them" do
    for {milliseconds, text} <- [
          {400, "Less than a second"},
          {1_000, "1 second"},
          {59_000, "59 seconds"},
          {60_000, "About a minute"},
          {59 * 60_000, "59 minutes"},
          {60 * 60_000, "About an hour"},
          {47 * 3_600_000, "47 hours"},
          {3 * 86_400_000, "3 days"},
          {20 * 86_400_000, "2 weeks"},
          {90 * 86_400_000, "3 months"},
          {800 * 86_400_000, "2 years"}
        ] do
      assert Listing.human_duration(milliseconds) == text
    end
  end

  test "run records are bounded, untrusted input" do
    valid = %{
      "version" => 1,
      "run" => 2,
      "pid" => 12,
      "started_at" => "2026-11-27T10:00:00.123456789Z",
      "finished_at" => "2026-11-27T10:00:04.5Z",
      "exit_code" => 143,
      "signal" => "SIGTERM",
      "oom_killed" => false,
      "error" => nil
    }

    assert %RunRecord{run: 2, exit_code: 143, signal: "SIGTERM"} =
             RunRecord.parse(Jason.encode!(valid))

    for invalid <- [
          %{valid | "version" => 2},
          %{valid | "run" => 0},
          %{valid | "started_at" => "now"},
          %{valid | "exit_code" => 300},
          %{valid | "pid" => -1},
          %{valid | "signal" => String.duplicate("S", 17)},
          %{valid | "oom_killed" => "yes"}
        ] do
      assert RunRecord.parse(Jason.encode!(invalid)) == :missing
    end

    assert RunRecord.parse("not json") == :missing
  end

  test "until takes RFC 3339 times, Unix seconds and durations" do
    now = ~U[2026-11-27 12:00:00Z]

    assert Listing.until(["2026-11-27T10:00:00Z"], now) == {:ok, ~U[2026-11-27 10:00:00Z]}

    assert Listing.until(["1700000000"], now) ==
             {:ok, DateTime.from_unix!(1_700_000_000_000_000, :microsecond)}

    assert Listing.until(["1h30m"], now) == {:ok, ~U[2026-11-27 10:30:00.000000Z]}
    assert {:error, 400, _} = Listing.until(["soon"], now)
  end
end
