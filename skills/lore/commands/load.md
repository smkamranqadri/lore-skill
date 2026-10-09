---
description: Load the user's memory for this session: preferences, core rules, and the gotchas notes for the stacks in play.
argument-hint: [optional stacks or task, e.g. "flutter" or "coordinating agents"]
---

# lore: load

Run the Load step of lore. Apart from the snapshot and the queue's replay below, change nothing.

Full instructions: `~/.agents/skills/lore/SKILL.md`. Resolve the backend first:
`~/.agents/skills/lore/scripts/lore-store.sh config` prints the backend (and space, when set), and
`… config mapping` prints the mapping file. The operations below are the ones that mapping defines;
the mapping also says how a store that does not exist yet is created on first use.

## Steps

1. Read the config, then the mapping file of the configured backend.
2. **reachable?** If the configured backend is an MCP and it is not reachable (or its tools are
   absent in this session), say so in one line and offer exactly these three choices. Never create
   a store or a space to make it reachable.
   - **Reconnect**: name the MCP from the config and this host's one reconnecting step (Claude
     Code: `/mcp`; Codex and other hosts: their own MCP settings), then retry the reachability call.
   - **Files for now**: read from the snapshot; every write goes to the snapshot and the queue
     (`commands/fold.md` refuses Fold while the backend is down). Then go on to step 4.
   - **Switch to files for good**: run `switch-files`; the snapshot becomes the store and the queue
     is cleared.
3. If the backend is reachable and the queue is not empty, **replay** it now, before the load's own
   note reads (steps 4 and 5). The replay may look up each target note it writes, to get its id (the
   mapping's "find a note"). Apply the oldest entry first, and drop the entry only after that write
   succeeded; on the first failure stop, keep that entry and every later one, and show the user what
   failed.
4. **read a note with thoughts** for `preferences.md`, `core-rules.md` and `profile.md`.
5. **read a note with thoughts** for the gotchas notes that apply, chosen from `$ARGUMENTS`, the
   repository and the task in front of you, and for `references.md` only when the task needs to
   locate a repo, tool or service. Read `coordinating.md` only if you will brief or run other
   agents.
6. When the backend is an MCP and it is reachable, write each note you read to its snapshot file
   with `snapshot-write <note>`, as the mapping says. Read nothing else.

## Report

One line per note read, with its title. In fallback, name any note the snapshot does not hold as
missing; never invent it. Then the three rules most likely to matter for this task, quoted by
number. Do not summarise the rest. Follow them.
