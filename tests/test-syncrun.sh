#!/usr/bin/env bash
# lore sync-run tests: the free gate, the lock, the log, failures and the systemd timer files.
# The headless agent is a fake (LORE_SYNC_CMD); no real model or hub is called. Temporary HOME.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
lore="$repo_root/skills/lore/scripts/lore.py"
tmp="$(mktemp -d)"
trap '[[ -n "${KEEP:-}" ]] || rm -rf "$tmp"' EXIT
export HOME="$tmp/home"; mkdir -p "$HOME"
unset LORE_STORE LORE_SYNC_CMD 2>/dev/null || true
log="$tmp/log"; S="$tmp/store"
fail() { echo "FAIL: $*" >&2; echo "--- last output ---" >&2; cat "$log" >&2 || true; exit 1; }
ok()   { "$@" >"$log" 2>&1 || fail "$* exited non-zero"; }
L() { python3 "$lore" --store "$S" "$@"; }
lines() { wc -l < "$S/sync-log.jsonl" | tr -d ' '; }
last() { tail -n 1 "$S/sync-log.jsonl"; }

# The fake agent: exports the store and records the sync, as commands/sync.md does, then prints
# Codex's token line.
cat > "$tmp/fake-ok.sh" <<FAKE
#!/usr/bin/env bash
d="\$(mktemp -d)"
python3 "$lore" --store "$S" export --out "\$d" >/dev/null
echo '{}' > "\$d.seen"
python3 "$lore" --store "$S" sync-done --pushed "\$d" --remote-seen "\$d.seen" >/dev/null
printf 'done\ntokens used\n12,345\n'
FAKE
printf '#!/usr/bin/env bash\necho boom >&2; exit 3\n' > "$tmp/fake-bad.sh"
printf '#!/usr/bin/env bash\necho quiet\n' > "$tmp/fake-noop.sh"
chmod +x "$tmp"/fake-*.sh

ok L --today 2026-10-01 init
ok L --today 2026-10-01 add --cat git --text "Never run git reset in the main checkout" --explicit

# 1. No hub: skipped for free, and logged.
export LORE_SYNC_CMD="$tmp/fake-ok.sh"
ok L sync-run
last | grep -q '"action": "skip"' || fail "no hub: not a skip"
last | grep -q '"reason": "no hub configured"' || fail "no hub: wrong reason"
ok L sync-run --force
last | grep -q '"reason": "no hub configured"' || fail "--force ran with no hub"

printf 'hub: tartib\nhub_space: agent-memory\n' >> "$S/config"

# 2. Never synced: runs the agent, records tokens, and is quiet afterwards.
ok L sync-run
last | grep -q '"action": "run"' || fail "never synced: did not run"
last | grep -q '"reason": "never synced"' || fail "never synced: wrong reason"
last | grep -q '"tokens": 12345' || fail "token line not parsed"
last | grep -q '"still_due": false' || fail "run left the sync due"
[[ -n "$(ls "$S/sync-runs")" ]] || fail "run output was not kept"

# 3. Nothing changed: skipped, and the agent is not started.
n="$(lines)"
export LORE_SYNC_CMD="$tmp/fake-bad.sh"
ok L sync-run
[[ "$(lines)" == "$((n + 1))" ]] || fail "a skip did not log exactly one line"
last | grep -q '"action": "skip"' || fail "nothing changed: did not skip"
last | grep -q '"reason": "nothing to sync"' || fail "nothing changed: wrong reason"

