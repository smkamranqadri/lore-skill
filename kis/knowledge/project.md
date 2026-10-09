# Project

lore-skill is the source repo of **lore**: one memory across projects for any agent (Claude
Code, Codex, Command Code, others). It holds what is true in every project: lessons,
preferences, gotchas per stack, the user profile and references. It replaces the
agent-lessons skill.

## Neighbours

- **KIS** (`../kis-loop-skill`, installed per project under `.agents/skills/kis`): project
  memory. Project facts and decisions belong there, never in lore.
- **orch and session-close** (`../orch-skill`): run state and the closing routine. The
  per-project Tartib status space belongs to them, not to lore.
- Each of the three works alone; none requires another.

## What lore replaces (as of 2026-10-09)

- Install: `~/.agents/skills/agent-lessons` (1.0.0), linked from
  `~/.claude/skills/agent-lessons`; commands linked at `~/.claude/commands/lessons`
  (`/lessons:load`, `/lessons:retro`, `/lessons:fold`). No source repo; the install is the
  only copy.
- Content: Tartib space `ai-agents`, 12 notes: `Agents: start here` (index), preferences,
  core rules, coordinating parallel agents, gotchas for shell/macOS/Claude Code, Flutter,
  web, backend data, infra, Pencil MCP, Herdr, and `Codex experiment: rollback`.
  Preferences and core rules are each near the 15,000-character fold limit.
- Live files that name agent-lessons or `/lessons:*`: in orch-skill
  `skills/orch/SKILL.md`, `skills/orch/commands/start.md`, `skills/orch/commands/handoff.md`,
  `skills/session-close/SKILL.md`, `kis/knowledge/project.md`; global
  `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, `~/.commandcode/AGENTS.md`. No settings,
  hooks or sub-agent definitions mention it (checked 2026-10-09).

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
