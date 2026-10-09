---
description: Load the user's memory for this session: preferences, core rules, and the gotchas notes for the stacks in play.
argument-hint: [optional stacks or task, e.g. "flutter" or "coordinating agents"]
---

# lore: load

Run the Load step of lore. Read-only once the store exists; change nothing else.

Full instructions: `~/.agents/skills/lore/SKILL.md`. Backend in use: read `~/.agents/memory/config`,
then its mapping under `~/.agents/skills/lore/backends/` (the default is `files.md`). For the files
backend the mechanics are `~/.agents/skills/lore/scripts/lore-store.sh`, called below as
`lore-store.sh`.

## Steps

1. Make sure the store exists: `lore-store.sh init` (creates the starter notes on first use; it
   never overwrites a note).
2. Read `preferences.md` and `core-rules.md`, with any thoughts on them.
3. From `$ARGUMENTS`, or from the repository and the task in front of you, pick the gotchas notes
   that apply and read those only. Read `coordinating.md` only if you will brief or run other
   agents.
4. Read nothing else.
5. If the configured backend is not available, say so in one line and work from the files
   snapshot.

## Report

One line per note read, with its title. Then the three rules most likely to matter for this task,
quoted by number. Do not summarise the rest. Follow them.
