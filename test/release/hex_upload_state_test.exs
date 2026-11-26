defmodule Opsmaru.Release.HexUploadStateTest do
  # Regression tests for .github/scripts/hex-upload-state.sh. `curl` and
  # `mise` are replaced on PATH by stubs that answer from fixtures and log
  # each call, so no request leaves the machine and no workload identity
  # exchange can happen. A `mise` call is how the helper reads staged state
  # through OIDC, so the log shows whether that path ran.
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @script Path.expand("../../.github/scripts/hex-upload-state.sh", __DIR__)
  @sha String.duplicate("ab", 32)
  @other_sha String.duplicate("cd", 32)
  @dashboard "https://hex.pm/dashboard/staged-releases"
  @approval "https://hex.pm/packages/opsmaru_containers/staged/7"

  @curl_stub """
  #!/bin/sh
  url=""
  for arg in "$@"; do url="$arg"; done
  echo "curl $url" >> "$STUB_LOG"
  case "$url" in
    */releases/*) status="$STUB_RELEASE_STATUS"; body="$STUB_RELEASE_BODY" ;;
    */packages/*) status="$STUB_PACKAGE_STATUS"; body="{}" ;;
    *) exit 3 ;;
  esac
  [ "$status" = "unreachable" ] && exit 7
  printf '%s\\n%s' "$body" "$status"
  """

  @mise_stub """
  #!/bin/sh
  echo "mise $*" >> "$STUB_LOG"
  suffix=""
  for arg in "$@"; do suffix="$arg"; done
  case "$suffix" in
    staged) answer="$STUB_STAGED_PACKAGE" ;;
    docs/staged) answer="$STUB_STAGED_DOCS" ;;
    *) exit 3 ;;
  esac
  if [ "$answer" = "fail" ]; then
    echo "::error::unexpected Hex answer" >&2
    exit 1
  fi
  printf '%s\\n' "$answer"
  """

  setup_all do
    # The helper hides a missing jq behind "unexpected JSON", so say so here.
    unless System.find_executable("jq") do
      flunk("jq is required by hex-upload-state.sh; run `mise install`")
    end

    :ok
  end

  setup %{tmp_dir: tmp_dir} do
    bin = Path.join(tmp_dir, "bin")
    File.mkdir_p!(bin)

    for {name, source} <- [{"curl", @curl_stub}, {"mise", @mise_stub}] do
      path = Path.join(bin, name)
      File.write!(path, source)
      File.chmod!(path, 0o755)
    end

    %{bin: bin, log: Path.join(tmp_dir, "calls.log")}
  end

  describe "initial 0.1.0 release" do
    test "bootstraps read-only while nothing is public, without OIDC", ctx do
      result = run(ctx, "0.1.0", package: 404, release: 404)

      assert result.status == 0
      assert result.outputs["action"] == "bootstrap"
      assert result.outputs["verify_attempts"] == "120"
      refute mise_called?(ctx)
    end

    test "bootstraps while the package is live but the release is not served", ctx do
      result = run(ctx, "0.1.0", package: 200, release: 404)

      assert result.outputs["action"] == "bootstrap"
      refute mise_called?(ctx)
    end

    test "bootstraps while the public release has no docs", ctx do
      result = run(ctx, "0.1.0", package: 200, release: {200, release(@sha, false)})

      assert result.outputs["action"] == "bootstrap"
      refute mise_called?(ctx)
    end

    test "skips once the release and docs are public", ctx do
      result = run(ctx, "0.1.0", package: 200, release: {200, release(@sha, true)})

      assert result.status == 0
      assert result.outputs["action"] == "skip"
      refute mise_called?(ctx)
    end

    test "fails on a checksum mismatch", ctx do
      result = run(ctx, "0.1.0", package: 200, release: {200, release(@other_sha, false)})

      assert_failed(result, "Refusing to republish")
      refute mise_called?(ctx)
    end
  end

  describe "later releases, not publicly served" do
    test "a missing package is never a bootstrap", ctx do
      result = run(ctx, "0.2.0", package: 404, release: 404)

      assert_failed(result, "not an initial release")
      refute mise_called?(ctx)
    end

    test "staged and approved records wait without another upload", ctx do
      for status <- ["staged", "approved"] do
        result =
          run(ctx, "0.2.0",
            package: 200,
            release: 404,
            staged: staged(status, @approval, @sha)
          )

        assert result.status == 0
        assert result.outputs["action"] == "wait-staged"
        assert result.outputs["staged_kind"] == "package"
        assert result.outputs["approval_url"] == @approval
        assert result.outputs["verify_attempts"] == "120"
      end
    end

    test "an approval URL off hex.pm falls back to the dashboard", ctx do
      result =
        run(ctx, "0.2.0",
          package: 200,
          release: 404,
          staged: staged("staged", "https://example.com/approve", @sha)
        )

      assert result.outputs["approval_url"] == @dashboard
    end

    test "a missing staged record uploads", ctx do
      result =
        run(ctx, "0.2.0", package: 200, release: 404, staged: staged("missing", @dashboard, ""))

      assert result.status == 0
      assert result.outputs["action"] == "upload"
      assert result.outputs["verify_attempts"] == "8"
      assert mise_args(ctx) == [".github/scripts/hex-staged-state.exs 0.2.0 staged"]
    end

    test "a staged checksum mismatch fails", ctx do
      result =
        run(ctx, "0.2.0",
          package: 200,
          release: 404,
          staged: staged("staged", @approval, @other_sha)
        )

      assert_failed(result, "Refusing to republish")
    end

    test "a staged record without a checksum fails", ctx do
      result =
        run(ctx, "0.2.0", package: 200, release: 404, staged: staged("approved", @approval, ""))

      assert_failed(result, "no checksum")
    end
  end

  describe "later releases, publicly served" do
    test "skips when docs are public, without OIDC", ctx do
      result = run(ctx, "0.2.0", package: 200, release: {200, release(@sha, true)})

      assert result.outputs["action"] == "skip"
      refute mise_called?(ctx)
    end

    test "recovers docs only when no docs record is staged", ctx do
      result =
        run(ctx, "0.2.0",
          package: 200,
          release: {200, release(@sha, false)},
          docs: staged("missing", @dashboard, "")
        )

      assert result.status == 0
      assert result.outputs["action"] == "docs-only"
      assert result.outputs["verify_attempts"] == "8"
      assert mise_args(ctx) == [".github/scripts/hex-staged-state.exs 0.2.0 docs/staged"]
    end

    test "waits on staged or approved docs", ctx do
      for status <- ["staged", "approved"] do
        result =
          run(ctx, "0.2.0",
            package: 200,
            release: {200, release(@sha, false)},
            docs: staged(status, @approval, "")
          )

        assert result.outputs["action"] == "wait-staged"
        assert result.outputs["staged_kind"] == "docs"
        assert result.outputs["approval_url"] == @approval
      end
    end

    test "fails on a checksum mismatch before reading staged state", ctx do
      result = run(ctx, "0.2.0", package: 200, release: {200, release(@other_sha, false)})

      assert_failed(result, "Refusing to republish")
      refute mise_called?(ctx)
    end
  end

  describe "unexpected responses fail closed" do
    test "package or release lookups other than 200 or 404", ctx do
      assert_failed(run(ctx, "0.2.0", package: 500, release: 404), "package lookup 500")
      assert_failed(run(ctx, "0.2.0", package: 200, release: 503), "release lookup 503")
      assert_failed(run(ctx, "0.1.0", package: 403, release: 404), "package lookup 403")
    end

    test "an unreachable Hex API", ctx do
      assert_failed(run(ctx, "0.2.0", package: "unreachable", release: 404), "lookup 000")
    end

    test "release JSON without a checksum or docs flag", ctx do
      for body <- [~s({"has_docs":true}), ~s({"checksum":"#{@sha}"}), "not json"] do
        assert_failed(run(ctx, "0.2.0", package: 200, release: {200, body}), "unexpected JSON")
      end
    end

    test "a failed or empty staged read", ctx do
      assert_failed(
        run(ctx, "0.2.0", package: 200, release: 404, staged: "fail"),
        "Could not read staged state"
      )

      assert_failed(
        run(ctx, "0.2.0", package: 200, release: 404, staged: ""),
        "empty"
      )
    end

    test "an unknown staged status", ctx do
      assert_failed(
        run(ctx, "0.2.0", package: 200, release: 404, staged: staged("pending", @approval, @sha)),
        "Unexpected staged answer pending"
      )

      assert_failed(
        run(ctx, "0.2.0",
          package: 200,
          release: {200, release(@sha, false)},
          docs: staged("pending", @approval, "")
        ),
        "Unexpected staged answer pending"
      )
    end
  end

  defp run(ctx, version, fixture) do
    File.rm(ctx.log)
    File.touch!(ctx.log)

    {release_status, release_body} =
      case Keyword.fetch!(fixture, :release) do
        {status, body} -> {status, body}
        status -> {status, "{}"}
      end

    env = [
      {"PATH", ctx.bin <> ":" <> System.get_env("PATH", "")},
      {"HEX_API_URL", "https://hex.test/api"},
      {"STUB_LOG", ctx.log},
      {"STUB_PACKAGE_STATUS", to_string(Keyword.fetch!(fixture, :package))},
      {"STUB_RELEASE_STATUS", to_string(release_status)},
      {"STUB_RELEASE_BODY", release_body},
      {"STUB_STAGED_PACKAGE", Keyword.get(fixture, :staged, "fail")},
      {"STUB_STAGED_DOCS", Keyword.get(fixture, :docs, "fail")}
    ]

    {output, status} =
      System.cmd("bash", [@script, version, @sha], env: env, stderr_to_stdout: true)

    outputs =
      for line <- String.split(output, "\n", trim: true),
          [key, value] <- [String.split(line, "=", parts: 2)],
          not String.starts_with?(key, "::"),
          into: %{},
          do: {key, value}

    %{status: status, output: output, outputs: outputs}
  end

  defp assert_failed(result, message) do
    assert result.status != 0
    assert result.output =~ "::error::"
    assert result.output =~ message
    refute Map.has_key?(result.outputs, "action")
  end

  defp mise_args(ctx) do
    for "mise " <> args <- File.read!(ctx.log) |> String.split("\n", trim: true) do
      args |> String.split(" ") |> Enum.take(-3) |> Enum.join(" ")
    end
  end

  defp mise_called?(ctx), do: mise_args(ctx) != []

  defp release(checksum, has_docs), do: ~s({"checksum":"#{checksum}","has_docs":#{has_docs}})

  defp staged(status, html_url, checksum),
    do: "status=#{status}\nhtml_url=#{html_url}\nchecksum=#{checksum}"
end
