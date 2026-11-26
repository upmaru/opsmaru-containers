# Tasks

- [x] Add OpenSpec proposal, spec and tasks; validate with mise run spec:validate
- [x] Add .github/workflows/release.yml: push-to-main trigger, read-only merged-release-PR check (gh api + jq over release/<version> eligibility) with bounded retry for lag and fail-on-real-API-error, unrelated pushes skip
- [x] Verify release branch version vs mix.exs and extract dated nonempty changelog section
- [x] Read-only conflicting-tag reject before any Hex upload (single git ls-remote call covering ref and peeled ref)
- [x] Publish job: release environment (main-only), contents: read, id-token: write, no secrets, mix hex.publish --yes --wait
- [x] Inspect Hex API first: distinguish 404 from transport/unexpected status; release 200 checksum comparison with skip; typed .has_docs handling (false → docs-only); no --replace; verify public checksum/docs (with propagation retry) before GitHub Release
- [x] GitHub Release job with needs [verify, hex]: contents: write, push tag v<version> at exact merge SHA only after verified Hex (gh release create --verify-tag); notes from CHANGELOG; existing published tag/release skipped safely; missing tag with published release rejected; conflicting tag rejected in read-only verification and in the release job; no Hex credential; serialized workflow (concurrency release-main with queue: max)
- [x] Concurrency queue: add queue: max to release-main (one running run while GitHub retains up to 100 waiting runs; a new run at capacity is canceled; accepting runs does not guarantee push order) so an active release plus two pending pushes (one possibly an unrelated push) is never replaced mid-queue; validated against the official concurrency docs and lint the rest with actionlint 1.7.12 ignoring the known queue-key false positive
- [x] Release runbook documenting the process, staged publishing kept on, the one-time 0.1.0 bootstrap (local personal Hex key with API Read+Publish only, interactive mix hex.publish selecting upmaru public owner, dashboard approval, key revocation) and subsequent automatic publishes
- [x] Fixture-exercised the gate and .has_docs false handling; run mise run check, mix hex.build, mix hex.publish --dry-run --yes and actionlint/shellcheck
- [x] Finalize CHANGELOG 0.1.0 dated 2026-11-26
- [x] Update OpenSpec for staged publishing: bootstrap path (exact 0.1.0 read-only wait even when the package endpoint is 200), staged resume via hex-staged-state.exs (Mix.Local.append_archives, Hex.start, WorkloadIdentity auth, get_staged), checksum check before wait, 90-minute job timeout with ~1 hour approval wait, summary approval link, and runbook for staged publishing
- [x] Helper-driven verification of approved/staged/initial bootstrap/docs-false/mismatch paths (PATH-stubbed curl/mise; scratch fixture tests removed); run mise run check, mix hex.publish --dry-run --yes, bash -n, actionlint/shellcheck
