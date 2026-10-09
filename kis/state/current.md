# Current

- Branch: `main`, tracking `origin/main` at `https://github.com/smkamranqadri/lore-skill`
  (private until the owner says otherwise). Commits: `5f69f00` phase 1, `39486f4` phase 2a, the
  phase 2 switch sync, `8ccb83f` phase 3 (0.3.0), `825a86b` phase 4 (0.4.0), `370d7fe` 0.4.1.
  Pushed through `8ccb83f`; later commits are local until the owner says push.
- Task: none in progress. The plan `../intent/plan-2026-10-09-lore.md` is complete: all five
  phases done 2026-10-09.
- Live (2026-10-09): lore **0.4.1** at `~/.agents/skills/lore`; `./bootstrap.sh check --source .`
  reports `Already current: lore` and `Claude skill link already current: lore` (exit 0).
  `~/.agents/memory/config` = `backend: tartib`, `space: ai-agents`; the snapshot holds the 13
  mapped notes in the pinned rendering (title once), `pending.md` empty.
- Command: `tests/run.sh`; `./bootstrap.sh check --source .`.
- Blocker: none.
- Proof: 0.4.1 `.orch/lore/proof-041.txt` (suite, 8 link and 7 render mutations), re-run by the
  orchestrator with one more render mutation; live snapshot `.orch/lore/proof-snapshot-refresh.txt`;
  phase 4 `.orch/lore/proof-phase4.txt` and `.orch/lore/live-acceptance-0.4.0.md`.
- Not proved: the replay wording and the rendering pin are prose around a script (the fixture
  proves the script's bytes, not that an agent passes the right arguments). The gotchas slug is not
  pinned by the mapping; the refresh used title-derived slugs that match the existing files.
- Next: push at the owner's word. Possible follow-up: pin the gotchas slugs in the mapping table.
