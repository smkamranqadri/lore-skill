#!/usr/bin/env bash
# lore v1: one test per finding of the 2026-10-16 Codex review (.orch/lore-v1/proof/codex-review.md).
# Finding 10 (a refused rewrite deletes its source) is covered in test-review.sh. Temporary HOME.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
scripts="$repo_root/skills/lore/scripts"; lore="$scripts/lore.py"; hook="$scripts/lore-hook.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"; mkdir -p "$HOME"
unset LORE_STORE LORE_HARVEST LORE_HOOK_NO_SPAWN 2>/dev/null || true
log="$tmp/log"; store="$HOME/.agents/memory"; calls="$tmp/calls"
export SCRIPTS="$scripts" LORE_REVIEW_CMD="echo '[]'"

fail() { echo "FAIL: $*" >&2; echo "--- last output ---" >&2; cat "$log" >&2 || true; exit 1; }
ok()   { "$@" >"$log" 2>&1 || fail "$* exited non-zero"; }
L() { python3 "$lore" "$@"; }
ncalls() { [[ -f "$calls" ]] && wc -l < "$calls" | tr -d ' ' || echo 0; }

# A fake extractor: logs calls, can fail on a chosen call number, answers from keywords.
cat > "$tmp/fake.sh" <<'EOF'
#!/usr/bin/env bash
echo call >> "$FAKE_CALLS"; n=$(wc -l < "$FAKE_CALLS"); cp "$LORE_PROMPT_FILE" "$FAKE_CALLS.prompt-$n"
[[ -n "${FAKE_FAIL_ON:-}" && "$n" == "$FAKE_FAIL_ON" ]] && { echo down >&2; exit 1; }
p="$(cat "$LORE_PROMPT_FILE")"; items=()
grep -q 'pnpm' <<<"$p" && items+=('{"rule":"Use pnpm, not npm, in node projects","category":"tools","scope":"global"}')
grep -q 'leakrule' <<<"$p" && items+=('{"rule":"Use the key sk-abcdefghijklmnopqrstuv for deploys","category":"tools","scope":"global"}')
(IFS=,; echo "[${items[*]}]")
EOF
chmod +x "$tmp/fake.sh"
export LORE_EXTRACT_CMD="bash '$tmp/fake.sh'" FAKE_CALLS="$calls"
mkdir -p "$HOME/.claude/projects/p" "$HOME/.codex" "$HOME/.commandcode/projects/p"
ok L --today 2026-10-16 init

# F1. A hub entry whose category points outside the store cannot write there.
echo "Keep me" > "$HOME/.codex/AGENTS.md"
mkdir -p "$tmp/hub1"
printf '# Candidates\n\n- Evil rule. Confidence: 0.90 <!-- id=%s first=2026-10-16 last=2026-10-16 days=3 n=3 cat=../../.codex/AGENTS flags=explicit -->\n' \
  "$(python3 -c "import sys; sys.path.insert(0,'$scripts'); import lore; print(lore.entry_id('Evil rule.'))")" > "$tmp/hub1/candidates.md"
ok L --today 2026-10-16 merge --remote "$tmp/hub1"
grep -q '^Keep me$' "$HOME/.codex/AGENTS.md" || fail "F1: a hub category reached a global file"
grep -q 'Evil rule' "$store/workflow.md" || fail "F1: the entry did not fall back to a safe category"
python3 - <<'PY' || fail "F1: Store.path allowed a path outside the store"
import os, sys; sys.path.insert(0, os.environ["SCRIPTS"]); import lore
s = lore.Store(os.path.expanduser("~/.agents/memory"))
try:
    s.path("../../.codex/AGENTS.md"); sys.exit(1)
except lore.LoreError:
    pass
PY

