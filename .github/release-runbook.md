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
   Hex package, publishes with keyless Workload Identity (the `release`
   environment, restricted to `main`, `id-token: write`, no secrets), verifies
   the public checksum and docs, then pushes the tag `v<version>` at the
   merge SHA (on first release only) and creates the GitHub Release
   (`gh release create --verify-tag`) with notes from the changelog section.

## First release (0.1.0, unregistered)

Hex has no `opsmaru_containers` package yet, so it cannot publish keylessly:
Workload Identity tokens can publish only to packages the workload identity
already belongs to. Bootstrap manually, once, from the exact main merge
commit:

1. `mix hex.user auth`
2. `mix hex.publish` — interactively, without `--yes`, and select the upmaru
   **public** owner at the prompt. The `--yes` flag suppresses the owner
   picker and must not be used here. An authenticated personal publish goes
   live directly; it does not stage.
3. Configure the org Hex form: Write, `upmaru`, `opsmaru-containers`,
   `release.yml`, `release`, **public** checked, `opsmaru_containers`,
   private unchecked.
4. Choose the package's staging setting for future CI runs
   (**Settings > Staged publishing**): off for fully unattended
   Workload-Identity publishes.
5. Re-run the original workflow. It skips the existing release (checksum
   match), verifies public checksum and docs, and creates the GitHub
   Release (tag and release).

There is no billing or stored key involved: the public package scope uses the
workload identity configured in step 3.

## Subsequent releases

Publish automatically on the `main` merge. New Hex packages have staged
publishing enabled by default; with staging on, the workflow waits with
`--wait` for an owner's approval — approve the staged package and docs, or
turn **Settings > Staged publishing** off on the package for fully unattended
runs. If staging is on and the wait fails, approve and rerun the workflow (a
rerun never re-uploads a staged release).

## Ambiguous staging / recovery

Do not re-run blindly while a release is half-published or staged. Confirm on
hex.pm whether the release and its docs are staged, approved, live or missing,
then either let the workflow resume (existing correct tag/release are safe to
resume; identical checksums are skipped) or use explicit operator recovery
(`mix hex.publish` / `mix hex.publish docs`). Never use `--replace`.
