#!/usr/bin/env bash
# lore v1 daily review tests: a fake reviewer stands in for the strong model. Temporary HOME.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
lore="$repo_root/skills/lore/scripts/lore.py"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"; mkdir -p "$HOME"
unset LORE_STORE LORE_HARVEST LORE_EXTRACT_CMD 2>/dev/null || true
log="$tmp/log"; store="$HOME/.agents/memory"; calls="$tmp/review-calls"

fail() { echo "FAIL: $*" >&2; echo "--- last output ---" >&2; cat "$log" >&2 || true; exit 1; }
ok()   { "$@" >"$log" 2>&1 || fail "$* exited non-zero"; }
deny_msg() {
  local d="$1" want="$2"; shift 2
  if "$@" >"$log" 2>&1; then fail "$d"; fi
  grep -q -- "$want" "$log" || fail "$d (wanted '$want')"
}
L() { python3 "$lore" "$@"; }
ncalls() { [[ -f "$calls" ]] && wc -l < "$calls" | tr -d ' ' || echo 0; }

# The fake reviewer: merges the pnpm pair, rewrites the sequential rule, rejects the deploy fact,
# and also tries ops it must not get: a context-only id, an unknown id, and a blocklisted text.
cat > "$tmp/fake-review.sh" <<'EOF'
#!/usr/bin/env bash
echo call >> "$FAKE_CALLS"; cp "$LORE_PROMPT_FILE" "$FAKE_CALLS.last-prompt"
[[ -n "${FAKE_FAIL:-}" ]] && { echo "quota exceeded" >&2; exit 1; }
[[ -n "${FAKE_EMPTY:-}" ]] && { echo '[]'; exit 0; }
p="$LORE_PROMPT_FILE"
ids() { sed -n '/^To review/,/^Other rules/p' "$p" | grep -E '^[0-9a-f]{8} \[' | grep -- "$1" | cut -c1-8; }
ctx() { sed -n '/^Other rules/,$p' "$p" | grep -E '^[0-9a-f]{8}:' | grep -- "$1" | cut -c1-8; }
ops=()
mapfile -t pn < <(ids pnpm)
[[ ${#pn[@]} -ge 2 ]] && ops+=("{\"op\":\"merge\",\"ids\":[\"${pn[0]}\",\"${pn[1]}\"],\"text\":\"Use pnpm, not npm, in node projects\",\"category\":\"tools\",\"reason\":\"same preference\"}")
s="$(ids 'strictly sequentially')"; [[ -n "$s" ]] && ops+=("{\"op\":\"rewrite\",\"id\":\"$s\",\"text\":\"Run agents sequentially when tasks share files; parallel only with disjoint files\",\"category\":\"orchestration\",\"reason\":\"scoped\"}")
d="$(ids deploy.sh)"; [[ -n "$d" ]] && ops+=("{\"op\":\"reject\",\"id\":\"$d\",\"reason\":\"project fact\"}")
c="$(ctx 'Old context rule')"; [[ -n "$c" ]] && ops+=("{\"op\":\"reject\",\"id\":\"$c\",\"reason\":\"not allowed: context only\"}")
ops+=('{"op":"reject","id":"deadbeef","reason":"unknown id"}')
b="$(ids 'Blocked rewrite')"; [[ -n "$b" ]] && ops+=("{\"op\":\"rewrite\",\"id\":\"$b\",\"text\":\"Banned rule text\",\"reason\":\"to a blocklisted text\"}")
(IFS=,; echo "[${ops[*]}]")
EOF
chmod +x "$tmp/fake-review.sh"
export LORE_REVIEW_CMD="bash '$tmp/fake-review.sh'" FAKE_CALLS="$calls"

# 1. An old confirmed rule, reviewed on day one; from then on it is context only.
ok L --today 2026-10-01 init
ok L --today 2026-10-01 add --cat tools --text "Old context rule about formatting only changed files" --explicit
ok L --today 2026-10-01 maintain
FAKE_EMPTY=1 L --today 2026-10-01 review --force >"$log" 2>&1 || fail "first review failed"
grep -q '"last_review": "2026-10-01"' "$store/harvest-state.json" || fail "review did not record its day"

# 2. A day of new memory: a near-duplicate pair, a promoted rule to scope, a project fact, and a
#    rule whose rewrite would land on a blocklisted text.
ok L --today 2026-10-10 add --cat orchestration --text "Run agents strictly sequentially" --explicit
ok L --today 2026-10-10 maintain   # promoted on the 10th, never reviewed
ok L --today 2026-10-16 add --cat tools --text "Use pnpm in node projects"
ok L --today 2026-10-16 add --cat tools --text "Always use pnpm instead of npm"
ok L --today 2026-10-16 add --cat tools --text "Deploy with deploy.sh to the server"
ok L --today 2026-10-16 add --cat ui --text "Blocked rewrite source rule"
ok L --today 2026-10-16 add --cat ui --text "Banned rule text" --explicit
ok L --today 2026-10-16 maintain
ok L --today 2026-10-16 drop "Banned rule text"
ok L --today 2026-10-16 add --cat tools --text "Use pnpm in node projects"   # n=2 on the first of the pair
before="$(ncalls)"
ok L --today 2026-10-16 review
[[ "$(ncalls)" == $((before + 1)) ]] || fail "review did not call the reviewer once"
grep -q 'Old context rule' "$calls.last-prompt" || fail "context rules missing from the prompt"
sed -n '/^To review/,/^Other rules/p' "$calls.last-prompt" | grep -q 'Old context rule' && fail "an old rule was put up for review"

grep -q 'Use pnpm, not npm, in node projects\. Confidence: 0\.30 .*n=3' "$store/candidates.md" || fail "merge lost counts or confidence"
grep -q 'Use pnpm in node projects\.\|Always use pnpm instead' "$store/candidates.md" && fail "merged originals left behind"
grep -q 'Run agents sequentially when tasks share files; parallel only with disjoint files\. Confidence: 0\.60 .*flags=explicit' \
  "$store/orchestration.md" || fail "rewrite moved a confirmed rule or lost its flags"
grep 'Run agents sequentially when tasks share files' "$store/orchestration.md" | grep -q 'promoted=2026-10-10' \
  || fail "rewrite moved a confirmed rule back through promotion (its promotion date changed)"
grep -q 'strictly sequentially' "$store/orchestration.md" && fail "rewritten original left behind"
grep -q 'Deploy with deploy.sh' "$store/candidates.md" && fail "rejected entry left behind"
grep -q 'Old context rule about formatting' "$store/tools.md" || fail "a context-only rule was rejected"
grep -q 'Banned rule text' "$store/ui.md" "$store/candidates.md" && fail "a blocklisted text came back through a rewrite"
grep -q 'Blocked rewrite source rule' "$store/candidates.md" || fail "a refused rewrite deleted its source rule"
grep -q 'review: refused rewrite of [0-9a-f]* onto blocked or secret-looking text (to a blocklisted text)' "$log" \
  || fail "a rewrite onto a blocklisted text was not refused as such"
grep -q 'Run agents sequentially when tasks share files' "$store/INDEX.md" || fail "index not regenerated after review"
grep -q '^## 2026-10-16: .* reviewed, 3 changed$' "$store/review.log" || fail "review.log does not record 3 changes"
grep -q '^- reject .*(project fact)' "$store/review.log" || fail "review.log lacks the reason"
grep -q '"last_review": "2026-10-16"' "$store/harvest-state.json" || fail "review did not record its day"

# 3. Once a day: a second run makes no call.
before="$(ncalls)"
ok L --today 2026-10-16 review
grep -q 'already reviewed today' "$log" || fail "second review did not say it was done"
[[ "$(ncalls)" == "$before" ]] || fail "reviewed twice in one day"

# 4. A failed review leaves the day unmarked, so the next harvest retries it.
ok L --today 2026-10-17 add --cat git --text "Never force push to main"
deny_msg "a failed review exited zero" "review failed" env FAKE_FAIL=1 python3 "$lore" --today 2026-10-17 review
grep -q '"last_review": "2026-10-16"' "$store/harvest-state.json" || fail "a failed review marked the day"

# 5. The first harvest of a day triggers the review; a later harvest that day does not.
before="$(ncalls)"
FAKE_EMPTY=1 L --today 2026-10-17 harvest >"$log" 2>&1 || fail "harvest failed"
[[ "$(ncalls)" == $((before + 1)) ]] || fail "harvest did not trigger the review"
FAKE_EMPTY=1 L --today 2026-10-17 harvest >"$log" 2>&1 || fail "harvest failed"
[[ "$(ncalls)" == $((before + 1)) ]] || fail "a second harvest reviewed again"

# 6. Nothing to review: no call, the day is still marked.
s2="$tmp/s2"; ok L --store "$s2" --today 2026-10-17 init
before="$(ncalls)"
ok L --store "$s2" --today 2026-10-17 review
grep -q 'nothing to review' "$log" || fail "empty store was reviewed"
[[ "$(ncalls)" == "$before" ]] || fail "the reviewer was called with nothing to review"

echo "test-review: all checks passed"
