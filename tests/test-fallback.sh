#!/usr/bin/env bash
# Fallback mechanics (snapshot, queue, replay) in a temporary HOME. Never touches the real
# ~/.agents and never reaches an MCP: the MCP calls are the agent's, per the backend mapping,
# and these tests exercise the files-side half that the mapping runs.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
L="$repo_root/skills/lore/scripts/lore-store.sh"

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
queued() { awk '/^- /{ c++ } END{ print c+0 }' "$store/pending.md"; }
first_op() { awk -F"$tab" '/^- /{ print $3; exit }' "$store/pending.md"; }

# 1. init makes no queue: a files store needs none, pending.md is only for an MCP backend.
ok "$L" init
[[ ! -e "$store/pending.md" ]] || fail "init created pending.md for a files store"
printf 'backend: tartib\nspace: ai-agents\n' > "$store/config"

# 2. snapshot-write: the files-store format; it never touches config or pending.md.
printf '# Preferences\n\n1. Short and direct: report what changed and what was proved.\n' > "$tmp/prefs"
ok "$L" snapshot-write preferences.md < "$tmp/prefs"
grep -q '^# Preferences$' "$store/preferences.md" || fail "snapshot-write did not write the note"
cp "$store/config" "$tmp/config.before"
printf '# x\n' > "$tmp/x"
deny_msg "snapshot-write refused config" "not a note" "$L" snapshot-write config < "$tmp/x"
deny_msg "snapshot-write refused pending.md" "not a note" "$L" snapshot-write pending.md < "$tmp/x"
deny "snapshot-write refused a path escaping the store" "$L" snapshot-write ../evil.md < "$tmp/x"
deny "snapshot-write refused an absolute name" "$L" snapshot-write /abs.md < "$tmp/x"
deny_msg "snapshot-write refused empty content" "snapshot content is empty" "$L" snapshot-write core-rules.md < /dev/null
printf 'no title here\n' > "$tmp/notitle"
deny_msg "snapshot-write refused content with no title" "begins with a '# Title' line" "$L" snapshot-write core-rules.md < "$tmp/notitle"
diff "$tmp/config.before" "$store/config" || fail "snapshot-write changed config"
[[ ! -e "$store/pending.md" ]] || fail "snapshot-write created pending.md"

# 3. snapshot-read: a note in the snapshot reads; one never read here is reported missing.
ok "$L" snapshot-read preferences.md
grep -q 'Short and direct' "$log" || fail "snapshot-read did not print the note"
deny_msg "snapshot-read reported a note missing from the snapshot" "not in the snapshot" "$L" snapshot-read gotchas/cobol.md

# 4. fallback-write add-thought: the snapshot is updated AND the write is queued.
ok "$L" fallback-write add-thought preferences.md "Ask one question at a time."
grep -q 'Ask one question at a time.' "$store/preferences.md" || fail "fallback-write did not update the snapshot"
grep -qE "^- p1${tab}[0-9]{4}-[0-9]{2}-[0-9]{2}${tab}add-thought${tab}preferences\.md${tab}Ask one question" "$store/pending.md" \
  || fail "the queued entry has no id, date, op, note or argument"
[[ "$(queued)" -eq 1 ]] || fail "fallback-write queued $(queued) entries, expected 1"

# 5. fallback-write refuses Fold (and any op it cannot queue), queueing nothing.
cp "$store/pending.md" "$tmp/pending.before"
deny_msg "fallback-write refused Fold" "no Fold while the backend is unreachable" "$L" fallback-write fold preferences.md "x"
deny_msg "fallback-write refused an unknown operation" "unknown fallback operation" "$L" fallback-write rewrite preferences.md "x"
deny_msg "fallback-write needed an operation" "fallback-write needs an operation" "$L" fallback-write
diff "$tmp/pending.before" "$store/pending.md" || fail "a refused fallback write still queued an entry"

# 6. fallback-write bump-rule and create-note: snapshot plus the exact argument queued.
printf '# Core rules\n\nThe rules that cost the most when broken.\n\n1. Keep it simple. (×2)\n' > "$tmp/core"
ok "$L" snapshot-write core-rules.md < "$tmp/core"
ok "$L" fallback-write bump-rule core-rules.md "Keep it simple"
grep -q 'Keep it simple. (×3)' "$store/core-rules.md" || fail "fallback bump did not raise the marker"
grep -qE "^- p2${tab}[0-9-]*${tab}bump-rule${tab}core-rules\.md${tab}Keep it simple$" "$store/pending.md" \
  || fail "the bump was not queued with its exact match"
ok "$L" fallback-write create-note gotchas/rust.md "Gotchas: Rust"
grep -q '^# Gotchas: Rust$' "$store/gotchas/rust.md" || fail "fallback create did not write the snapshot note"
grep -qE "^- p3${tab}[0-9-]*${tab}create-note${tab}gotchas/rust\.md${tab}Gotchas: Rust$" "$store/pending.md" \
  || fail "the create was not queued"
