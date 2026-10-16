#!/usr/bin/env bash
# lore v1 capture tests: hook queueing, harvest, extraction, sweep, hook install.
# Temporary HOME; a fake extractor stands in for the model CLIs. Never touches the real homes.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
scripts="$repo_root/skills/lore/scripts"
lore="$scripts/lore.py"; hook="$scripts/lore-hook.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"; mkdir -p "$HOME"
unset LORE_STORE LORE_HARVEST LORE_HOOK_NO_SPAWN 2>/dev/null || true
log="$tmp/log"; store="$HOME/.agents/memory"; calls="$tmp/extract-calls"

fail() { echo "FAIL: $*" >&2; echo "--- last output ---" >&2; cat "$log" >&2 || true; exit 1; }
ok()   { "$@" >"$log" 2>&1 || fail "$* exited non-zero"; }
deny_msg() {
  local d="$1" want="$2"; shift 2
  if "$@" >"$log" 2>&1; then fail "$d"; fi
  grep -q -- "$want" "$log" || fail "$d (wanted '$want')"
}
L() { python3 "$lore" "$@"; }
ncalls() { [[ -f "$calls" ]] && wc -l < "$calls" | tr -d ' ' || echo 0; }

# The fake extractor: logs each call and answers from keywords in the prompt.
cat > "$tmp/fake-extract.sh" <<'EOF'
#!/usr/bin/env bash
echo "call LORE_HARVEST=${LORE_HARVEST:-unset}" >> "$FAKE_CALLS"
cp "$LORE_PROMPT_FILE" "$FAKE_CALLS.last-prompt"
[[ -n "${FAKE_FAIL:-}" ]] && { echo "model unavailable" >&2; exit 1; }
p="$(cat "$LORE_PROMPT_FILE")"; items=()
grep -q 'pnpm' <<<"$p" && items+=('{"rule":"Use pnpm, not npm, in node projects","category":"tools","quote":"always use pnpm","explicit":false,"scope":"global","contradicts":null}')
grep -q 'caprover' <<<"$p" && items+=('{"rule":"Deploy this app with deploy.sh to CapRover","category":"tools","quote":"deploy to caprover","explicit":false,"scope":"project","contradicts":null}')
grep -q 'remember: toggles' <<<"$p" && items+=('{"rule":"Prefer toggle switches over checkboxes","category":"ui","quote":"remember: toggles","explicit":true,"scope":"global","contradicts":null}')
(IFS=,; echo "Here you go: [${items[*]}]")
EOF
chmod +x "$tmp/fake-extract.sh"
export LORE_EXTRACT_CMD="bash '$tmp/fake-extract.sh'" FAKE_CALLS="$calls"
export LORE_REVIEW_CMD="echo '[]'"   # the daily review is tested in test-review.sh; never a real model here

mkdir -p "$HOME/.claude/projects/-work-app" "$HOME/.codex/sessions/2026/10/16" "$HOME/.commandcode/projects/work-app" \
  "$HOME/.gemini/antigravity-cli/brain/c0ffee01/.system_generated/logs"
ok L --today 2026-10-16 init

