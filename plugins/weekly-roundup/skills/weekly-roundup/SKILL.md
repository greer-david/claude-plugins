---
name: weekly-roundup
description: Build the weekly work log (Sun–Sat) and propose Jira updates for approval. Sweeps git/gh, Claude Code sessions (clerk summaries, raw transcripts as fallback) and Jira, applies the user's rules file, and posts nothing without row-by-row approval. Invoke on "/weekly-roundup", "weekly roundup", "what did I do this week", "draft my weekly update", "propose Jira updates for this week".
argument-hint: "[week-start YYYY-MM-DD] [--dry-run] [--calibrate <manual-log>]"
---

# Weekly roundup

One run per week, Friday morning by default. The output is one markdown log. Jira writes happen only after the user approves specific rows.

## 0. Load config

Run `scripts/config-json` (in the plugin root). It prints `~/.config/weekly-roundup/config.json` with defaults merged in. If it fails because the file is missing, copy `templates/config.example.json` there, ask the user to fill it in, and stop. Keys:

- `log_dir`: where weekly logs go (one file per week, named by the week's start date)
- `team_rules_file`: shared team rules, kept in a team repo and changed by PR (optional)
- `rules_file`: the user's personal rules (the template is `templates/rules.md`)
- `log_template`: optional override for `templates/week.md`
- `repos`: local repo paths; `github_repos`: `owner/name` for `gh`; `github_user`: the `gh` account to read with (its token is used without switching the active account)
- `clerk_dir`: clerk `output.dir` (optional)
- `transcripts_dir`: default `~/.claude/projects`
- `skip_projects`: transcript or clerk slugs to ignore (substring match)
- `jira`: `site`, `project`, `user` (display name)
- `week_start_day`: `sunday` by default
- `reviewers`: the names used in wording rules
- `caps`: `transcript_kb` (96), `clerk_kb` (60), `commits_per_repo` (100), enforced by `scripts/sweep-local.sh`; `findings_per_source` (40), a limit for the sweep subagents. `scripts/config-json` rejects invalid values.
- `budgets`: maximum calls per M365 tool per run (e.g. `outlook_email_search: 12`, `read_resource: 40`, `default: 3`); `max_window_days` (8). Enforced by `hooks/guard.sh`.
- `m365`: `include_self_chat` (true), `noise_senders` (substrings or domains to drop), `mute_chats` (chat or channel names to skip), `alert_patterns` (subject substrings of automated mail to surface instead of drop)

## 1. Fix the window


- Default: the week (from `week_start_day`) that contains today. If today is before the week's last day, the window ends now, and anything after the run lands in next week's log as **late from last week**.
- An argument `YYYY-MM-DD` picks that week.
- Read the previous week's log (if any) and carry forward its open **Pending verification** items, the Jira rows it left unposted, and anything after its run time.
- If a log for this window already exists, update it in place. Never duplicate rows; keep the posted/skipped marks.

## 2. Load rules

Read `team_rules_file` (if set), then `rules_file`, completely. Every proposal below must follow both. When they conflict, the personal rule wins. Note the conflict under Gaps so the user can raise it with the team. If `team_rules_file` is set but missing, say so and continue with personal rules only. It usually means the team repo isn't pulled or the path is wrong. Keep a list of the rule IDs you actually used; it goes into the log under `Rules applied`.

## 3. Sweep sources

Each source is swept by its own subagent on **Haiku** (`model: haiku`), all in parallel. Raw data stays inside the subagent. Each one returns at most `caps.findings_per_source` findings (a summarizing limit the subagent follows, not one enforced in code), one line each:

`date | source | repo/project | refs (PR #, KEY-###, person) | one-line outcome | done / in progress / open`

If this week's log already exists, sweep only activity after its `run_at`.

1. **Local (git, GitHub, sessions)**: one subagent runs `scripts/sweep-local.sh <start> <end>` and turns its output into findings. The script is the only way to read these sources. Don't run your own `git log`, `gh` or transcript reads. It dedupes commits across worktrees, uses clerk summaries and falls back to transcripts (user turns plus final reply), and applies the size caps (`transcript_kb`, `clerk_kb`, `commits_per_repo`) in code. Return its `## STATS` block verbatim along with the findings.
2. **Jira**: use the Atlassian MCP. Search the issues the user updated, commented on or was assigned in the window (`project = <project> AND (assignee = currentUser() OR updatedBy = currentUser()) AND updated >= <start>`), plus every ticket key mentioned by the other sources. Fetch each one's status, epic and owner, and nothing else.
3. **Microsoft 365** (the claude.ai connector, `mcp__claude_ai_Microsoft_365__*`, read tools only). If the tools aren't loaded, the session was started without connectors. Tell the user to restart with the `roundup` alias (see the plugin README), or carry on and list M365 under Gaps. In a roundup run the guard hook enforces call budgets, and every search must pass ISO `afterDateTime`/`beforeDateTime` covering the window (max `max_window_days`). Plan calls to fit the budget: `limit: 25`, paging with `offset`. When a call is denied for budget, stop that source and note it under Gaps. Each M365 subagent also returns a **Dropped** list: sender or chat, count and reason (e.g. `noreply@x.com · 14 · automated`). Split it across three subagents:
   - **Email** (`outlook_email_search`, window only): everything the user sent, and everything received from real people or real groups/distribution lists. Drop automated mail: senders matching `m365.noise_senders`, no-reply addresses, notifications, newsletters, calendar notices, delivery reports. Search **all folders**: never set `folderName`, because mail filed to other folders is otherwise missed. **Fixed plan:** one query per day in the window (`afterDateTime` = that day, `beforeDateTime` = the next day, `query: "*"`, `limit: 25`), paged with `offset` until the response has no `nextOffset`. Don't stop early and don't summarize until every day is paged. Work from search previews; use `read_resource` only for threads that look like work done or a possibly-missed ask. Automated mail matching `m365.alert_patterns` (e.g. refresh failures) is not dropped; it goes under possibly missed. A possibly-missed ask needs the user in **To** or addressed by name. Asks where the user is only cc'd or that are addressed to a team or distribution list count as context, not possibly missed. Return two kinds of findings: **work done** (what the user delivered, decided or answered) and **possibly missed** (asks, questions or commitments addressed to the user with no reply from them in the thread).
   - **Calendar** (`outlook_calendar_search`): meetings the user attended or organized. Skip all-day, OOO, declined and cancelled events, personal blocks (lunch, focus time) and routine recurring meetings (stand-ups, office hours) unless the user presented or something was decided. 
   - **Teams** (`chat_message_search`, `teams_list_chats`, `teams_list_channel_messages`): chats and channels with activity in the window from real people. **Fixed plan:** one `chat_message_search` per day (`query: "*"`, day window, `limit: 25`), paged until no `nextOffset`. Skip `m365.mute_chats` and bot posts. Include the user's own notes-to-self chat (id `48:notes`, or the 1:1 chat whose only member is the user) when `m365.include_self_chat` is true (default): its messages are work done, open questions or plans, never possibly missed. `chat_message_search` already covers channels you're a member of. If `teams_list_teams` returns 403 (the connector lacks `Team.ReadBasic.All`), don't retry it or the channel tools; rely on search. Same two kinds of findings as email.
   - Also run `sharepoint_search` for documents modified in the window that the user authored **or** that came up in the email and Teams findings (by file name).
4. **Not available**: Claude web chats. Always list them under Gaps.

## 4. Verify and classify

This step and step 5 run in the main session, which only ever sees the findings lines.

- Check every PR's scope and state with `gh pr view` before you describe it. Don't trust session summaries for scope.
- Group the findings by theme (one theme per model, epic or workstream).
- Classify after-hours and weekend items with the classification rules. Ambiguous items go into the review as questions, never guesses.
- Drop small items according to the scope rules.
- **Possibly missed** findings go into their own log section and never become Jira rows directly. The user decides what to do with them.

## 5. Write the log

Fill in `templates/week.md` (or `log_template`), keeping the section order. Write it to `<log_dir>/<week-start>.md`. Fill in the frontmatter, including `jira_proposed` (the row count) and `jira_posted: 0`.

After the M365 subagents return, run `scripts/run-stats.sh`. If it lists **unread pages**, send that subagent back to fetch them (within budget) before writing the log. Whatever is still unread goes under Gaps.

**Sweep stats** are copied from code output, never written by you: paste the local `## STATS` block, then the output of `scripts/run-stats.sh` (M365 calls, budgets, KB read, denials from the hook record), then the M365 subagents' Dropped lists.

Jira proposals: number the rows continuously. Each row has the ticket, the action (comment / status / new ticket / link-merge), the exact text in a quote block, the sources, and a confidence (high/med/low). Put them in three groups: **Review closely**, **Quick skim**, **Not posting (why)**. Status changes, new tickets and merges always go in a separate **Needs explicit approval** list, never in a group.

## 6. Review and approval

Show the user the path and the leadership summary, then ask for approvals in the form `post 1-6, 9`.

- Post only the rows named. Status, new-ticket and merge rows also need their own explicit "yes" each.
- If the user edits a row's text, post the edited text.
- After posting, mark each row in the log `✅ posted <date>` or `⏭ skipped`, and update `jira_posted`.
- With `--dry-run`, write the log and stop before approval.

## 7. Learning step

Look at what the user corrected: edited text, rejected rows, reclassified items, wrong tickets, and "you missed X". For a miss, check the sweep stats: if a cap or budget was hit, or the item's sender is in a Dropped list, propose a **config change** (`budgets`, `caps`, `m365.noise_senders`) instead of a rule. Propose rule changes under **Rule changes proposed** using the rules-file format (`ID [team|personal] rule`), each naming the rule it replaces or merges with, or saying `new`. Write them only after the user approves them. Never change rules silently. `[personal]` rules go into `rules_file`. `[team]` rules are **never edited in place**: write the approved change as a ready-to-apply diff of `team_rules_file` in the log under Rule changes proposed, and tell the user to open a PR in the team repo.

## Calibration

`--calibrate <manual-log-path>`: run as `--dry-run` for that log's week with a **full sweep** (ignore any existing log's `run_at`, and overwrite that log), then diff. Also read any `<log_dir>/calibration/<week-start>-*.md` files as additional ground truth. List items in the manual log that the skill missed, with the cap, budget or filter that hid each one per the sweep stats, and items the skill added that look like noise. Propose `config.json` changes. Write nothing else.

## Hard rules

`hooks/guard.sh` enforces these outside the model: Microsoft 365 tools are on a read-only allow-list (everything else is denied), and every Jira/Confluence write needs a permission prompt. In a roundup run it also enforces M365 call budgets and date windows, and records every call. If the guard denies a call, don't look for another route; report it.

- Never post, transition, create or link in Jira without approval in this run.
- Never send email or messages. The leadership summary is text the user sends.
- Comments post under the user's name and the whole project sees them. Keep them factual.
- Respect the permission zones of the repo where the log lives (e.g. the vault's `CLAUDE.md`).
