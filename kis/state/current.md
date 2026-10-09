# Current

- Branch: `main`, no commits yet, no remote.
- Task: phase 1 of `../intent/plan-2026-10-09-lore.md` (files alone) — **DONE, uncommitted**.
  The orchestrator commits it (message and paths in `.orch/lore/handoff.md`).
- Command: `tests/run.sh` (runs `test-install.sh` and `test-store.sh`).
- Blocker: none.
- Proof (2026-10-09):
  - `tests/run.sh` → `install tests: pass` and `store tests: pass`; the log was read in full.
  - 27 guards mutation-checked: each broken with a literal edit, its test observed to fail with
    the expected message, the original written back (`restored: True`).
  - Acceptance in a temporary home (no backend): first load created the starter notes from an
    empty store; retro added a dated thought and raised an existing rule's `(×2)`→`(×3)`; fold
    merged a thought into the text, read it back, then deleted it. The real `$HOME` stayed
    untouched (no `~/.agents/skills/lore`, `~/.claude/commands/lore` or `~/.agents/memory`).
- Next: phase 2 (Tartib and the switch), after the orchestrator commits phase 1.
