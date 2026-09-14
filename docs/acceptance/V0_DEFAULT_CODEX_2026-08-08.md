# Default Codex Isolation Acceptance

Captured on August 8, 2026 with Codex CLI 0.144.6 and the local v0 integration candidate at `92e7baeefd6739a28577c29e6be30ca1a5e5d9bf`.

## Setup

- The test used the normal authenticated `CODEX_HOME`; it did not create a temporary Codex home or authentication link.
- The desktop Codex host was active with local `xcodebuildmcp` and `mcp-remote` child processes, so configured MCP services were present elsewhere in the normal desktop session.
- Auditorium invoked the default command added by [PR #28](https://github.com/charliewilco/Auditorium/pull/28):

```sh
codex exec --json --ephemeral --ignore-user-config --disable apps --disable plugins --sandbox workspace-write -c approval_policy="never"
```

## App-To-Pull-Request Result

The opt-in macOS test `liveAppRunCoordinatorUsesRealSymphonyQueueWhenConfigured()` ran the real `AppRunCoordinator → Symphony → Codex → validation → GitHub pull request` path for [issue #29](https://github.com/charliewilco/Auditorium/issues/29).

- Xcode reported `** TEST SUCCEEDED **` after 134.14 seconds.
- Repeated `ps` snapshots during the agent phase showed only `Auditorium → symphony → codex` in the run-owned process tree. The run-owned Codex process had no child process, so it did not launch any local MCP server.
- The run created [PR #30](https://github.com/charliewilco/Auditorium/pull/30) at `334ddb5063841d8ec98c6f01d368ac512933a3d6`.
- The app test asserted persisted queue, running-state, `codex_started`, `codex_completed`, pull-request, report, completed-run, and terminal inspector state.
- The temporary mode-0600 GitHub credential config was unlinked after the test, and all run-owned processes exited.
- PR #30 passed the hosted Swift package and Symphony CI jobs.

## Tool-Availability Probe

A separate normal-home probe used the same isolation flags with a read-only sandbox and asked Codex to name every MCP, app, or plugin tool visible to the session. The agent reported only the platform-provided `image_gen.imagegen` and `web.run` tools; it reported none of the user-configured local MCP tools that were active under the desktop host. The probe exited successfully and launched no local MCP child process.

## Proof Boundary

This evidence proves that the Auditorium-owned default run ignored user configuration and did not inherit or launch the desktop session's local MCP services. Platform-provided built-in tools remained available. This does not prove fresh interactive GitHub browser authentication, notarization, Gatekeeper acceptance, or clean-Mac installation.
