# Current

- Branch: `main`, no remote. Phase 1 committed as `5f69f00` (the orchestrator's commit; it tracks
  `.agents/`, `.claude/` and `.pi/`, as in orch-skill).
- Task: phase 2a of `../intent/plan-2026-10-09-lore.md` (Tartib backend and live probe) — **DONE,
  uncommitted**. Phase 2 is split: 2a is this repo; the orchestrator installs lore into the real
  home and removes agent-lessons, and a Claude worker updates the orch-skill pointer files.
- Command: `tests/run.sh`; the probe called the Tartib MCP tools directly.
- Blocker: none.
- Proof (2026-10-09):
  - `tests/run.sh` → `install tests: pass` and `store tests: pass`; the log was read in full.
  - 29 guards mutation-checked (the 27 from phase 1 plus `config-mapping-missing` and
    `config-unknown-key`): each broken with a literal edit, its test observed to fail, the
    original written back (`restored: True`).
  - Live probe on `ai-agents` with a temporary config: reachable; load read 323 (2 thoughts) and
    324; retro added thought 471 to 333 and deleted it (count back to 0); the bump raised rule 1
    `(×15)`→`(×16)` and lowered it back with `expected=1 scope=text`, before and after sha256 both
    `6c92e1de…a467bc` (16772 bytes). Full record: `.orch/lore/proof-tartib-probe.txt`. Side effect:
    324's text is byte-identical but its `updated_at` moved to 2026-10-09T11:56:59.600Z.
  - The real `$HOME` stayed untouched: no `~/.agents/memory`, `~/.agents/skills/lore` or
    `~/.claude/commands/lore`.
- Next: the orchestrator commits phase 2a, installs lore with `backend: tartib` space `ai-agents`
  and removes agent-lessons after `check` passes; then phase 3 (profile and references).
