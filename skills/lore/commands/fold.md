---
description: Fold the thoughts on a lore note into the note's text, then delete them, keeping the note small.
argument-hint: [optional note; default every note with 10 or more thoughts]
---

# lore: fold

Run the Fold step of lore.

Full instructions: `~/.agents/skills/lore/SKILL.md`. Backend in use: read `~/.agents/memory/config`,
then its mapping under `~/.agents/skills/lore/backends/` (the default is `files.md`). For the files
backend the mechanics are `~/.agents/skills/lore/scripts/lore-store.sh`, called below as
`lore-store.sh`.

## Steps

1. Pick the note named in `$ARGUMENTS`, or else every note with 10 or more thoughts (`list`, then
   count the `- ` lines under `## Thoughts` in each). If none qualifies, say so and stop.
2. `read` the note. Merge every thought into the text in its section: a repeat raises a rule's
   `(×N)` instead of adding a line; a new rule takes the next number, or goes under the right
   heading. Drop anything now project-specific or superseded; when two lessons conflict, the later
   one wins. A merged rule keeps its whole text on one source line.
3. Save the merged text by editing the note file.
4. `read` the saved note back in full: check nothing was lost, numbering is continuous, and links
   still read `[[Exact first line of the target note]]`.
5. `sha` the note, then `fold-done <note> --confirm-sha <sha>`. It refuses when the file changed
   since the read-back, and when there is nothing to delete. Never delete a thought whose content
   you have not just seen in the read-back.
6. If a note passes about 15,000 characters, merge rules that say the same thing or cut ones that
   no longer bite, and tell the user what you cut.

## Report

Per note: thoughts folded, rules added, rules bumped, anything cut and why.
