# lore sync

Bring this machine's memory and the hub's into step. Run it when the memory index says a sync is
due, or when the user asks. It is self-contained: the scripts do the merging; you move files
between the hub and two folders. Never edit memory files by hand.

`L` below means `python3 ~/.agents/skills/lore/scripts/lore.py`.

## Rules

- The hub is the Tartib space the status names (`agent-memory` for the owner). Each memory file
  is one note whose first line is `lore/<file>` (for example `lore/git.md`); the file's exact text
  follows after one blank line.
- The owner approved, on 2026-10-16, that lore sync creates and edits these `lore/*` notes in that
  space. That approval covers nothing else: never touch other notes or other spaces.
- Copy note text byte for byte. Do not reformat, summarise or "fix" it.
- If the Tartib tools are not available in this session, say so in one line and stop. Nothing is
  lost: the next session with Tartib syncs everything.

## Steps

1. `L sync-status`. It prints JSON: `space`, `push`, `remote_seen` (note title to `updated_at`
   at the last sync). If `hub` is empty, stop: sync is not configured.
2. `list_items` for the space. If the space does not exist, `create_space` with exactly that
   name (approved), then continue with an empty listing.
3. Pull. Make two empty folders, `pull` and `push` (e.g. `mktemp -d`). For every listed note whose
   first line starts with `lore/` and whose `updated_at` differs from `remote_seen[first line]`:
   `get_item` it, and write its text without the first line and the blank line after it to
   `pull/<file>`, ending with a newline (Tartib drops the final one). Note the `updated_at` that
   `get_item` returned for it.
4. If `pull` has any file: `L merge --remote <pull>`.
5. `L export --out <push>`, then `L sync-status` again. For each file named in its `push` list,
   the note text is `lore/<file>`, a blank line, then the file's content. If a note with that first
   line exists, `edit_item` it with the `updated_at` from the listing (or from `get_item`);
   otherwise `add_note` with that text and the space. Note the `updated_at` each call returned.
   If an edit is refused because the note changed, start again from step 2, once.
6. Write a JSON object, note first line to `updated_at`, holding only the notes this sync fetched
   (step 3) or wrote (step 5), to a file outside `push`; never take versions from a fresh listing.
   Then `L sync-done --pushed <push> --remote-seen <that file>`.
7. Tell the user in one line: how many notes were pulled and pushed. Mention any `profile:` line
   that `merge` printed.
