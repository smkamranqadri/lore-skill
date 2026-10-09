#!/usr/bin/env bash
# Store (files backend) tests in a temporary HOME. Never touches the real ~/.agents.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
store_sh="$repo_root/skills/lore/scripts/lore-store.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
home="$tmp/home"; mkdir -p "$home"
log="$tmp/log"
export HOME="$home"
unset LORE_STORE 2>/dev/null || true

fail() { echo "FAIL: $*" >&2; echo "--- last output ---" >&2; cat "$log" >&2 || true; exit 1; }
ok()   { "$@" >"$log" 2>&1 || fail "$* exited non-zero: $(cat "$log")"; }
deny() { local d="$1"; shift; if "$@" >"$log" 2>&1; then fail "$d"; fi; }
deny_msg() {
  local d="$1" want="$2"; shift 2
  if "$@" >"$log" 2>&1; then fail "$d"; fi
  grep -q -- "$want" "$log" || fail "$d (wanted message '$want', got: $(cat "$log"))"
}

store="$home/.agents/memory"
L="$store_sh"

# 1. init from nothing creates the starter notes
ok "$L" init
for n in config start-here.md preferences.md core-rules.md coordinating.md gotchas/shell-macos-claude-code.md; do
  [[ -f "$store/$n" ]] || fail "init did not create $n"
done
grep -q '^backend: files$' "$store/config" || fail "config missing backend: files"
grep -q '^Created ' "$log" || fail "init did not report what it created"

# 2. init is idempotent and never overwrites (mutation would clobber the edit)
printf '%s\n' '7. A rule the user added.' >> "$store/core-rules.md"
ok "$L" init
grep -q 'A rule the user added' "$store/core-rules.md" || fail "init overwrote an existing note"
grep -q 'Store current' "$log" || fail "second init did not say the store is current"

# 3. list
ok "$L" list
for n in core-rules.md preferences.md gotchas/shell-macos-claude-code.md; do
  grep -qx "$n" "$log" || fail "list did not show $n"
done

# 4. read and sha
ok "$L" read preferences.md
grep -q '^# Preferences' "$log" || fail "read did not print the note"
deny_msg "read refused an unknown note" "note not found" "$L" read nope.md
ok "$L" sha preferences.md
s1="$(cat "$log")"
[[ "$s1" =~ ^[0-9a-f]{64}$ ]] || fail "sha did not print a sha256"
printf '\n' >> "$store/preferences.md"
ok "$L" sha preferences.md
[[ "$(cat "$log")" != "$s1" ]] || fail "sha did not change after an edit"

# 5. create
ok "$L" create gotchas/web.md --title 'Gotchas: web'
grep -q '^# Gotchas: web$' "$store/gotchas/web.md" || fail "create wrote the wrong title"
deny "create refused an existing note" "$L" create gotchas/web.md
deny "create refused a path escaping the store" "$L" create ../evil.md
deny "create refused an absolute name" "$L" create /abs.md
# a note with a Thoughts heading but no bullets, to exercise fold-done's second guard
ok "$L" create scratch-empty.md --title Scratch
printf '\n## Thoughts\n' >> "$store/scratch-empty.md"

# 6. add-thought
ok "$L" add-thought gotchas/web.md "Next dev server: stop it before finishing."
grep -qx '## Thoughts' "$store/gotchas/web.md" || fail "add-thought did not create the Thoughts heading"
grep -qE '^- [0-9]{4}-[0-9]{2}-[0-9]{2}: Next dev server' "$store/gotchas/web.md" || fail "the thought is not dated"
deny "add-thought refused an unknown note" "$L" add-thought nope.md "x"
deny "add-thought refused empty text" "$L" add-thought gotchas/web.md ""
deny "add-thought refused whitespace text" "$L" add-thought gotchas/web.md "   "
deny "add-thought refused a multi-line thought" "$L" add-thought gotchas/web.md "$(printf 'a\nb')"
deny "add-thought refused a note-escaping path" "$L" add-thought ../x.md "x"

# 7. bump-rule
ok "$L" bump-rule core-rules.md "Check the real state"
grep -q 'read the latest message. (×3)' "$store/core-rules.md" || fail "bump did not raise (×2) to (×3)"
ok "$L" bump-rule core-rules.md "Mutation-check every guard"
grep -q 'restore the original. (×2)' "$store/core-rules.md" || fail "bump did not add (×2) to an unmarked rule"
deny_msg "bump-rule refused an absent match" "no rule matches" "$L" bump-rule core-rules.md "zzz absent zzz"
deny "bump-rule refused an ambiguous match" "$L" bump-rule core-rules.md "the"
deny_msg "bump-rule refused an empty match" "match text is required" "$L" bump-rule core-rules.md ""
deny "bump-rule refused a thought-only match" "$L" bump-rule gotchas/web.md "Next dev server"

