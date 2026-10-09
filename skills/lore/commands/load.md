---
description: Load the user's memory for this session: preferences, core rules, and the gotchas notes for the stacks in play.
argument-hint: [optional stacks or task, e.g. "flutter" or "coordinating agents"]
---

# lore: load

Run the Load step of lore. Read-only once the store exists; change nothing else.

Full instructions: `~/.agents/skills/lore/SKILL.md`. Resolve the backend first:
`~/.agents/skills/lore/scripts/lore-store.sh config` prints the backend (and space, when set), and
`… config mapping` prints the mapping file. The operations below are the ones that mapping defines;
the mapping also says how a store that does not exist yet is created on first use.

## Steps

1. Read the config, then the mapping file of the configured backend.
2. **reachable?** — if the backend is not reachable (or its tools are absent in this session), say
   so in one line and work from the files snapshot. Never create a store or a space to make it
   reachable.
3. **read a note with thoughts** for `preferences.md`, `core-rules.md` and `profile.md`.
4. **read a note with thoughts** for the gotchas notes that apply, chosen from `$ARGUMENTS`, the
   repository and the task in front of you, and for `references.md` only when the task needs to
   locate a repo, tool or service. Read `coordinating.md` only if you will brief or run other
   agents.
5. Read nothing else.

## Report

One line per note read, with its title. Then the three rules most likely to matter for this task,
quoted by number. Do not summarise the rest. Follow them.
