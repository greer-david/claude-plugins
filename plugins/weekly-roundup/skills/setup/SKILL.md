---
name: setup
description: Set up weekly-roundup for one person: check requirements, write the config (merging a team config if there is one), the rules file and shell aliases, then run the tests. Invoke on "set up weekly-roundup", "/weekly-roundup:setup", a team config file named for setup, or when /weekly-roundup finds no config.
argument-hint: "[path to a team-config.json]"
---

# Set up weekly-roundup

Paths are relative to the plugin root, two folders up from this file. Every write in this skill is shown to the user and confirmed first. Ask your questions in batches, not one at a time.

## 1. Check requirements

Start from a stock machine: assume only Claude Code and what it needs (Git for Windows on Windows), and check everything else. Find the OS first (`uname -s`; `MINGW*` or `MSYS*` is Windows) and give fixes for that OS: `winget install jqlang.jq GitHub.cli` on Windows (then restart the terminal and Claude Code so PATH picks them up), `brew install jq gh` on macOS, the package manager on Linux. On Windows, say the plugin hasn't been tested there yet (README.md, Requirements).

Check each and show a table: requirement, ok / missing, and the fix.

- `jq`, `git`, `gh` on PATH, and `gh auth status` signed in. These three block setup: if one is missing, show the fix and stop. Until `jq` is installed, the plugin's guard blocks every Jira and Microsoft 365 call in every session, so fix it first.
- **Atlassian MCP:** a loaded tool from a server whose name contains `atlassian`, `jira`, `confluence` or `rovo` (the guard recognises Jira by that name). Fix: `claude mcp add --transport http --scope user atlassian https://mcp.atlassian.com/v1/mcp`, then sign in. Offer to run it.
- **Microsoft 365:** `mcp__claude_ai_Microsoft_365__*` tools loaded. If they aren't, the connector is either not connected (claude.ai → Settings → Connectors) or turned off for this session (`ENABLE_CLAUDEAI_MCP_SERVERS=false`, which step 5 sets up on purpose). Roundups run without it and list it under Gaps.
- **clerk** (optional): `command -v clerk`.

Some fixes only the user can do: installs, `gh auth login`, signing in to Atlassian, connecting Microsoft 365 at claude.ai. If the `mattpocock-skills:wizard` skill is available, offer to build a wizard that walks them through those; otherwise give them as numbered steps.

Done when every row is ok, or missing with its fix shown.

## 2. Read the team config

Use the team config the user named. Otherwise look for `docs/weekly-roundup/team-config.json` in the current repo, and ask if there's none. No team config is fine: skip to step 3.

A team config is a partial `config.json` holding the team's shared values (Jira site and projects, `github_repos`, `m365.noise_senders`, `m365.alert_patterns`, `team_rules`). Take its values as given; they're the team's decisions. If its `team_rules` has no `repo`, the repo is the clone the team config was read from (`git rev-parse --show-toplevel`).

## 3. Gather personal values

Derive what you can, then show the whole list once for the user to confirm or correct:

- `jira.user`: the display name from Atlassian `atlassianUserInfo`. `jira.site` and `jira.project` from the team config, else ask (site is `<name>.atlassian.net`; project is the key tickets start with).
- `m365.my_addresses`: `git config user.email` and Microsoft 365 `get_me` if loaded; ask for aliases.
- `github_user`: `gh api user --jq .login`.
- `repos`: the local clones the user works in. Offer the team repo's clone and any sibling folder whose `origin` is in `github_repos`. Add each repo's GitHub `owner/name` to `github_repos`.
- `log_dir`: somewhere private, such as their own notes folder. A log holds summaries of other people's mail and chats, so it must be outside every shared repo: check with `git -C <dir> rev-parse --show-toplevel` and push back if it lands in one.
- `rules_file`: a personal file beside `log_dir`, not inside it.
- `clerk_dir`: clerk's `output.dir`, only if clerk is installed.
- `reviewers`: the names wording rules refer to (optional).

Done when every key in `skills/weekly-roundup/templates/config.example.json` has a confirmed value or is deliberately left out. Keys left out take the defaults in `scripts/config-json`; leave out `caps` and `budgets` unless the team config sets them.

## 4. Write the config

Build the config: team values, then personal values on top. Show the full JSON. If `~/.config/weekly-roundup/config.json` exists, show the diff instead and keep every existing key the user isn't changing. Write it after the user confirms, then run `scripts/config-json`. Done when it exits 0.

## 5. Rules and aliases

- Copy `skills/weekly-roundup/templates/rules.md` to `rules_file` if that file doesn't exist yet.
- Run `scripts/team-rules.sh`. The first line must be `STATUS: ok` (or `STATUS: none` with no team rules). On `missing` or `stale`, fix the path, ref or remote with the user and run it again.
- Offer the shell lines from README.md "Microsoft 365 only in roundup sessions". Pick the rc file from `$SHELL`, skip lines already there, and append after the user agrees. On Windows they go in Git Bash's `~/.bashrc`, and roundups start from Git Bash; tell the user this, since they may never have opened it.

## 6. Test and hand over

Run `for t in tests/*-test.sh; do bash "$t"; done`. Every line must say `ok`; show any failure in full.

Finish with what was written (config, rules file, rc lines) and the first run: open a new terminal so the aliases load, type `roundup-session`, then `/weekly-roundup --dry-run`, and read the log as README.md "First run" describes.