[[ "$(queued)" -eq 3 ]] || fail "expected 3 queued entries, got $(queued)"
deny_msg "fallback bump refused an absent match" "no rule matches" "$L" fallback-write bump-rule core-rules.md "zzz absent zzz"
[[ "$(queued)" -eq 3 ]] || fail "a refused fallback bump still queued"
deny_msg "fallback-write reported a note missing from the snapshot" "note not found" \
  "$L" fallback-write add-thought gotchas/cobol.md "x"

# 7. queue-add guards.
deny_msg "queue-add refused an unknown op" "unknown queued operation" "$L" queue-add fold preferences.md "x"
deny_msg "queue-add refused an empty argument" "needs its argument" "$L" queue-add add-thought preferences.md ""
deny_msg "queue-add refused a multi-line argument" "one line with no tabs" "$L" queue-add add-thought preferences.md "$(printf 'a\nb')"
deny_msg "queue-add refused a tab in the argument" "one line with no tabs" "$L" queue-add add-thought preferences.md "$(printf 'a\tb')"
deny_msg "queue-add refused a spaced note name" "must have no spaces" "$L" queue-add add-thought "go tchas/x.md" "x"
deny "queue-add refused a note-escaping path" "$L" queue-add add-thought ../x.md "x"

# 8. queue-list, and a replay run to the end (each entry popped as it is applied).
ok "$L" queue-list
[[ "$(grep -c . "$log" || true)" -eq 3 ]] || fail "queue-list did not list all 3 entries"
grep -qE "^p1${tab}" "$log" || fail "queue-list did not start with the oldest entry"
ok "$L" queue-pop
grep -qE "^p1${tab}" "$log" || fail "queue-pop did not print the popped entry"
[[ "$(queued)" -eq 2 ]] || fail "queue-pop did not remove the oldest entry"
[[ "$(first_op)" == "bump-rule" ]] || fail "queue-pop removed the wrong entry"
ok "$L" queue-list
if grep -qE "^p1${tab}" "$log"; then fail "queue-pop left the popped entry"; fi
ok "$L" queue-pop
ok "$L" queue-pop
[[ "$(queued)" -eq 0 ]] || fail "replay-done left $(queued) entries"
ok "$L" queue-list
[[ ! -s "$log" ]] || fail "queue-list was not empty after replaying every entry"
deny_msg "queue-pop refused an empty queue" "the queue is empty" "$L" queue-pop

# 9. a replay that fails halfway keeps exactly the failed entry and every later one.
ok "$L" queue-add add-thought preferences.md "first"
ok "$L" queue-add bump-rule core-rules.md "Keep it simple"
ok "$L" queue-add create-note gotchas/rust.md "Gotchas: Rust"
[[ "$(queued)" -eq 3 ]] || fail "setup: expected 3 entries, got $(queued)"
# replay entry 1 (applied, so popped); entry 2 must fail, and the replay stops there.
ok "$L" queue-pop
[[ "$(queued)" -eq 2 ]] || fail "a half replay left $(queued) entries, expected the failed one and the rest"
[[ "$(first_op)" == "bump-rule" ]] || fail "the failed entry was not kept at the front"
awk -F"$tab" '/^- /{ print $3 }' "$store/pending.md" | tail -1 | grep -qx 'create-note' \
  || fail "the entry after the failed one was not kept"

# 10. queue-clear removes every entry.
ok "$L" queue-clear
grep -q 'Cleared 2 queued write(s)' "$log" || fail "queue-clear did not report the count"
[[ "$(queued)" -eq 0 ]] || fail "queue-clear left entries"

# 11. switch-files leaves a store that loads with no backend.
ok "$L" queue-add add-thought preferences.md "queued before the switch"
[[ "$(queued)" -eq 1 ]] || fail "setup for switch-files failed"
ok "$L" switch-files
grep -q '^backend: files$' "$store/config" || fail "switch-files did not set backend: files"
if grep -q '^space:' "$store/config"; then fail "switch-files left the tartib space in config"; fi
[[ "$(queued)" -eq 0 ]] || fail "switch-files left queued entries"
ok "$L" config
grep -q '^backend: files$' "$log" || fail "the switched store does not resolve to the files backend"
ok "$L" config mapping
grep -q 'backends/files.md$' "$log" || fail "the switched store has no files mapping"
ok "$L" list
grep -qx 'preferences.md' "$log" || fail "the switched store lost preferences.md"
grep -qx 'gotchas/rust.md' "$log" || fail "the switched store lost a snapshot note"
ok "$L" read preferences.md
grep -q 'Short and direct' "$log" || fail "the switched store cannot read a note"
ok "$L" snapshot-read gotchas/rust.md
grep -q '^# Gotchas: Rust$' "$log" || fail "the switched snapshot note is unreadable"

