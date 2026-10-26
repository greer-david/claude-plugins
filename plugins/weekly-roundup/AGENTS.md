# weekly-roundup (developer notes)

One skill, `/weekly-roundup`. It sweeps a week of work, writes a markdown log, and proposes Jira updates that the user approves row by row. User-facing setup is in `README.md`.

## Layout

- `skills/weekly-roundup/SKILL.md`: the workflow
- `skills/weekly-roundup/templates/`: `config.example.json`, `rules.md` (personal rules starter), `team-rules.md` (team rules starter), `week.md` (log template)
- `hooks/guard.sh`: PreToolUse on `mcp__.*`, the deterministic hard rules
- `hooks/approve.sh`: UserPromptSubmit; in a run, turns a prompt that is exactly `post <numbers>` into approvals (the exact Jira write each named proposal shows) in the run's `approvals.jsonl`
- `hooks/lib.sh`: sourced by the hooks; `classify` (tool name to m365/atlassian and tool key, one rule for guard and recorder) and `take_lock` (the run lock: an `ln -s` symlink naming its holder; a dead holder's lock is reclaimed under a second lock and only if unchanged)
- `hooks/record.sh`: PostToolUse on MCP tools; for M365 and Atlassian, the call record for roundup runs (result bytes feed the guard's `budgets.total_kb` ceiling), and the noise filter (`noise_senders`, `alert_patterns`, `mute_chats` by chat ID) that rewrites email and chat search results via `updatedMCPToolOutput` and records Dropped counts
- `scripts/config-json`: config plus defaults as JSON
- `scripts/start-run.sh [--week D | --since X]`: fixes the run's window once (run_at, week_start, window_start, window_end) in the run's state; the guard, the sweep and check-log read it
- `scripts/sweep-local.sh [SINCE UNTIL]`: git/gh/clerk/transcript sweep of the window, with caps, `[late]` marks and a STATS block
- `scripts/check-log.sh LOG`: fails if the log's window frontmatter differs from the run's, or a possibly-missed item lacks a source tag, or an email one wasn't opened in the run with the user in To
- `scripts/run-stats.sh [RUN]`: M365 call table, errors, unread pages and omitted days (window days no successful email or chat search covered) from the call record
- `tests/guard-test.sh`: guard self-test (classification, fail-closed, dates, parallel budgets)
- `tests/stats-test.sh`: recorder (errors, classification) + unread-page and omitted-day detection self-test
- `tests/filter-test.sh`: noise filter + Dropped table self-test
- `tests/sweep-test.sh`: sweep-local GitHub sections with a stubbed `gh`
- `tests/window-test.sh`: start-run window rules + check-log self-test
- `tests/approval-test.sh`: approve.sh + guard approval binding self-test

## Invariants

- **Nothing posts to Jira or sends anything without approval.** The guard enforces it: M365 read-only allow-list (anything else is denied), Jira/Confluence writes return `ask`. A tool added to the allow-list must be read-only.
- **The guard fails closed.** Without `jq` it blocks every MCP call. If it can't parse the call, read a valid config (in a run), read or write the call record, or take the budget lock, it blocks. Atlassian is an allow-list of reads; anything else asks. In a roundup run, an Atlassian write must also match an unused approval exactly (comment, status, new ticket or link, no extra options) or it is denied; a match still asks. The approval hook can't tell a human prompt from an agent message, so never drop the ask (docs/adr/0002). M365 is an allow-list of reads; anything else is denied. Keep that true, and add a test to `tests/guard-test.sh` for every new rule.
- **Limits live in code, not prompts.** Caps are in `sweep-local.sh`; M365 budgets, the per-run KB ceiling (M365 + Atlassian), date windows and the run window are in the guard; run_at and the window come from `start-run.sh`, never from the model; sweep stats and Dropped counts come from the record, never from the model.
- **Portable:** bash, `jq`, `git`, `gh` only. No `date -j`/GNU-only flags, no Ruby, Python or Node. Do date math with `jq` (`strptime`/`mktime`).
- **No personal or company data in this repo.** Config, rules and logs live with each user; team rules live in the team's repo.

## Releasing

Bump `version` in `.claude-plugin/plugin.json` and in the root `.claude-plugin/marketplace.json` on every change. Installed copies refresh only when the version changes. Run every test in `tests/` before committing.
