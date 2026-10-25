# Current

- Branch: `lore-2.0` (local, not pushed) at `3e44b1e`; `main` tracks `origin/main` at
  `https://github.com/smkamranqadri/lore-skill` (public). Installed live: lore 2.0.0-p4a beside
  1.x (2026-10-25, `update` and `check` exit 0). 1.0.0 is the last public release; `v1.1.0` is
  tagged locally at `e52b56e`, not released.
- Task: P4a done 2026-10-25 (`82784d5` server, `3e44b1e` UI; proof in the plan's Status). Revert
  moved to P4b under the owner's cap; its work is kept at `refs/orch/p4a-server-r5`. Next: P5
  (eval and switch), unless the owner picks one of the open items below first.
- Open, waiting on the owner: (1) P1 bug: hub integration (fetch-rebase without
  `--rebase-merges`) drops an owner merge's own changes, also in 2.0.0-p3/p4a (CHANGELOG "Known
  limit"); a small stream is proposed. (2) The 1.x timer (below). (3) About 400 leftover `tmp.*`
  dirs from test runs in `/home/mkamran/.cache/lt` (not inspected yet).
- Command: `tests/run.sh` from a short `TMPDIR` (see Knowledge, Test facts), about five minutes;
  `./bootstrap.sh check --source .`; worker proof `.orch/lore-2.0/verify.sh build|repro|clean`; `lore ui` serves the UI on 127.0.0.1:3870.
- Blocker: none.
- Live store `~/.agents/lore` holds no rules yet by the owner's choice (filing session in P5); its
  queue holds a stray temp file `.git/lore/queue/.in-1792702601-...` from 2026-10-23, ignored by
  filing, not deleted. Agents do not call `lore remember` until P5 delivers the 2.0 index.
- 1.x track (soak 2, until P5): since 2026-10-22 19:53, 16 runs and 2 fails. The 2026-10-25 00:13
  fail was the headless Codex (Luna low) stopping before its Tartib writes and `sync-done`; lore
  logged it and backed off correctly. `lore-sync.timer` has had no next run since the reboot of
  2026-10-23 (cause in Knowledge, Test facts); re-arming it (`systemctl --user start
  lore-sync.service`) and an `OnStartupSec` fix in `lore_sync.py` wait on the owner. Release gate for 1.1.0: a run of `sync-log` with session-triggered
  runs and no failures; then the owner commits the release. Open: macOS install and
  macOS-portable test scripts (no Mac); the owner rotates the Tartib token.
