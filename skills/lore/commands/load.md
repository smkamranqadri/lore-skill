---
description: Load the user's memory for this session: preferences, core rules, and the gotchas notes for the stacks in play.
argument-hint: [optional stacks or task, e.g. "flutter" or "coordinating agents"]
---

# lore: load

Run the Load step of lore. Apart from the snapshot and the queue's replay below, change nothing.

One call gives this load everything it needs — the read to make and the title to check for each
note, the queue length and the snapshot state. Do not open the script or the backend mapping.

```bash
lore-store.sh load-plan                                        # preferences, core rules, profile
lore-store.sh load-plan --note gotchas/<stack>.md --note coordinating.md
```

(`lore-store.sh` is `~/.agents/skills/lore/scripts/lore-store.sh`.) The default is exactly
preferences.md, core-rules.md and profile.md. The core is small on purpose: the rules that are not
needed every session live in four topic notes, each added with `--note` only when its moment
applies.

| `--note` this | when |
|---|---|
| `core-verify.md` | Anything to check: tests, guards, debugging, a refactor or migration, a UI change, a measurement, or a deploy to prove. |
| `core-production.md` | Production or live data, a server, a deploy, secrets or credentials, a destructive delete, or SSH and firewall settings. |
| `core-tools.md` | Many files or scripts edited, git or a formatter or linter run, or large reads batched. |
| `core-user.md` | Asking the user, recording a decision, writing State or KIS, or closing and handing off. |

Also `--note` a gotchas note only for a stack the work touches, `coordinating.md` only when you
will brief or run other agents, and `references.md` only when the task needs to locate a repo, tool
or service. Never name anything else: `load-plan` refuses a note outside the known set.

## Steps

1. Run `load-plan` with the notes this session needs.
2. **reachable?** If the configured backend is an MCP and it is not reachable (or its tools are
   absent in this session), say so in one line and offer exactly these three choices. Never create
   a store or a space to make it reachable.
   - **Reconnect**: name the MCP from the config and this host's one reconnecting step (Claude
     Code: `/mcp`; Codex and other hosts: their own MCP settings), then retry the reachability call.
   - **Files for now**: read from the snapshot; every write goes to the snapshot and the queue
     (`commands/fold.md` refuses Fold while the backend is down), then go on to step 6.
   - **Switch to files for good**: run `switch-files`; the snapshot becomes the store and the queue
     is cleared.
3. If the backend is reachable and the queue is not empty, **replay** it now, before the load's own
   note reads (steps 4 and 5). Apply the oldest entry first, look each target note up by its pinned
   id, and drop the entry only after that write succeeded; on the first failure stop, keep that
   entry and every later one, and show the user what failed.
4. **read a note with thoughts** for every line the plan printed: by its id (`get_item <id>`) when
   the line names one, or as a plain `read <note>` on the files backend.
5. Check each note against the pin: its first line must equal the title on the plan's line. When a
   line says `MISSING`, or the note does not begin with its title, the pin is absent or stale —
   recover it with **one** `search "<title>"` in the space, take only the hit whose first line
   equals the title, record it with `ids-pin <note> <id>` (with the title for a gotchas note), and
   report `stale pin for <note>: <old> -> <new>` (or `pinned <note> for the first time`). That is
   the only lookup a load makes; never list the space, and never search for a note whose pin is
   current. If no hit carries the title, report `<note> not found in <space>` and never invent it.
6. When the backend is an MCP and it is reachable, write each note you read to its snapshot file
   with `snapshot-write <note>`, as the mapping says.
7. Run `lore-store.sh load-size <the notes you read>` and print its line. That is the load's size
   budget. Read nothing else.

## Report

One line per note read, with its title. In fallback, name any note the snapshot does not hold as
missing; never invent it. Then the `load-size` budget line, then the three rules most likely to
matter for this task, quoted by number. Do not summarise the rest. Follow them.
