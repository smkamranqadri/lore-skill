#!/usr/bin/env bash
# lore setup tests: the one command a new user runs, and its removal. Temporary HOME.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"; mkdir -p "$HOME/.claude" "$HOME/.codex"
unset LORE_STORE 2>/dev/null || true
log="$tmp/log"; lore="$HOME/.agents/skills/lore/scripts/lore.py"

fail() { echo "FAIL: $*" >&2; echo "--- last output ---" >&2; cat "$log" >&2 || true; exit 1; }
ok()   { "$@" >"$log" 2>&1 || fail "$* exited non-zero"; }
deny_msg() {
  local d="$1" want="$2"; shift 2
  if "$@" >"$log" 2>&1; then fail "$d"; fi
  grep -q -- "$want" "$log" || fail "$d (wanted '$want')"
}

echo '{"model":"opus"}' > "$HOME/.claude/settings.json"
cp "$HOME/.claude/settings.json" "$tmp/settings.orig"

# 1. Install without --setup names the next step and changes no agent file.
ok "$repo_root/bootstrap.sh" install --source "$repo_root" --home "$HOME"
grep -q 'lore.py setup' "$log" || fail "install did not name the setup step"
[[ -e "$HOME/.claude/CLAUDE.md" || -d "$HOME/.agents/memory" ]] && fail "install alone touched agent files or the store"

# 2. A dry run lists every file and changes nothing; without a terminal it refuses to act.
ok python3 "$lore" setup --dry-run
for want in "memory store" "claude .*CLAUDE.md \(new\)" "claude .*settings.json" "codex .*AGENTS.md \(new\)" "codex .*hooks.json \(new\)"; do
  grep -Eq "$want" "$log" || fail "dry run does not list: $want"
done
grep -q 'cmd \|agy ' "$log" && fail "dry run listed an agent that is not installed"
[[ -d "$HOME/.agents/memory" ]] && fail "a dry run created the store"
deny_msg "setup acted without a terminal or --yes" "run again with --yes" python3 "$lore" setup </dev/null

# 3. setup --yes: store, index in each global file, hooks; existing files backed up first.
ok python3 "$lore" setup --yes
[[ -f "$HOME/.agents/memory/INDEX.md" ]] || fail "setup did not create the store"
grep -q 'lore:index start' "$HOME/.claude/CLAUDE.md" "$HOME/.codex/AGENTS.md" || fail "setup did not deliver the index"
grep -q 'lore-hook.sh' "$HOME/.claude/settings.json" || fail "setup did not install the Claude hooks"
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(d.get('model')!='opus')" "$HOME/.claude/settings.json" \
  || fail "setup lost an existing setting"
bk="$(ls -d "$HOME"/.agents/lore-backup-* | head -1)"
cmp -s "$bk/.claude/settings.json" "$tmp/settings.orig" || fail "the backup is not the original settings file"
grep -q 'trust lore' "$log" || fail "setup did not mention the Codex trust step"

# 4. setup --remove takes lore out of every agent and keeps the memory.
ok python3 "$lore" setup --remove --yes
grep -q 'lore' "$HOME/.claude/CLAUDE.md" "$HOME/.codex/AGENTS.md" && fail "remove left a lore block"
grep -q 'lore-hook.sh' "$HOME/.claude/settings.json" && fail "remove left the hooks"
[[ -f "$HOME/.agents/memory/INDEX.md" ]] || fail "remove deleted the memory"

# 5. bootstrap --setup does install and setup in one go.
home2="$tmp/home2"; mkdir -p "$home2/.claude"
HOME="$home2" "$repo_root/bootstrap.sh" install --source "$repo_root" --home "$home2" --setup >"$log" 2>&1 || fail "bootstrap --setup failed"
grep -q 'lore:index start' "$home2/.claude/CLAUDE.md" || fail "bootstrap --setup did not set lore up"
[[ -f "$home2/.agents/memory/INDEX.md" ]] || fail "bootstrap --setup did not create the store"

echo "test-setup: all checks passed"
