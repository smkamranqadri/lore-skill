---
name: lore
description: "Load and maintain the user's memory across projects: preferences and core rules at session start, the gotchas note for a stack you are about to touch, the coordination rules before briefing or running other agents, and a dated retrospective at the end of a session. Use when the user says retro, retrospective, lessons, fold, or asks to load, save or clean up their general memory. What is true in one project only belongs in that project's own memory (KIS), never here."
metadata:
  version: "0.2.0"
---

# lore

One memory across projects, for any agent. It holds what is true everywhere: preferences, core
rules, gotchas per stack, the user profile and references. Project facts stay in the project's
own memory; project status belongs to orch and session-close. Lore never reads or writes a
host's built-in memory.

## The store

Notes are Markdown, one per file, in `~/.agents/memory/`:

```text
config             backend: files | tartib | <name>, plus per-backend settings (space)
start-here.md      the index: each note, and when to read it
preferences.md     how the user wants work done
core-rules.md      rules that cost the most when broken
coordinating.md    briefing, running and merging other agents
gotchas/<stack>.md a stack the session touches
profile.md         who the user is                          (phase 3)
references.md      reference facts and links               (phase 3)
pending.md         writes queued while a backend is down    (phase 4)
```

## Backends

A backend maps lore's operations onto a notes store, so any MCP can be attached by writing one
file under `backends/`. This release ships **`files`** (the store above, nothing else installed)
and **`tartib`** (the configured space, over the Tartib MCP tools). `files.md` and `tartib.md`
name the concrete call behind each operation and its quirks.

Resolve the backend before acting:

```bash
lore-store.sh config          # backend: <name>, then space: <name> when set
lore-store.sh config mapping  # the mapping file to read
```

No `config`, or `backend: files`, means the files backend: everything runs on `~/.agents/memory/`.
When the configured backend is unavailable, say so in one line and work from the files snapshot;
never create a Tartib space or a store to make it reachable.

## Operations

Every backend maps these eight. Use the name, then read the mapping for the call:

| Operation | What it does |
|---|---|
| reachable? | can this backend be read right now (read-only) |
| find a note | locate one note by its identity |
| read a note with thoughts | the note's text and its unfiled thoughts |
| add a thought | append one dated lesson to a note |
| change a few words (a bump) | raise one rule's `(×N)` in place |
| rewrite a note (Fold) | replace a note's text with the folded version |
| delete a thought | remove one folded thought |
| create a note | make a new note, never a new space |

## The notes, and when to read them

| Note | Read when |
|---|---|
| `start-here.md` | Anything below is unclear; it is the index and the method. |
| `preferences.md` | Always, at session start. |
| `core-rules.md` | Always, at session start. |
| `coordinating.md` | You brief, run or merge other agents. |
| `gotchas/<stack>.md` | The work touches that stack. |

Do not read the whole store. Do not summarise the notes back to the user; follow them.

## Commands

Claude Code: `/lore:load`, `/lore:retro`, `/lore:fold` (files in `commands/`, linked from
`~/.claude/commands/lore`). Other hosts: name the step ("run the lore retro"). Each command file
stands alone.

- **Load** (session start): resolve the backend, read preferences and core rules, then only the
  gotchas notes the work touches. Read-only after setup.
- **Retrospective** (end of session, or when asked): turn this session's lessons into general
  ones; a bump for a rule already covered, a thought for a new one. A preference only after the
  user confirms it in words; a new stack's gotchas note only when a stack has none.
- **Fold** (a note with 10 or more thoughts, or when asked): merge the thoughts into the note
  text, read it back, then delete them. Never delete a thought whose content is not in the text
  you just read back.

## Never

- Never write a near-duplicate rule; bump the existing one.
- Never record a project fact, a project name, or a session story here.
- Never put secrets, hostnames, IPs or customer data in a note.
- Never rewrite a note's text beyond the rule you are changing, except in Fold.
