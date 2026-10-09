---
description: Fold the thoughts on a lore note into the note's text, then delete them, keeping the note small.
argument-hint: [optional note; default every note with 10 or more thoughts]
---

# lore: fold

Run the Fold step of lore.

Full instructions: `~/.agents/skills/lore/SKILL.md`. Resolve the backend first:
`~/.agents/skills/lore/scripts/lore-store.sh config` prints the backend (and space, when set), and
`… config mapping` prints the mapping file. The mapping names the concrete call behind each
operation below; for `files` those are `lore-store.sh` subcommands.

## Steps

1. Pick the note named in `$ARGUMENTS`, or else every note with 10 or more thoughts (count the
   unfiled thoughts in each). If none qualifies, say so and stop.
2. **Read a note with thoughts**. Merge every thought into the text in its section: a repeat raises
   a rule's `(×N)` instead of adding a line; a new rule takes the next number, or goes under the
   right heading. Drop anything now project-specific or superseded; when two lessons conflict, the
   later one wins. Keep each rule's whole text together, with its `(×N)` at the end of the rule.
3. **Rewrite a note** with the merged text.
4. **Read a note with thoughts** again: check nothing was lost, numbering is continuous, and links
   still read `[[Exact first line of the target note]]`.
5. Only then **delete a thought** for each folded thought, one by one, using what the read-back
   just showed. Never delete a thought whose content you have not seen in that read-back.
6. If a note passes about 15,000 characters, merge rules that say the same thing or cut ones that
   no longer bite, and tell the user what you cut.

## Report

Per note: thoughts folded, rules added, rules bumped, anything cut and why.
