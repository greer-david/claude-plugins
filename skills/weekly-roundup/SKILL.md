---
name: weekly-roundup
description: Build the weekly work log (Sun–Sat) and propose Jira updates for approval. Sweeps git/gh, Claude Code sessions (clerk summaries, raw transcripts as fallback) and Jira, applies the user's rules file, and posts nothing without row-by-row approval. Invoke on "/weekly-roundup", "weekly roundup", "what did I do this week", "draft my weekly update", "propose Jira updates for this week".
argument-hint: "[week-start YYYY-MM-DD] [--dry-run]"
---

# Weekly roundup

One run per week, Friday morning by default. The output is one markdown log. Jira writes happen only after the user approves specific rows.

## 0. Load config

Read `~/.config/weekly-roundup/config.yaml`. If it's missing, copy `templates/config.example.yaml` there, ask the user to fill it in, and stop. Keys:

- `log_dir`: where weekly logs go (one file per week, named by the week's start date)
- `rules_file`: the user's rules file (the template is `templates/rules.md`)
- `log_template`: optional override for `templates/week.md`
- `repos`: local repo paths; `github_repos`: `owner/name` for `gh`
- `clerk_dir`: clerk `output.dir` (optional)
- `transcripts_glob`: default `~/.claude/projects/*/*.jsonl`
- `skip_projects`: transcript or clerk slugs to ignore (substring match)
- `jira`: `site`, `project`, `user` (display name)
- `week_start_day`: `sunday` by default
- `reviewers`: the names used in wording rules
- `caps`: `findings_per_source` (40), `transcript_kb` (20), `emails` (150), `meetings` (60), `teams_threads` (60)
- `m365`: `noise_senders` (substrings or domains to drop), `mute_chats` (chat or channel names to skip)

## 1. Fix the window

- Default: the week (from `week_start_day`) that contains today. If today is before the week's last day, the window ends now, and anything after the run lands in next week's log as **late from last week**.
- An argument `YYYY-MM-DD` picks that week.
- Read the previous week's log (if any) and carry forward its open **Pending verification** items, the Jira rows it left unposted, and anything after its run time.
- If a log for this window already exists, update it in place. Never duplicate rows; keep the posted/skipped marks.

## 2. Load rules

Read `rules_file` completely. Every proposal below must follow it. Keep a list of the rule IDs you actually used; it goes into the log under `Rules applied`.

## 3. Sweep sources

Each source is swept by its own subagent on **Haiku** (`model: haiku`), all in parallel. Raw data stays inside the subagent. Each one returns at most `caps.findings_per_source` findings, one line each:

`date | source | repo/project | refs (PR #, PBI-###, person) | one-line outcome | done / in progress / open`

If a cap cuts results short, the subagent says so on its last line; record that under **Gaps**. If this week's log already exists, sweep only activity after its `run_at`.

1. **Git**: for each `repos` path, run `git log --all --author="$(git config user.email)" --since=<start> --until=<end> --format='%h %ad %s' --date=short`.
2. **GitHub**: for each `github_repos` entry, run `gh pr list -R <repo> --author @me --state all --search "updated:>=<start>" --json number,title,state,mergedAt,url,headRefName`, plus `gh search prs --reviewed-by @me --updated ">=<start>"` for reviews.
3. **Sessions**: the clerk summaries in `clerk_dir/summary/<YYYYMMDD>/*.md` for each day in the window. For any day with transcript activity (a `.jsonl` file modified that day) but no clerk summary, read those transcripts directly, but only the user turns and the final assistant message, up to `caps.transcript_kb` per session (use `jq`, never the whole file). Note under **Gaps** that clerk was behind. Skip `skip_projects`.
4. **Jira**: use the Atlassian MCP. Search the issues the user updated, commented on or was assigned in the window (`project = <project> AND (assignee = currentUser() OR updatedBy = currentUser()) AND updated >= <start>`), plus every ticket key mentioned by the other sources. Fetch each one's status, epic and owner, and nothing else.
5. **Microsoft 365** (the claude.ai connector, `mcp__claude_ai_Microsoft_365__*`, read tools only). If the tools aren't loaded, the session was started without connectors. Tell the user to restart with `env -u ENABLE_CLAUDEAI_MCP_SERVERS claude "/weekly-roundup"`, or carry on and list M365 under Gaps. Split it across three subagents:
   - **Email** (`outlook_email_search`, window only): everything the user sent, and everything received from real people or real groups/distribution lists. Drop automated mail: senders matching `m365.noise_senders`, no-reply addresses, notifications, newsletters, calendar notices, delivery reports. Read at most `caps.emails` messages, newest first, previews before full bodies. Return two kinds of findings: **work done** (what the user delivered, decided or answered) and **possibly missed** (asks, questions or commitments addressed to the user with no reply from them in the thread).
   - **Calendar** (`outlook_calendar_search`): meetings the user attended or organized. Skip all-day, OOO, declined and cancelled events. At most `caps.meetings`.
   - **Teams** (`chat_message_search`, `teams_list_chats`, `teams_list_channel_messages`): chats and channels with activity in the window from real people. Skip `m365.mute_chats` and bot posts. At most `caps.teams_threads` threads. Same two kinds of findings as email.
   - Also run `sharepoint_search` for files the user edited in the window (decks, docs), at most 20 results.
6. **Not available**: Claude web chats. Always list them under Gaps.

## 4. Verify and classify

This step and step 5 run in the main session, which only ever sees the findings lines.


- Check every PR's scope and state with `gh pr view` before you describe it. Don't trust session summaries for scope.
- Group the findings by theme (one theme per model, epic or workstream).
- Classify after-hours and weekend items with the classification rules. Ambiguous items go into the review as questions, never guesses.
- Drop small items according to the scope rules.
- **Possibly missed** findings go into their own log section and never become Jira rows directly. The user decides what to do with them.

## 5. Write the log

Fill in `templates/week.md` (or `log_template`), keeping the section order. Write it to `<log_dir>/<week-start>.md`. Fill in the frontmatter, including `jira_proposed` (the row count) and `jira_posted: 0`.

Jira proposals: number the rows continuously. Each row has the ticket, the action (comment / status / new ticket / link-merge), the exact text in a quote block, the sources, and a confidence (high/med/low). Put them in three groups: **Review closely**, **Quick skim**, **Not posting (why)**. Status changes, new tickets and merges always go in a separate **Needs explicit approval** list, never in a group.

## 6. Review and approval

Show the user the path and the leadership summary, then ask for approvals in the form `post 1-6, 9`.

- Post only the rows named. Status, new-ticket and merge rows also need their own explicit "yes" each.
- If the user edits a row's text, post the edited text.
- After posting, mark each row in the log `✅ posted <date>` or `⏭ skipped`, and update `jira_posted`.
- With `--dry-run`, write the log and stop before approval.

## 7. Learning step

Look at what the user corrected: edited text, rejected rows, reclassified items, wrong tickets. Propose rule changes under **Rule changes proposed** using the rules-file format (`ID [team|personal] rule`), each naming the rule it replaces or merges with, or saying `new`. Write them to the rules file only after the user approves them. Never change rules silently.

## Hard rules

`hooks/guard.sh` enforces these outside the model: Microsoft 365 tools are on a read-only allow-list (everything else is denied), and every Jira/Confluence write needs a permission prompt. If the guard denies a call, don't look for another route; report it.

- Never post, transition, create or link in Jira without approval in this run.
- Never send email or messages. The leadership summary is text the user sends.
- Comments post under the user's name and the whole project sees them. Keep them factual.
- Respect the permission zones of the repo where the log lives (e.g. the vault's `CLAUDE.md`).
