# weekly-roundup (developer notes)

One skill, `/weekly-roundup`. It sweeps a week of work, writes a markdown log, and proposes Jira updates that the user approves row by row. User-facing setup is in `README.md`.

## Layout

- `skills/weekly-roundup/SKILL.md`: the workflow
- `skills/weekly-roundup/templates/`: `config.example.json`, `rules.md` (personal rules starter), `team-rules.md` (team rules starter), `week.md` (log template)
- `hooks/guard.sh`: PreToolUse on `mcp__.*`, the deterministic hard rules
- `hooks/record.sh`: PostToolUse on M365 tools, the call record for roundup runs
- `scripts/config-json`: config plus defaults as JSON
- `scripts/sweep-local.sh START END`: git/gh/clerk/transcript sweep with caps and a STATS block
- `scripts/run-stats.sh [RUN]`: M365 call table, errors and unread pages from the call record
- `tests/guard-test.sh`: guard self-test (classification, fail-closed, dates, parallel budgets)
- `tests/stats-test.sh`: recorder + unread-page detection self-test

## Invariants

- **Nothing posts to Jira or sends anything without approval.** The guard enforces it: M365 read-only allow-list (anything else is denied), Jira/Confluence writes return `ask`. A tool added to the allow-list must be read-only.
- **The guard fails closed.** Without `jq` it blocks every MCP call. If it can't parse the call, read a valid config (in a run), read or write the call record, or take the budget lock, it blocks. Atlassian is an allow-list of reads; anything else asks. M365 is an allow-list of reads; anything else is denied. Keep that true, and add a test to `tests/guard-test.sh` for every new rule.
- **Limits live in code, not prompts.** Caps are in `sweep-local.sh`; M365 budgets and date windows are in the guard; sweep stats come from the record, never from the model.
- **Portable:** bash, `jq`, `git`, `gh` only. No `date -j`/GNU-only flags, no Ruby, Python or Node. Do date math with `jq` (`strptime`/`mktime`).
- **No personal or company data in this repo.** Config, rules and logs live with each user; team rules live in the team's repo.

## Releasing

Bump `version` in `.claude-plugin/plugin.json` and in the root `.claude-plugin/marketplace.json` on every change. Installed copies refresh only when the version changes. Run both tests before committing.