# 12. the new commands refuse a store that does not exist.
home2="$tmp/home2"; mkdir -p "$home2"
deny_msg "snapshot-write refused a missing store" "store not found" env HOME="$home2" "$L" snapshot-write x.md < /dev/null
deny_msg "snapshot-read refused a missing store" "store not found" env HOME="$home2" "$L" snapshot-read x.md
deny_msg "queue-add refused a missing store" "store not found" env HOME="$home2" "$L" queue-add add-thought x.md "x"
deny_msg "queue-list refused a missing store" "store not found" env HOME="$home2" "$L" queue-list
deny_msg "fallback-write refused a missing store" "store not found" env HOME="$home2" "$L" fallback-write add-thought x.md "x"
deny_msg "switch-files refused a missing store" "store not found" env HOME="$home2" "$L" switch-files

# 13. snapshot-render pins one rendering of a Tartib note: the title once as the H1, then the rest
# of the text byte for byte, then ## Thoughts with one dated line per --thought.
cat > "$tmp/note.txt" <<'EOF'
Agents: preferences

How the user wants work done.

1. A rule. (×2)
2. Another rule.
EOF
cat > "$tmp/expected.md" <<'EOF'
# Agents: preferences

How the user wants work done.

1. A rule. (×2)
2. Another rule.

## Thoughts

- 2026-10-08: first thought
- 2026-10-09: second thought
EOF
"$L" snapshot-render --thought 2026-10-08 "first thought" --thought 2026-10-09 "second thought" \
  < "$tmp/note.txt" > "$tmp/out.md" 2>"$log" || fail "snapshot-render exited non-zero: $(cat "$log")"
cmp -s "$tmp/expected.md" "$tmp/out.md" || fail "snapshot-render bytes differ from the fixture: $(diff "$tmp/expected.md" "$tmp/out.md" || true)"
# a Tartib text has no trailing newline; the bytes must not change
printf '%s' "$(cat "$tmp/note.txt")" > "$tmp/note-nonl.txt"
"$L" snapshot-render --thought 2026-10-08 "first thought" --thought 2026-10-09 "second thought" \
  < "$tmp/note-nonl.txt" > "$tmp/out2.md" 2>"$log" || fail "snapshot-render (no trailing newline) exited non-zero"
cmp -s "$tmp/out.md" "$tmp/out2.md" || fail "a missing trailing newline changed the rendered bytes"
# the title is the H1 once, and never repeated as a plain line
[[ "$(grep -c '^# Agents: preferences$' "$tmp/out.md")" -eq 1 ]] || fail "the H1 is not written exactly once"
if grep -q '^Agents: preferences$' "$tmp/out.md"; then fail "the title is repeated as a plain line"; fi
# no --thought means no ## Thoughts section
"$L" snapshot-render < "$tmp/note.txt" > "$tmp/out3.md" 2>"$log" || fail "snapshot-render (no thoughts) exited non-zero"
if grep -q '^## Thoughts$' "$tmp/out3.md"; then fail "an empty Thoughts section was written"; fi
# and the render pipes into snapshot-write unchanged
"$L" snapshot-render --thought 2026-10-08 "first thought" --thought 2026-10-09 "second thought" \
  < "$tmp/note.txt" 2>"$log" | "$L" snapshot-write gotchas/rendered.md >"$log" 2>&1 \
  || fail "the render did not pipe into snapshot-write: $(cat "$log")"
cmp -s "$tmp/expected.md" "$store/gotchas/rendered.md" || fail "snapshot-write changed the rendered bytes"
# guards
deny_msg "snapshot-render refused empty input" "needs the note's text on stdin" "$L" snapshot-render < /dev/null
printf '\nbody text\n' > "$tmp/blank-first.txt"
deny_msg "snapshot-render refused a blank first line" "must have a first line" "$L" snapshot-render < "$tmp/blank-first.txt"
printf '# Already headed\n\nbody\n' > "$tmp/already-h1.txt"
deny_msg "snapshot-render refused text that already starts with a heading" "already begins with a heading" "$L" snapshot-render < "$tmp/already-h1.txt"
deny_msg "snapshot-render refused a bad thought date" "must be YYYY-MM-DD" "$L" snapshot-render --thought 10-08-2026 x < "$tmp/note.txt"
deny_msg "snapshot-render refused a multi-line thought" "a thought is one line" "$L" snapshot-render --thought 2026-10-08 "$(printf 'a\nb')" < "$tmp/note.txt"
deny_msg "snapshot-render refused a --thought with a missing argument" "--thought needs" "$L" snapshot-render --thought 2026-10-08 < "$tmp/note.txt"

echo "fallback tests: pass"
