#!/usr/bin/env bash
# The load path: pinned ids, load-plan and load-size, in a temporary HOME. Never touches the real
# ~/.agents and never reaches an MCP: the MCP calls are the agent's, per the backend mapping, and
# these tests exercise the files-side half that the mapping runs.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
L="$repo_root/skills/lore/scripts/lore-store.sh"
tartib_map="$repo_root/skills/lore/backends/tartib.md"
load_cmd="$repo_root/skills/lore/commands/load.md"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
home="$tmp/home"; mkdir -p "$home"
export HOME="$home"
unset LORE_STORE 2>/dev/null || true
store="$home/.agents/memory"
tab=$'\t'
log="$tmp/log"

fail() { echo "FAIL: $*" >&2; echo "--- last output ---" >&2; cat "$log" >&2 || true; exit 1; }
ok()   { "$@" >"$log" 2>&1 || fail "$* exited non-zero: $(cat "$log")"; }
deny() { local d="$1"; shift; if "$@" >"$log" 2>&1; then fail "$d"; fi; }
deny_msg() {
  local d="$1" want="$2"; shift 2
  if "$@" >"$log" 2>&1; then fail "$d"; fi
  grep -q -- "$want" "$log" || fail "$d (wanted message '$want', got: $(cat "$log"))"
}

mkdir -p "$store"
printf 'backend: tartib\nspace: ai-agents\n' > "$store/config"

# 1. ids-pin and ids-list: the pin file, an upsert (never a duplicate), and the missing file.
ok "$L" ids-list
[[ ! -s "$log" ]] || fail "ids-list on a store with no pins should print nothing"
ok "$L" ids-pin preferences.md 323
grep -q '^Pinned preferences.md 323$' "$log" || fail "ids-pin did not report the pin"
head -n1 "$store/ids" | grep -q '^# ' || fail "ids-pin did not write the header"
ok "$L" ids-pin preferences.md 999
[[ "$(grep -c . "$store/ids")" -eq 2 ]] || fail "ids-pin duplicated a note instead of updating it"
grep -qx "preferences.md${tab}999" "$store/ids" || fail "ids-pin did not update the id"
ok "$L" ids-pin gotchas/herdr.md 332 "Gotchas: Herdr"
ok "$L" ids-list
grep -qx "preferences.md${tab}999" "$log" || fail "ids-list did not print the id"
grep -qx "gotchas/herdr.md${tab}332${tab}Gotchas: Herdr" "$log" || fail "ids-list did not print the title"

# 2. ids-pin guards: a number, a gotchas title, no spaces, and a store that does not exist.
deny_msg "ids-pin refused a non-numeric id" "a Tartib id is a number" "$L" ids-pin core-rules.md abc
deny_msg "ids-pin refused an empty id" "a Tartib id is a number" "$L" ids-pin core-rules.md ""
deny_msg "ids-pin refused a gotchas note with no title" "a gotchas pin needs its title" "$L" ids-pin gotchas/web.md 328
deny_msg "ids-pin refused a note name with spaces" "no spaces" "$L" ids-pin "go tchas/web.md" 328
deny "ids-pin refused a note escaping the store" "$L" ids-pin ../evil.md 1

# 3. load-plan: the default is the three notes, by pinned id, with no search and no list_items.
ok "$L" ids-pin core-rules.md 324
ok "$L" ids-pin profile.md 405
ok "$L" load-plan
grep -qx "get_item 999${tab}# preferences.md : Agents: preferences" "$log" || fail "load-plan did not name preferences by id"
grep -qx "get_item 324${tab}# core-rules.md : Agents: core rules" "$log" || fail "load-plan did not name core rules by id"
grep -qx "get_item 405${tab}# profile.md : User: profile" "$log" || fail "load-plan did not name the profile by id"
if grep -q 'search\|list_items' "$log"; then fail "the pinned happy path named a search or list_items"; fi
for absent in coordinating.md references.md start-here.md gotchas/herdr.md; do
  if grep -q "# $absent" "$log"; then fail "load-plan read $absent by default"; fi
done

# 4. --note adds one note only, and its title is the pin's third field.
ok "$L" load-plan --note gotchas/herdr.md
grep -qx "get_item 332${tab}# gotchas/herdr.md : Gotchas: Herdr" "$log" || fail "load-plan --note did not name a gotchas note"
if grep -q 'coordinating.md' "$log"; then fail "load-plan --note added a note that was not asked for"; fi

# 5. an unpinned note is MISSING, with one search and its fixed title.
ok "$L" load-plan --note coordinating.md
grep -q '^MISSING coordinating.md : Agents: coordinating parallel agents' "$log" \
  || fail "load-plan did not report an unpinned note with the one-search fallback"
grep -q 'one search' "$log" || fail "the MISSING line did not name the one-search fallback"

