#!/usr/bin/env bash
# lore 2.0 P2 tests: `lore remember` and the filing step at session end (`store run`): the queue,
# one model call per filing run through a fake role command, commit and push to a local bare hub,
# no call without a queue, a rejected reply, a failing and a hanging model (queue kept, backoff),
# and `lore check` (no model call without --live). Never calls a real model or the network:
# LORE_LOREMASTER_CMD is a fake; the other roles are faked too for the one --live run.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap '[[ -n "${KEEP:-}" ]] || rm -rf "$tmp"' EXIT
export HOME="$tmp/home"; mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset LORE_STORE LORE_STORE2 LORE_GH_CMD LORE_GIT_TIMEOUT LORE_SYNC_CMD LORE_EXTRACT_CMD LORE_REVIEW_CMD LORE_MODEL_TIMEOUT 2>/dev/null || true
# Canon (P3) runs in `check --live` and at session end: a fake that fixes nothing keeps every real
# agent CLI out of reach (XDG_DATA_HOME could point lore at the real mise installs).
unset XDG_DATA_HOME MISE_DATA_DIR 2>/dev/null || true
cat > "$tmp/canon-none.sh" <<'FAKE'
#!/bin/sh
echo '{"ops": [], "answer": "nothing to fix"}'
FAKE
chmod +x "$tmp/canon-none.sh"; export LORE_CANON_CMD="$tmp/canon-none.sh"
log="$tmp/log"; S="$tmp/store"; HUB="$tmp/hub.git"; calls="$tmp/calls"
fail() { echo "FAIL: $*" >&2; echo "--- last output ---" >&2; cat "$log" >&2 || true; exit 1; }
ok()   { "$@" >"$log" 2>&1 || fail "$* exited non-zero"; }
has()  { grep -qxF -- "$1" "$log" || fail "${2:-output lacks the line: $1}"; }
hasre() { grep -qE -- "$1" "$log" || fail "${2:-output lacks a line matching: $1}"; }
ncalls() { if [[ -f "$calls" ]]; then wc -l < "$calls" | tr -d ' '; else echo 0; fi; }
receipts() { find "$S/.git/lore/remember-receipts" -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }
queued() { find "$S/.git/lore/remember" -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }
state() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$S/.git/lore/state.json" "$1"; }
age_failure() {   # pretend the last filing failure was three hours ago
  python3 - "$S/.git/lore/state.json" <<'PY'
import json, sys, datetime as dt
p = sys.argv[1]; d = json.load(open(p))
d["file_last_fail"] = (dt.datetime.now().astimezone() - dt.timedelta(hours=3)).isoformat(timespec="seconds")
json.dump(d, open(p, "w"))
PY
}

alive() { ps -o stat= -p "$1" 2>/dev/null | grep -qv '^Z'; }
rules() { grep -cxF -- "- $1" "$S/preferences/editing.md" || true; }
# Run one filing step in a process that dies (exit 86) at a chosen point of the real flow.
crash_run() {   # $1: before-commit | after-commit | mid-dequeue
  (cd "$tmp/skill/scripts" && python3 - "$S" "$1" <<'PY'
import os, sys
sys.path.insert(0, ".")
import lore, lore_hub, lore_master, lore_store
where = sys.argv[2]
if where == "before-commit":
    real = lore_master.apply
    def stop(*a, **kw): os._exit(86)
    lore_master.apply = stop
elif where == "after-commit":
    real = lore_master.file_items
    def stop(*a, **kw):
        real(*a, **kw)
        os._exit(86)
    lore_master.file_items = stop
else:
    real, queue, seen = os.unlink, os.path.join(sys.argv[1], ".git", "lore", "remember"), []
    def stop(path, *a, **kw):
        real(path, *a, **kw)
        if os.path.dirname(os.path.abspath(path)) == queue:
            os._exit(86)
    os.unlink = stop
lore_hub.store_run(lore_store.Store2(sys.argv[1]), "test:crash", True)
PY
  )
}

