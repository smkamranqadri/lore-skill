# Project

lore-skill is the source repo of **lore**: one memory across projects for any agent (Claude
Code, Codex, Command Code, others). It holds what is true in every project: lessons,
preferences, gotchas per stack, the user profile and references.

## Neighbours

- **KIS** (`../kis-loop-skill`, installed per project under `.agents/skills/kis`): project
  memory. Project facts and decisions belong there, never in lore.
- **orch and session-close** (`../orch-skill`): run state and the closing routine. The
  per-project Tartib status space belongs to them, not to lore.
- Each of the three works alone; none requires another.

## Current install and store

- Lore 0.5.0 installs at `~/.agents/skills/lore`, with Claude discovery linked at
  `~/.claude/skills/lore` and commands at `~/.claude/commands/lore`.
- Commands: `/lore:load`, `/lore:retro`, `/lore:fold`, `/lore:backend`; other hosts name
  the step. Backend config lives at `~/.agents/memory/config`.
- No config or `backend: files` means the Markdown store at `~/.agents/memory/`.
  With an MCP backend, that folder holds the snapshot, pinned ids and pending queue.
- The owner's backend is Tartib, space `ai-agents`; the mapped note identities and pinned-id
  load path are described below. Lore never creates a space or uses host memory as its store.

## Seed sources for profile and references

Claude Code's per-project memory (`~/.claude/projects/*/memory/*.md`, 33 files on
2026-10-09, frontmatter `type: user | feedback | project | reference`), `~/.claude/CLAUDE.md`,
and KIS Knowledge files. Read once for the seed; lore never depends on them afterwards.
Phase 3 read the 6 `user`/`reference` entries, CLAUDE.md and the cross-project KIS references,
drafted `.orch/lore/seed-candidates.md`, and wrote only the owner-approved lines
(`.orch/lore/seed-approved.md`) as the two notes.

## Shape

Like orch-skill: `skills/lore/` ships and is copied verbatim to `~/.agents/skills/lore`; the
installer also makes the Claude links `~/.claude/skills/lore` (-> `../../.agents/skills/lore`) and
`~/.claude/commands/lore` — a correct link is left alone, anything else at the path is kept and
reported, even with `--force`; `bootstrap.sh` installs, checks and updates; `tests/run.sh` runs the
tests. KIS 0.10.0 is installed in this repo from the local `../kis-loop-skill` clone.

Phase 1 (2026-10-09) ships `skills/lore/SKILL.md`, the `load`/`retro`/`fold` commands,
`backends/files.md`, and `scripts/lore-store.sh` (subcommands: init, list, read, sha, create,
add-thought, bump-rule, fold-done). Note format: one rule per source line, `(×N)` at the end of
a rule, thoughts under `## Thoughts`. Tests in `tests/` install into a temporary HOME.

Phase 2a (2026-10-09, version 0.2.0) ships `backends/tartib.md` and a `config` subcommand on
`lore-store.sh` that resolves the backend, space and mapping file from `~/.agents/memory/config`
(no config, or `backend: files`, means the files backend). SKILL.md and the commands now name the
eight operations and read the mapping of the configured backend instead of naming tools. The live
Tartib space `ai-agents` holds 12 notes; the ones lore maps: `Agents: start here` (333),
`Agents: preferences` (323), `Agents: core rules` (324), `Agents: coordinating parallel agents`
(325), and the `Gotchas: …` notes. Lore uses the configured space only; it never creates one.

Phase 3 (2026-10-09, version 0.3.0) adds the two notes. `profile.md` (Tartib `User: profile`, 405)
and `references.md` (`User: references`, 406) join the store layout and the files backend's
starter notes; load reads the profile always and references only when a task needs a location; a
profile fact lands only after the owner confirms it in words, and a reference never holds a secret,
address or value. `ai-agents` now holds 14 notes; `Agents: start here` links both new notes.
Proved by `tests/run.sh` (the two new `init` guards mutation-checked) and
`.orch/lore/proof-phase3-tartib.txt`.

Phase 4 (2026-10-09, version 0.4.0) adds the fallback. When the configured backend is an MCP and it
is unreachable, the store becomes a snapshot and the agent offers exactly three choices: reconnect
it, work from the snapshot for now (each write goes to the snapshot **and** to `pending.md`, Fold is
refused, and the queue replays at the next load), or switch to files for good. `lore-store.sh` adds
`snapshot-write`/`snapshot-read`, `queue-add`/`queue-list`/`queue-pop`/`queue-clear`,
`fallback-write` (snapshot + queue together) and `switch-files`; a replay applies entries oldest
first and pops each only after its write succeeded, stopping at the first failure and keeping the
rest. A new `/lore:backend` command drives config, reachability, reconnect, replay and switch. The
MCP calls stay the agent's, per the mapping; the files-side mechanics are proved in temp homes by
`tests/test-fallback.sh` and `.orch/lore/proof-phase4.txt`. The live acceptance of 0.4.0 passed
2026-10-09 (`.orch/lore/live-acceptance-0.4.0.md`); it found that a replay must first `search` for
the target note's id, which the old "before any read" wording did not allow.

0.4.1 (2026-10-09) fixes that wording — a replay runs before the load's own note reads and may look
up each target note it writes — and has `install-skill.sh` create the Claude discovery link
`~/.claude/skills/lore` under the `--no-claude-link` opt-out (correct: left alone; anything else:
kept and reported even with `--force`), with `bootstrap.sh check` reporting a missing or different
link. It also pins the snapshot rendering: `lore-store.sh snapshot-render` writes the title once as
the H1, the rest of the note's text byte for byte, then `## Thoughts` per `--thought <date> <text>`
(the tartib mapping names the call), so two agents produce the same bytes. Proved by
`tests/test-skill-links.sh` (8 guards mutation-checked), a `snapshot-render` fixture (7 guards
mutation-checked) and `.orch/lore/proof-041.txt`.

0.5.0 (2026-10-09, branch `lore-ids`) pins the load path to ids. A load reads each mapped note by
its pinned id (`get_item <id>`) and never by `search` or a space listing; the ids live in the store
(`~/.agents/memory/ids`, `<note><TAB><id>` plus a title for gotchas), not in the shipped mapping, so
`bootstrap.sh update` cannot clobber them. `lore-store.sh` adds `ids-list`, `ids-pin <note> <id>
[title]`, `load-plan [--note <note>]...` (the read and title for each note, the queue length and the
snapshot check) and `load-size <note>...` (the load's size line, budget from `budget:` in the config,
default 60000). The default load is preferences, core rules and the profile; a gotchas note only for
a stack in play, coordinating only when briefing agents, references only when a location is needed.
An absent or stale pin self-heals with **one** `search` and is reported, then re-pinned. It cuts a
live load from ~171k chars (5 `search` + 4 `get_item`) or ~139k (one listing) to 25,990 chars for the
three notes, and drops the ~30k of skill internals a load used to read. Proved by the new
`tests/test-load-path.sh` (4 guards mutation-checked), `tests/run.sh`, a clean live
`bootstrap.sh update`/`check` to 0.5.0, and `.orch/lore-ids/proof.txt`.
