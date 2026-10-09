# Current

- Branch: `main`, tracking `origin/main` at `https://github.com/smkamranqadri/lore-skill`
  (private until the owner says otherwise), pushed 2026-10-09 through the phase 3 commit.
  Commits: `5f69f00` phase 1, `39486f4` phase 2a, the phase 2 switch sync, phase 3.
- Task: none in progress. **Phase 3 (profile and references) done** 2026-10-09: the owner
  approved the seed line by line (stage A), stage B shipped the two notes and the skill change;
  verified by the orchestrator (notes match the approved lines, suite, one more mutation).
- Live (2026-10-09): lore **0.3.0** at `~/.agents/skills/lore` (`bootstrap.sh update` then
  `check` current). `~/.claude/commands/lore`
  and `~/.claude/skills/lore` present; `~/.agents/memory/config` = `backend: tartib`, `space:
  ai-agents`.
- Command: `tests/run.sh`; `./bootstrap.sh check --source .`.
- Blocker: none.
- Proof (phase 3): `.orch/lore/proof-phase3-tartib.txt` (dated). Full suite green (install and
  store); the new `init` guards mutation-checked (4 mutations, each failed with its expected
  message, the saved original written back identical); Tartib notes 405 `User: profile` and 406
  `User: references` written from the approved lines and read back; `Agents: start here` (333)
  gained one link line for each (`find_replace`, `expected=1`, `scope=text`; lines 8 and 19 only),
  and a load-style `search` then `get_item` read of `User: profile` succeeded.
- Not proved: the host-instruction redirect (phase 5).
- Next: phase 4 (fallback, snapshot, queue) on the owner's go.
