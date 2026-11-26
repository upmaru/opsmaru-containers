# Release runbook

How `opsmaru-containers` reaches Hex and creates a GitHub Release. The workflow
is `.github/workflows/release.yml`, triggered on push to `main`. It only acts
when the push is exactly the merge of a `release/<version>` PR (one merged PR,
base `main`, head repo this repository, head ref `release/<version>`, where
`<version>` matches `mix.exs`). Unrelated pushes are skipped.

## Routine release

1. Develop on a `feature/*` branch from `develop`; land it there.
2. From the updated `develop`, create `release/<version>`: bump `version` in
   `mix.exs` and change the changelog heading to
   `## <version> — YYYY-MM-DD` with real notes (dated, non-empty).
3. Open a PR `release/<version>` → `main` and **merge it with a merge commit**
   (not squash) so `main` carries the merge SHA the workflow verifies.
4. Back-merge `main` into `develop` after the merge.
5. The push to `main` triggers the workflow: it verifies the merge, builds the
   Hex package, then resolves the action from the public API (and, for later
   versions, from the staged endpoints via `.github/scripts/hex-staged-state.exs`
   through the `release` environment's keyless Workload Identity — no secrets).
   For a new upload it publishes with native `mix hex.publish --yes --wait`
   (docs-only recovery uses `mix hex.publish docs --yes --wait`), then verifies
   the public checksum and docs, then pushes the tag `v<version>` at the
   merge SHA, then creates the GitHub Release
   (`gh release create --verify-tag`) with notes from the changelog section. The
   workflow creates the tag at that SHA whenever the version's tag is absent.

## Staged publishing (default, intentional)

Staged publishing is **enabled by default** on the `opsmaru_containers`
package and is intentionally kept on. Staged publishing works as expected for
keyless Workload Identity publishes: the native `mix hex.publish --yes --wait`
waits (roughly an hour) for an owner to approve the staged release, then
publishes. The workflow surfaces the dashboard link
(https://hex.pm/dashboard/staged-releases) in the Actions summary; the native
Hex publish prints the exact approval link in the log and renews OIDC. After
approval, the same run resumes once the public release (checksum and docs) is
live. The workflow does not replay a staged mutation: an already-staged or
approved record skips the upload and uses the long bounded public verification
(~1 hour). See https://hex.pm/docs/publish#staged-publishing.

## First release (0.1.0, unregistered)

Hex has no `opsmaru_containers` package yet, so it cannot publish keylessly:
Workload Identity tokens can publish only to packages the workload identity
already belongs to. After the human merge of `release/0.1.0` into `main`, CI
waits for the matching 0.1.0 to go public (read-only; no OIDC exchange, no
upload). To finish the bootstrap locally, from the exact merge commit:

1. Use a short-lived **local personal** Hex API key with **API Read and Publish
   only** (no other scopes).
2. Run `mix hex.publish` interactively with that `HEX_API_KEY` set **for that
   command only** (no `--yes`).
3. Select the `upmaru` public owner at the prompt.
4. Approve the staged release and docs via the dashboard link printed in the
   output (https://hex.pm/dashboard/staged-releases), then revoke the key.
5. After the first publish, configure the org Hex form: Write, `upmaru`,
   `opsmaru-containers`, `release.yml`, `release`, **public** checked,
   `opsmaru_containers`, private unchecked.

The same workflow run then verifies the public release and docs and creates the
GitHub Release. There is **no CI key**; personal OAuth is the alternative direct
bootstrap path (`mix hex.user auth` + interactive `mix hex.publish` selecting
the `upmaru` public owner). Once 0.1.0 is public, configure Hex Workload
Identity for later releases and use the workload-identity path documented at
https://hex.pm/docs/workload-identity.

## Subsequent releases

Publish automatically on the `main` merge. With staging on (kept on), the
workflow waits with `--wait` for an owner's approval — approve the staged
package and docs on the dashboard
(https://hex.pm/dashboard/staged-releases). If the wait fails, approve and
rerun the workflow (a rerun never re-uploads a staged release).

## Concurrency

The workflow runs on a single `release-main` concurrency group with
`cancel-in-progress: false` and `queue: max`: one workflow run executes while
GitHub retains up to 100 waiting runs; a new run at capacity is canceled, and
accepting runs does not guarantee push order. This matters when an active
release is in flight and two further pushes arrive — one of them may be an
unrelated push; under the default `single` queue, an unrelated push would
cancel and replace the pending legitimate release. `max` keeps both waiting
runs without replacing the legitimate one.

## Ambiguous staging / recovery

Do not re-run blindly while a release is half-published or staged. Confirm on
hex.pm whether the release and its docs are staged, approved, live or missing,
then either let the workflow resume (existing correct tag/release are safe to
resume; identical checksums are skipped) or use explicit operator recovery
(`mix hex.publish` / `mix hex.publish docs`). Never use `--replace`.
