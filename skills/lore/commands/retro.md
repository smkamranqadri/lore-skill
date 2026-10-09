---
description: Run the end-of-session retrospective into the user's memory, adding only new general lessons and bumping repeats.
argument-hint: [optional notes on what went wrong or well]
---

# lore: retro

Run the Retrospective step of lore.

Full instructions: `~/.agents/skills/lore/SKILL.md`. Resolve the backend first:
`~/.agents/skills/lore/scripts/lore-store.sh config` prints the backend (and space, when set), and
`… config mapping` prints the mapping file. The mapping names the concrete call behind each
operation below; for `files` those are `lore-store.sh` subcommands.

## Steps

1. From this session (and `$ARGUMENTS`), list what went wrong and what worked. Be honest about
   your own mistakes.
2. Keep only general lessons: true in another project or with another agent. Project facts belong
   in the project's own memory, never here.
3. For each lesson, **find a note**, then **read a note with thoughts** (rules and thoughts):
   - **already covered**: **change a few words** on that rule to raise its `(×N)`, changing nothing
     else. A bump is never **rewrite a note** (that rewrites the whole note) and never a thought.
   - **new**: **add a thought** — one line of rule in the imperative, plus at most one line of why,
     with no session story and no project names. The backend dates it.
   - **a preference**: only if the user confirmed it in words this session, as a thought on
     `preferences.md`.
   - **a stack with no gotchas note**: **create a note** titled `Gotchas: <stack>` and add a link
     line for it to `start-here.md`. No other new notes.
4. If any note you touched now has 10 or more thoughts, run Fold on it (`commands/fold.md`).

## Report

What you added, what you bumped and to what count, and any rule now at ×3 or more with a suggested
stronger fix. Three to six lines.
