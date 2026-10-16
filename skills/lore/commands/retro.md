---
description: Record this session's general lessons in lore by hand, when the user asks for a retro.
argument-hint: [optional notes on what went wrong or well]
---

# lore: retro

lore learns from finished sessions on its own, so a retro is optional: run it when the user asks.

`L` means `python3 ~/.agents/skills/lore/scripts/lore.py`.

## Steps

1. List what this session taught that would hold in any project: a mistake that cost time, a
   correction the user made, a preference they showed. Leave out facts about this project (they
   belong in its KIS) and anything already in the index.
2. For each lesson, one imperative sentence, then
   `L add --cat <category> --text "<rule>" --src "<what happened, briefly>"`.
   Add `--explicit` only for rules the user stated in words. Use an existing category from the
   index when one fits.
3. `L maintain`, then `L deliver`.
4. Tell the user in one or two lines what was recorded, as candidates or rules.
