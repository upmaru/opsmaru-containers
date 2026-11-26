# Proposal

## Why

`opsmaru-containers` reaches Hex (the only distribution route) only by manual,
interactive publishing. That is error-prone and makes the public package hard
to repeat. Workload Identity lets GitHub Actions publish to Hex without stored
API keys, using a short-lived OIDC identity. Hex stages releases published with
an API key until an owner approves them, so the release workflow must wait for
that approval rather than fail the run.

## What Changes

- Add `.github/workflows/release.yml`, triggered on push to `main`.
- A read-only check confirms the push is exactly a merged release PR
  (`release/<version>` into `main`, head repo is this repository), with a
  bounded retry for absent association (indexing lag), fail on real API
  errors, and unrelated pushes skipped. Before any Hex upload, a conflicting
  pre-existing tag is rejected.
- Verify the release branch version equals `mix.exs` and extract the exact dated
  non-empty `## VERSION — YYYY-MM-DD` changelog section.
- The publish job uses the already-configured release environment (main-only),
  `id-token: write`, no secrets, and native `mix hex.publish --yes --wait`
  (with the pinned Hex 2.7.0). Before publishing it inspects the Hex API.
- Bootstrap path (exact initial 0.1.0): any unserved release or missing public
  docs takes the read-only wait path, even if the package endpoint is already
  200 (Hex may still be completing bundled docs). No OIDC exchange and no
  uploads on this path; the workflow waits up to an hour for the exact public
  checksum and docs from the owner-initiated local publish, with the merge
  SHA and instructions in the Actions summary. Later versions fail on a 404
  package endpoint instead of waiting.
- Staged/resume path: an unserved release with the package existing, or a
  public release without docs, is read through
  `.github/scripts/hex-staged-state.exs` (via `mise exec -- mix run --no-start
  --no-compile`), which uses a local module loader
  (`Mix.Local.append_archives()` + `Hex.start()`), exchanges OIDC with
  `Hex.WorkloadIdentity.auth!("hexpm", "opsmaru_containers")` (nonempty), and
  GETs `Hex.API.Release.get_staged(url, auth)`. The staged package checksum
  must match the built archive before waiting; staged releases are never
  re-uploaded. 404/rejected/expired is eligible for an upload in a new run;
  other answers fail closed.
- Actions summary shows the dashboard link whenever anything is staged (and
  the exact validated approval_url for existing pending records, plus the merge
  SHA and local publish instructions on bootstrap). Native keyed CI uploads
  print the exact approval link in the publish log and renew OIDC, allow
  roughly an hour for operator approval, and the job carries a 90-minute
  timeout.
- Newly uploaded releases get a short propagation check; skipped or resumed
  releases get a longer bounded polling verification. No replay after an
  ambiguous outcome.
- A separate GitHub Release job (`contents: write`) pushes tag `v<version>` at
  the exact merge SHA (after Hex is verified) and creates the GitHub Release
  with notes from the changelog via `gh release create --verify-tag`;
  existing published tag/release is resumable; a published release with a
  missing tag or a conflicting tag is rejected. The release workflow is
  serialized on the `release-main` concurrency group (`cancel-in-progress:
  false`, `queue: max`).
- Add a release runbook: staged publishing enabled, human approval at
  https://hex.pm/dashboard/staged-releases, then public checksum and docs
  before GitHub Release. 0.1.0's first public release cannot use OIDC (the
  first-publish bootstrap is a local interactive `mix hex.publish`, or a
  short-lived personal key limited to API Read + Publish, or Personal OAuth);
  org Workload Identity is configured after 0.1.0.

Not in this change: changes to library behavior or the unreleased changelog.

## Impact

- Workflow, runbook and CI docs only. No library code.
