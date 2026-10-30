---
name: weekly-roundup
description: Build the weekly work log (Sun–Sat) and propose Jira updates for approval. Sweeps git/gh, Claude Code sessions (clerk summaries, raw transcripts as fallback) and Jira, applies the user's rules file, and posts nothing without row-by-row approval. Invoke on "/weekly-roundup", "weekly roundup", "what did I do this week", "draft my weekly update", "propose Jira updates for this week".
argument-hint: "[week-start YYYY-MM-DD | --since DATE-OR-ISO] [--dry-run] [--calibrate <manual-log>]"
---

# Weekly roundup

One run per week, Friday morning by default. The output is one markdown log. Jira writes happen only after the user approves specific rows.

## 0. Load config

Run `scripts/config-json` (in the plugin root). It prints `~/.config/weekly-roundup/config.json` with defaults merged in. If it fails because the file is missing, run the `weekly-roundup:setup` skill instead, and stop. Keys:

- `log_dir`: where weekly logs go (one file per week, named by the week's start date)
- `team_rules`: shared team rules, kept in a team repo and changed by PR (optional). `{repo, ref, path}`: the file at `path` on `ref` (default `origin/HEAD`) in the local clone at `repo`, read without touching the checkout. Or `team_rules_file`: a plain path. Not both.
- `rules_file`: the user's personal rules (the template is `templates/rules.md`)
- `log_template`: optional override for `templates/week.md`
- `repos`: local repo paths; `github_repos`: `owner/name` for `gh`; `github_user`: the `gh` account to read with (its token is used without switching the active account)
- `clerk_dir`: clerk `output.dir` (optional)
- `transcripts_dir`: default `~/.claude/projects`
- `session_dirs`: folders whose Claude Code sessions are swept (a session counts if its working directory is one of them or inside one); default: `repos`. Other sessions are only counted in STATS. `["~"]` sweeps everything.
- `skip_projects`: transcript or clerk slugs to ignore inside those (substring match)
- `jira`: `site`, `project` (a key, or a list of keys when the team's tickets span projects, e.g. mid-migration; new tickets go in the first), `user` (display name)
- `week_start_day`: `sunday` by default
- `gap_days`: if the previous log's window ended more than this many days ago (14), the run starts at this week's start instead
- `reviewers`: the names used in wording rules
- `caps`: `transcript_kb` (96), `clerk_kb` (60), `commits_per_repo` (100), enforced by `scripts/sweep-local.sh`; `findings_per_source` (40), a limit for the sweep subagents. `scripts/config-json` rejects invalid values.
- `budgets`: maximum calls per M365 tool per run (e.g. `outlook_email_search: 12`, `read_resource: 40`, `default: 3`), and `total_kb` (1024): a ceiling on the KB of M365 and Atlassian results read per run (identity calls exempt); `max_window_days` (8). Enforced by `hooks/guard.sh`, which also denies searches outside the run's window.
- `m365`: `my_addresses` (the user's email addresses, aliases too; needed for possibly-missed email), `include_self_chat` (true), `noise_senders` (sender substrings or domains to drop), `mute_chats` (chat IDs to skip, e.g. `19:abc@thread.v2`; names are rejected), `alert_patterns` (subject substrings of automated mail to keep instead of drop). In a roundup run `hooks/record.sh` applies these three to email and chat search results in code, before you see them.

## 1. Fix the window

Run `scripts/start-run.sh` first, before any sweep. It records the run time and the window in code, once per run, and prints them as JSON (`run_at`, `week_start`, `window_start`, `window_end`, `reason`, and `gap` if any). Never compute or change these yourself.

- Default: from where the previous log's window ended to now, so every moment is swept exactly once. With no previous log, or one more than `gap_days` (14) old, it starts at this week's start, and the uncovered span (`gap`) goes under Gaps.
- An argument `YYYY-MM-DD` runs `start-run.sh --week YYYY-MM-DD` (that whole week). `--since DATE-OR-ISO` passes through to `start-run.sh --since`. `--dry-run` passes through as `start-run.sh --dry-run` (with either); a dry run's log never counts as the previous run, so the next real run sweeps the same span again. `--calibrate` doesn't pass it: a calibration log covers its week.
- The log is `<log_dir>/<week_start>.md`. Items dated before `week_start` are **late items**: put them in this log, marked late; never rewrite an older log. The local sweep marks them `[late]`; for Jira and M365 findings, compare the date yourself.
- Read the previous log (if any) and bring forward its **carried items**: open **Pending verification** items and Jira proposals it left unposted.
- If a log for this window already exists, update it in place. Never duplicate rows; keep the posted/skipped marks.

## 2. Load rules

Run `scripts/team-rules.sh` and read its output, then `rules_file`, completely. Every proposal below must follow both. When they conflict, the personal rule wins. Note the conflict under Gaps so the user can raise it with the team. The output starts with a `STATUS:` line. On `stale` (the fetch failed, so these are the last fetched rules) or `missing`, put the status line under Gaps and continue (with personal rules only, if missing). Keep a list of the rule IDs you actually used; it goes into the log under `Rules applied`.

## 3. Sweep sources

Each source is swept by its own subagent on **Haiku** (`model: haiku`), all in parallel. Raw data stays inside the subagent. Each one returns at most `caps.findings_per_source` findings (a summarizing limit the subagent follows, not one enforced in code), one line each:

`date | source | repo/project | refs (PR #, KEY-###, person) | one-line outcome | done / in progress / open`

Every source sweeps exactly the window from step 1 (`window_start` to `window_end`).

1. **Local (git, GitHub, sessions)**: one subagent runs `scripts/sweep-local.sh` (no arguments: it reads the run's window) and turns its output into findings. The script is the only way to read these sources. Don't run your own `git log`, `gh` or transcript reads. It dedupes commits across worktrees, uses clerk summaries and falls back to transcripts (user turns plus final reply), and applies the size caps (`transcript_kb`, `clerk_kb`, `commits_per_repo`) in code. Return its `## STATS` block verbatim along with the findings. Its "review requested, not done" section lists open pull requests waiting on the user's review; each one is a **possibly missed** finding.
2. **Jira**: use the Atlassian MCP. First call `atlassianUserInfo` for the user's `account_id`. Then search the issues the user updated, commented on or was assigned in the window: `project in (<project, comma-separated if a list>) AND (issuekey in updatedBy("<account_id>", "<window_start in local time, yyyy-MM-dd HH:mm>") OR (assignee = currentUser() AND updated >= "<same>"))`. Use the account ID, not `currentUser()`: `updatedBy = currentUser()` silently matches nothing, and `updatedBy()` doesn't accept `currentUser()` as an argument. Add every ticket key mentioned by the other sources. Fetch each one's status, epic and owner, and nothing else.
3. **Microsoft 365** (the claude.ai connector, `mcp__claude_ai_Microsoft_365__*`, read tools only). If the tools aren't loaded, the session was started without connectors. Tell the user to restart with the `roundup` alias (see the plugin README), or carry on and list M365 under Gaps. In a roundup run the guard hook enforces call budgets, and every search must pass ISO `afterDateTime`/`beforeDateTime` covering the window (max `max_window_days`). Plan calls to fit the budget: `limit: 25`, paging with `offset`. When a call is denied for budget or the size ceiling, stop that source and note it under Gaps. The config filters (`noise_senders`, `mute_chats`, `alert_patterns`) are already applied to email and chat search results by the hook, which also counts what it dropped. Each M365 subagent returns a **Judgement drops** list only for what it dropped beyond that (sender or chat, count, reason, e.g. `newsletter@x.com · 3 · newsletter`). Split it across three subagents:
   - **Email** (`outlook_email_search`, window only): everything the user sent, and everything received from real people or real groups/distribution lists. Drop remaining automated mail: no-reply addresses, notifications, newsletters, calendar notices, delivery reports. Search **all folders**: never set `folderName`, because mail filed to other folders is otherwise missed. **Fixed plan:** one query per local day in the window (`afterDateTime` = that day, `beforeDateTime` = the next day, but `window_start` for the first day and `window_end` for the last, `query: "*"`, `limit: 25`), paged with `offset` until the response has no `nextOffset`. Don't stop early and don't summarize until every day is paged. Work from search previews; use `read_resource` only for threads that look like work done or a possibly-missed ask. Automated mail matching `m365.alert_patterns` (e.g. refresh failures) is not dropped; it goes under possibly missed. A possibly-missed email must be opened with `read_resource` (search results don't show To), and the user must be in **To** (`m365.my_addresses`): `hooks/record.sh` records that from the opened message, and `scripts/check-log.sh` fails the log if a possibly-missed email wasn't opened in this run or wasn't to the user. Return each one with its message `id`. Asks where the user is only cc'd or that are addressed to a team or distribution list count as context, not possibly missed. Return two kinds of findings: **work done** (what the user delivered, decided or answered) and **possibly missed** (asks, questions or commitments addressed to the user with no reply from them in the thread).
   - **Calendar** (`outlook_calendar_search`): meetings the user attended or organized. Skip all-day, OOO, declined and cancelled events, personal blocks (lunch, focus time) and routine recurring meetings (stand-ups, office hours) unless the user presented or something was decided. 
   - **Teams** (`chat_message_search`, `teams_list_chats`, `teams_list_channel_messages`): chats and channels with activity in the window from real people. **Fixed plan:** one `chat_message_search` per day (`query: "*"`, day window, `limit: 25`), paged until no `nextOffset`. Then one more pass for the user's own messages: `chat_message_search` with `query: "*"`, `sender` set to each address in `m365.my_addresses`, the whole window, paged until no `nextOffset` (the `*` pass can leave out messages the user sent, notes-to-self included). Skip bot posts (muted chats are already removed). Include the user's own notes-to-self chat (id `48:notes`, or the 1:1 chat whose only member is the user) when `m365.include_self_chat` is true (default): its messages are work done, open questions or plans, never possibly missed. `chat_message_search` already covers channels you're a member of. If `teams_list_teams` returns 403 (the connector lacks `Team.ReadBasic.All`), don't retry it or the channel tools; rely on search. Same two kinds of findings as email.
   - Also run `sharepoint_search` for documents modified in the window that the user authored **or** that came up in the email and Teams findings (by file name).
4. **Not available**: Claude web chats. Always list them under Gaps.

## 4. Verify and classify

This step and step 5 run in the main session, which only ever sees the findings lines.

- Check every PR's scope and state with `gh pr view` before you describe it. Don't trust session summaries for scope.
- Group the findings by theme (one theme per model, epic or workstream).
- Classify after-hours and weekend items with the classification rules. Ambiguous items go into the review as questions, never guesses.
- Drop small items according to the scope rules.
- Before an item goes under Possibly missed, check it against the user's own work after the ask's date: the local findings (commits, PRs, sessions) and the other M365 findings (a reply in another channel, a meeting where it was settled). If the findings don't settle it, send the local subagent back with the ask and its date, and have it check whether a later session, commit or PR acted on it. If the user acted on it, it's work done: put it in its theme with the evidence, not under Possibly missed. If the evidence is partial, keep the item and say what was found. Answers given in person or by phone stay invisible; the user clears those in review.
- **Possibly missed** findings go into their own log section and never become Jira rows directly. The user decides what to do with them. Each bullet ends with its source tag: `· email <message id>`, `· teams <link>`, `· github <url>`, `· jira <key>`, `· calendar` or `· other`.

## 5. Write the log

Fill in `templates/week.md` (or `log_template`), keeping the section order. Write it to `<log_dir>/<week-start>.md`. Fill in the frontmatter: copy `run_at`, `week_start`, `window_start` and `window_end` exactly from `start-run.sh` (and `dry_run: true` when it printed that), plus `jira_proposed` (the row count) and `jira_posted: 0`. Then run `scripts/check-log.sh <log>` and fix what it reports until it prints `check-log: ok` (window frontmatter and dry_run, possibly-missed source tags and To). Don't present the log for approval before that. A possibly-missed email it rejects moves to context or is dropped; don't remove its tag to get past the check.

After the M365 subagents return, run `scripts/run-stats.sh`. If it lists **unread pages** or **omitted days**, send that subagent back to fetch or search them (within budget) before writing the log. Whatever is still unread or unsearched goes under Gaps.

**Sweep stats** are copied from code output, never written by you: paste the local `## STATS` block, then the output of `scripts/run-stats.sh` (M365 calls, budgets, KB read, denials from the hook record), including its Dropped table, then the M365 subagents' Judgement drops, labelled as self-reported.

Jira proposals: number them continuously. Each proposal heading must use one of these exact forms, because `hooks/approve.sh` reads them to bind approvals (anything else can't be approved), followed by the sources and a confidence (high/med/low):

- `**N. KEY-123 · comment**`, then the exact comment text as a quote block (`> ` lines), posted as Markdown
- `**N. KEY-123 · status → Done (transition 31)**`: the transition ID from `getTransitionsForJiraIssue`
- `**N. KEY-123 · link Blocks → KEY-456**`: the first key is the inward issue, the second the outward
- `**N. KEY · new Task**`: then a quote block whose first line is the summary and the rest the description

The quote is exactly what gets posted. Don't put anything in a post that the proposal doesn't show (no extra fields, assignees, visibility or link comments): the guard denies it. Put them in three groups: **Review closely**, **Quick skim**, **Not posting (why)**. Status changes, new tickets and merges always go in a separate **Needs explicit approval** list, never in a group.

## 6. Review and approval

Show the user the path and the leadership summary, then every proposal: its number, ticket (key, summary and link `https://<jira.site>/browse/<KEY>`; for a new ticket, its project and proposed summary), group, and the exact text it posts as a quote block, copied from the log. Only then ask for approvals in the form `post 1-6, 9`. The user approves what they've read, so never summarise or shorten a post's text here. If the user edits a proposal, show it again in full.

- Post only the proposals named, with exactly the text the log shows. In a roundup run the guard enforces this: each `post` message (exactly `post <numbers>`, nothing else) approves one write per named proposal, and any write that doesn't match one is denied. Status changes, new tickets and links must be named singly (`post 12`); a range skips them. Each approved write still shows the user a permission prompt.
- If the user edits a proposal's text, they approve it again with `post N` after the edit; the earlier approval no longer counts.
- If a post fails or is denied, report it. Don't retry with different text; ask the user to approve again.
- After posting, mark each row in the log `✅ posted <date>` or `⏭ skipped`, and update `jira_posted`.
- With `--dry-run`, write the log and stop before approval.

## 7. Learning step

Look at what the user corrected: edited text, rejected rows, reclassified items, wrong tickets, and "you missed X". For a miss, check the sweep stats: if a cap or budget was hit, or the item's sender or chat is in the Dropped table or a Judgement drops list, propose a **config change** (`budgets`, `caps`, `m365.noise_senders`, `m365.mute_chats`) instead of a rule. Propose rule changes under **Rule changes proposed** using the rules-file format (`ID [team|personal] rule`), each naming the rule it replaces or merges with, or saying `new`. Write them only after the user approves them. Never change rules silently. `[personal]` rules go into `rules_file`. `[team]` rules are **never edited in place**: write the approved change as a ready-to-apply diff of the team rules file (against the text `scripts/team-rules.sh` printed, at its `path` in the team repo) in the log under Rule changes proposed, and tell the user to open a PR in the team repo.

## Calibration

`--calibrate <manual-log-path>`: run as `--dry-run` with `start-run.sh --week <that log's week>` (a full sweep of that week; overwrite that week's log). Nothing goes to Jira. The log holds only what this run swept: never copy items from the manual log or the baseline into it, even to fill a gap. Then:

1. **Baseline items.** If `<log_dir>/calibration/<week-start>-baseline.md` doesn't exist, write it from the manual log and any other `<log_dir>/calibration/<week-start>-*.md` ground truth (e.g. a Jira truth file): one line per item the manual roundup reported, `- B<n> · <source> · <one-line summary with its date>`. Stop and ask the user to review it before going on. If it exists, use it as it is; never renumber or edit it.
2. **Report.** Write `<log_dir>/calibration/<week-start>-report.md`: the two windows (manual and this run), then one table row per baseline item, `| B<n> | found / missed / outside-overlap | <the skill's matching item> | <what hid it> |`. `outside-overlap` is for items dated outside this run's window; they aren't counted. A missed item names what hid it per the sweep stats: `cap`, `budget`, `ceiling`, `filter`, `omitted day`, `unread page`, `judgement`, `not swept` or `off-plan`. An item found only by a search outside the fixed plan (an extra lookup made after seeing a gap) is `missed`, cause `off-plan`, naming the search that found it: recall measures the plan. Then a table of items the skill added that look like noise, `| N<n> | <skill item> | <why> |`, and finally proposed `config.json` changes, each tied to the rows it would fix.
3. **Check.** Run `scripts/calibration-check.sh <report> <baseline>`. It fails if any baseline item has no row or a value isn't allowed; fix the report until it prints `calibration-check: ok`. It writes the totals (recall over the overlap, misses by cause, noise count) and the sweep stats into the report. Never write those numbers yourself.

Write nothing else.

## Hard rules

`hooks/guard.sh` enforces these outside the model: Microsoft 365 tools are on a read-only allow-list (everything else is denied), and every Jira/Confluence write needs a permission prompt. In a roundup run it also enforces M365 call budgets and date windows, and records every call. If the guard denies a call, don't look for another route; report it.

- Never post, transition, create or link in Jira without approval in this run.
- Never send email or messages. The leadership summary is text the user sends.
- Comments post under the user's name and the whole project sees them. Keep them factual.
- Respect the permission zones of the repo where the log lives (e.g. the vault's `CLAUDE.md`).
