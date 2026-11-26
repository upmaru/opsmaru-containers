# Spec Delta

## ADDED Requirements

### Requirement: Release triggered by the release merge

The release workflow SHALL trigger on push to `main`, restricted to the opsmaru-containers repository. It SHALL confirm the push is exactly the merge of a `release/<version>` pull request: the commit SHALL be associated with a merged PR whose `merge_commit_sha` equals `GITHUB_SHA`, base `main`, head repo full name equal to the repository, and head ref matching `release/<version>`. Eligible `release/` PRs are filtered before deciding; empty associations are retried a bounded number of times (indexing lag) and a real API error fails the check. Pushes that are not such a merged release PR SHALL be skipped. Before any Hex upload, a conflicting pre-existing tag pointing at a different SHA SHALL abort the check.

#### Scenario: Unrelated push

- **WHEN** a push to `main` is not the merge of a `release/<version>` PR
- **THEN** the workflow exits successfully without publishing

### Requirement: Version and changelog verification

The workflow SHALL fail unless the release branch version (`mix.exs`) equals the PR version in the head ref, and CHANGELOG.md SHALL contain a dated, non-empty `## VERSION — YYYY-MM-DD` section.

#### Scenario: Unreleased section

- **WHEN** the changelog section for the version is unreleased or empty
- **THEN** the workflow fails

### Requirement: Bounded HTTP and propagation tolerance

The workflow SHALL bound network calls with connect/max time limits and SHALL allow time for public propagation after publishing before verifying the release: a short bounded check for freshly uploaded releases, and a longer bounded verification for skipped or resumed releases.

#### Scenario: Propagation lag

- **WHEN** the release endpoint does not report the live checksum and docs on the first poll
- **THEN** the workflow retries with a bounded number of attempts before failing

### Requirement: Keyless Hex publish via Workload Identity

The publish job SHALL use the already-configured release environment (main-only), `contents: read`, `id-token: write`, and no secrets, and SHALL publish with native `mix hex.publish --yes --wait` on the pinned Hex 2.7.0 for new uploads and docs-only uploads. The job SHALL allow roughly an hour for operator approval and SHALL carry a 90-minute timeout. Before publishing it SHALL GET the Hex package and release endpoints and distinguish 404 from transport/unexpected status. A release-endpoint 200 SHALL be compared by `.checksum` (outer SHA256 of the `mix hex.build` archive): an identical existing release SHALL skip. The workflow SHALL NOT use `--replace`. Public checksum and docs SHALL be verified before the GitHub Release. The native CI publish prints the exact approval link in its own log and renews OIDC. The Actions summary SHALL surface the staged-release dashboard link (https://hex.pm/dashboard/staged-releases) for approval paths and the exact validated approval_url for existing pending records; bootstrap paths show the merge SHA and local publish instructions instead.

#### Scenario: Existing identical release

- **WHEN** the release endpoint returns 200 with the same checksum and docs
- **THEN** the publish is skipped

### Requirement: Bootstrap path for the initial 0.1.0 package

For the exact version 0.1.0, an unserved release or missing public docs SHALL take the read-only wait path, even if the package endpoint returns 200 (Hex completes bundled docs before making the release public, so the package may be 200 while docs are still pending, or while the workload identity is not yet configured). The workflow SHALL NOT exchange OIDC or upload on this path. It SHALL wait up to an hour for the exact public checksum and docs from the owner-initiated local publish, with the merge SHA and instructions in the Actions summary, then verify the release. A package endpoint 404 on any later version SHALL FAIL instead of waiting.

#### Scenario: Initial 0.1.0 package endpoint 200 but docs pending

- **WHEN** version 0.1.0 is released publicly without docs (or with a public package but an unserved release)
- **THEN** the workflow takes the read-only wait path, prints the merge SHA and instructions in the summary, and does not exchange OIDC or upload

#### Scenario: Package missing for a later version

- **WHEN** the package endpoint returns 404 for version 0.1.1 or later
- **THEN** the workflow fails with bootstrap instructions instead of waiting

### Requirement: Staged release resume

For later versions that need an upload or resume, the workflow SHALL exchange OIDC and read staged endpoints through `.github/scripts/hex-staged-state.exs`, run via `mise exec -- mix run --no-start --no-compile` with the version and the suffix (`staged` or `docs/staged`). The helper SHALL add the Hex archive path with `Mix.Local.append_archives()`, start Hex with `Hex.start()`, require `Hex.WorkloadIdentity.auth!("hexpm", "opsmaru_containers")` to return a nonempty value, and then call `Hex.API.Release.get_staged("https://hex.pm/api/packages/opsmaru_containers/releases/#{version}/#{suffix}", auth)`. A 200 response SHALL include `status` (staged/approved/rejected/expired), `html_url` and the outer archive `checksum`; the staged package checksum SHALL be checked against the built archive before waiting. A staged or approved package/docs SHALL skip uploads and use the longer bounded public verification. 404/rejected/expired SHALL be eligible to upload in a new run. Other answers SHALL fail closed. Credentials SHALL never be printed. Docs-only approved records are visible from the docs staged endpoint, and a public release without docs SHALL query the docs staged endpoint.

#### Scenario: Staged package resume

- **WHEN** the release is public-404 with the package existing and the staged endpoint reports a staged package
- **THEN** the staged checksum is checked against the archive, nothing is uploaded, and the workflow waits for the operator approval with the approval link in the Actions summary

#### Scenario: Staged package 404/rejected/expired

- **WHEN** the staged endpoint reports 404/rejected/expired
- **THEN** the release is eligible to upload in a new run

#### Scenario: Public release without docs

- **WHEN** a public release exists without docs and the docs staged endpoint reports staged/approved
- **THEN** uploads are skipped and public verification is retried with longer bounded polling

#### Scenario: Later version with a missing package

- **WHEN** the package is missing for version 0.1.1 or later
- **THEN** the workflow fails instead of waiting

### Requirement: No replay after ambiguous outcomes

The workflow SHALL NOT replay a possibly accepted mutation after an ambiguous answer (transport error, unexpected status, missing fields, or a checksum mismatch on a staged record). Failures SHALL stop the workflow with explicit operator recovery instructions.

#### Scenario: Unexpected staged answer

- **WHEN** the staged endpoint answers with an unknown status, malformed JSON, or a missing checksum
- **THEN** the workflow fails closed without uploading

### Requirement: GitHub Release creation

A separate job SHALL create tag `v<version>` at the exact merge SHA (after Hex is verified, via `gh release create --verify-tag`) with notes from the changelog section, and SHALL be resumable when the tag/release already exists correctly and published. A published release with a missing tag, or a conflicting pre-existing tag, SHALL be rejected with explicit operator recovery. It SHALL use no Hex credential. The release workflow SHALL be serialized on the `release-main` concurrency group with `cancel-in-progress: false` and `queue: max`: one workflow run executes while GitHub retains up to 100 waiting runs; a new run at capacity is canceled; accepting runs does not guarantee push order. A legitimate pending release is never replaced by an unrelated push.

#### Scenario: Existing correct tag

- **WHEN** the tag and release already exist at the right SHA
- **THEN** the job succeeds without recreating them

#### Scenario: One active release plus two pending runs

- **WHEN** a release is mid-publish and two further pushes arrive (one of them unrelated)
- **THEN** both runs wait in the group without replacing the legitimate release; when the group is at capacity (100 waiting) additional pushes are canceled
