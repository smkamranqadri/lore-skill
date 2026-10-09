---
description: Run the end-of-session retrospective into the user's memory, adding only new general lessons and bumping repeats.
argument-hint: [optional notes on what went wrong or well]
---

# lore: retro

Run the Retrospective step of lore.

Full instructions: `~/.agents/skills/lore/SKILL.md`. Backend in use: read `~/.agents/memory/config`,
then its mapping under `~/.agents/skills/lore/backends/` (the default is `files.md`). For the files
backend the mechanics are `~/.agents/skills/lore/scripts/lore-store.sh`, called below as
`lore-store.sh`.

## Steps

1. From this session (and `$ARGUMENTS`), list what went wrong and what worked. Be honest about
   your own mistakes.
2. Keep only general lessons: true in another project or with another agent. Project facts belong
   in the project's own memory, never here.
3. For each lesson, read the note it belongs in (`read <note>`), rules and thoughts:
   - **already covered**: `bump-rule <note> "<enough of the rule to match once>"`, changing nothing
     else; never record a bump as a thought;
   - **new**: `add-thought <note> "<rule>; <why>"` — one line of rule in the imperative, plus at
     most one line of why, with no session story and no project names;
   - **a preference**: only if the user confirmed it in words this session, as a thought on
     `preferences.md`;
   - **a stack with no gotchas note**: `create gotchas/<stack>.md --title "Gotchas: <stack>"` and
     add a link line for it to `start-here.md`. No other new notes.
4. If any note you touched now has 10 or more thoughts, run Fold on it (`commands/fold.md`).

## Report

What you added, what you bumped and to what count, and any rule now at ×3 or more with a suggested
stronger fix. Three to six lines.
