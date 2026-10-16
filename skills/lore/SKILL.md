---
name: lore
description: "The user's memory across projects and hosts: how they want coding agents to work, hard rules, and gotchas per stack. Its index is already in your global instructions. Use this skill when the user says remember, always, never, or drop that; when they correct you in a way that should hold in other projects; when the index says a memory sync is due; when you need a category file the index points to; or when the user asks to sync memory, learn from taste, or see what lore knows. What is true in one project only belongs in that project's own memory (KIS), never here."
metadata:
  version: "1.0.0"
---

# lore

One memory for every host (Claude Code, Codex, Command Code, agy) and every project. It learns
on its own: hooks hand finished sessions to a background harvester, a cheap model turns your
corrections into candidate rules, and a candidate becomes a rule once it is seen on two
different days or the user states it outright. A stronger model reviews new memory once a day.
You rarely run anything yourself.

`L` means `python3 ~/.agents/skills/lore/scripts/lore.py`. Never edit the memory files by hand;
they are rewritten by `L`.

## What you already have

The index (`~/.agents/memory/INDEX.md`) is in your global instructions: the strongest rules
inline, then one "read when" line per category file. Follow the rules. Read a category file
(`~/.agents/memory/<category>.md`) only when its read-when line matches the task. Do not
summarise memory back to the user.

## When the user speaks to memory

| The user says | You run |
|---|---|
| "remember: X", or "always / never X" about how to work | `L add --cat <category> --text "<X as one imperative rule>" --src "<their words>" --explicit` |
| "drop that" about a rule shown under New | `L drop <id shown in brackets>` |
| "what does lore know about X" | `L list --cat <category>` (or `--candidates`) |
| "pin that" | `L pin <id>` |

A rule is one imperative sentence that holds in any project. A fact about this project only (its
stack, paths, deploy steps) goes to the project's KIS instead; say so. Never store secrets,
credentials or personal data.

## Commands

- `/lore:sync` (`commands/sync.md`): run it when the index says a sync is due.
- `/lore:learn-taste` (`commands/learn-taste.md`): harvest Command Code's taste files.
- `/lore:retro` (`commands/retro.md`): record this session's lessons by hand, when the user asks.

Hosts without slash commands: "run the lore sync step" and follow the command file.

## Checks and repairs

`L deliver --check` (is every host's copy of the index current), `L hooks check` (are the
capture hooks installed), `L index` (index size against its budget), `L review --force` (run the
daily review now). Logs: `~/.agents/memory/harvest.log`, `review.log`, `notices` (project facts
that belong in KIS).
