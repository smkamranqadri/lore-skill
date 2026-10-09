# Backend: files

The default backend, and the one that needs nothing else installed. The store is
`~/.agents/memory/`, one Markdown file per note. It is also the shape of a snapshot taken from
any other backend, so switching to files for good is a snapshot plus a config change.

Mechanics: `../scripts/lore-store.sh`. Prose steps that say *when* to run them: `../SKILL.md`
and `../commands/`.

## Reachability (read-only)

The store folder exists: `test -d ~/.agents/memory`. No network, no tool lookup. `list` refuses
with `store not found` when it is absent; `init` creates it.

## Note format

```markdown
# <Title>

Some prose, then the rules. One rule per source line — a numbered item or a `-` bullet — so a
rule, its `(×N)` marker and the text a bump matches all live on one line.

1. A rule that has been broken twice. (×2)
2. A rule with no marker yet.
- A rule in a gotchas note.

## Thoughts

- 2026-10-09: a new lesson, one line, dated by the script.
```

- A **rule line** starts with `N. ` or `- ` (optionally indented) and may end with ` (×N)`.
- A **marked rule** carries `(×N)` at the end of its line. A bump raises it; a rule with no
  marker becomes `(×2)` on its first bump. A bump is never written as a thought.
- **Thoughts** live under a `## Thoughts` heading at the end, one dated `- ` line each.
- The note text is everything above `## Thoughts`; **Fold** merges each thought into it and then
  deletes the thoughts.

## Operations

| Operation | Call |
|---|---|
| reachable? | `test -d ~/.agents/memory` |
| find a note | `lore-store.sh list` |
| read a note with thoughts | `lore-store.sh read <note>` |
| add a thought | `lore-store.sh add-thought <note> <text>` |
| change a few words (a bump) | `lore-store.sh bump-rule <note> <match>` |
| rewrite a note (Fold) | edit the file directly, then `read` it back |
| delete a thought | `lore-store.sh fold-done <note> --confirm-sha <sha>` |
| create a note | `lore-store.sh create <note> --title <title>` |

`sha <note>` prints the note's sha256 for the read-back guard below.

## Quirks and guards

- `init` never overwrites a note, so it is safe at every load and preserves the user's edits.
- `bump-rule` matches whole rule lines and requires **exactly one** match; no match or an
  ambiguous one is refused with a message naming the count.
- `add-thought` refuses an empty thought and a multi-line one: a thought is one line.
- `fold-done` refuses unless the note still has a `## Thoughts` section with at least one
  thought, **and** the caller passes `--confirm-sha <sha>` equal to the note's sha at the moment
  of the read-back. That is the guard for "never delete a thought whose content you have not just
  read": read the note back, `sha` it, then delete.
- Note names are store-relative paths (`gotchas/web.md`). Absolute paths and `..` are refused.

## Config

`config` holds `backend: files`. No settings to add. A store with no `config`, or with
`backend: files`, is served by this backend.
