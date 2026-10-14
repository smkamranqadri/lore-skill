# Current

- Branch: `lore-ids` in worktree `../lore-skill.wt/lore-ids`, based on `main` at `6508528`.
  Not committed, not pushed; `main` is untouched and tracks
  `origin/main` at `https://github.com/smkamranqadri/lore-skill` (public since 2026-10-09).
- Task: DONE — the lore load path reads notes by pinned id, not `search`/listing. Version 0.5.0
  (from 0.4.1): `lore-store.sh` gains `ids-list`, `ids-pin`, `load-plan`, `load-size`; `load.md`
  is self-contained; `backends/tartib.md` names the pinned-id identity and a Load plan; `files.md`,
  `commands/backend.md` and `commands/retro.md` follow. 13 pins live in `~/.agents/memory/ids`.
- Command: `tests/run.sh`; `./bootstrap.sh check --source .`.
- Blocker: none.
- Proof: `tests/run.sh` — all five suites pass, including the new `tests/test-load-path.sh` with
  four mutation-checked guards; live `bootstrap.sh update` -> `Installed lore 0.5.0` and `check`
  -> `Already current`, exit 0; the default load is `load: 3 notes, 25990 chars (budget 60000)`
  against ~171k for the old `search` path. Detail: orch-skill `.orch/lore-ids/proof.txt` and
  `report.md`.
- Not proved: no Tartib MCP in the session, so no live `get_item` and no live stale pin; the
  stale-pin recovery is fixture-only.
- Next: the user decides whether to commit and push `lore-ids`; a resume is a plain continuation
  (work alone, no sub-agents).
