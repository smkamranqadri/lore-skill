# Backend: tartib

Notes live in the Tartib space named by `space` in the config (the owner's: `ai-agents`), reached
through the Tartib MCP tools. Lore never creates a space; it only uses the configured one. The
space is small on purpose: every line an agent reads costs context.

## Reachability (read-only)

`list_spaces` names the configured space. If it does not, or the Tartib tools are not available in
this session, the backend is unavailable — say so in one line and work from the files snapshot.
Never create the space to make it reachable.

## Note identity

A store note maps to the Tartib note whose **first line** is the mapped title. It is found by its
**pinned id**, never by searching or listing the space: `get_item <id>` returns just that note,
while `search` returns the full text of every fuzzy hit and listing the space returns all of it.

| store note | Tartib note (first line) |
|---|---|
| start-here.md | `Agents: start here` |
| preferences.md | `Agents: preferences` |
| core-rules.md | `Agents: core rules` |
| coordinating.md | `Agents: coordinating parallel agents` |
| gotchas/<stack>.md | `Gotchas: <stack>` |
| profile.md | `User: profile` |
| references.md | `User: references` |

The ids live in the store's `ids` file (see Ids below), not in this file: this file ships, the ids
do not. The gotchas notes in `ai-agents` today: `Gotchas: shell, macOS and Claude Code`; `Gotchas:
Flutter, Android and iOS`; `Gotchas: web (Next.js, Tailwind, React, Tiptap, Node)`; `Gotchas:
backend data (NestJS, Mongo, Postgres, SQLite, Frappe)`; `Gotchas: infra (Docker, CapRover, servers,
Cloudflare, backups)`; `Gotchas: Pencil MCP`; `Gotchas: Herdr`. The title is the identity; the
files-side slug is a convenience for the snapshot, not the source of truth.

## Operations

| Operation | Call |
|---|---|
| reachable? | `list_spaces` contains `space` |
| find a note | its pinned id (`lore-store.sh ids-list`); when the pin is absent or stale, one `search "<title>" space=<space>` then `lore-store.sh ids-pin` |
| read a note with thoughts | `get_item <id>`; `text` is the note, `thoughts` are dated lines |
| add a thought | `add_thought id "<one line>"` (Tartib dates it) |
| change a few words (bump) | `find_replace id find="<rule tail> (×N)" replace="<rule tail> (×N+1)" expected=1 scope="text" updated_at=<just read>` |
| rewrite a note (Fold) | `edit_item id text=<merged text> updated_at=<just read>` |
| delete a thought | `delete_thought id thought_id=<id from get_item>` |
| create a note | `add_note text="<Title>\n…" space=<space>` (the first line is the title, as in the table above) |

## Ids (the load path's one lookup)

Each mapped note has a **pinned id** in the store's `ids` file, one line per note, `"<note><TAB><id>"`
and, when the note's title is not fixed, a third field with its exact first line:

```text
preferences.md	323
core-rules.md	324
gotchas/herdr.md	332	Gotchas: Herdr
```

`lore-store.sh ids-list` prints them; `lore-store.sh ids-pin <note> <id> [title]` records one (the
title is required for a `gotchas/` note, whose first line the script cannot know). Ids live in the
store, so a skill update never clobbers them.

A read checks the pin: `get_item <id>` and the note's first line must equal the mapped title. When
the pin is **absent** (`ids-list` has no line for the note) or **stale** (the id names no note, or
its first line differs), recover with **one** `search "<title>" space=<space>`, take only the hit
whose first line equals the title, `ids-pin` it, and report `stale pin for <note>: <old> -> <new>`
(or `pinned <note> for the first time`). Never list the space, and never search for a note whose pin
is current. No hit carries the title: report `<note> not found in <space>`; never invent it.

## Load plan

`lore-store.sh load-plan [--note <note>]...` prints the whole load in one call: for each note the
read to make and the title to check (`get_item <id>` when pinned, `MISSING` when not, `read <note>`
on the files backend), then the queue length and whether each note is already in the snapshot. The
default is preferences.md, core-rules.md and profile.md; `--note` adds a gotchas note for a stack in
play, coordinating.md only when briefing or running other agents, references.md only when the task
needs a location. `lore-store.sh load-size <note>...` prints the characters read against the budget
(`budget:` in the config, default 60000) — the load's size line. A load reads this section no
further than these two calls.

## Quirks and guards

- **Every write needs the `updated_at` you just read.** It is refused as stale otherwise. When one
  is refused, `get_item` again and redo it; never guess a newer value.
- **A bump is `find_replace` on the text only** (`scope="text"`), with `expected=1`, and a `find`
  holding enough of the rule to match exactly once — ending at the `(×N)`, so the marker moves and
  nothing else does. Zero or several matches is refused. Never bump with `edit_item`: that rewrites
  the whole note and can silently resurrect a stale copy. Never record a bump as a thought.
- **A bump is reversible by construction**: to lower it again, run `find_replace` with find and
  replace swapped, same `expected=1` and `scope="text"` and the fresh `updated_at`. That is how the
  live probe proves it changed nothing.
- `find_replace` defaults to `scope="both"`; a bump must always pass `scope="text"` so a thought is
  never touched.
- **A thought is a Tartib thought, not a line in a note.** There is no `## Thoughts` section here;
  `add_thought` dates it, `get_item` reads it back, `delete_thought` removes it.
- **`delete_thought` cannot be undone.** Only after the merged text is saved with `edit_item` and
  read back with `get_item` may the folded thoughts be deleted, one by one, ids from that read-back.
- `add_note` must pass `space`, so the classifier cannot file the note elsewhere.
- **A pin is a number and a note's title is its first line.** A `gotchas/` pin carries its title; a
  changed title is a stale pin, recovered by one `search` and re-pinned, never silently trusted.
- Keep each note under about 15,000 characters; a rule count hides long rules.

## Fallback (the backend is unreachable)

When `list_spaces` does not name the configured space, or the Tartib tools are absent in this
session, say so in one line and offer exactly three choices. Never create the space.

1. **Reconnect.** Name Tartib from the config and this host's one reconnecting step (Claude Code:
   `/mcp`; Codex and other hosts: their own MCP settings), then retry the reachability call.
