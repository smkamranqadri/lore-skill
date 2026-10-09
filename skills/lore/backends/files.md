# Backend: files

The default backend, and the one that needs nothing else installed. The store is
`~/.agents/memory/`, one Markdown file per note. It is also the shape of a snapshot taken from
any other backend, so switching to files for good is a snapshot plus a config change.

Mechanics: `../scripts/lore-store.sh`. Prose steps that say *when* to run them: `../SKILL.md`
and `../commands/`. The fallback half (the snapshot and the queue) is below.

## Reachability (read-only)

The store folder exists: `test -d ~/.agents/memory`. No network, no tool lookup. `list` refuses
with `store not found` when it is absent. A load runs `init` first, so an empty store is created
on first use with its starter notes.

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

## Fallback: the snapshot and the queue

When the configured backend is an MCP and it is not reachable, the store becomes the **snapshot**:
the same layout and note format above, holding whatever has been read from the backend so far. Every
write then goes to the snapshot **and** to the queue, and the queue replays at the next load once
the backend is back. `config` says which backend is configured; `pending.md` is the queue.

| Operation | Call |
|---|---|
| write a snapshot note | `lore-store.sh snapshot-write <note>` (the note on stdin) |
| read a snapshot note | `lore-store.sh snapshot-read <note>` |
| render a note for a snapshot | `lore-store.sh snapshot-render` (text on stdin; `--thought <date> <text>`) |
| make one write while the backend is down | `lore-store.sh fallback-write <op> <note> <arg>` |
| list the queue, oldest first | `lore-store.sh queue-list` |
| finish the oldest queued write | `lore-store.sh queue-pop` (after the backend write succeeded) |
| empty the queue | `lore-store.sh queue-clear` |
| make files the backend for good | `lore-store.sh switch-files` |

- **`snapshot-write`** takes the whole note on stdin; its first line must be `# Title`. It refuses
  `config` and `pending.md`: a snapshot never touches either.
- **`snapshot-read`** reads one snapshot note. A note not read on this machine yet is reported
  `not in the snapshot`, never invented.
- **`snapshot-render`** turns one note's text into the files-store shape for `snapshot-write`: the
  title once as the H1, the rest of the text byte for byte, then `## Thoughts` with one dated line
  per `--thought` (an MCP mapping names the exact call). It refuses an empty text, a blank first
  line, a first line that already starts with `# `, and a `--thought` whose date is not `YYYY-MM-DD`
  or whose text is not one line.
- **`fallback-write`** applies one write to the snapshot and appends it to `pending.md`, so the two
  cannot drift. The op is `add-thought` (arg is the thought), `bump-rule` (arg is the exact match
  text) or `create-note` (arg is the title). **Fold is refused**, with a one-line reason: it is a
  rewrite plus deletes and cannot be queued.
- **`queue-add <op> <note> <arg>`** appends one entry on its own; `fallback-write` uses it after a
  successful snapshot write. An entry's argument is one line with no tabs.
- **`pending.md`**: a heading, then one entry per line after a `- `, tab-separated — the id, the
  date, the operation, the note and its argument. Ids are `p1`, `p2`, … in order. `queue-pop`
  removes the oldest entry, and replay calls it only after that entry's backend write succeeded.
- **`switch-files`** writes `backend: files` and clears the queue, since every entry is already in
  the snapshot; the store then loads with this backend and no other.

## Config

`config` holds `backend: files`. No settings to add. A store with no `config`, or with
`backend: files`, is served by this backend; any other value names a mapping under this folder.
While another backend is configured, the folder is its snapshot and `pending.md` may hold queued
writes — but a snapshot write still never touches `config` or `pending.md`.
