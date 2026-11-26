# Proposal

## Why

`opsmaru-containers` reaches Hex (the only distribution route) only by manual,
interactive publishing. That is error-prone and makes the public package hard
to repeat. Workload Identity lets GitHub Actions publish to Hex without stored
API keys, using a short-lived OIDC identity.

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
  `id-token: write`, no secrets, and native `mix hex.publish --yes --wait`.
  Before publishing it inspects the Hex API: package 404 means bootstrap
  required; release 200 has `.checksum` and `.has_docs` and is compared for a
  skip; doc-only gaps are handled explicitly. No `--replace`.
- A separate GitHub Release job (`contents: write`) pushes tag `v<version>` at
  the exact merge SHA (on first release only, after Hex is verified) and
  creates the GitHub Release with notes from the changelog via
  `gh release create --verify-tag`; existing published tag/release is resumable;
  a published release with a missing tag or a conflicting tag is rejected. No
  Hex credential. The release workflow is serialized on the `release-main`
  concurrency group (`cancel-in-progress: false`, `queue: max`): one
  workflow run executes while GitHub retains up to 100 waiting runs; a new run
  at capacity is canceled and accepting runs does not guarantee push order. A
  legitimate pending release is never replaced by an unrelated push.
- Add a concise release runbook (feature → develop; release/<version> from
  updated develop, version/date bump, PR to main with merge commit, then
  back-merge to develop; one-time bootstrap for the initial 0.1.0 package, then
  automatic publishes).

Not in this change: changes to library behavior or the unreleased changelog.

## Impact

- New workflow and runbook docs only. No library code.