2. **Files for now.** Read from the snapshot. Make every write with
   `fallback-write <op> <note> <arg>` — it writes the snapshot and the queue together. Fold is
   refused. Replay the queue at the start of the next load once Tartib is back.
3. **Switch to files for good.** `switch-files`: `backend: files`, the snapshot becomes the store,
   the queue is cleared.

**Snapshot.** After a load that read Tartib, write each note it read to its snapshot file so that two
agents produce the same bytes: pipe the note through `snapshot-render`, then into `snapshot-write`.

```bash
lore-store.sh snapshot-render [--thought <YYYY-MM-DD> "<one-line thought>"]... < note-text.txt \
  | lore-store.sh snapshot-write <note>
```

`snapshot-render` reads the note's `text` on stdin and prints the files-store note: the title once,
as the H1 (`# <the note's first line>`, so `# Agents: preferences` for `preferences.md`), then the
rest of the text byte for byte, then — only when at least one `--thought` is given — a blank line,
`## Thoughts`, a blank line, and one `- <date>: <text>` line per thought, in the order given (its own
date). The title never appears twice: `# Agents: preferences` on line 1, and no plain
`Agents: preferences` line after it. It refuses an empty text, a blank first line, a first line that
already starts with `# `, a `--thought` date that is not `YYYY-MM-DD`, and a `--thought` text that is
not one line.

Retro refreshes **every** mapped note the same way. `snapshot-write` refuses `config`, `pending.md`
and `ids`, so a snapshot never touches them; and a note not yet snapshotted is reported missing,
never made up.

**Queue.** One `fallback-write` per write, using the store-side name from the identity table above
(`gotchas/<stack>.md` for a `Gotchas:` note) and, as its argument, the thought, the exact match
text, or the title.

**Replay** (at the start of a load with Tartib reachable, before the load's own note reads):
`queue-list`, oldest first; look up each target note by its pinned id (`ids-list`), falling back to
one `search` for its first line; apply each entry through the table above; `queue-pop` only after
that write succeeded. On the first failure, stop, keep that entry and every later one, and show the
user what failed. A bump whose match is not found exactly once is a failure — `find_replace` with
`expected=1` refuses it; never guess a match.

`/lore:backend` (`../commands/backend.md`) drives all of this: config, reachability, reconnect,
replay now, switch.

## Config

`~/.agents/memory/config` holds `backend: tartib`, `space: ai-agents` and optionally `budget:` (the
`load-size` budget, default 60000). Read it through `../scripts/lore-store.sh config` (see
`files.md` for the files twin). No other setting is needed.

The pinned ids live beside it, in `~/.agents/memory/ids`, through `ids-list` and `ids-pin`.
