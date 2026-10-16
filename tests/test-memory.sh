#!/usr/bin/env bash
# lore v1 memory store (lore.py) tests in a temporary HOME. Never touches the real ~/.agents.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
lore="$repo_root/skills/lore/scripts/lore.py"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"; mkdir -p "$HOME"
unset LORE_STORE 2>/dev/null || true
log="$tmp/log"
store="$HOME/.agents/memory"

fail() { echo "FAIL: $*" >&2; echo "--- last output ---" >&2; cat "$log" >&2 || true; exit 1; }
ok()   { "$@" >"$log" 2>&1 || fail "$* exited non-zero"; }
deny_msg() {
  local d="$1" want="$2"; shift 2
  if "$@" >"$log" 2>&1; then fail "$d"; fi
  grep -q -- "$want" "$log" || fail "$d (wanted '$want')"
}
L() { python3 "$lore" "$@"; }
idof() { L list "$@" | awk -F'\t' 'NR==1{print $1}'; }

# 1. Commands refuse to run before init; init creates the store and never overwrites.
deny_msg "add ran without a store" "run init first" L add --cat git --text "x"
ok L --today 2026-10-01 init
for f in config candidates.md profile.md INDEX.md; do [[ -f "$store/$f" ]] || fail "init missed $f"; done
echo "- my own line" >> "$store/profile.md"
ok L init
grep -q '^- my own line$' "$store/profile.md" || fail "init overwrote profile.md"
grep -q '^Store already initialised$' "$log" || fail "second init did not say it changed nothing"

# 2. A new learning is a candidate at 0.30 and stays out of the index.
ok L --today 2026-10-01 add --cat git --text "Never run git reset in the main checkout" --src "don't reset main"
grep -q '^added [0-9a-f]\{8\} candidate$' "$log" || fail "add did not report a candidate"
grep -q 'Never run git reset in the main checkout\. Confidence: 0\.30 .*cat=git' "$store/candidates.md" \
  || fail "candidate not written with 0.30 and its category"
grep -q 'git reset' "$store/INDEX.md" && fail "a candidate leaked into the index"

# 3. Same day again: count rises, confidence and days do not; one-day candidates are not promoted.
ok L --today 2026-10-01 add --cat git --text "never run GIT reset in the main checkout!"
grep -q 'Confidence: 0\.30 .*days=1 n=2' "$store/candidates.md" || fail "same-day repeat changed days or confidence"
ok L --today 2026-10-01 maintain
grep -q 'promoted=0' "$log" || fail "a one-day candidate was promoted"

# 4. A second day promotes it into its category at >= 0.60, and the index lists it as New.
ok L --today 2026-10-03 add --cat git --text "Never run git reset in the main checkout."   # add promotes at once now
ok L --today 2026-10-03 maintain
grep -q 'Never run git reset in the main checkout\. Confidence: 0\.60 ' "$store/git.md" || fail "promotion did not land in git.md at 0.60"
grep -q 'git reset' "$store/candidates.md" && fail "promoted candidate stayed in candidates.md"
grep -q '^New (say "drop that"' "$store/INDEX.md" || fail "index has no New section after a promotion"
grep -q '^- `git.md`: read when the task touches git (1)$' "$store/INDEX.md" || fail "index lacks the git read-when line"

# 5. Explicit statements promote at once.
ok L --today 2026-10-03 add --cat ui --text "Prefer toggle switches over checkboxes" --explicit
ok L --today 2026-10-03 maintain
grep -q 'Prefer toggle switches over checkboxes\. Confidence: 0\.60 .*flags=explicit' "$store/ui.md" || fail "explicit learning not promoted"

# 6. Repeats on new days raise a confirmed entry until it goes inline (>= 0.80), capped at 0.95.
for d in 2026-10-04 2026-10-05 2026-10-06 2026-10-07 2026-10-08; do
  ok L --today "$d" add --cat git --text "Never run git reset in the main checkout"
done
grep -q 'Never run git reset in the main checkout\. Confidence: 0\.95 ' "$store/git.md" || fail "confidence did not cap at 0.95"
grep -q '^Rules:$' "$store/INDEX.md" || fail "index has no Rules heading"
awk '/^Rules:$/{r=1;next} /^$/{r=0} r' "$store/INDEX.md" | grep -q 'Never run git reset' || fail "a 0.95 rule is not inline"

# 7. drop removes and blocklists; adding it again is refused (guard: blocklist).
gid="$(idof --cat git)"
ok L --today 2026-10-08 drop "$gid"
grep -q 'git reset' "$store/git.md" && fail "drop left the entry"
grep -q "^$gid	" "$store/blocklist" || fail "drop did not blocklist"
ok L --today 2026-10-09 add --cat git --text "Never run git reset in the main checkout"
grep -q "^blocked $gid$" "$log" || fail "a blocklisted rule was accepted again"
grep -q 'git reset' "$store/candidates.md" && fail "a blocklisted rule reached candidates"

