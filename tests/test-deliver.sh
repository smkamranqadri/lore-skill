#!/usr/bin/env bash
# lore v1 delivery tests: the index reaches each host's global file in a temporary HOME.
# Never touches the real ~/.claude, ~/.codex, ~/.commandcode or ~/.gemini.
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
between() { awk '/<!-- lore:index start -->/{b=1;next} /<!-- lore:index end -->/{b=0} b' "$1"; }

claude="$HOME/.claude/CLAUDE.md"; codex="$HOME/.codex/AGENTS.md"
cmdf="$HOME/.commandcode/AGENTS.md"; agy="$HOME/.gemini/GEMINI.md"

# 1. Without an index there is nothing to deliver.
mkdir -p "$store"
deny_msg "deliver ran without an index" "run init" L deliver

# 2. Hosts not installed are skipped and get no file.
ok L --today 2026-10-16 init
ok L --today 2026-10-16 add --cat git --text "Never run git reset in the main checkout" --explicit
ok L --today 2026-10-16 maintain
ok L deliver
for h in claude codex cmd agy; do grep -q "^$h: skipped, not installed" "$log" || fail "$h was not skipped"; done
[[ -e "$claude" || -e "$codex" || -e "$cmdf" || -e "$agy" ]] && fail "deliver created a file for a host that is not installed"

# 3. Installed hosts: user text is kept byte for byte; import hosts get one import line, block
#    hosts a copy of the index.
mkdir -p "$HOME/.claude" "$HOME/.codex" "$HOME/.commandcode" "$HOME/.gemini"
printf '# Global instructions\n\n- My own rule, keep it.\n' > "$claude"
printf 'Codex notes\nno trailing newline' > "$codex"
cp "$claude" "$tmp/claude.orig"
ok L deliver
for h in claude codex cmd agy; do grep -q "^$h: delivered to" "$log" || fail "$h was not delivered"; done
head -c "$(wc -c < "$tmp/claude.orig")" "$claude" | cmp -s - "$tmp/claude.orig" || fail "user text in CLAUDE.md changed"
[[ "$(between "$claude")" == "@$store/INDEX.md" ]] || fail "claude block is not the import line"
[[ "$(between "$cmdf")" == "@$store/INDEX.md" ]] || fail "cmd block is not the import line"
diff <(between "$codex") "$store/INDEX.md" >/dev/null || fail "codex block is not a copy of the index"
diff <(between "$agy") "$store/INDEX.md" >/dev/null || fail "agy block is not a copy of the index"
head -2 "$codex" | grep -q '^no trailing newline$' || fail "codex user text lost or not separated"

# 4. Idempotent: a second run changes nothing.
for f in "$claude" "$codex" "$cmdf" "$agy"; do sha256sum "$f"; done > "$tmp/sums"
ok L deliver
for h in claude codex cmd agy; do grep -q "^$h: up to date" "$log" || fail "$h rewritten on a no-op run"; done
for f in "$claude" "$codex" "$cmdf" "$agy"; do sha256sum "$f"; done | diff - "$tmp/sums" >/dev/null || fail "a no-op run changed bytes"
grep -c '<!-- lore:index start -->' "$claude" | grep -q '^1$' || fail "block duplicated"

# 5. After the index changes, --check reports block hosts stale; deliver updates only the block.
ok L --today 2026-10-16 describe git --read-when "committing or pushing"   # changes the index, delivers nothing
deny_msg "check passed with a stale block" "stale: agy, codex;" L deliver --check
echo "- A line the user added after lore." >> "$codex"
ok L deliver
diff <(between "$codex") "$store/INDEX.md" >/dev/null || fail "codex block not refreshed"
tail -1 "$codex" | grep -q 'A line the user added after lore' || fail "text after the block was lost"
ok L deliver --check

# 6. --host limits the run.
ok L deliver --host claude --remove
grep -q '^claude: removed from' "$log" || fail "--host claude --remove did not remove"
grep -q 'cmd:' "$log" && fail "--host claude touched cmd"
cmp -s "$claude" "$tmp/claude.orig" || fail "removing the block did not restore CLAUDE.md exactly"
deny_msg "unknown host accepted" "no host adapter for: zed" L deliver --host zed

# 7. Broken markers are refused, not guessed at.
printf 'x\n<!-- lore:index start -->\nhalf a block\n' > "$cmdf"
deny_msg "broken markers accepted" "markers in this file are broken" L deliver --host cmd

# 8. Codex's 32 KiB cap is enforced before writing.
head -c 33000 /dev/zero | tr '\0' 'a' > "$codex"
cp "$codex" "$tmp/codex.big"
deny_msg "over-cap codex file written" "over its 32768-byte cap" L deliver --host codex
cmp -s "$codex" "$tmp/codex.big" || fail "an over-cap delivery changed the file"

echo "test-deliver: all checks passed"
