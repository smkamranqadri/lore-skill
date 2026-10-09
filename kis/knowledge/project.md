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

## Shape

Like orch-skill: `skills/lore/` ships and is copied verbatim to `~/.agents/skills/lore`;
`bootstrap.sh` installs, checks and updates; `tests/run.sh` runs the tests. KIS 0.10.0 is
installed in this repo from the local `../kis-loop-skill` clone.

Phase 1 (2026-10-09) ships `skills/lore/SKILL.md`, the `load`/`retro`/`fold` commands,
`backends/files.md`, and `scripts/lore-store.sh` (subcommands: init, list, read, sha, create,
add-thought, bump-rule, fold-done). Note format: one rule per source line, `(×N)` at the end of
a rule, thoughts under `## Thoughts`. Tests in `tests/` install into a temporary HOME.