# 4. A local change runs it; a failing agent is logged as fail and exits non-zero.
ok L --today 2026-10-02 add --cat tools --text "Use pnpm, not npm, in node projects" --explicit
if L sync-run >"$log" 2>&1; then fail "a failing agent exited zero"; fi
last | grep -q '"action": "fail"' || fail "failure not logged as fail"
last | grep -q '"rc": 3' || fail "exit code not logged"
grep -q boom "$S"/sync-runs/*.log || fail "the failed run's output was not kept"

# 4b. After a failure the gate backs off instead of retrying every tick; --force still runs.
n="$(lines)"
ok L sync-run
[[ "$(lines)" == "$((n + 1))" ]] || fail "a backed-off tick did not log exactly one line"
last | grep -q '"action": "skip"' || fail "no backoff after a failure"
last | grep -q 'backing off after a failed run' || fail "backoff reason missing"

# 5. An agent that exits 0 but leaves the sync due is a failure too.
export LORE_SYNC_CMD="$tmp/fake-noop.sh"
if L sync-run --force >"$log" 2>&1; then fail "an agent that synced nothing counted as success"; fi
last | grep -q '"still_due": true' || fail "still_due not logged"

# 6. The lock: a second run while one is going is logged busy and does nothing.
export LORE_SYNC_CMD="$tmp/fake-ok.sh"
( exec 9>"$S/sync-run.lock"; flock -n 9 || exit 9; ok L sync-run; last | grep -q '"action": "busy"' ) \
  || fail "a run under the lock was not busy"
ok L sync-run --force
last | grep -q '"action": "run"' || fail "run after the lock released did not run"
ok L --today 2026-10-02 add --cat tools --text "Use pnpm, not npm, in node projects" --explicit
ok L sync-run
last | grep -q '"action": "run"' || fail "a run after a success was still backing off"

# 6b. sync_cmd in the config replaces the adapter's command (a machine's own invocation).
unset LORE_SYNC_CMD
printf 'sync_cmd: %s\n' "$tmp/fake-ok.sh" >> "$S/config"
ok L sync-run --force
last | grep -q '"host": "config"' || fail "sync_cmd from the config was not used"
export LORE_SYNC_CMD="$tmp/fake-ok.sh"

# 6c. A failure older than the backoff no longer holds the gate back.
python3 - "$S/sync-log.jsonl" <<'PY'
import sys, json, datetime as dt
ts = (dt.datetime.now().astimezone() - dt.timedelta(hours=3)).replace(microsecond=0).isoformat()
open(sys.argv[1], "a").write(json.dumps({"action": "fail", "ts": ts, "reason": "old"}) + "\n")
PY
ok L --today 2026-10-02 add --cat tools --text "Use yarn, not npm, in old projects" --explicit
ok L sync-run
last | grep -q '"action": "run"' || fail "an old failure still held the gate back"

# 7. Old run output is pruned.
for i in $(seq 1 25); do echo x > "$S/sync-runs/2020010${i}.log"; done
ok L --today 2026-10-03 add --cat ui --text "Prefer toggle switches over checkboxes" --explicit
ok L sync-run
[[ "$(ls "$S/sync-runs" | wc -l | tr -d ' ')" -le 20 ]] || fail "sync-runs grew past 20 files"

# 8. The summary counts what happened.
ok L sync-log --days 3650
grep -q 'skip  *[1-9]' "$log" || fail "summary lacks the skips"
grep -q '^  fail  3$' "$log" || fail "summary lacks the three failures"
grep -q 'tokens in runs' "$log" || fail "summary lacks tokens"
grep -q '% of checks needed no model call' "$log" || fail "summary lacks the skip rate"

# 9. The timer: unit files, the interval, removal. A fake systemctl stands in for the real one.
mkdir -p "$tmp/bin"; printf '#!/usr/bin/env bash\necho "$@" >> "%s/systemctl.log"\n' "$tmp" > "$tmp/bin/systemctl"
chmod +x "$tmp/bin/systemctl"
PATH="$tmp/bin:$PATH" ok L sync-timer install --every 45min
u="$HOME/.config/systemd/user"
grep -q '^OnUnitActiveSec=45min$' "$u/lore-sync.timer" || fail "timer interval missing"
grep -q '^OnBootSec=2min$' "$u/lore-sync.timer" || fail "boot catch-up missing"
grep -q "^ExecStart=.* $repo_root/skills/lore/scripts/lore.py --store $S sync-run$" "$u/lore-sync.service" || fail "service command wrong"
grep -q 'enable --user\|--user enable --now lore-sync.timer' "$tmp/systemctl.log" || fail "timer was not enabled"
if PATH="$tmp/bin:$PATH" L sync-timer install --every soon >"$log" 2>&1; then fail "a bad interval was accepted"; fi
PATH="$tmp/bin:$PATH" ok L sync-timer remove
[[ ! -e "$u/lore-sync.timer" && ! -e "$u/lore-sync.service" ]] || fail "timer files left after remove"

# 10. Every session end syncs: the real hook (detached, as a host runs it) chains the gate after the
# harvest. Three sessions, each after a memory change, give three runs logged with their trigger;
# a session with no change gives a skip, still logged with its trigger.
hook="$repo_root/skills/lore/scripts/lore-hook.sh"
unset LORE_SYNC_CMD; export LORE_SYNC_CMD="$tmp/fake-ok.sh" LORE_STORE="$S"
export LORE_EXTRACT_CMD="echo []" LORE_REVIEW_CMD="echo []"
for i in 1 2 3; do
  ok L --today 2026-10-0$((3 + i)) add --cat ui --text "Session rule number $i for the hook proof" --explicit
  before="$(grep -c "\"trigger\": \"claude:SessionEnd\"" "$S/sync-log.jsonl" || true)"
  echo '{"session_id":"s'$i'","transcript_path":"/nonexistent"}' | "$hook" claude SessionEnd
  for _ in $(seq 1 100); do
    now="$(grep -c "\"trigger\": \"claude:SessionEnd\"" "$S/sync-log.jsonl" || true)"
    [[ "$now" -gt "$before" ]] && break; sleep 0.2
  done
  [[ "$now" -gt "$before" ]] || fail "session $i: the hook never reached sync-run"
  last | grep -q '"action": "run"' || fail "session $i: the session end did not sync"
  last | grep -q '"trigger": "claude:SessionEnd"' || fail "session $i: trigger not logged"
done
before="$(grep -c "\"trigger\": \"claude:SessionEnd\"" "$S/sync-log.jsonl")"
echo '{"session_id":"s4","transcript_path":"/nonexistent"}' | "$hook" claude SessionEnd
for _ in $(seq 1 100); do
  now="$(grep -c "\"trigger\": \"claude:SessionEnd\"" "$S/sync-log.jsonl")"; [[ "$now" -gt "$before" ]] && break; sleep 0.2
done
last | grep -q '"action": "skip"' || fail "a session with no change did not skip"
python3 "$lore" --store "$S" sync-status | grep -q '"push": \[\]' || fail "memory left unsynced after the sessions"

echo "test-syncrun: all checks passed"
