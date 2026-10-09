---
description: Show the memory backend and whether it is reachable, reconnect it, replay the queued writes, or switch to files.
argument-hint: [optional: reconnect | replay | switch]
---

# lore: backend

Drive the lore backend: show it, reconnect it, replay the queue, or switch to files for good.

Full instructions: `~/.agents/skills/lore/SKILL.md`; the fallback detail is in the backend mapping
(`backends/files.md`, `backends/tartib.md`). Resolve the backend with
`~/.agents/skills/lore/scripts/lore-store.sh config`, and its mapping with `… config mapping`.

## Show

1. Print the config (`lore-store.sh config`): the backend, and the space when set.
2. Run the mapping's read-only **reachable?** call and say whether the backend is reachable.

## Reconnect (when unreachable)

Name the MCP from the config and this host's one reconnecting step (Claude Code: `/mcp`; Codex and
other hosts: their own MCP settings), then retry the reachability call.

## Replay

Only when the backend is reachable. Apply the queue (`lore-store.sh queue-list`) oldest entry first
through the mapping, and `queue-pop` only after that write succeeded; on the first failure stop, keep
that entry and every later one, and show the user what failed. Never read before the replay.

## Switch

- **To files for good**: `lore-store.sh switch-files` — `backend: files`, the snapshot is the store
  from then on, and the queue is cleared because its entries are already in the snapshot.
- **To a named backend**: set `backend:` (and `space:`) in `~/.agents/memory/config` to the backend
  and its settings, then run Show again. Switch back to an MCP only one the user names.

## Report

The backend and whether it is reachable; then whatever was reconnected, replayed (the count, and
what failed if it stopped), or switched.