# 5b. the four core topic notes: unpinned -> MISSING with the title, pinned -> get_item by id.
core_title() {
  case "$1" in
    core-verify.md)     echo 'Agents: core rules - verify and test' ;;
    core-production.md) echo 'Agents: core rules - production, data and secrets' ;;
    core-tools.md)      echo 'Agents: core rules - git and tools' ;;
    core-user.md)       echo 'Agents: core rules - working with the user' ;;
  esac
}
core_id=940
for note in core-verify.md core-production.md core-tools.md core-user.md; do
  ct="$(core_title "$note")"
  ok "$L" load-plan --note "$note"
  grep -Fqx -- "MISSING $note : $ct${tab}# one search \"$ct\", then ids-pin $note <id>" "$log" \
    || fail "load-plan did not report an unpinned $note with its one-search fallback"
  ok "$L" ids-pin "$note" "$core_id"
  ok "$L" load-plan --note "$note"
  grep -Fqx -- "get_item $core_id${tab}# $note : $ct" "$log" \
    || fail "load-plan did not name $note by its pinned id"
  core_id=$(( core_id + 1 ))
done

# 5c. source-scanning guard: the core-*.md rows in the mapping equal the cases default_title knows,
# and both equal the measured count (5: core-rules + the four topic notes), so it cannot pass by
# finding nothing.
map_core="$(grep -cE '^\| core-[a-z-]+\.md \|' "$tartib_map")"
script_core="$(grep -cE '^    core-[a-z-]+\.md\)' "$L")"
[[ "$map_core" -eq 5 ]] || fail "expected 5 core-*.md rows in the mapping, found $map_core"
[[ "$script_core" -eq 5 ]] || fail "expected 5 core-*.md cases in default_title, found $script_core"
[[ "$map_core" -eq "$script_core" ]] \
  || fail "the mapping lists $map_core core notes, default_title knows $script_core"

# 5d. an unknown --note is refused; a gotchas note is accepted; a note escaping the store is refused.
deny_msg "load-plan refused an unknown note" "unknown note for a load" "$L" load-plan --note bogus.md
ok "$L" load-plan --note gotchas/x.md
grep -q 'gotchas/x.md' "$log" || fail "load-plan did not accept a gotchas note"
deny "load-plan refused a note escaping the store" "$L" load-plan --note ../evil.md

# 6. load-plan reports the queue and the snapshot check.
printf '# Pending writes\n\n- p1\t2026-10-09\tadd-thought\tpreferences.md\tx\n' > "$store/pending.md"
printf '# Preferences\n\nrule\n' > "$store/preferences.md"
ok "$L" load-plan
grep -qx 'queue: 1' "$log" || fail "load-plan did not report the queue length"
grep -qx 'snapshot: preferences.md present' "$log" || fail "load-plan did not report a present snapshot note"
grep -qx 'snapshot: core-rules.md missing' "$log" || fail "load-plan did not report a missing snapshot note"

# 7. the files backend plans plain reads.
printf 'backend: files\n' > "$store/config"
ok "$L" load-plan
grep -qx "read preferences.md${tab}# Agents: preferences" "$log" || fail "the files load-plan did not print a read"
if grep -q 'get_item\|MISSING\|snapshot:' "$log"; then fail "the files load-plan printed an MCP line"; fi
printf 'backend: tartib\nspace: ai-agents\n' > "$store/config"

# 8. load-size sums the notes read and prints the budget line; budget comes from the config.
printf '# A\n12345' > "$store/a.md"
printf '# B\n678' > "$store/b.md"
ok "$L" load-size a.md b.md
grep -qx 'load: 2 notes, 16 chars (budget 60000)' "$log" || fail "load-size counted $(cat "$log")"
printf 'backend: tartib\nspace: ai-agents\nbudget: 10\n' > "$store/config"
ok "$L" load-size a.md
grep -qx 'load: 1 notes, 9 chars (budget 10)' "$log" || fail "load-size ignored the config budget"
deny_msg "load-size refused a note not in the store" "note not found" "$L" load-size nope.md
printf 'backend: tartib\nspace: ai-agents\n' > "$store/config"

# 9. a store that does not exist: the new commands refuse.
home2="$tmp/home2"; mkdir -p "$home2"
deny_msg "ids-list refused a missing store" "store not found" env HOME="$home2" "$L" ids-list
deny_msg "ids-pin refused a missing store" "store not found" env HOME="$home2" "$L" ids-pin a.md 1
deny_msg "load-plan refused a missing store" "store not found" env HOME="$home2" "$L" load-plan
deny_msg "load-size refused a missing store" "store not found" env HOME="$home2" "$L" load-size a.md

# 10. the load path names no list_items, and finds a note by search only in the pin fallback.
if grep -q 'list_items' "$load_cmd"; then fail "load.md named list_items"; fi
if grep -q 'list_items' "$tartib_map"; then fail "the tartib mapping named list_items"; fi
hits="$(grep -c 'search "' "$load_cmd" || true)"
[[ "$hits" -eq 1 ]] || fail "load.md has $hits search calls; the load path allows exactly one (the pin fallback)"

# 11. the script's fixed titles equal the mapping's table (the mirror cannot drift).
awk -F'|' '/^\| [a-z-]+\.md \|/ { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); gsub(/^[[:space:]]+|[[:space:]]+$/, "", $3); gsub(/`/, "", $3); print $2 "\t" $3 }' "$tartib_map" > "$tmp/titles"
[[ -s "$tmp/titles" ]] || fail "the mapping table could not be parsed"
while IFS="$tab" read -r note title; do
  [[ -n "$note" ]] || continue
  ok "$L" load-plan --note "$note"
  grep -Fq -- "$title" "$log" || fail "the script's title for $note does not match the mapping ('$title')"
done < "$tmp/titles"

echo "load-path tests: pass"
