# weekly-roundup

A Claude Code plugin with one skill, `/weekly-roundup`. It sweeps a week of work (git, gh, Claude Code sessions, Jira), writes a markdown log, and proposes Jira updates that the user approves row by row.

## Layout

- `.claude-plugin/plugin.json`, `marketplace.json`: the plugin and a single-plugin marketplace (install from a local path or the git repo)
- `skills/weekly-roundup/SKILL.md`: the workflow
- `skills/weekly-roundup/templates/`: `config.example.yaml`, `rules.md` (starter rules), `week.md` (log template)

## Conventions

- No personal data in this repo. Rules, logs and config live with each user (`~/.config/weekly-roundup/config.yaml` points at them).
- Rules are tagged `[team]` or `[personal]`. Shared team rules will later live here as `rules/team.md`, changed by PR.
- Nothing posts to Jira without approval. Keep that invariant in every change.
- `hooks/guard.sh` (PreToolUse on `mcp__.*`) enforces the hard rules: Microsoft 365 uses a read-only allow-list and every other M365 tool is denied; Jira/Confluence writes return `ask`. When you add a tool to the allow-list, it must be read-only. Test with `printf '{"tool_name":"<name>"}' | hooks/guard.sh`.

## Microsoft 365 without always-on connectors

Keep claude.ai connectors off by default with `export ENABLE_CLAUDEAI_MCP_SERVERS=false` in your shell profile; don't use `disableClaudeAiConnectors`, because any `true` wins and can't be overridden per session. Connect Microsoft 365 at claude.ai → Settings → Connectors, then run the roundup with:

```
env -u ENABLE_CLAUDEAI_MCP_SERVERS claude "/weekly-roundup"
```

## Install (local)

```
/plugin marketplace add ~/repos/weekly-roundup
/plugin install weekly-roundup@weekly-roundup
```
