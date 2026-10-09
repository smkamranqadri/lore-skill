#!/usr/bin/env bash
# Installer tests in a temporary HOME. Never touches the real ~/.agents or ~/.claude.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
home="$tmp/home"; mkdir -p "$home"
log="$tmp/log"

fail() { echo "FAIL: $*" >&2; echo "--- last output ---" >&2; cat "$log" >&2 || true; exit 1; }

# 1. install
"$repo_root/bootstrap.sh" install --source "$repo_root" --home "$home" >"$log" 2>&1 || fail "install exited non-zero"
grep -q "Installed lore " "$log" || fail "install did not report lore"
test -f "$home/.agents/skills/lore/SKILL.md" || fail "lore SKILL.md missing"
test -f "$home/.agents/skills/lore/scripts/lore-store.sh" || fail "store script missing"
test -f "$home/.agents/skills/lore/backends/files.md" || fail "files backend missing"
test -L "$home/.claude/commands/lore" || fail "commands link missing"
test -f "$home/.claude/commands/lore/load.md" || fail "commands link does not resolve"
test -f "$home/.claude/commands/lore/backend.md" || fail "commands link does not resolve the backend command"
test ! -e "$home/.agents/skills/lore/tests" || fail "tests must not be installed"

# 2. byte-identical to source
diff -r --exclude=__pycache__ --exclude=.DS_Store "$repo_root/skills/lore" "$home/.agents/skills/lore" >"$log" 2>&1 \
  || fail "installed lore differs from source"

# 3. a second install refuses without --force
if "$repo_root/bootstrap.sh" install --source "$repo_root" --home "$home" >"$log" 2>&1; then fail "second install should refuse"; fi
grep -q "use --force" "$log" || fail "refusal message missing"

# 4. check says current
"$repo_root/bootstrap.sh" check --source "$repo_root" --home "$home" >"$log" 2>&1 || fail "check should exit 0 when current"
grep -q "Already current: lore" "$log" || fail "check did not say lore current"

# 5. drift is detected and update restores it, keeping a backup
echo "# drift" >> "$home/.agents/skills/lore/SKILL.md"
if "$repo_root/bootstrap.sh" check --source "$repo_root" --home "$home" >"$log" 2>&1; then fail "check should exit 1 on drift"; fi
grep -q "Update available: lore" "$log" || fail "drift not reported"
"$repo_root/bootstrap.sh" update --source "$repo_root" --home "$home" >"$log" 2>&1 || fail "update failed"
grep -q "Backed up previous lore" "$log" || fail "update did not back up"
grep -q "Installed lore " "$log" || fail "update did not reinstall lore"
ls "$home/.agents/"lore-backup-*.tgz >/dev/null 2>&1 || fail "backup tgz missing"
diff -r --exclude=__pycache__ "$repo_root/skills/lore" "$home/.agents/skills/lore" >"$log" 2>&1 || fail "update did not restore lore"
"$repo_root/bootstrap.sh" check --source "$repo_root" --home "$home" >"$log" 2>&1 || fail "check should be current after update"

# 6. --no-claude-link installs the skill but leaves no link
home2="$tmp/home2"; mkdir -p "$home2"
"$repo_root/bootstrap.sh" install --source "$repo_root" --home "$home2" --no-claude-link >"$log" 2>&1 || fail "no-claude-link install failed"
test -f "$home2/.agents/skills/lore/SKILL.md" || fail "lore missing in home2"
test ! -e "$home2/.claude/commands/lore" || fail "no-claude-link: link should not exist"

# 7. a pre-existing non-symlink commands dir is refused, not overwritten
home3="$tmp/home3"; mkdir -p "$home3/.claude/commands/lore"
echo keep > "$home3/.claude/commands/lore/mine.md"
if "$repo_root/bootstrap.sh" install --source "$repo_root" --home "$home3" >"$log" 2>&1; then fail "should refuse to replace a real directory"; fi
grep -q "exists and is not a symlink" "$log" || fail "did not name the non-symlink commands path"
test -f "$home3/.claude/commands/lore/mine.md" || fail "real directory was destroyed"

# 8. a source without skills/, and no source at all, are refused
home4="$tmp/home4"; mkdir -p "$home4"
if "$repo_root/bootstrap.sh" install --source "$tmp" --home "$home4" >"$log" 2>&1; then fail "install should refuse a non-repo source"; fi
grep -q "not a lore-skill repo root: $tmp" "$log" || fail "did not name the bad source"
if "$repo_root/bootstrap.sh" install --home "$home4" >"$log" 2>&1; then fail "install should refuse with no source"; fi
grep -q "missing --repo" "$log" || fail "did not ask for a source"

# 8b. a skills/ entry with no SKILL.md is refused
noskill="$tmp/noskill"; mkdir -p "$noskill/skills/empty"
cp -R "$repo_root/scripts" "$noskill/"
if "$repo_root/bootstrap.sh" install --source "$noskill" --home "$home4" >"$log" 2>&1; then fail "install should refuse a skills/ entry with no SKILL.md"; fi
grep -q "skills/empty has no SKILL.md" "$log" || fail "did not name the skill without a SKILL.md"

# 8c. no HOME and no --home is refused
if env -u HOME "$repo_root/bootstrap.sh" check --source "$repo_root" >"$log" 2>&1; then fail "check should refuse when HOME is unset and no --home is given"; fi
grep -q "missing --home" "$log" || fail "did not name the missing home"

# 8d. install-skill.sh used directly also refuses a non-repo source and a missing source
if "$repo_root/scripts/install-skill.sh" --source "$tmp" --home "$home4" >"$log" 2>&1; then fail "install-skill should refuse a non-repo source"; fi
grep -q "not a lore-skill repo root (no skills/)" "$log" || fail "install-skill did not name the bad source"
if LORE_SKILL_SOURCE= "$repo_root/scripts/install-skill.sh" --home "$home4" >"$log" 2>&1; then fail "install-skill should refuse with no source"; fi
grep -q "missing --source" "$log" || fail "install-skill did not ask for a source"

# 9. frontmatter without metadata.version is refused
bad="$tmp/badsrc"; mkdir -p "$bad"
cp -R "$repo_root/skills" "$repo_root/scripts" "$bad/"
printf '%s\n' '---' 'name: lore' 'description: x' '---' '' '# lore' > "$bad/skills/lore/SKILL.md"
if "$repo_root/bootstrap.sh" install --source "$bad" --home "$home4" >"$log" 2>&1; then fail "install should refuse a SKILL.md with no version"; fi
grep -q "missing metadata.version" "$log" || fail "did not name the missing version"

echo "install tests: pass"
