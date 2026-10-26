# claude-plugins (marketplace)

A Claude Code plugin marketplace. Each plugin lives in `plugins/<name>/` with its own `.claude-plugin/plugin.json`, `README.md` (for users) and `AGENTS.md` (for developers). The root `.claude-plugin/marketplace.json` lists every plugin.

## Adding a plugin

1. Create `plugins/<name>/` with `.claude-plugin/plugin.json`, `README.md` and `AGENTS.md`.
2. Add an entry to `.claude-plugin/marketplace.json` (`source: "./plugins/<name>"`, plus `version`).
3. Add a line to the plugin table in `README.md`.

## Rules

- Bump the plugin's `version` in both its `plugin.json` and `marketplace.json` on every change.
- No personal or company data. Config, rules and logs live on each user's machine or in their team's repo.
- Read the plugin's own `AGENTS.md` before changing it.
