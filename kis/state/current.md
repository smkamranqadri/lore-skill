# Current

- Branch: `lore-2.0` (local, not pushed; last code commit `87ab73a`, KIS commits follow it); `main` tracks `origin/main` at
  `https://github.com/smkamranqadri/lore-skill` (public). Installed live: lore 2.0.0-p4a.1 beside
  1.x (2026-11-05, `update` and `check` exit 0). 1.0.0 is the last public release; `v1.1.0` is
  tagged locally at `e52b56e`, not released.
- Task: P5 planned 2026-11-05 (see the 2.0 plan's "P5 detail"): P5a Eval, P5b Switch, P5c File and
  release, a gate after each. Next: P5a, starting with the fixture in `tests/fixtures/eval/` committed
  before any real run; the owner has not yet told the orch to start building. Of the Hindsight-inspired
  items only "keep the last good index" is in (P5b); the other two are post-2.0.
- Command: `tests/run.sh` from a short `TMPDIR` (see Knowledge, Test facts), about five minutes;
  `./bootstrap.sh check --source .`; worker proof `.orch/lore-2.0/verify.sh build|repro|clean`; `lore ui` serves the UI on 127.0.0.1:3870.
- Blocker: none.
- Live store `~/.agents/lore` holds no rules yet by the owner's choice (filing session in P5); its
  queue holds a stray temp file `.git/lore/queue/.in-1792702601-...` from 2026-10-23, ignored by
  filing, not deleted. Agents do not call `lore remember` until P5 delivers the 2.0 index.
- 1.x track (soak 2, until P5): the headless Codex sync (Luna low) still fails at times (checked
  2026-10-25: 4 failures, 2 runs); lore logs and backs off correctly. `lore-sync.timer` now writes `OnStartupSec=2min` (rewritten live 2026-11-05, next run shown by
  `systemctl --user list-timers`). Release gate for 1.1.0: a run of `sync-log` with session-triggered
  runs and no failures; then the owner commits the release. Open: macOS install and
  macOS-portable test scripts (no Mac); the owner rotates the Tartib token.
