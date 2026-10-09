# Current

- Branch: `main`, tracking `origin/main` at `https://github.com/smkamranqadri/lore-skill`
  (private until the owner says otherwise), pushed 2026-10-09. Commits: `5f69f00` phase 1,
  `39486f4` phase 2a, then the phase 2 switch sync.
- Task: none in progress. Phase 2 of `../intent/plan-2026-10-09-lore.md` is **done**
  (2026-10-09); phase 3 (profile and references) waits for the owner's go.
- Live (2026-10-09): lore 0.2.0 at `~/.agents/skills/lore` (`bootstrap.sh check --source .`
  current), `~/.claude/commands/lore`, `~/.claude/skills/lore` (made by hand: no installer here
  or in orch-skill creates `~/.claude/skills/<name>`); `~/.agents/memory/config` holds
  `backend: tartib`, `space: ai-agents` and resolves through `lore-store.sh config`.
  agent-lessons removed; backup and the pre-switch global files in
  `~/.agents/lore-switch-backup-20261009/`.
- Command: `tests/run.sh`; `./bootstrap.sh check --source .`.
- Blocker: none.
- Proof: 2a in the plan Status and `.orch/lore/proof-tartib-probe.txt` (probe thought 471 gone,
  core rule 1 back at ×15, rechecked by the orchestrator). Switch: no live file under
  `~/.agents/skills`, `~/.claude` (CLAUDE.md, agents, settings), `~/.codex/AGENTS.md` or
  `~/.commandcode/AGENTS.md` names agent-lessons or `/lessons:`.
- Proof of the installed path (2026-10-09, lore 0.2.0): a Haiku sub-agent ran `/lore:load` with
  the real config: backend tartib, space ai-agents reachable, read 323, 324 and 326, no writes,
  `~/.agents/memory` holds only `config`. Tartib notes 333 and 325 reworded to lore by
  `find_replace` (one line each, owner approved); no ai-agents note names agent-lessons.
- Not proved: orch and session-close with lore absent (checked by reading the fallback prose,
  not by a run).
- Before phase 3: probe whether the lore agent (Command Code) can read and write outside this
  repo (it did read outside during 2a); refresh or drop `.orch/lore/ref/`; read its context.
  `commands/load.md` already says "work from the files snapshot" when unreachable; that
  snapshot is phase 4.
- Next: phase 3 (profile and references) on the owner's go.
