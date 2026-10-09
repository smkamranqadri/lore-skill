# Current

- Branch: `main`, tracking `origin/main` at `https://github.com/smkamranqadri/lore-skill`
  (private until the owner says otherwise). Commits: `5f69f00` phase 1, `39486f4` phase 2a, the
  phase 2 switch sync, `8ccb83f` phase 3 (0.3.0), `825a86b` phase 4 (0.4.0).
- Task: none in progress. **0.4.1 (replay wording; Claude discovery link; pinned snapshot
  rendering) built and proved in this repo, uncommitted** 2026-10-09. Items 1-2 were verified by the
  orchestrator; items 3-4 (advisor review) are done. 10 files modified (`AGENTS.md`, `bootstrap.sh`,
  `scripts/install-skill.sh`, `skills/lore/SKILL.md`, `backends/files.md`, `backends/tartib.md`,
  `commands/backend.md`, `commands/load.md`, `scripts/lore-store.sh`, `tests/test-fallback.sh`),
  1 new (`tests/test-skill-links.sh`); `SKILL.md` at 0.4.1.
- Live (2026-10-09): lore **0.4.0** at `~/.agents/skills/lore`. `~/.claude/skills/lore` ->
  `../../.agents/skills/lore` and `~/.claude/commands/lore` both correct; `bootstrap.sh check`
  reports the skill `differs` (the repo is now 0.4.1) and the skill link `already current`.
  `~/.agents/memory/config` = `backend: tartib`, `space: ai-agents`. The four live snapshot files
  still repeat the title (the pre-0.4.1 rendering) and must be rewritten; `profile.md` also holds a
  stray empty `## Thoughts` section.
- Command: `tests/run.sh`; `./bootstrap.sh check --source .`.
- Blocker: none.
- Proof (0.4.1): `.orch/lore/proof-041.txt` — the link acceptance transcript, the `/lore:backend`
  show output, a demo of the pinned render against the live `profile.md`, the full `tests/run.sh`
  log, the 8 link mutations and the 7 `snapshot-render` mutations. Phase 4:
  `.orch/lore/proof-phase4.txt`; the live acceptance of 0.4.0 is `.orch/lore/live-acceptance-0.4.0.md`
  and is summarised in the plan's phase 4 status.
- Verified (0.4.1): `tests/run.sh` green (fallback, install, skill-links, store). The item-3 fixture
  renders a Tartib-shaped note to the exact bytes (`cmp`), identical with and without a trailing
  newline, title once, and it pipes into `snapshot-write` unchanged. 15 guards mutation-checked: 8
  link guards plus 7 `snapshot-render` guards, each observed to fail its test with the expected
  message, then the saved originals written back (diff identical).
- Not proved: the live install of 0.4.1 and the rewrite of the four live snapshots (the
  orchestrator's); the replay wording and the rendering pin are prose around a script.
- Next: the orchestrator commits the paths in the handoff, then `bootstrap.sh update --source .` and
  `check` (expect `current`) to move the live install to 0.4.1, then rewrites the four live
  snapshots (a load or a retro with Tartib reachable). Phase 5 (the host-instruction redirect)
  remains.