# 8. fold-done: guards first, then the fold of a merged note
ok "$L" sha start-here.md; no_thoughts_sha="$(cat "$log")"
deny "fold-done refused when there are no thoughts" "$L" fold-done start-here.md --confirm-sha "$no_thoughts_sha"
deny_msg "fold-done refused an empty Thoughts section" "no thoughts to delete" \
  "$L" fold-done scratch-empty.md --confirm-sha x
deny_msg "fold-done refused without --confirm-sha" "refusing to delete thoughts without" "$L" fold-done gotchas/web.md
deny "fold-done refused a wrong sha" "$L" fold-done gotchas/web.md --confirm-sha "$(printf '0%.0s' {1..64})"
ok "$L" sha gotchas/web.md; before_merge="$(cat "$log")"
# the fold: the agent merges the thought into the rule section, above "## Thoughts"
awk '/^## Thoughts$/{print "- Stop the dev server before finishing."} {print}' "$store/gotchas/web.md" > "$tmp/merged"
mv "$tmp/merged" "$store/gotchas/web.md"
deny "fold-done refused a stale sha after the file changed" "$L" fold-done gotchas/web.md --confirm-sha "$before_merge"
ok "$L" read gotchas/web.md
grep -q 'Stop the dev server before finishing.' "$log" || fail "the read-back does not show the merged rule"
ok "$L" sha gotchas/web.md; fresh="$(cat "$log")"
ok "$L" fold-done gotchas/web.md --confirm-sha "$fresh"
grep -q 'Stop the dev server before finishing.' "$store/gotchas/web.md" || fail "fold-done lost the merged rule"
if grep -q '## Thoughts' "$store/gotchas/web.md"; then fail "fold-done left the Thoughts heading"; fi
if grep -q 'Next dev server' "$store/gotchas/web.md"; then fail "fold-done left the folded thought"; fi
ok "$L" sha gotchas/web.md
deny "fold-done refused when there is nothing to delete" "$L" fold-done gotchas/web.md --confirm-sha "$(cat "$log")"

# 9. a missing store: refused by read-only commands, created by init
home2="$tmp/home2"; mkdir -p "$home2"
deny "list refused a missing store" "$L" --store "$home2/.agents/memory" list
grep -q 'store not found' "$log" || fail "list did not name the missing store"
ok "$L" --store "$home2/.agents/memory" init
[[ -d "$home2/.agents/memory" ]] || fail "init did not create the store dir"

# 10. an empty or unknown command exits non-zero and prints usage
if "$L" >"$log" 2>&1; then fail "an empty command should exit non-zero"; fi
grep -q 'Usage:' "$log" || fail "an empty command should print usage"
if "$L" bogus >"$log" 2>&1; then fail "an unknown command should exit non-zero"; fi
grep -q 'Usage:' "$log" || fail "an unknown command should print usage"

# 11. config resolution: backend, space, mapping; files is the default
cfg="$tmp/cfgstore"; mkdir -p "$cfg"
ok "$L" --store "$cfg" config
grep -q '^backend: files$' "$log" || fail "config: no config should default to files"
if grep -q '^space:' "$log"; then fail "config: space should be omitted when unset"; fi
ok "$L" --store "$cfg" config mapping
grep -q 'backends/files.md$' "$log" || fail "config: files mapping not resolved"
test -f "$(cat "$log")" || fail "config: files mapping file missing"
printf '# a comment\nbackend: tartib\nspace: ai-agents\n' > "$cfg/config"
ok "$L" --store "$cfg" config
grep -q '^backend: tartib$' "$log" || fail "config: backend not read"
grep -q '^space: ai-agents$' "$log" || fail "config: space not read"
ok "$L" --store "$cfg" config backend; [[ "$(cat "$log")" == "tartib" ]] || fail "config backend value wrong"
ok "$L" --store "$cfg" config space; [[ "$(cat "$log")" == "ai-agents" ]] || fail "config space value wrong"
ok "$L" --store "$cfg" config mapping
grep -q 'backends/tartib.md$' "$log" || fail "config: tartib mapping not resolved"
test -f "$(cat "$log")" || fail "config: tartib mapping file missing"
printf 'backend: nope\n' > "$cfg/config"
deny_msg "config mapping refused an unknown backend" "no mapping file for backend: nope" "$L" --store "$cfg" config mapping
deny_msg "config refused an unknown key" "unknown config key" "$L" --store "$cfg" config bogus

echo "store tests: pass"
