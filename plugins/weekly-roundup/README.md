# weekly-roundup

Once a week, `/weekly-roundup` collects what you did and writes a log you can use for status updates and Jira. It looks at:

- your git commits and GitHub PRs and reviews
- your Claude Code sessions (clerk summaries if you use clerk, otherwise the session transcripts)
- Jira tickets you touched
- Microsoft 365 (Outlook, calendar, Teams, SharePoint) through the claude.ai connector

It writes the log to a folder you choose. The log has a leadership summary, work by theme, "possibly fell through the cracks" (asks you haven't answered) and proposed Jira updates. Nothing goes to Jira until you approve specific rows ("post 1-4, 7").

## What installing it changes in every session

The plugin adds a safety hook that runs in **all** your Claude Code sessions, not just roundups:

- **Microsoft 365 is read-only.** Sending, deleting or editing mail, calendar events, files or Teams messages through the claude.ai connector is blocked.
- **Every Jira or Confluence write asks you first**, even in auto mode.
- If the hook can't run (for example, `jq` is missing), it **blocks** Microsoft 365 and Atlassian calls rather than letting them through.

In roundup sessions it also limits how many Microsoft 365 calls each tool can make and keeps searches to the week being swept. It records every call so the log's stats come from code, not from the model, and removes mail and Teams messages that match your noise and mute settings before the model reads them.

## Requirements

- macOS, Linux or WSL with `bash`, `jq`, `git` and `gh` (signed in to the GitHub account that sees your work repos)
- The Atlassian MCP server in Claude Code, for Jira
- For Microsoft 365: the claude.ai **Microsoft 365** connector, connected at claude.ai → Settings → Connectors
- Optional: [clerk](https://github.com/vulcanshen/clerk) for session summaries

## Setup

1. **Install**

   ```
   /plugin marketplace add greer-david/claude-plugins
   /plugin install weekly-roundup@greer-plugins
   ```

   Choose **user** scope.

2. **Config.** Copy `skills/weekly-roundup/templates/config.example.json` to `~/.config/weekly-roundup/config.json` and fill it in: log folder, repos, Jira project, and your team's rules file. `m365.mute_chats` takes Teams chat IDs (like `19:abc@thread.v2`), not chat names: in Teams, use **Copy link** on any message in the chat; the ID is the part of the link that starts with `19:`. `/weekly-roundup` will offer to do this on first run.

3. **Rules.**
   - **Team rules** live in your team's repo (for example `docs/weekly-roundup/team-rules.md`, started from `templates/team-rules.md`) and change by PR. Point `team_rules_file` at your local clone.
   - **Personal rules:** copy `templates/rules.md` to wherever `rules_file` points. It starts empty and grows from your corrections.

4. **Microsoft 365 only in roundup sessions (recommended).** Keep claude.ai connectors out of your everyday sessions and turn them on just for roundups. Add to `~/.zshrc` (or `~/.bashrc`):

   ```
   export ENABLE_CLAUDEAI_MCP_SERVERS=false
   alias roundup='env -u ENABLE_CLAUDEAI_MCP_SERVERS WEEKLY_ROUNDUP_RUN=$(date +%Y%m%dT%H%M%S) claude "/weekly-roundup"'
   alias roundup-session='env -u ENABLE_CLAUDEAI_MCP_SERVERS WEEKLY_ROUNDUP_RUN=$(date +%Y%m%dT%H%M%S) claude'
   ```

   Don't use the `disableClaudeAiConnectors` setting for this. Once it's `true` anywhere, nothing can turn connectors back on for one session.

5. **Check the hook works:** run each script in `tests/` (`guard-test.sh`, `stats-test.sh`, `filter-test.sh`, `window-test.sh`, `approval-test.sh`) from the installed plugin folder. Every line should say `ok`.

## Weekly use

- **Friday morning:** open a new terminal tab in your notes folder and type `roundup`. Review the log, then approve proposals with a message that is just `post 1-6, 9`. Status changes, new tickets and links must be named one by one (`post 12`). Only what you approved, with exactly the text in the log, can be posted, and Claude Code still asks before each post. If you edit a proposal, approve it again.
- **A different week:** run `roundup-session`, then `/weekly-roundup 2026-10-18`.
- **What each run covers:** from where your last log left off until now, so nothing is swept twice or skipped. Anything that happened before this week (say, Friday afternoon after last week's run) goes in this week's log, marked late. If your last run was over two weeks ago, the run starts at this week's start and tells you what it didn't cover; `/weekly-roundup --since 2026-10-01` covers more.
- **Dry run:** `/weekly-roundup --dry-run` writes the log and stops before approval.
- **Tuning:** `/weekly-roundup <week> --calibrate <manual-log>` compares a run with a roundup you did by hand and proposes config changes.

Your corrections become rule proposals at the end of each run. Personal rules are written after you approve them. Team rule changes come out as a diff for you to open as a PR in the team repo.

## Privacy

Everything stays on your machine. Each person sweeps only their own mail, Teams, repos and sessions. Logs go to the folder in your config; the call record goes to `~/.local/state/weekly-roundup/`.
