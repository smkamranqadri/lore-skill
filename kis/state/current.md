# Current

- Branch: `main`, tracking `origin/main` at `https://github.com/smkamranqadri/lore-skill`
  (public since 2026-10-09). Lore **0.6.0** merged on main 2026-10-14 (rebased onto `7f6f4e1`);
  vendored KIS at 0.10.1.
- Task: done — `Agents: core rules` (74 rules) split into a 13-rule always-loaded core plus four
  on-demand topic notes (`core-verify.md`, `core-production.md`, `core-tools.md`, `core-user.md`),
  numbers and text unchanged. The Tartib migration (`orch-skill/.orch/rules-split/migration.md`)
  is applied by the owner's orchestrator right after this merge, then 0.6.0 is installed.
- Command: `tests/run.sh`; `orch-skill/.orch/rules-split/check-split.sh`; `./bootstrap.sh check --source .`.
- Blocker: none.
- Proof: `tests/run.sh` five suites pass in a clean detached checkout of the 0.6.0 commit, with
  mutation-checked guards in `tests/test-load-path.sh` and `tests/test-store.sh`. `check-split.sh`:
  PASS — 74 rules exactly once, byte-identical to the snapshot (which matched live note 324 on
  2026-10-14), default load 27,007 -> 14,964 chars. Detail: `orch-skill/.orch/rules-split/report.md`.
- Earlier: 0.5.0 (pinned ids, `d92ba09`); the six-finding review and the lore-context investigation
  are closed (`orch-skill/.orch/reviewfix/`, `.orch/fixes/lore-context-report.md`). Stale-pin
  recovery remains fixture-only.
- Next: none due. The 3 thoughts on note 324 wait for the next `/lore:fold`.