# 8. Unseen candidates expire after 28 days; unseen confirmed entries decay and go below 0.40.
s2="$tmp/s2"   # its own store: far-future dates here must not decay the other tests' entries
L2() { L --store "$s2" "$@"; }
ok L2 --today 2026-10-01 init
ok L2 --today 2026-10-01 add --cat tools --text "Use pnpm for node projects"
ok L2 --today 2026-10-30 maintain
grep -q 'expired=1' "$log" || fail "a 29-day-old candidate did not expire"
ok L2 --today 2026-10-03 add --cat tools --text "Read lint scripts before running them" --explicit
ok L2 --today 2026-10-03 maintain
ok L2 --today 2026-12-03 maintain   # 61 days: two steps, 0.60 -> 0.50
grep -q 'Read lint scripts before running them\. Confidence: 0\.50 ' "$s2/tools.md" || fail "decay did not take two steps"
ok L2 --today 2026-12-10 add --cat tools --text "Read lint scripts before running them"   # seen again: 0.65
ok L2 --today 2027-01-05 maintain   # 26 days since seen: no decay
grep -q 'Read lint scripts before running them\. Confidence: 0\.65 ' "$s2/tools.md" || fail "an entry seen 26 days ago decayed"
ok L2 --today 2027-02-03 maintain   # 55 days since seen: one step from the last sighting, not two
grep -q 'Read lint scripts before running them\. Confidence: 0\.60 ' "$s2/tools.md" || fail "decay counted from the old decay date, not the last sighting"
ok L2 --today 2027-06-10 maintain   # 182 days unseen: six steps, 0.65 -> 0.35, removed
grep -q 'Read lint scripts' "$s2/tools.md" && fail "an entry under 0.40 was not removed"

# 9. A contradiction lowers the old entry by 0.30.
ok L --today 2026-10-03 add --cat orchestration --text "Run agents strictly sequentially" --explicit
ok L --today 2026-10-03 maintain
for d in 2026-10-04 2026-10-05; do ok L --today "$d" add --cat orchestration --text "Run agents strictly sequentially"; done
oid="$(idof --cat orchestration)"
ok L --today 2026-10-06 add --cat orchestration --text "Run parallel agents only with disjoint files" --contradicts "$oid"
grep -q 'Run agents strictly sequentially\. Confidence: 0\.60 ' "$store/orchestration.md" || fail "contradiction did not lower 0.90 to 0.60"

# 10. The index stays within budget (guard: budget); pinned rules over budget are an error.
for c in a b c; do   # 75 rules at 0.90, about 2,000 tokens: more than the budget can hold inline
  {
    echo "# Verification $c"; echo "<!-- read-when: claiming work is done -->"; echo
    for i in $(seq 1 25); do
      echo "- Verification rule $c$i with enough words to take real space in the start-up index. Confidence: 0.90 <!-- id=$(printf '%07x' "$i")$c first=2026-10-03 last=2026-10-06 days=4 n=4 -->"
    done
  } > "$store/verify-$c.md"
done
ok L --today 2026-10-06 maintain
ok L --today 2026-10-06 index
size="$(sed -n 's/^INDEX.md \([0-9]*\) tokens.*/\1/p' "$log")"
[[ -n "$size" && "$size" -le 1500 ]] || fail "index is $size tokens, over the 1500 budget"
[[ "$(grep -c '^- `verify-[abc].md`' "$store/INDEX.md")" == 3 ]] || fail "verify read-when lines missing"
inline="$(awk '/^Rules:$/{r=1;next} /^$/{r=0} r' "$store/INDEX.md" | grep -c 'Verification rule' || true)"
[[ "$inline" -gt 0 && "$inline" -lt 75 ]] || fail "budget fit kept $inline of 75 rules inline"
echo "- Extra rule over the cap. Confidence: 0.85 <!-- id=0000cap0 first=2026-10-06 last=2026-10-06 days=2 n=2 -->" >> "$store/verify-a.md"
ok L --today 2026-10-06 maintain
[[ "$(grep -c 'Confidence:' "$store/verify-a.md")" == 25 ]] || fail "category cap of 25 not applied"
grep -q 'Extra rule over the cap' "$store/verify-a.md" && fail "the cap kept the lowest-confidence entry"
echo "budget: 60" > "$store/config"
deny_msg "skeleton over budget was accepted" "exceeds the budget" L --today 2026-10-06 index
echo "budget: 1500" > "$store/config"

# 11. Pinned entries never decay and always go inline.
tid="$(idof --cat ui)"
ok L --today 2026-10-06 pin "$tid"
ok L --today 2028-01-01 maintain
grep -q 'Prefer toggle switches over checkboxes\. Confidence: 0\.60 .*flags=explicit,pin' "$store/ui.md" || fail "a pinned entry decayed or lost its flag"
awk '/^Rules:$/{r=1;next} /^$/{r=0} r' "$store/INDEX.md" | grep -q 'toggle switches' || fail "a pinned entry is not inline"

# 12. Bad input is refused.
deny_msg "reserved category accepted" "bad category" L add --cat candidates --text "x"
deny_msg "comment marker accepted in text" "may not contain" L add --cat git --text "a <!-- b"

# 13. The entry line before the comment is valid taste syntax.
line="$(grep -m1 'Confidence:' "$store/ui.md")"
[[ "$(sed 's/ <!--.*//' <<<"$line")" =~ ^-\ .+\ Confidence:\ 0\.[0-9][0-9]$ ]] || fail "entry is not taste-shaped: $line"

echo "test-memory: all checks passed"
