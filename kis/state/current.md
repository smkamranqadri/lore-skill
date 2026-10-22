# Current

- Branch: `main`, tracking `origin/main` at `https://github.com/smkamranqadri/lore-skill`
  (public). Version: lore 1.0.0. Vendored KIS 0.10.1.
- Task: lore 1.1.0 (2026-10-19), uncommitted: scheduled headless hub sync (`sync-run`, `sync-log`,
  `sync-timer`; Codex `gpt-6-luna` low), index no longer carries the sync line. Plan and proof:
  `../intent/plan-2026-10-19-lore-1.1.0-scheduled-sync.md`. 1.0.0 stays the last public release
  (tag `v1.0.0` and branch `backup/pre-squash-1.0.0` not found locally on 2026-10-19; check origin).
- Live: systemd user timer `lore-sync.timer` every 30 min on the owner's Linux machine; read
  `lore.py sync-log --days 7` after a few days and tune `--every`.
- Command: `tests/run.sh` (about five minutes here: each Python start costs about 1 s in the agent
  sandbox); `./bootstrap.sh check --source .`.
- Blocker: none.
- Installed on the owner's Linux machine (2026-10-16): skill, memory with a Tartib hub, index and
  hooks in all four agents; host settings backed up first.
- Soak 1 (2026-10-19 to 22) FAILED: 80 of 81 timer runs timed out at 900 s. Cause: `~/.local/bin/codex` is
  a wrapper (`mise use -g`, `mise x`) that hangs without a TTY under systemd; the real binary works.
  Fixed: `sync_cmd` in the machine's config names the mise binary; backoff 2 h after a failure;
  timeout 300 s. Proof: forced run under systemd rc 0 in 31 s; tests green; 4 new guards mutated.
- Soak 2 (from 2026-10-22 20:09): sync is event-driven. The capture hook chains `sync-run --trigger
  <host>:<event>` after the harvest; the timer is a 6 h safety net. Proof so far: test-syncrun.sh
  section 10 (three sessions, three runs, trigger logged; 3 mutations tripped) and one live hook
  call logged a skip with its trigger. Still to prove live: a real session end after a memory change.
- lore 2.0 (2026-10-22): planned, Phase mode, `../intent/plan-2026-10-22-lore-2.0.md`. 1.1.0 is
  held, not released; the owner commits the 1.1.0 work to branch `lore-2.0` and P1 builds there.
  Soak 2 keeps running so 1.x memory syncs until the 2.0 switch; 2.0 runs beside 1.x until P5.
  Plan reviewed (Fable 5.1 high, approve with changes, all 15 findings applied). Branch
  `lore-2.0` (local, not pushed); `v1.1.0` tagged locally at `e52b56e`.
- P1 done 2026-10-23 and installed live as 2.0.0-p1 (`lore-2.0` at `75cbc2d`; proof in the plan's
  Status). 2.0 store `~/.agents/lore`, private hub `smkamranqadri/lore-memory`, shim
  `~/.local/bin/lore`. 1.x keeps running beside it. Next: P2 (Loremaster).
- Soak 2 issue (1.x, before P1): 23:29 run on 2026-10-22 logged `fail` because the headless Codex
  had no Tartib tools; Tartib MCP and the Codex token both answer 200 at 01:2x, so it was transient.
  Backoff to ~01:29, 7 files pending push; next session end retries.
- orch on Herdr: spawn pastes without submitting, finish notices missing or early (Tartib #524,
  orch-skill ideas 15 and 16); agent `orch-fix` in the orch-skill workspace, coordinated by the
  owner. Until fixed, this orch tracks completion with its own watchers and `verify.sh`.
- Scratch left running from the understory evaluation (session scratchpad, not this repo):
  CLIProxyAPI on 127.0.0.1:8317 in the owner's terminal, understory on :3800 with dreaming every
  5 min. Stop both when the evaluation ends.
- Before 2.0 (1.x): after ~24 h read `lore.py sync-log --days 2` (ignore entries before 2026-10-22 19:53), confirm
  `run` lines with a session trigger and no failures, then release 1.1.0 (owner commits); macOS
  install (no Mac now); macOS-portable test scripts. Owner rotates the Tartib token.