# F2. Secrets are redacted before the prompt, and a secret-looking rule is never stored.
ct="$HOME/.claude/projects/p/s1.jsonl"
echo '{"type":"user","message":{"role":"user","content":"no, never use my token ghp_abcdefghijklmnopqrstuvwxyz0123 in pnpm scripts. leakrule"}}' > "$ct"
echo "{\"session_id\":\"s1\",\"transcript_path\":\"$ct\"}" | LORE_HOOK_NO_SPAWN=1 bash "$hook" claude SessionEnd
ok L --today 2026-10-16 harvest
grep -q 'ghp_' "$calls.prompt-1" && fail "F2: a token reached the extractor prompt"
grep -q '\[REDACTED\]' "$calls.prompt-1" || fail "F2: the token was not redacted"
grep -rq 'sk-abcdef' "$store" && fail "F2: a secret-looking rule was stored"
grep -q 'Use pnpm, not npm' "$store/candidates.md" || fail "F2: the safe rule from the same message was lost"

# F3. sync-done keeps the earlier version of notes this sync did not fetch or write.
mkdir -p "$tmp/pushed"; echo '{"lore/git.md":"v1","lore/ui.md":"v1"}' > "$tmp/seen1.json"
ok L --today 2026-10-16 sync-done --pushed "$tmp/pushed" --remote-seen "$tmp/seen1.json"
echo '{"lore/git.md":"v2"}' > "$tmp/seen2.json"
ok L --today 2026-10-16 sync-done --pushed "$tmp/pushed" --remote-seen "$tmp/seen2.json"
python3 -c "import json,sys; r=json.load(open(sys.argv[1]))['remote']; sys.exit(r!={'lore/git.md':'v2','lore/ui.md':'v1'})" \
  "$store/sync-state.json" || fail "F3: a note this sync never read was marked as seen"

# F4. A failure while promoting never loses the rule: categories are written before candidates.
ok L --today 2026-10-16 add --cat git --text "Never force push to main"
python3 - <<'PY' || fail "F4: a crash during promotion lost the rule"
import os, sys; sys.path.insert(0, os.environ["SCRIPTS"]); import lore
s = lore.Store(os.path.expanduser("~/.agents/memory"), lore.dt.date(2026, 10, 17))
for e in s.read_candidates():
    if "force push" in e.text:
        e.days = 2
cands = s.read_candidates()
for e in cands:
    if "force push" in e.text:
        e.days = 2
s.write_candidates(cands)
def boom(*a):
    raise OSError("disk full")
s.write_category = boom   # the destination write fails, as in the review's reproduction
try:
    lore.maintain(s, lore.dt.date(2026, 10, 17))
except OSError:
    pass
found = any("force push" in e.text for e in list(s.all_confirmed().values()) + lore.Store(s.root).read_candidates())
sys.exit(0 if found else 1)
PY

# F5. A tombstone received in a merge keeps its own date.
ok L --today 2026-10-16 add --cat ui --text "Short-lived rule"
sid="$(L list --candidates | grep 'Short-lived' | cut -f1)"
mkdir -p "$tmp/hub5"; printf '%s\t2026-10-16\n' "$sid" > "$tmp/hub5/tombstones"
ok L --today 2026-10-20 merge --remote "$tmp/hub5"
grep -q 'Short-lived' "$store/candidates.md" && fail "F5: the tombstoned rule survived"
grep "^$sid" "$store/tombstones" | grep -q '2026-10-20' && fail "F5: the received tombstone was re-dated to the merge day"

# F6. A newer decayed copy beats a stale higher one in a merge.
python3 - <<'PY' || fail "F6: sync undid a decay"
import os, sys; sys.path.insert(0, os.environ["SCRIPTS"]); import lore
sys.modules["lore"] = lore; import lore_sync
old = lore.Entry("Decayed rule.", 0.90, first="2026-01-01", last="2026-02-01", days=3, n=3)
new = lore.Entry("Decayed rule.", 0.45, first="2026-01-01", last="2026-02-01", days=3, n=3, decayed="2026-08-01")
assert lore_sync.combine(old, new).conf == 0.45 and lore_sync.combine(new, old).conf == 0.45
PY

# F7. Hits beyond one prompt go in batches; a failed batch is retried, the finished one is not.
bt="$HOME/.claude/projects/p/s7.jsonl"; : > "$bt"
for i in $(seq 1 9); do
  python3 -c "import json,sys; print(json.dumps({'type':'user','message':{'role':'user','content':'no, '+('use pnpm here %s ' % sys.argv[1])*90}}))" "$i" >> "$bt"
