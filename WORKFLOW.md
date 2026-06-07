---
tracker:
  kind: github
  active_states: ["open"]
  terminal_states: ["closed"]
polling:
  interval_ms: 30000
workspace:
  root: ".auditorium/symphony-workspaces"
validation:
  command: "cargo test --all-targets"
agent:
  max_concurrent_agents: 3
  max_turns: 1
  max_retry_backoff_ms: 300000
codex:
  command: "codex exec --json --sandbox workspace-write -c approval_policy=\"never\""
branch_prefix: "auditorium"
max_retries: 2
run_tests: true
open_pull_request: true
---
You are working on GitHub issue {{ issue.identifier }} in {{ issue.repo }}.

Read the issue carefully, inspect the repository, make the smallest correct change, run relevant tests, commit the changes, and open a pull request for human review.

Do not make unrelated changes. Do not touch secrets. When blocked, explain exactly what is missing.