# A scratch copy of the skill, with the real lore_master.
cp -r "$repo_root/skills/lore" "$tmp/skill"
lore="$tmp/skill/scripts/lore.py"
L() { python3 "$lore" --store2 "$S" "$@"; }

# The fake model: logs one line per call, keeps the prompt it was given, then acts by FAKE_MODE.
cat > "$tmp/fake-model.sh" <<FAKE
#!/usr/bin/env bash
n=\$(( \$(wc -l < "$calls" 2>/dev/null || echo 0) + 1 ))
echo "\$n \${FAKE_MODE:-ok} prompt_file=\${LORE_PROMPT_FILE:+set}" >> "$calls"
cp "\$LORE_PROMPT_FILE" "$tmp/prompt.\$n"
case "\${FAKE_MODE:-ok}" in
  ok)   python3 -c '
import json, os, sys
n, quotes = sys.argv[1], os.environ.get("FAKE_QUOTES", "remember it").split("|")
ops = [{"op": "add", "file": "preferences/editing.md", "text": "Filed rule number %s." % n if len(quotes) == 1 else "Filed rule number %s for %s." % (n, q),
        "explicit": True, "quote": q, "session": "s1"} for q in quotes]
print(json.dumps({"ops": ops, "answer": "filed"}))' "\$n" ;;
  bad)  printf '{"ops":[{"op":"add","file":"nowhere/x.md","text":"Outside the layout.","explicit":true,"quote":"q","session":"s1"}]}\n' ;;
  none) printf '{"ops":[],"answer":"nothing to file"}\n' ;;
  fail) echo "model exploded" >&2; exit 3 ;;
  hang) sleep 31 & echo "\$\$ \$! \$(ps -o pgid= -p \$\$ | tr -d ' ')" > "$tmp/hang.pids"; wait ;;
esac
FAKE
chmod +x "$tmp/fake-model.sh"
export LORE_LOREMASTER_CMD="$tmp/fake-model.sh"

git init -q --bare -b main "$HUB"
ok L --today 2026-10-01 store init
ok L hub set "$HUB"

