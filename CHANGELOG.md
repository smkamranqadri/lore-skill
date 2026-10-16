# Changelog

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
