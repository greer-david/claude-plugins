# The window runs from where the previous window ended to now

A run sweeps from where the previous log's window ended (normally that run's run time) to its own run time, not over a fixed Sun–Sat week plus a separate "late from last week" slice. Every instant is swept exactly once, the sweep and the guard check one span, and items dated before this Sunday are labelled late items in the current log; old logs are never rewritten. If the previous run is more than 14 days old, the window starts at this Sunday and the uncovered span is listed under Gaps (`--since` overrides). The window starts at the previous window's end, not its run time, because a backfill or calibration run is stamped after the week it covers; starting from its run time would skip days.

## Considered Options

- Fixed Sun–Sat window plus a late slice from the previous run time: two spans per run, harder to enforce in the guard.
