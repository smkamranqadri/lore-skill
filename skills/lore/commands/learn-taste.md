# lore learn-taste

Harvest what Command Code's taste has learned into lore, so every host gets it, not just cmd.
Run it when the user asks, or let cron run it.

`L` below means `python3 ~/.agents/skills/lore/scripts/lore.py`.

## Steps

1. `L learn-taste`. It searches the folders in the store config `taste_roots` (default: the
   global `~/.commandcode/taste` and the home folder, a few levels deep) for every
   `.commandcode/taste/**/taste.md`. Only entries that are new, or whose taste confidence rose
   since the last run, count. The cheap extractor sorts them into general preferences
   (candidates) and project facts (noted in the store's `notices`, never stored).
   Use `--root <folder>` to search only there.
2. Tell the user in one line what it printed: files read, new entries, items applied, promotions.
   If it failed, nothing was recorded, and the next run sees the same entries again.

## Cron

To run it nightly without a session, add a crontab line such as:

```
17 3 * * * python3 ~/.agents/skills/lore/scripts/lore.py learn-taste >> ~/.agents/memory/harvest.log 2>&1
```
