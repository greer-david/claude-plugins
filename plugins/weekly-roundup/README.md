# weekly-roundup

Once a week, `/weekly-roundup` collects what you did and writes a log you can use for status updates and Jira. It looks at:

- your git commits and GitHub PRs and reviews
- your Claude Code sessions (clerk summaries if you use clerk, otherwise the session transcripts) in your configured repos
- Jira tickets you touched
- Microsoft 365 (Outlook, calendar, Teams, SharePoint) through the claude.ai connector

It writes the log to a folder you choose. The log has a leadership summary, work by theme, "possibly fell through the cracks" (asks you haven't answered) and proposed Jira updates. Nothing goes to Jira until you approve specific rows ("post 1-4, 7").

## What installing it changes in every session

The plugin adds a safety hook that runs in **all** your Claude Code sessions, not just roundups:

- **Microsoft 365 is read-only.** Sending, deleting or editing mail, calendar events, files or Teams messages through the claude.ai connector is blocked.
- **Every Jira or Confluence write asks you first**, even in auto mode.
- If the hook can't run (for example, `jq` is missing), it **blocks** Microsoft 365 and Atlassian calls rather than letting them through.

In roundup sessions it also limits how many Microsoft 365 calls each tool can make, caps the total size of Microsoft 365 and Jira results a run reads (`budgets.total_kb`, 1 MB by default), and keeps searches to the span being swept. It records every call so the log's stats come from code, not from the model, and removes mail and Teams messages that match your noise and mute settings before the model reads them.

## Requirements

- macOS, Linux or WSL with `bash`, `jq`, `git` and `gh` (signed in to the GitHub account that sees your work repos)
- The Atlassian MCP server in Claude Code, for Jira (setup step 2)
- For Microsoft 365: the claude.ai **Microsoft 365** connector, connected at claude.ai → Settings → Connectors
- Optional: [clerk](https://github.com/vulcanshen/clerk) for session summaries

## Setup

1. **Install**

   ```
   /plugin marketplace add greer-david/claude-plugins
   /plugin install weekly-roundup@greer-plugins
   ```

   Choose **user** scope.

2. **Jira.** Add Atlassian's MCP server at user scope and sign in when it asks:

   ```
   claude mcp add --transport http --scope user atlassian https://mcp.atlassian.com/v1/mcp
   ```

   Keep `atlassian` (or `jira`, `confluence`, `rovo`) in the server's name: the safety hook recognises Jira tools by that name. Your site is the `<name>.atlassian.net` part of your Jira URL. Your project is the key your team's tickets start with (`ABC` in `ABC-123`). If they're split across projects (say, mid-migration), list them: `"project": ["NEW", "OLD"]`. New tickets go in the first.

3. **Config.** Copy `skills/weekly-roundup/templates/config.example.json` to `~/.config/weekly-roundup/config.json` and fill it in: log folder, repos, Jira project, and your team's rules file. `session_dirs` lists the folders whose Claude Code sessions are swept (default: your `repos`); see Privacy. Put your email addresses (aliases too) in `m365.my_addresses`: an email only counts as possibly missed when you're in its To line. `m365.mute_chats` takes Teams chat IDs (like `19:abc@thread.v2`), not chat names: in Teams, use **Copy link** on any message in the chat; the ID is the part of the link that starts with `19:`. `/weekly-roundup` will offer to do this on first run.

4. **Rules.**
   - **Team rules** live in your team's repo (for example `docs/weekly-roundup/team-rules.md`) and change by PR. Point `team_rules_file` at your local clone. If your team doesn't have the file yet, add one from `templates/team-rules.md` by PR, or leave `team_rules_file` out until it's merged; a path that doesn't exist is reported in every log.
   - **Personal rules:** copy `templates/rules.md` to wherever `rules_file` points. It starts empty and grows from your corrections.

5. **Microsoft 365 only in roundup sessions (recommended).** Keep claude.ai connectors out of your everyday sessions and turn them on just for roundups. Add to `~/.zshrc` (or `~/.bashrc`):

   ```
   export ENABLE_CLAUDEAI_MCP_SERVERS=false
   alias roundup='env -u ENABLE_CLAUDEAI_MCP_SERVERS WEEKLY_ROUNDUP_RUN=$(date +%Y%m%dT%H%M%S) claude "/weekly-roundup"'
   alias roundup-session='env -u ENABLE_CLAUDEAI_MCP_SERVERS WEEKLY_ROUNDUP_RUN=$(date +%Y%m%dT%H%M%S) claude'
   ```

   Don't use the `disableClaudeAiConnectors` setting for this. Once it's `true` anywhere, nothing can turn connectors back on for one session.

6. **Check the hook works:** from the installed plugin folder, run every test: `for t in tests/*-test.sh; do bash "$t"; done` (approval, calibration, filter, guard, stats, sweep, window). Every line should say `ok`. Contributors on a Mac can run the same tests on Linux with `tests/linux.sh` (needs Docker).

## First run

1. Type `roundup-session`, then `/weekly-roundup --dry-run`. It sweeps, writes the log and stops before proposing anything to Jira.
2. Check the log: is the window at the top what you expected? Are the themes your real work? Read the sweep stats and the Dropped table: a hit cap or budget, or a sender you care about being dropped, means a config change. Anything under "possibly fell through the cracks" you already handled is a rule to add.
3. When the log looks right, type `roundup` for the real run. A dry run's log doesn't count as covered, so the real run sweeps the same span again and updates the same log. Approve rows with a message that is just `post 1-4`.

## Weekly use

- **Friday morning:** open a new terminal tab in your notes folder and type `roundup`. Review the log, then approve proposals with a message that is just `post 1-6, 9`. Status changes, new tickets and links must be named one by one (`post 12`). Only what you approved, with exactly the text in the log, can be posted, and Claude Code still asks before each post. If you edit a proposal, approve it again.
- **A different week:** run `roundup-session`, then `/weekly-roundup 2026-10-18`.
- **What each run covers:** from where your last log left off until now, so nothing is swept twice or skipped. Anything that happened before this week (say, Friday afternoon after last week's run) goes in this week's log, marked late. If your last run was over two weeks ago, the run starts at this week's start and tells you what it didn't cover; `/weekly-roundup --since 2026-10-01` covers more.
- **Dry run:** `/weekly-roundup --dry-run` writes the log and stops before approval. The next run sweeps that span again.
- **Tuning:** `/weekly-roundup <week> --calibrate <manual-log>` compares a run with a roundup you did by hand and proposes config changes.

Your corrections become rule proposals at the end of each run. Personal rules are written after you approve them. Team rule changes come out as a diff for you to open as a PR in the team repo.

## Privacy

Your config, rules, logs and call record stay on your machine: logs go to the folder in your config, the call record to `~/.local/state/weekly-roundup/`. The run itself is not local. What it sweeps (mail, Teams, Jira, commits, session text) is sent to the model provider as part of the Claude Code session, and mail, Teams and Jira are read through their hosted connectors. Each person sweeps only their own sources.

Sessions are swept only from the folders in `session_dirs` (default: your `repos`), so sessions in personal projects stay out. Set it to `["~"]` to include every session.
