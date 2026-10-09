#!/usr/bin/env bash
# Claude discovery links, exercised only in temporary homes. Never touches the real ~/.agents
# or ~/.claude.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
log="$tmp/log"
fail() { echo "FAIL: $*" >&2; cat "$log" >&2; exit 1; }
install() {
  "$repo_root/bootstrap.sh" install --source "$repo_root" --home "$1" "${@:2}" >"$log" 2>&1 || fail "install $1 ${*:2}"
}
check() {
  "$repo_root/bootstrap.sh" check --source "$repo_root" --home "$1" "${@:2}" >"$log" 2>&1
}

# 1. a fresh install creates the link, and it resolves; check is current.
home="$tmp/fresh"
install "$home"
link="$home/.claude/skills/lore"
test -L "$link" || fail "fresh lore link missing"
[[ "$(readlink "$link")" == "../../.agents/skills/lore" ]] || fail "wrong lore link target"
test -f "$link/SKILL.md" || fail "lore link does not resolve"
test -f "$link/scripts/lore-store.sh" || fail "lore link does not resolve the store script"
check "$home" || fail "fresh links should check current"
grep -q 'Claude skill link already current: lore' "$log" || fail "fresh link not reported current"

# 2. a correct link keeps its inode and mtime, even on a forced reinstall.
python3 -I -c 'import os,sys; s=os.lstat(sys.argv[1]); print(s.st_ino,s.st_mtime_ns)' "$link" > "$tmp/before"
install "$home" --force
python3 -I -c 'import os,sys; s=os.lstat(sys.argv[1]); print(s.st_ino,s.st_mtime_ns)' "$link" > "$tmp/after"
cmp -s "$tmp/before" "$tmp/after" || fail "correct link was recreated"
grep -q 'Claude skill link already current:' "$log" || fail "correct link not reported"

# 3. check detects a missing link while the installed skill itself is current.
unlink "$link"
if check "$home"; then fail "missing link should fail check"; fi
grep -q 'Claude skill link missing: lore' "$log" || fail "missing link not reported"
check "$home" --no-claude-link || fail "opt-out check should ignore a missing link"

# 4. anything but a correct link at the path is kept and reported, never replaced, even with --force.
for kind in file directory foreign-link dangling-link; do
  home="$tmp/$kind"
  mkdir -p "$home/.claude/skills" "$home/other"
  echo keep > "$home/other/marker"
  link="$home/.claude/skills/lore"
  case "$kind" in
    file) echo keep > "$link" ;;
    directory) mkdir "$link"; echo keep > "$link/marker" ;;
    foreign-link) ln -s "$home/other" "$link" ;;
    dangling-link) ln -s "$home/absent" "$link" ;;
  esac
  install "$home" --force
  grep -q 'Kept your existing Claude skill path:' "$log" || fail "$kind not reported"
  case "$kind" in
    file) [[ "$(cat "$link")" == keep ]] || fail "foreign file changed" ;;
    directory) [[ "$(cat "$link/marker")" == keep ]] || fail "foreign directory changed" ;;
    foreign-link) [[ "$(readlink "$link")" == "$home/other" ]] || fail "foreign link changed" ;;
    dangling-link) [[ "$(readlink "$link")" == "$home/absent" ]] || fail "dangling link changed" ;;
  esac
  if check "$home"; then fail "$kind should fail check"; fi
  grep -q 'Claude skill link differs: lore' "$log" || fail "$kind check not reported"
done

# 5. --no-claude-link creates neither link.
home="$tmp/opt-out"
install "$home" --no-claude-link
test ! -e "$home/.claude/skills" || fail "opt-out created the skill link"
test ! -e "$home/.claude/commands/lore" || fail "opt-out created the commands link"
check "$home" --no-claude-link || fail "opt-out check"

echo "skill-link tests: pass"
