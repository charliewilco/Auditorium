# Auditorium v0 Acceptance Evidence

Captured on August 8, 2026 against a local integration of the following focused changes from `origin/main` at `6defb6a105e0d0bece6872767f53d4efc8c7a9b3`:

- Integrated candidate commit: `37d36b52cbacfbadefde37f43ac445de662243c8`.
- Integrated candidate tree: `62fdc77d3e1200d24a92cb42d8e474888ce6a4c7`.

- [PR #18](https://github.com/charliewilco/Auditorium/pull/18): preserve unrelated queue items when running or retrying one ticket.
- [PR #19](https://github.com/charliewilco/Auditorium/pull/19): remove Apple Container from Local Workspace onboarding.
- [PR #20](https://github.com/charliewilco/Auditorium/pull/20): use GitHub CLI browser authentication without a user-provided OAuth client ID.
- [PR #21](https://github.com/charliewilco/Auditorium/pull/21): prove file-backed relaunch reconciliation and durable state.
- [PR #26](https://github.com/charliewilco/Auditorium/pull/26): package universal arm64 and x86_64 `symphony` executables.

The Apple Container runtime proposal in [PR #10](https://github.com/charliewilco/Auditorium/pull/10) was not merged or included.

## Fresh Live GitHub And Codex Flow

The opt-in `liveAppRunCoordinatorUsesRealSymphonyQueueWhenConfigured()` app test ran with real GitHub, the real `symphony` executable, and the real Codex CLI:

- Issue: [#24 Acceptance: prove isolated Codex app coordinator completion](https://github.com/charliewilco/Auditorium/issues/24)
- Pull request: [#25 #24: Acceptance: prove isolated Codex app coordinator completion](https://github.com/charliewilco/Auditorium/pull/25)
- Branch: `auditorium-app-smoke/issue-24-acceptance--prove-isolated-codex-app-coord`
- Commit: `7c5a17c1d10ec0a189840117e46da40544e8e5b5`
- Changed file: `docs/acceptance/V0_ISOLATED_CODEX_2026-08-08.md`
- Result: passed in 157.316 seconds.

The test asserted that the app coordinator:

- launched a one-ticket `symphony run-queue` operation;
- persisted the active queue and runtime event timeline;
- received Codex completion and validation events;
- stored the branch and pull request URL;
- stored the generated markdown report;
- moved the ticket and ticket run to review state; and
- exposed terminal inspector actions without enabling cancellation.

Codex used a temporary isolated `CODEX_HOME` containing only a link to the existing Codex authentication file. This kept desktop MCP servers out of the acceptance process and made process termination deterministic. The temporary GitHub credential file and authentication link were removed after the run.

An earlier attempt against [issue #22](https://github.com/charliewilco/Auditorium/issues/22) created [PR #23](https://github.com/charliewilco/Auditorium/pull/23), but inherited desktop MCP child processes prevented the Xcode test session from terminating. That interrupted test is not counted as passing evidence.

## Queue, Retry, Cancellation, And Relaunch

The integrated macOS app test suite passed, including focused coverage that:

- runs one selected ticket without deleting or reordering three durable queue records;
- preserves an unrelated disabled item and unrelated queued ticket statuses;
- records only the selected ticket in the run snapshot;
- cancels the active process and persists canceled run state;
- retries eligible failed work with bounded backoff;
- continues unrelated queued work after one ticket fails; and
- closes and reopens a file-backed SwiftData store, reconciles an interrupted run, preserves the queue, and retains terminal pull request, report, and event evidence.

## Local Build And Test Gates

The following passed on the integrated candidate:

- `git diff --check`
- strict recursive `swift-format` lint
- `swift build`
- `swift test` with 58 passing tests
- `cargo fetch --locked`
- `cargo fmt --all --check`
- `cargo build --all-targets`
- `cargo test --all-targets` with 50 library tests and 17 CLI integration tests passing
- `cargo run -p symphony -- --help`
- `symphony doctor --json --workflow WORKFLOW.md`
- offline `symphony run --mock`
- full Debug Xcode app tests with signing disabled
- Xcode static analysis
- Release Xcode app build with signing disabled
- `script/build_and_run.sh --verify`

Hosted CI for the focused code PRs runs SwiftPM and Rust checks only. It does not build or test the Xcode app, export screenshots, package the app, sign it, or notarize it.

### Post-Review Integrated Candidate

After addressing code-review findings in the queue, onboarding, GitHub authentication, release, and default Codex command PRs, the combined candidate was revalidated at:

- Commit: `4e1b6879daa30f89ca393379394faa5d65e6129a`.
- Tree: `edb70041b51ff9f12782b0943a1e8e910baac040`.

Strict recursive Swift formatting passed, `swift test` passed 60 tests, `cargo test --all-targets` passed 52 library and 17 CLI tests, and the full Debug Xcode app test scheme passed. The unsigned release package also rebuilt successfully; its bundled `symphony` executable was universal `x86_64 arm64`, the ad-hoc app signature passed strict verification, the bundled CLI help command succeeded, and the zip SHA-256 was `c41867f2500a0a3f92f1b6eccc0285713f41fa8b7f3f0491acc54dbc91cdef12`.

The live GitHub acceptance above was not rerun at this exact post-review tree. Its external issue-to-pull-request result remains pinned separately, while the post-review functional changes are covered by the combined local suites and each PR's refreshed hosted CI.

## Visual Review

`script/export_screenshots.sh` generated all 16 deterministic desktop and compact PNGs. Every output was inspected. The reviewed dashboard, tickets, queue, run detail, reports, settings, and empty/error surfaces had no overlapping controls or clipped primary actions; long branch, pull request, and report values truncated within their containers.

These PNGs are fixture-backed `ImageRenderer` output. They are not evidence of a running window or live account state.

The launched app was also inspected directly:

- The prerequisite sheet listed Git, Codex, and GitHub only, with no Apple Container row or copy.
- The setup wizard offered compact GitHub Browser Login and personal-access-token fallback controls with no OAuth client ID field.

The browser-login button was not used to create a fresh GitHub grant during visual inspection. Existing `gh` authentication reuse was validated separately.

## Packaging And Distribution

Both package modes completed after the universal CLI fix:

- The unsigned smoke package contained a runnable universal `symphony` executable, passed zip integrity checks, and passed strict ad-hoc signature verification.
- The Developer ID archive/export produced universal arm64 and x86_64 app and `symphony` executables.
- Strict app and nested executable signature verification passed for team `824752FF3X` with trusted timestamps.
- The signed zip SHA-256 was `7bc676f20aec4caf00c82c9a8b53fd8fa2b76f1873d604b38b1f575be2be4547`.
- Gatekeeper rejected the signed app with `source=Unnotarized Developer ID`, which is the expected result before notarization.
- `xcrun notarytool history --keychain-profile Auditorium-notary` confirmed that the documented Keychain profile is not present; no alternate notarization credential environment was configured.

## Remaining External Gates

This evidence does not establish distribution readiness. The following remain open:

- Complete a fresh GitHub browser login from the app rather than reusing an existing `gh` session.
- Notarize and staple the Developer ID artifact with release credentials.
- Confirm Gatekeeper accepts the notarized artifact.
- Download, unzip, launch, authenticate, and complete a real run on a separate clean Mac.
- Decide whether production runs should isolate Codex from user-configured MCP servers or support and supervise those child processes explicitly.

No pull request created by these acceptance runs was merged automatically.