# 1. The hook queues its payload and exits at once; it does nothing under LORE_HARVEST=1, without
#    a store, or for a malformed host name.
ct="$HOME/.claude/projects/-work-app/s1.jsonl"
cat > "$ct" <<'EOF'
{"type":"user","message":{"role":"user","content":"no, don't use npm here. always use pnpm"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok, switching to pnpm"}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"never mind this tool output"}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"x"},{"type":"text","text":"never mind this mixed tool text"}]}}
{"type":"user","isMeta":true,"message":{"role":"user","content":"always meta, never the user"}}
{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name> never"}}
EOF
start=$(date +%s%N)
echo "{\"session_id\":\"s1\",\"transcript_path\":\"$ct\",\"cwd\":\"/work/app\"}" | LORE_HOOK_NO_SPAWN=1 bash "$hook" claude SessionEnd
ms=$(( ($(date +%s%N) - start) / 1000000 ))
[[ "$ms" -lt 1000 ]] || fail "hook took ${ms} ms"
[[ "$(ls "$store/queue"/*.json | wc -l)" == 1 ]] || fail "hook did not queue exactly one entry"
grep -q '"lore_host":"claude","lore_event":"SessionEnd"' "$store/queue"/*.json || fail "queue entry lacks host and event"
echo '{}' | LORE_HARVEST=1 LORE_HOOK_NO_SPAWN=1 bash "$hook" claude SessionEnd
echo '{}' | LORE_HOOK_NO_SPAWN=1 bash "$hook" 'bad host' SessionEnd
echo '{}' | LORE_STORE="$tmp/nostore" LORE_HOOK_NO_SPAWN=1 bash "$hook" claude SessionEnd
[[ "$(ls "$store/queue"/*.json | wc -l)" == 1 ]] || fail "hook queued under LORE_HARVEST=1 or for a bad host"
[[ -e "$tmp/nostore" ]] && fail "hook created a store that did not exist"

# 2. Harvest: only the user's own words reach the extractor, once; a global item becomes a
#    candidate; the index is delivered.
mkdir -p "$HOME/.codex"   # an installed host, to receive the delivery
ok L --today 2026-10-16 harvest
[[ "$(ncalls)" == 1 ]] || fail "extractor called $(ncalls) times, wanted 1"
grep -q 'call LORE_HARVEST=1' "$calls" || fail "extractor ran without LORE_HARVEST=1"
grep -q "always use pnpm" "$calls.last-prompt" || fail "the user's message is not in the prompt"
grep -qi "tool output\|mixed tool text\|meta, never\|command-name\|switching to pnpm" "$calls.last-prompt" && fail "non-user text leaked into the prompt"
grep -q 'Use pnpm, not npm, in node projects\. Confidence: 0\.30 .*cat=tools' "$store/candidates.md" || fail "item not added as a candidate"
[[ -z "$(ls "$store/queue"/*.json 2>/dev/null)" ]] || fail "processed queue entry left behind"
grep -q 'lore:index start' "$HOME/.codex/AGENTS.md" || fail "index not delivered after harvest"

# 3. The offset holds: the same transcript is not extracted twice.
echo "{\"session_id\":\"s1\",\"transcript_path\":\"$ct\"}" | LORE_HOOK_NO_SPAWN=1 bash "$hook" claude SessionEnd
ok L --today 2026-10-16 harvest
[[ "$(ncalls)" == 1 ]] || fail "an already-read transcript was extracted again"

# 4. A session with no correction makes no model call.
ct2="$HOME/.claude/projects/-work-app/s2.jsonl"
echo '{"type":"user","message":{"role":"user","content":"please add a login page"}}' > "$ct2"
echo "{\"session_id\":\"s2\",\"transcript_path\":\"$ct2\"}" | LORE_HOOK_NO_SPAWN=1 bash "$hook" claude SessionEnd
ok L --today 2026-10-16 harvest
[[ "$(ncalls)" == 1 ]] || fail "a session without a hit called the extractor"

# 5. A project fact is dropped and noted, never stored.
xt="$HOME/.codex/sessions/2026/10/16/rollout-2026-10-16T10-00-00-0b1e2c3d-aaaa.jsonl"
cat > "$xt" <<'EOF'
{"type":"session_meta","payload":{"id":"0b1e2c3d-aaaa","cwd":"/work/app"}}
{"type":"event_msg","payload":{"type":"user_message","message":"no, deploy to caprover with deploy.sh"}}
{"type":"response_item","payload":{"role":"user","content":[{"type":"input_text","text":"<environment_context>x</environment_context>"}]}}
EOF
echo '{"session_id":"0b1e2c3d-aaaa","transcript_path":null,"cwd":"/work/app"}' | LORE_HOOK_NO_SPAWN=1 bash "$hook" codex SessionEnd
ok L --today 2026-10-16 harvest
[[ "$(ncalls)" == 2 ]] || fail "codex transcript (found by session id) was not extracted"
grep -q 'CapRover' "$store/candidates.md" && fail "a project fact became a candidate"
grep -q "/work/app	project fact, belongs in that project's KIS: Deploy this app" "$store/notices" || fail "project fact not noted"

# 6. Per-turn Stop (cmd): a still-active session waits; once idle it is harvested.
mt="$HOME/.commandcode/projects/work-app/m1.jsonl"
echo '{"role":"user","content":"remember: toggles over checkboxes, always"}' > "$mt"
echo "{\"session_id\":\"m1\",\"transcript_path\":\"$mt\"}" | LORE_HOOK_NO_SPAWN=1 bash "$hook" cmd Stop
ok L --today 2026-10-16 harvest
[[ "$(ncalls)" == 2 ]] || fail "an active per-turn session was harvested before it went idle"
[[ -n "$(ls "$store/queue"/*.json 2>/dev/null)" ]] || fail "the deferred entry was dropped"
ok L --today 2026-10-16 harvest --now "$(( $(date +%s) + 700 ))"
[[ "$(ncalls)" == 3 ]] || fail "an idle per-turn session was not harvested"
grep -q 'Prefer toggle switches over checkboxes\. Confidence: 0\.60 .*flags=explicit' "$HOME/.agents/memory/ui.md" \
  || fail "an explicit item was not promoted at once"

# 7. Sweep: the first sets a starting point only; a later one finds new idle transcripts.
at="$HOME/.gemini/antigravity-cli/brain/c0ffee01/.system_generated/logs/transcript.jsonl"
# The real agy shape (checked on agy 1.4.0, 2026-10-16): the prompt inside <USER_REQUEST>, then metadata.
echo '{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"<USER_REQUEST>\nno, always use pnpm please\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\nnever mind this metadata\n</ADDITIONAL_METADATA>"}' > "$at"
touch -d '-2 hours' "$at"   # old and idle: only the starting point keeps the first sweep off it
ok L --today 2026-10-16 harvest --sweep
[[ "$(ncalls)" == 3 ]] || fail "the first sweep processed old history"
grep -q '"sweep_from"' "$store/harvest-state.json" || fail "the first sweep set no starting point"
touch -d '+1 minute' "$at"   # written again after the starting point
ok L --today 2026-10-17 harvest --sweep --now "$(( $(date +%s) + 2000 ))"
[[ "$(ncalls)" == 4 ]] || fail "a later sweep missed a new transcript"
grep -q 'no, always use pnpm please' "$calls.last-prompt" || fail "the agy prompt inside USER_REQUEST was not read"
grep -q 'never mind this metadata' "$calls.last-prompt" && fail "agy metadata leaked into the prompt"
grep -q 'Use pnpm, not npm, in node projects\. Confidence: 0\.60 ' "$store/tools.md" \
  || fail "a learning seen on a second day was not promoted"
grep -q 'Use pnpm, not npm' "$store/INDEX.md" || fail "the promoted rule is not in the index"

# 8. Extraction failures keep the entry; the third parks it.
ft="$HOME/.claude/projects/-work-app/s3.jsonl"
echo '{"type":"user","message":{"role":"user","content":"never commit on main"}}' > "$ft"
for i in 1 2 3; do
  echo "{\"session_id\":\"s3\",\"transcript_path\":\"$ft\"}" | LORE_HOOK_NO_SPAWN=1 bash "$hook" claude SessionEnd
  FAKE_FAIL=1 L --today 2026-10-17 harvest >"$log" 2>&1 || fail "harvest exited non-zero on a failed extraction"
  if [[ "$i" -lt 3 ]]; then [[ -n "$(ls "$store/queue"/*.json 2>/dev/null)" ]] || fail "failed entry dropped on try $i"; fi
done
[[ -n "$(ls "$store/queue/failed"/*.json 2>/dev/null)" ]] || fail "third failure did not park the entry"
[[ -z "$(ls "$store/queue"/*.json 2>/dev/null)" ]] || fail "parked entry still queued"

# 9. The detached path end to end: the hook starts a harvest that outlives it.
dt="$HOME/.claude/projects/-work-app/s4.jsonl"
echo '{"type":"user","message":{"role":"user","content":"actually, always use pnpm"}}' > "$dt"
echo "{\"session_id\":\"s4\",\"transcript_path\":\"$dt\"}" | bash "$hook" claude SessionEnd
for _ in $(seq 1 30); do [[ "$(ncalls)" -ge 5 ]] && break; sleep 1; done
[[ "$(ncalls)" -ge 5 ]] || fail "the detached harvest never ran"
for _ in $(seq 1 30); do pgrep -f "$store harvest" >/dev/null || break; sleep 1; done

# 10. Hook install keeps foreign hooks and settings, is idempotent, and removes cleanly.
mkdir -p "$HOME/.gemini/config"
cat > "$HOME/.claude/settings.json" <<'EOF'
{"model":"fable","hooks":{"SessionStart":[{"matcher":"startup","hooks":[{"type":"command","command":"bash herdr-agent-state.sh session"}]}]}}
EOF
cp "$HOME/.claude/settings.json" "$tmp/claude-settings.orig"
ok L hooks install
for h in claude codex cmd agy; do grep -q "^$h: hooks installed in" "$log" || fail "$h hooks not installed"; done
grep -q 'trust lore' "$log" || fail "codex trust step not mentioned"
python3 - "$HOME" "$hook" <<'PY' || fail "installed hook config is wrong"
import json, sys
home, hook = sys.argv[1], sys.argv[2]
c = json.load(open(f"{home}/.claude/settings.json"))
assert c["model"] == "fable"
assert c["hooks"]["SessionStart"][0]["hooks"][0]["command"] == "bash herdr-agent-state.sh session"
for ev in ("SessionEnd", "PreCompact", "SessionStart"):
    assert any(f"'{hook}' claude {ev}" in h["command"] for g in c["hooks"][ev] for h in g["hooks"]), ev
m = json.load(open(f"{home}/.commandcode/settings.json"))
assert set(m["hooks"]) == {"Stop", "SessionStart"}
a = json.load(open(f"{home}/.gemini/config/hooks.json"))
assert set(a["lore"]) == {"Stop", "SessionStart"} and "agy Stop" in a["lore"]["Stop"][0]["command"]
x = json.load(open(f"{home}/.codex/hooks.json"))
assert "SessionEnd" in x["hooks"]
PY
for f in .claude/settings.json .codex/hooks.json .commandcode/settings.json .gemini/config/hooks.json; do sha256sum "$HOME/$f"; done > "$tmp/hsums"
ok L hooks install
for f in .claude/settings.json .codex/hooks.json .commandcode/settings.json .gemini/config/hooks.json; do sha256sum "$HOME/$f"; done | diff - "$tmp/hsums" >/dev/null || fail "a second install changed bytes"
ok L hooks check
ok L hooks remove
python3 -c "import json,sys; a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2])); sys.exit(a!=b)" \
  "$HOME/.claude/settings.json" "$tmp/claude-settings.orig" || fail "remove did not restore claude settings"
grep -q 'lore-hook' "$HOME/.gemini/config/hooks.json" && fail "agy hooks not removed"
deny_msg "check passed after remove" "hooks missing or stale" L hooks check
echo '{not json' > "$HOME/.commandcode/settings.json"
deny_msg "invalid JSON was overwritten" "not valid JSON" L hooks install --host cmd

echo "test-capture: all checks passed"
