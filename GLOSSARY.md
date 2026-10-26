# Weekly roundup

The weekly-roundup plugin turns a week of work into one log and proposes Jira updates that the user approves.

## Language

**Run**:
One roundup session, started with the `roundup` alias, that produces or updates one weekly log.
_Avoid_: Session, sweep

**Run time** (`run_at`):
The instant a run's sweep started, recorded by code, not by the model.
_Avoid_: Run date

**Week**:
Sunday through Saturday. Each week has at most one log.

**Window**:
The span a run sweeps: from the previous run time to this run time. With no previous log, it starts at this week's Sunday.
_Avoid_: Range, period

**Late item**:
Something in the window dated before the current week, i.e. after the previous run but before this Sunday.
_Avoid_: Carryover, late from last week

**Carried item**:
An open item brought forward from the previous log: a pending verification or an unposted proposal.
_Avoid_: Carryover

**Finding**:
One line a sweep returns about one piece of work or one possibly missed ask.
_Avoid_: Result, item

**Dropped**:
Mail or chat messages removed by the user's noise and mute settings before the model saw them, counted by sender or chat and reason.

**Judgement drop**:
Something a sweep chose to leave out beyond the noise and mute settings, as reported by the model.
_Avoid_: Dropped

**Proposal**:
A numbered row in the log proposing one Jira write (a comment, a status change, a new ticket or a link).
_Avoid_: Row, suggestion

**Approval**:
The user's go-ahead for specific proposals: a `post 1-6, 9` message, plus an explicit "yes" for each status change, new ticket or link. The permission prompt on each Jira write is the final, human-only check.
