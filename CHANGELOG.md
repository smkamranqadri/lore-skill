# Changelog

## 1.1.0 (2026-10-19)

Hub sync no longer costs tokens in every agent session.

- `lore.py sync-run`: a free gate (local changes, or no sync in a day) that starts one headless
  agent (Codex `gpt-6-luna`, low effort) only when a sync is needed. One lock, one log line per
  check in `sync-log.jsonl`, the last 20 runs' output in `sync-runs/`.
- After a failed run the gate backs off for two hours (`--force` overrides), a run times out after
  5 minutes, and `sync_cmd` in the config replaces the adapter's command for a machine whose CLI
  needs its own invocation.
- Every session end syncs: the capture hook chains `sync-run` after the harvest (free unless the
  memory changed), and each log line records its trigger (`claude:SessionEnd`, `timer`). The
  timer stays as a slow safety net.
- `lore.py sync-log` summarises skips, runs, failures and tokens, to tune the interval.
- `lore.py sync-timer install|remove|check`: a systemd user timer (default every 30 minutes).
- The memory index no longer carries a "sync is due" line.

## 1.0.0 (2026-10-16)

lore becomes one memory for Claude Code, Codex, Command Code and agy that learns on its own.

- Automatic capture: hooks queue finished sessions; a background harvester reads only your
  messages, skips sessions without a correction, and turns corrections into candidate rules with
  a cheap model. Project facts are noted for the project's own memory, never stored.
- Promotion after two separate days or an explicit "remember:", decay of unused rules, at most
  25 rules per topic, and "drop that" to delete and blocklist a rule.
- A daily review by a stronger model that merges, scopes and rejects, with every decision logged.
- A capped index (about 1,500 tokens) delivered into each agent's global instructions.
- `lore.py setup`: one command that finds your agents, shows the plan, backs up and installs;
  `setup --remove` undoes it.
- Optional sync between machines through a notes hub (Tartib), with tombstones and an
  order-independent merge.
- `/lore:learn-taste` harvests Command Code's taste files.
- Secrets are redacted before any prompt, and secret-looking rules are refused.
- Replaces 0.6.0's manual load, fold and backend machinery.