# 1. remember queues one item on this machine and makes no model call and no commit.
head0="$(git -C "$S" rev-parse HEAD)"
ok L remember "Use tabs, never spaces." --explicit --quote "remember it" --session s1 --host claude
has "queued; it is filed at the end of this session"
[[ "$(queued)" == 1 ]] || fail "remember did not queue exactly one item"
python3 - "$S"/.git/lore/remember/*.json <<'PY' || fail "the queued item has the wrong fields"
import json, sys
d = json.load(open(sys.argv[1]))
assert set(d) == {"text", "explicit", "quote", "session", "host", "created"}, d
assert d["text"] == "Use tabs, never spaces." and d["explicit"] is True and d["quote"] == "remember it", d
assert d["session"] == "s1" and d["host"] == "claude" and d["created"], d
PY
[[ "$(ncalls)" == 0 ]] || fail "remember called the model"
[[ "$(git -C "$S" rev-parse HEAD)" == "$head0" ]] || fail "remember made a commit"
[[ -z "$(git -C "$S" status --porcelain)" ]] || fail "remember touched the working tree"
if L remember "my api_key = abcdef123456xyz" >"$log" 2>&1; then fail "a secret was queued"; fi
has "Error: refused: that looks like a secret; nothing was queued"
# 1b. queue files are 0600 and the queue directory 0700 whatever the umask (F3).
modes() { stat -c '%a' "$@" 2>/dev/null || stat -f '%Lp' "$@"; }
[[ "$(modes "$S/.git/lore/remember")" == 700 ]] || fail "the queue directory is not 0700"
[[ "$(modes "$S"/.git/lore/remember/*.json)" == 600 ]] || fail "the queued file is not 0600"
chmod 755 "$S/.git/lore/remember"
(umask 000; L remember "Umask rule." --explicit --quote "umask rule" >"$log" 2>&1) || fail "remember under umask 000"
[[ "$(modes "$S/.git/lore/remember")" == 700 ]] || fail "a loose queue directory was not tightened to 0700"
[[ "$(modes "$S"/.git/lore/remember/*.json | sort -u | tr '\n' ' ')" == "600 " ]] || fail "queue files are not 0600 under umask 000"
[[ -z "$(find "$S/.git/lore/remember" -name '.in-*')" ]] || fail "a temporary queue file was left"
grep -l "Umask rule." "$S"/.git/lore/remember/*.json | xargs rm -f
[[ "$(queued)" == 1 ]] || fail "the umask item was not removed"
if L remember "a harmless rule" --quote "my api_key = abcdef123456xyz" >"$log" 2>&1; then fail "a secret quote was queued"; fi
has "Error: refused: that looks like a secret; nothing was queued"
if L remember "   " >"$log" 2>&1; then fail "an empty item was queued"; fi
if L remember "$(python3 -c 'print("x " * 600)')" >"$log" 2>&1; then fail "an over-long item was queued"; fi
hasre '^Error: too long \(1[0-9]{3} characters, at most 1000\)'
[[ "$(queued)" == 1 ]] || fail "a refused item was queued"

# 2. a session end with a queue calls the fake once, with a prompt file, applies, commits, pushes.
ok L store run --trigger test:end
[[ "$(ncalls)" == 1 ]] || fail "the filing run made $(ncalls) model calls, not 1"
grep -qxF "1 ok prompt_file=set" "$calls" || fail "the model was not given a prompt file"
grep -qF "Use tabs, never spaces." "$tmp/prompt.1" || fail "the prompt does not carry the queued item"
grep -qxF -- "- Filed rule number 1." "$S/preferences/editing.md" || fail "the rule was not applied"
[[ "$(queued)" == 0 ]] || fail "the queue is not empty after a successful filing"
hasre 'store-run: filed 1 item\(s\); commit [0-9a-f]+, 2 file\(s\), 0 inbox item\(s\) \(test:end\)$'
[[ "$(git -C "$S" rev-parse HEAD)" == "$(git -C "$HUB" rev-parse main)" ]] || fail "the filing commit did not reach the hub"
[[ -z "$(git -C "$S" status --porcelain)" ]] || fail "filing left the tree dirty"
[[ "$(git -C "$S" rev-list --count "$head0"..HEAD)" == 1 ]] || fail "filing made other than one commit"

# 3. a session end with no queue makes no model call and says so.
ok L store run --trigger test:idle
[[ "$(ncalls)" == 1 ]] || fail "a session end with no queue called the model"
hasre 'store-run: filing skipped, nothing queued \(test:idle\)$'

# 4. a rejected reply keeps the queue and leaves the store exactly as it was, then backs off.
ok L remember "Second rule to file." --explicit --quote "remember it"
head1="$(git -C "$S" rev-parse HEAD)"; tree1="$(git -C "$S" ls-files -s | sha1sum)"
FAKE_MODE=bad ok L store run --trigger test:bad
[[ "$(ncalls)" == 2 ]] || fail "the rejected run did not call the model exactly once"
[[ "$(queued)" == 1 ]] || fail "a rejected reply emptied the queue"
[[ "$(git -C "$S" rev-parse HEAD)" == "$head1" && "$(git -C "$S" ls-files -s | sha1sum)" == "$tree1" ]] || fail "a rejected reply changed the store"
[[ -z "$(git -C "$S" status --porcelain)" ]] || fail "a rejected reply left changes in the tree"
hasre "store-run: filing FAILED, 1 item\(s\) stay queued; the Loremaster.s reply was rejected, nothing written: "
[[ "$(state file_fails)" == 1 ]] || fail "the rejection was not counted"
# Backing off: a good model is not called again within the backoff window.
ok L store run --trigger test:soon
[[ "$(ncalls)" == 2 ]] || fail "filing did not back off after a failure"
hasre 'store-run: filing waits, 1 item\(s\) queued; backing off after a failed run \(under 120 min ago\)$'
[[ "$(queued)" == 1 ]] || fail "backing off dropped the queue"
# --force overrides the backoff: the model is called again (and rejects again, so the failure stays).
FAKE_MODE=bad ok L store run --force --trigger test:forced
[[ "$(ncalls)" == 3 ]] || fail "--force did not override the filing backoff"
[[ "$(state file_fails)" == 2 ]] || fail "the forced rejection was not counted"
# After the window the retry files the same item and clears the failure.
age_failure
ok L store run --trigger test:retry
[[ "$(ncalls)" == 4 ]] || fail "the retry did not call the model once"
[[ "$(queued)" == 0 && "$(state file_fails)" == "" ]] || fail "a good retry kept the queue or the failure count"
grep -qxF -- "- Filed rule number 4." "$S/preferences/editing.md" || fail "the retry did not apply"
grep -qF "Second rule to file." "$tmp/prompt.4" || fail "the retry prompt lost the queued item"
[[ "$(git -C "$S" rev-parse HEAD)" == "$(git -C "$HUB" rev-parse main)" ]] || fail "the retry did not push"

# 5. a failing model keeps the queue and backs off; the error names the exit code.
ok L remember "Third rule to file." --explicit --quote "remember it"
FAKE_MODE=fail ok L store run --trigger test:fail
[[ "$(ncalls)" == 5 && "$(queued)" == 1 && "$(state file_fails)" == 1 ]] || fail "a failing model: calls, queue or count wrong"
hasre 'store-run: filing FAILED, 1 item\(s\) stay queued; .*the model command exited 3: model exploded$'
FAKE_MODE=ok ok L store run --trigger test:soon2
[[ "$(ncalls)" == 5 ]] || fail "no backoff after a failing model"
# 5b. a hanging model is killed at the timeout, its process group with it; the queue is kept.
age_failure
sleep 31 & sleeper=$!   # unrelated, kept alive: the check below must look only at the fake's own processes
t0=$SECONDS
FAKE_MODE=hang LORE_MODEL_TIMEOUT=2 ok L store run --trigger test:hang
(( SECONDS - t0 < 20 )) || fail "a hanging model held the run for $((SECONDS - t0))s"
[[ "$(ncalls)" == 6 && "$(queued)" == 1 && "$(state file_fails)" == 2 ]] || fail "a hanging model: calls, queue or count wrong"
hasre 'store-run: filing FAILED, 1 item\(s\) stay queued; .*the model command timed out after 2s$'
read -r hang_pid hang_child hang_pgid < "$tmp/hang.pids"
[[ -n "$hang_pid" && -n "$hang_child" && "$hang_pgid" == "$hang_pid" ]] || fail "the hanging fake did not record its pids: $(cat "$tmp/hang.pids")"
for pid in "$hang_pid" "$hang_child"; do alive "$pid" && fail "the hung model's process $pid was left running"; done
alive "$sleeper" || fail "the unrelated sleeper was killed with the hung model"
kill "$sleeper"; wait "$sleeper" 2>/dev/null || true
# 5c. an unreadable queue entry is reported and left, never dropped; a missing binary fails clearly.
printf 'not json' > "$S/.git/lore/remember/20260101T000000000000-aaaaaa.json"
age_failure
LORE_LOREMASTER_CMD="$tmp/no-such-binary" ok L store run --trigger test:nobin
hasre 'store-run: filing: left an unreadable queue entry 20260101T000000000000-aaaaaa.json$'
hasre "the role command.s binary was not found: "
[[ -f "$S/.git/lore/remember/20260101T000000000000-aaaaaa.json" ]] || fail "an unreadable entry was deleted"
rm "$S/.git/lore/remember/20260101T000000000000-aaaaaa.json"

# 5d. a partial reply keeps what it did not account for (F1): two items, a reply that files one.
rm -f "$S"/.git/lore/remember/*.json
ok L remember "Alpha rule." --explicit --quote "alpha"
ok L remember "Beta rule." --explicit --quote "beta"
age_failure
n=$(ncalls)
FAKE_QUOTES="alpha" ok L store run --trigger test:partial
[[ "$(ncalls)" == "$((n + 1))" ]] || fail "the partial run made other than one model call"
[[ "$(queued)" == 1 ]] || fail "a partial reply did not leave exactly the unaccounted item queued"
grep -qF "Beta rule." "$S"/.git/lore/remember/*.json || fail "the wrong item stayed queued"
[[ "$(rules "Filed rule number $((n + 1)).")" == 1 ]] || fail "the accounted item was not filed"
hasre 'store-run: filing INCOMPLETE, 1 item\(s\) stay queued; the reply accounted for 1 of 2 \(test:partial\)$'
hasre 'store-run: filed 1 item\(s\); commit [0-9a-f]+, 2 file\(s\), 0 inbox item\(s\) \(test:partial\)$'
[[ "$(grep -c 'store-run: hub: ' "$log")" == 2 ]] || fail "a partial run with a commit did not push twice"
[[ "$(state file_fails)" == 4 ]] || fail "a partial reply was not counted for the backoff"
[[ "$(receipts)" == 0 ]] || fail "a finished filing run left its receipt"
ok L store run --trigger test:partial-soon
[[ "$(ncalls)" == "$((n + 1))" ]] || fail "no backoff after a partial reply"
age_failure
FAKE_QUOTES="beta" ok L store run --trigger test:partial-rest
[[ "$(queued)" == 0 && "$(state file_fails)" == "" ]] || fail "the remaining item was not filed and the failure cleared"
# 5d1. an item with no quote is accounted for by an op quoting its text; ops that carry no item are no account (F1).
ok L remember "Kappa rule." --explicit
age_failure
FAKE_QUOTES="Kappa rule." ok L store run --trigger test:text
[[ "$(queued)" == 0 ]] || fail "an op quoting a quote-less item's text did not account for it"
(cd "$tmp/skill/scripts" && python3 - <<'PY') || fail "accounted_items counted an op that is not an add or supersede"
import sys
sys.path.insert(0, ".")
import lore, lore_hub
items = [("p1", {"text": "A rule.", "quote": "q1"}), ("p2", {"text": "B rule.", "quote": ""})]
assert lore_hub.accounted_items([{"op": "link", "quote": "q1"}, {"op": "retire", "quote": "B rule."}], items) == []
assert [p for p, _ in lore_hub.accounted_items([{"op": "supersede", "quote": "q1"}, {"op": "add", "quote": "B rule."}], items)] == ["p1", "p2"]
PY
# 5d2. a reply with no ops files nothing and keeps every item; it makes no commit, so one push.
ok L remember "Gamma rule." --explicit --quote "gamma"
ok L remember "Delta rule." --explicit --quote "delta"
age_failure
FAKE_MODE=none ok L store run --trigger test:none
[[ "$(grep -c 'store-run: hub: ' "$log")" == 1 ]] || fail "a filing run with no commit pushed twice"
hasre 'store-run: filing INCOMPLETE, 2 item\(s\) stay queued; the reply accounted for 0 of 2 \(test:none\)$'
if grep -q 'store-run: filed ' "$log"; then fail "an empty reply was logged as filed"; fi
[[ "$(queued)" == 2 ]] || fail "an empty reply dropped queued items"
rm -f "$S"/.git/lore/remember/*.json
# 5d3. a stop between the commit and the dequeue is recovered from the receipt, without a second model call (F2).
ok L remember "Epsilon rule." --explicit --quote "epsilon"
age_failure; n=$(ncalls); rc=0
FAKE_QUOTES="epsilon" crash_run before-commit >"$log" 2>&1 || rc=$?
[[ "$rc" == 86 ]] || fail "the before-commit stop did not happen (exit $rc)"
[[ "$(ncalls)" == "$((n + 1))" && "$(queued)" == 1 && "$(receipts)" == 1 && "$(rules "Filed rule number $((n + 1)).")" == 0 ]] || fail "before the commit: calls, queue, receipt or rule wrong"
[[ "$(modes "$S/.git/lore/remember-receipts" "$S"/.git/lore/remember-receipts/*.json | tr '\n' ' ')" == "700 600 " ]] || fail "the receipt is not private"
FAKE_QUOTES="epsilon" ok L store run --force --trigger test:recover0
hasre 'store-run: filing: dropped receipt [0-9a-f]{12}; its commit never happened, the items stay queued$'
[[ "$(queued)" == 0 && "$(receipts)" == 0 && "$(rules "Filed rule number $((n + 2)).")" == 1 && "$(ncalls)" == "$((n + 2))" ]] || fail "after a stop before the commit the item was not filed once"
ok L remember "Zeta rule." --explicit --quote "zeta"
age_failure; n=$(ncalls); rc=0
FAKE_QUOTES="zeta" crash_run after-commit >"$log" 2>&1 || rc=$?
[[ "$rc" == 86 ]] || fail "the after-commit stop did not happen (exit $rc)"
[[ "$(queued)" == 1 && "$(receipts)" == 1 && "$(rules "Filed rule number $((n + 1)).")" == 1 ]] || fail "after the commit: queue, receipt or rule wrong"
FAKE_QUOTES="zeta" ok L store run --force --trigger test:recover1
hasre 'store-run: filing: recovered receipt [0-9a-f]{12}; commit [0-9a-f]{7} had filed 1 item\(s\), dequeued$'
hasre 'store-run: filing skipped, nothing queued \(test:recover1\)$'
[[ "$(ncalls)" == "$((n + 1))" ]] || fail "the recovery spent a second model call"
[[ "$(queued)" == 0 && "$(receipts)" == 0 && "$(rules "Filed rule number $((n + 1)).")" == 1 ]] || fail "the recovery did not dequeue once"
ok L remember "Eta rule." --explicit --quote "eta"
ok L remember "Theta rule." --explicit --quote "theta"
age_failure; n=$(ncalls); rc=0
FAKE_QUOTES="eta|theta" crash_run mid-dequeue >"$log" 2>&1 || rc=$?
[[ "$rc" == 86 ]] || fail "the mid-dequeue stop did not happen (exit $rc)"
[[ "$(queued)" == 1 && "$(receipts)" == 1 ]] || fail "mid-dequeue: expected one item and one receipt left"
FAKE_QUOTES="eta|theta" ok L store run --force --trigger test:recover2
hasre 'had filed 2 item\(s\), dequeued$'
[[ "$(ncalls)" == "$((n + 1))" && "$(queued)" == 0 && "$(receipts)" == 0 ]] || fail "mid-dequeue recovery: calls, queue or receipt wrong"
[[ "$(rules "Filed rule number $((n + 1)) for eta.")" == 1 && "$(rules "Filed rule number $((n + 1)) for theta.")" == 1 ]] || fail "the batch was not filed exactly once"
# 5e. no loremaster command at all (no override, no installed adapter): the items stay queued, with the reason.
ok L remember "Fifth rule to file." --explicit --quote "remember it"
printf 'loremaster_models: nonesuch\n' >> "$S/.lore/config"
(unset LORE_LOREMASTER_CMD; ok L store run --trigger test:nocmd)
hasre 'store-run: filing FAILED, 1 item\(s\) stay queued; .*no loremaster command: no host adapter with a .loremaster:. line is installed$'
[[ "$(queued)" == 1 ]] || fail "a missing role command dropped the queue"
sed -i.bak '/^loremaster_models:/d' "$S/.lore/config"; rm -f "$S/.lore/config.bak"   # the run committed the line; take it out again
ok L store commit
rm -f "$S"/.git/lore/remember/*.json

# 5f. a shell-quoted executable path with a space runs, and the rest of the command is passed on unchanged (F5).
mkdir -p "$tmp/fictional tools"
cat > "$tmp/fictional tools/model" <<SPACED
#!/bin/sh
echo "\$*" > "$tmp/spaced.args"
echo '{"ops":[{"op":"add","file":"preferences/editing.md","text":"Spaced path rule.","explicit":true,"quote":"spaced","session":"s1"}],"answer":"ok"}'
SPACED
chmod +x "$tmp/fictional tools/model"
ok L remember "Spaced path rule." --explicit --quote "spaced"
age_failure
LORE_LOREMASTER_CMD="'$tmp/fictional tools/model' --flag 'two  words' \$HOME" ok L store run --trigger test:spaced
[[ "$(rules "Spaced path rule.")" == 1 && "$(queued)" == 0 ]] || fail "a quoted executable path with a space did not run"
[[ "$(cat "$tmp/spaced.args")" == "--flag two  words $HOME" ]] || fail "the rest of the command was changed: $(cat "$tmp/spaced.args")"
# ...and an adapter binary found on a PATH directory with a space is shown as a quoted absolute path.
mkdir -p "$tmp/bin dir"; printf '#!/bin/sh\ncat > /dev/null\n' > "$tmp/bin dir/claude"; chmod +x "$tmp/bin dir/claude"
(unset LORE_LOREMASTER_CMD; PATH="$tmp/bin dir:$PATH" ok L check)
hasre "^loremaster: ok  claude: '$tmp/bin dir/claude' -p --model sonnet "

# 6. check: reports each role without --live and calls no model; --live calls each fake once.
n=$(ncalls)
ok L check
[[ "$(ncalls)" == "$n" ]] || fail "check without --live called the model"
hasre '^loremaster: ok  override: '
has "not run live (add --live to call each model once)"
for role in extract review sync; do hasre "^$role: (ok|unavailable)  "; done
printf '#!/bin/sh\necho ok\n' > "$tmp/role-ok.sh"; chmod +x "$tmp/role-ok.sh"
LORE_EXTRACT_CMD="$tmp/role-ok.sh" LORE_REVIEW_CMD="$tmp/role-ok.sh" LORE_SYNC_CMD="$tmp/role-ok.sh" ok L check --live
[[ "$(ncalls)" == "$((n + 1))" ]] || fail "check --live did not call the loremaster exactly once"
hasre '^loremaster: ok  override: .*  live: ok in [0-9.]+s, replied [0-9]+ characters$'
hasre '^extract: ok  override: .*  live: ok in '
printf '#!/bin/sh\n' > "$tmp/role-empty.sh"; chmod +x "$tmp/role-empty.sh"
if LORE_EXTRACT_CMD="$tmp/role-empty.sh" LORE_REVIEW_CMD="$tmp/role-ok.sh" LORE_SYNC_CMD="$tmp/role-ok.sh" python3 "$lore" --store2 "$S" check --live >"$log" 2>&1; then fail "check --live passed an empty reply"; fi
hasre '^extract: FAILED  .*  live: empty reply$'
if FAKE_MODE=fail LORE_EXTRACT_CMD="$tmp/role-ok.sh" LORE_REVIEW_CMD="$tmp/role-ok.sh" LORE_SYNC_CMD="$tmp/role-ok.sh" python3 "$lore" --store2 "$S" check --live >"$log" 2>&1; then fail "check --live passed a failing role"; fi
hasre '^loremaster: FAILED  .*  live: the model command exited 3: model exploded$'

# 7. the shipped adapter lines: claude and codex run the Loremaster headless, tool-less or read-only,
# ephemeral and without hooks, on the models the plan names.
hosts="$repo_root/skills/lore/hosts"
grep -qxF 'loremaster: claude -p --model sonnet --effort medium --tools "" --no-session-persistence --settings '"'"'{"disableAllHooks":true}'"'"' --output-format text < "$LORE_PROMPT_FILE"' "$hosts/claude.conf" || fail "claude.conf loremaster line"
grep -qxF 'loremaster: codex exec --ephemeral --disable hooks -s read-only --skip-git-repo-check -m gpt-6.1-sol -c model_reasoning_effort=medium - < "$LORE_PROMPT_FILE"' "$hosts/codex.conf" || fail "codex.conf loremaster line"
for h in cmd agy; do grep -qE '^loremaster: .*LORE_PROMPT_FILE' "$hosts/$h.conf" || fail "$h.conf has no loremaster line"; done

echo "test-remember: all checks passed"
