# Auditorium v0 Manual Acceptance Evidence

Generated on June 7, 2026 with:

```sh
./script/export_screenshots.sh
```

The command builds the native macOS app with Xcode, launches it in screenshot export mode with an in-memory SwiftData store, and writes deterministic PNGs to `docs/acceptance/screenshots`.

## Visual Evidence

| Surface | Desktop | Compact |
| --- | --- | --- |
| Welcome | [desktop](screenshots/01-welcome-desktop.png) | [compact](screenshots/01-welcome-compact.png) |
| Dashboard | [desktop](screenshots/02-dashboard-desktop.png) | [compact](screenshots/02-dashboard-compact.png) |
| Tickets | [desktop](screenshots/03-tickets-desktop.png) | [compact](screenshots/03-tickets-compact.png) |
| Queue | [desktop](screenshots/04-queue-desktop.png) | [compact](screenshots/04-queue-compact.png) |
| Run Detail | [desktop](screenshots/05-run-detail-desktop.png) | [compact](screenshots/05-run-detail-compact.png) |
| Reports | [desktop](screenshots/06-reports-desktop.png) | [compact](screenshots/06-reports-compact.png) |
| Settings | [desktop](screenshots/07-settings-desktop.png) | [compact](screenshots/07-settings-compact.png) |
| Empty and Error States | [desktop](screenshots/08-empty-states-desktop.png) | [compact](screenshots/08-empty-states-compact.png) |

The desktop captures render at 1280x800 points, 2560x1600 pixels. The compact captures render at 1120x760 points, 2240x1520 pixels.

## Reviewed Locally

- The dashboard, ticket browser, queue, run detail, reports, settings, inspector, and empty/error states render at both window sizes.
- Long branch and pull request values truncate or wrap inside the inspector instead of overlapping adjacent columns.
- The compact run-detail view pins content to the top of the viewport and does not clip the title.
- Empty and blocked states include recovery copy for first-run, filtered, queued, and credential-blocked workflows.

## Still Requires Credentialed Manual Acceptance

These items are not proven by deterministic screenshots and remain tracked in `CHECKLIST.md`:

- A queued issue can produce a GitHub PR URL from a real repository.
- A real Codex CLI run can process one GitHub issue in a workspace and stream events into the app.
- A real issue run has a deterministic, inspectable workspace containing the repository at the expected branch.
- Completed ticket runs show real GitHub PR URLs.
- Copy, export, and reveal report actions need manual app verification.
- The full v0 real GitHub flow needs one final manual pass without leaving the app except OAuth/browser approval.
- Release build signing and launch on a clean Mac still need distribution credentials and a clean-machine check.
