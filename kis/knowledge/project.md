# Project

lore-skill is the source repo of **lore**: one memory across projects for any agent (Claude
Code, Codex, Command Code, others). It holds what is true in every project: lessons,
preferences, gotchas per stack, the user profile and references.

## Mission

Tell it once: lore learns how the user works (preferences, tech stack, hard-won lessons) and every
coding agent and model they use already knows it. Vision: any coding agent, frontier or local,
knows the user from the first message; the memory is plain files in the user's own git repo.
Scope is coding agents only. The 2.0 direction is in `../intent/plan-2026-10-22-lore-2.0.md`.

## Facts that shape 2.0 (checked 2026-10-22)

- 1.x memory files are 53% sync metadata (37,145 of 70,003 characters, `<!-- -->` comments and
  `Confidence:` suffixes), all of it read by agents.
- A hub sync through a model costs 40k to 90k tokens a run (Codex Luna low).
- A registered MCP server's tool schemas load into every session on every host, used or not.
- Host memories: Claude Code's auto memory is controlled by `autoMemoryEnabled` (env
  `CLAUDE_CODE_DISABLE_AUTO_MEMORY`), found in the installed binary; Codex has a `memories`
  feature (off here, empty database); Command Code learns into `~/.commandcode/taste/taste.md`.
- understory (thecodacus, `7625aa4`, v0.1.0, one author) with a librarian on gpt-6.1-sol low:
  every write enriched one note into a blob; ingest reworded and merged facts; its dream split a
  note only past 6,000 characters or 6 sections, and kept every rule through the split. Left on a
  5-minute interval, it ran 29 dreams: 1 changed files (the split), 28 ran the model and changed
  nothing, because its gates still saw work after the split. Gates must turn quiet once fixed.

## Neighbours

- **KIS** (`../kis-loop-skill`, installed per project under `.agents/skills/kis`): project
  memory. Project facts and decisions belong there, never in lore.
- **orch and session-close** (`../orch-skill`): run state and the closing routine. The
  per-project Tartib status space belongs to them, not to lore.
- Each of the three works alone; none requires another.

## Install (checked 2026-10-25)

- The skill installs at `~/.agents/skills/lore` (2.0.0-p3), linked for Claude at
  `~/.claude/skills/lore` and `~/.claude/commands/lore` (commands sync, learn-taste, retro). The
  installer leaves a correct link alone and keeps and reports anything else at the path.
- 1.x store `~/.agents/memory` with the Tartib hub; 2.0 store `~/.agents/lore` (git) with the
  private hub `github.com/smkamranqadri/lore-memory`, shim `~/.local/bin/lore`. Both run until P5.
- Vendored KIS 0.10.1 under `.agents/skills/kis`.
- History before 1.0 (0.x: `lore-store.sh`, Tartib note ids, the core split) is in git and the
  1.0.0 commit `90b0f72`.

## Test facts

- `tests/run.sh` fails four older suites (test-canon, test-lint, test-master, test-store2) when
  `TMPDIR` is long (about 130 characters, such as an agent's session scratchpad): the index-budget
  tests print the store path into the index. They pass from a short path; run proof runs with
  `TMPDIR=/home/mkamran/.cache/<dir>` (checked on base `1f6dff3`, 2026-10-24).
- The 1.x `lore-sync.timer` (`OnBootSec=2min`, `OnUnitActiveSec=6h`) never fires after a login
  more than 2 minutes after boot: `OnBootSec` counts from kernel boot and has passed when the user
  manager starts the timer, and `OnUnitActiveSec` needs a run of the service in this boot
  (journal and `systemctl show`, checked 2026-10-25). `OnStartupSec` counts from the user manager.