done
before="$(ncalls)"
echo "{\"session_id\":\"s7\",\"transcript_path\":\"$bt\"}" | LORE_HOOK_NO_SPAWN=1 bash "$hook" claude SessionEnd
FAKE_FAIL_ON=$((before + 2)) L --today 2026-10-16 harvest >"$log" 2>&1 || fail "F7: harvest failed"
[[ "$(ncalls)" == $((before + 2)) ]] || fail "F7: wanted two batches, got $(( $(ncalls) - before )) call(s)"
ok L --today 2026-10-16 harvest
[[ "$(ncalls)" == $((before + 3)) ]] || fail "F7: the retry did not resume at the failed batch"
grep -q 'pnpm here 1 ' "$calls.prompt-$((before + 3))" && fail "F7: the retry re-sent the finished batch"
grep -q 'pnpm here 9 ' "$calls.prompt-$((before + 3))" || fail "F7: the last messages were never sent"

# F8. add --explicit promotes and delivers at once; drop delivers too.
ok L --today 2026-10-16 add --cat ui --text "Prefer toggle switches over checkboxes" --explicit
grep -q 'Prefer toggle switches' "$store/ui.md" || fail "F8: an explicit add was not promoted at once"
grep -q 'Prefer toggle switches' "$HOME/.codex/AGENTS.md" || fail "F8: an explicit add was not delivered"
tid="$(L list --cat ui | grep toggle | cut -f1)"
ok L --today 2026-10-16 drop "$tid"
grep -q 'Prefer toggle switches' "$HOME/.codex/AGENTS.md" && fail "F8: a dropped rule stayed in a host's copy"

# F9. With --wait, the worker stays until a per-turn session goes idle, then harvests it.
mt="$HOME/.commandcode/projects/p/m9.jsonl"
echo '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"actually, always use pnpm"}]}}' > "$mt"
echo "settle: 3" >> "$store/config"
before="$(ncalls)"
echo "{\"session_id\":\"m9\",\"transcript_path\":\"$mt\"}" | LORE_HOOK_NO_SPAWN=1 bash "$hook" cmd Stop
L --today 2026-10-16 harvest --wait >"$log" 2>&1 || fail "F9: harvest --wait failed"
[[ "$(ncalls)" == $((before + 1)) ]] || fail "F9: the worker left without harvesting the idle session"
sed -i '/^settle: 3$/d' "$store/config"

# F11. Decay runs on a quiet day, with nothing to harvest.
ok L --today 2026-10-16 add --cat git --text "Quiet day rule" --explicit
ok L --today 2027-01-20 harvest
grep 'Quiet day rule' "$store/git.md" | grep -q 'Confidence: 0\.60' && fail "F11: a quiet harvest ran no decay"

# F12. One session across two days is one sighting; a second session is another.
python3 - <<'PY' || fail "F12: one session counted as two sightings"
import os, sys; sys.path.insert(0, os.environ["SCRIPTS"]); import lore
e = lore.Entry("Session rule.", 0.30, first="2026-10-16", last="2026-10-16", days=1, n=1)
e.sess.add(lore.session_key("sess-A"))
lore.seen(e, lore.dt.date(2026, 10, 17), "sess-A")
assert e.days == 1, e.days
lore.seen(e, lore.dt.date(2026, 10, 17), "sess-B")
assert e.days == 2, e.days
PY

# F13. A symlinked global file stays a symlink; its target gets the block.
mkdir -p "$tmp/dotfiles"; echo "# mine" > "$tmp/dotfiles/CLAUDE.md"
rm -f "$HOME/.claude/CLAUDE.md"; ln -s "$tmp/dotfiles/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
ok L --today 2026-10-16 deliver --host claude
[[ -L "$HOME/.claude/CLAUDE.md" ]] || fail "F13: delivery replaced the symlink with a file"
grep -q 'lore:index start' "$tmp/dotfiles/CLAUDE.md" || fail "F13: the symlink target did not get the block"

echo "test-fixes: all checks passed"
