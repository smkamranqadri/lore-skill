# Current

- Branch: `main`, tracking `origin/main` at `https://github.com/smkamranqadri/lore-skill`
  (private until the owner says otherwise), pushed 2026-10-09 through the phase 3 commit.
  Commits: `5f69f00` phase 1, `39486f4` phase 2a, the phase 2 switch sync, phase 3 (`8ccb83f`).
- Task: none in progress. **Phase 4 (fallback: snapshot, queue, replay, `/lore:backend`) built and
  proved in this repo, uncommitted** 2026-10-09. 10 files modified, 2 new
  (`skills/lore/commands/backend.md`, `tests/test-fallback.sh`); `SKILL.md` at 0.4.0.
- Live (2026-10-09): lore **0.3.0** at `~/.agents/skills/lore` (`bootstrap.sh update` then
  `check` current). `~/.claude/commands/lore` and `~/.claude/skills/lore` present;
  `~/.agents/memory/config` = `backend: tartib`, `space: ai-agents`.
- Command: `tests/run.sh`; `./bootstrap.sh check --source .`.
- Blocker: none.
- Proof (phase 4): `.orch/lore/proof-phase4.txt` — an acceptance transcript from a temporary home
  (`backend: tartib`, no MCP reached), the full `tests/run.sh` log, and the 22 mutations. Phase 3:
  `.orch/lore/proof-phase3-tartib.txt`.
- Verified: `tests/run.sh` green (install, store, fallback). Every new guard mutation-checked: 22
  mutations, each broke one guard, `tests/test-fallback.sh` was observed to fail with the expected
  message, and the saved original was written back (diff identical).
- Not proved: the live acceptance of the fallback (a session without Tartib, then one with it) is
  the orchestrator's; the MCP calls themselves stay the agent's, per the mapping.
- Next: the orchestrator commits the paths in the handoff, then `bootstrap.sh update --source .`
  and `check` to move the live install to 0.4.0, then runs the live fallback acceptance; advisor
  review before marking phase 4 done.
