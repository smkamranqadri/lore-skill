#!/usr/bin/env bash
# lore v1 seed import tests (lore.py import). Temporary HOME.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
lore="$repo_root/skills/lore/scripts/lore.py"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"; mkdir -p "$HOME"
unset LORE_STORE 2>/dev/null || true
log="$tmp/log"; store="$HOME/.agents/memory"

fail() { echo "FAIL: $*" >&2; echo "--- last output ---" >&2; cat "$log" >&2 || true; exit 1; }
ok()   { "$@" >"$log" 2>&1 || fail "$* exited non-zero"; }
deny_msg() {
  local d="$1" want="$2"; shift 2
  if "$@" >"$log" 2>&1; then fail "$d"; fi
  grep -q -- "$want" "$log" || fail "$d (wanted '$want')"
}
L() { python3 "$lore" "$@"; }

ok L --today 2026-10-16 init
ok L --today 2026-10-16 add --cat git --text "Banned seed rule" --explicit
ok L --today 2026-10-16 maintain
ok L --today 2026-10-16 drop "Banned seed rule"

cat > "$tmp/seed.json" <<'EOF'
[
 {"rule":"Check the real state behind every claim","category":"verification","confidence":0.95,"explicit":true,"pin":true,"src":"tartib core 4 (x20)","days":20},
 {"rule":"Never print any part of a secrets file","category":"safety","confidence":0.9,"explicit":true,"src":"tartib core","days":8},
 {"rule":"check the REAL state behind every claim!","category":"verification","confidence":0.8,"src":"taste V1","days":4},
 {"rule":"Prefer toggle switches over checkboxes","category":"ui","confidence":0.5,"src":"taste U9","days":2},
 {"rule":"Banned seed rule","category":"git","confidence":0.9},
 {"rule":"Bad category","category":"Not Valid","confidence":0.9},
 {"rule":"Has a <!-- comment","category":"git","confidence":0.9},
 {"rule":"No confidence","category":"git"},
 {"rule":"Too sure","category":"git","confidence":7},
 "not an object"
]
EOF

# 1. Valid items land: >= 0.60 confirmed in its category, lower as a candidate; duplicates merge.
ok L --today 2026-10-16 import --file "$tmp/seed.json"
grep -q '^confirmed=2 candidates=1 merged=1 blocked=1 skipped=5 promoted=0 ' "$log" || fail "import counts are wrong: $(head -1 "$log")"
grep -q 'Check the real state behind every claim\. Confidence: 0\.95 .*days=20 .*flags=explicit,pin' "$store/verification.md" \
  || fail "a confirmed seed rule lost its confidence, days or flags"
grep -q 'Never print any part of a secrets file\. Confidence: 0\.90 ' "$store/safety.md" || fail "second confirmed rule missing"
grep -q 'Prefer toggle switches over checkboxes\. Confidence: 0\.50 .*cat=ui' "$store/candidates.md" || fail "a low-confidence item did not become a candidate"
[[ "$(grep -c 'real state' "$store/verification.md")" == 1 ]] || fail "a duplicate was imported twice"

# 2. Blocklisted rules stay out; every bad item is skipped with its reason.
grep -q 'Banned seed rule' "$store/git.md" "$store/candidates.md" 2>/dev/null && fail "a blocklisted rule was imported"
for want in "bad category 'Not Valid'" "may not contain" "item 8:" "out of range" "item 10: not an object"; do
  grep -q -- "$want" "$log" || fail "no skip reason containing: $want"
done

# 3. Imported rules are not announced as New; pinned ones go inline; the index is within budget.
grep -q '^New ' "$store/INDEX.md" && fail "seed rules were listed as New"
awk '/^Rules:$/{r=1;next} /^$/{r=0} r' "$store/INDEX.md" | grep -q 'Check the real state' || fail "a pinned seed rule is not inline"
[[ "$(sed -n 's/.* index_tokens=\([0-9]*\)$/\1/p' "$log")" -le 1500 ]] || fail "index over budget after import"

# 4. Importing the same file again changes nothing.
cat "$store"/*.md | sha256sum > "$tmp/before"
ok L --today 2026-10-16 import --file "$tmp/seed.json"
grep -q '^confirmed=0 candidates=0 merged=4 blocked=1 skipped=5 promoted=0 ' "$log" || fail "a second import added entries: $(head -1 "$log")"
cat "$store"/*.md | sha256sum | diff - "$tmp/before" >/dev/null || fail "a second import changed the store"

# 5. A file that is not a JSON array is refused.
echo '{"rule":"x"}' > "$tmp/obj.json"
deny_msg "a non-array was imported" "must hold a JSON array" L import --file "$tmp/obj.json"

# 6. describe sets the title and the read-when line the index shows; bad input is refused.
ok L --today 2026-10-16 describe verification --title "Verification" --read-when "claiming anything is done, fixed or passing"
grep -q '^<!-- read-when: claiming anything is done, fixed or passing -->$' "$store/verification.md" || fail "read-when not written"
grep -q '^- `verification.md`: read when claiming anything is done, fixed or passing (1)$' "$store/INDEX.md" || fail "index not regenerated with the new read-when"
grep -q 'Check the real state behind every claim' "$store/verification.md" || fail "describe lost entries"
deny_msg "a comment marker was accepted" "without '-->'" L describe verification --read-when "x --> y"
deny_msg "an unknown category was described" "no category nope" L describe nope --title "Nope"

echo "test-import: all checks passed"
