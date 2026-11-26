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

The workflow SHALL bound network calls with connect/max time limits and SHALL allow time for public propagation after publishing before verifying the release.

#### Scenario: Propagation lag

- **WHEN** the release endpoint does not report the live checksum and docs on the first poll
- **THEN** the workflow retries with a bounded number of attempts before failing

### Requirement: Keyless Hex publish via Workload Identity

The publish job SHALL use the already-configured release environment (main-only), `contents: read`, `id-token: write`, and no secrets, and SHALL publish with native `mix hex.publish --yes --wait`. Before publishing it SHALL GET the Hex package and release endpoints and distinguish 404 from transport/unexpected status. A package-endpoint 404 SHALL fail with bootstrap instructions. A release-endpoint 200 SHALL be compared by `.checksum` (outer SHA256 of the `mix hex.build` archive): an identical existing release SHALL skip; doc-only gaps SHALL be handled with docs-only publish or an explicit operator recovery path. The workflow SHALL NOT use `--replace`. Public checksum and docs SHALL be verified before the GitHub Release.

#### Scenario: Existing identical release

- **WHEN** the release endpoint returns 200 with the same checksum
- **THEN** the publish is skipped

### Requirement: GitHub Release creation

A separate job SHALL create tag `v<version>` at the exact merge SHA (after Hex is verified, via `gh release create --verify-tag`) with notes from the changelog section, and SHALL be resumable when the tag/release already exists correctly and published. A published release with a missing tag, or a conflicting pre-existing tag, SHALL be rejected with explicit operator recovery. It SHALL use no Hex credential. The release workflow SHALL be serialized (concurrency group, `cancel-in-progress: false`).

#### Scenario: Existing correct tag

- **WHEN** the tag and release already exist at the right SHA
- **THEN** the job succeeds without recreating them
