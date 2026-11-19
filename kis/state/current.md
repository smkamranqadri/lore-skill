# Current

- Branch: `lore-2.0` (local, not pushed; P5a code commit `decfaad`, KIS sync commit follows); `main` tracks `origin/main` at
  `https://github.com/smkamranqadri/lore-skill` (public). Installed live: lore 2.0.0-p4a.1 beside
  1.x (2026-11-05, `update` and `check` exit 0). 1.0.0 is the last public release; `v1.1.0` is
  tagged locally at `e52b56e`, not released.
- Now: P5a Eval (Phase). Codex Terra high repaired the five review findings plus F6 in the separate
  `p5a-eval` worktree based on `1e37722`. Commit `decfaad` was fast-forwarded from `p5a-eval` onto
  `lore-2.0` on 2026-11-20, per owner direction despite the recorded missed eval bars.
- Status: run 1 (2026-11-10, configured Sonnet medium and Opus high) recorded Loremaster folder
  51/60, oversized 0/23, related 15/20, and Canon 6/8. Run 2 (2026-11-19 UTC, Codex GPT-6.1
  Terra high) recorded Loremaster folder 51/60, oversized 0/26, related 18/20, and Canon 7/8.
  Both Loremaster 15-item meaning sheets await the owner's judgments. Run 1 is under
  `.orch/lore-2.0/p5a-eval-run1/`; run 2 reports, sheets, and temp stores are under
  `.orch/lore-2.0/p5a-eval-run2/`.
- Proof (2026-11-20, final candidate): `PYTHONDONTWRITEBYTECODE=1 bash tests/run.sh` passed all 22 suites. F1–F6 all report `NOT-REPRODUCED` in the independent fresh checkout; the reviewer confirmed byte- and mode-identical transfer across 243 paths (manifest SHA-256 `7e130bbb…89639c`). The targeted eval suite passed. Independent literal mutations caught the persisted Canon retirement ID and F6 ambiguity guards; Terra's F6 mutation also failed and restored byte-identically. Product changes are committed as `decfaad`.
- Proof after apply (2026-11-20): `PYTHONDONTWRITEBYTECODE=1 bash tests/run.sh` on `lore-2.0` exited 0 with all 22 suites.
- Final review (2026-11-20): Codex Sol high cleared F1–F6 on the exact candidate; no remaining blocker found in code review.
- Live eval proof (2026-11-20): one run per role using the approved Codex GPT-6.1 Terra high command. Loremaster used 6 calls, fixture SHA-256 `f2891075…07e1`; Canon used 1 call, v2 fixture SHA-256 `c7a6b485…5082`. Full reports and workdirs are preserved under `.orch/lore-2.0/p5a-eval-run2/`.
- Next: owner judges the 15 fixed meaning samples in the run-2 report and decides whether to close P5a with missed bars or authorize a new tuning scope. The P5a one-round tuning limit is exhausted; no new tuning run is authorized.
- Retrospective: cross-batch attribution uniqueness must be measured from accepted operations before filtering by final-store survival; superseding a rule later must not erase earlier ambiguity.
- Command: `tests/run.sh` from a short `TMPDIR` (see Knowledge, Test facts), about five minutes;
  `./bootstrap.sh check --source .`; worker proof `.orch/lore-2.0/verify.sh build|repro|clean`; `lore ui` serves the UI on 127.0.0.1:3870.
- Blocker: none for applying the reviewed patch. Run 2 missed two bars: Loremaster folder 51/60 versus 90% required; Canon 7/8 because the core-budget gate remains unresolved. The owner meaning judgments remain pending. No further tuning run is authorized.
- Live store `~/.agents/lore` holds no rules yet by the owner's choice (filing session in P5); its
  queue holds a stray temp file `.git/lore/queue/.in-1792702601-...` from 2026-10-23, ignored by
  filing, not deleted. Agents do not call `lore remember` until P5 delivers the 2.0 index.
- 1.x track (soak 2, until P5): the headless Codex sync (Luna low) still fails at times (checked
  2026-10-25: 4 failures, 2 runs); lore logs and backs off correctly. `lore-sync.timer` now writes `OnStartupSec=2min` (rewritten live 2026-11-05, next run shown by
  `systemctl --user list-timers`). Release gate for 1.1.0: a run of `sync-log` with session-triggered
  runs and no failures; then the owner commits the release. Open: macOS install and
  macOS-portable test scripts (no Mac); the owner rotates the Tartib token.
