#!/usr/bin/env bash
# lore v1 sync tests: two machines and a hub, simulated with folders. Temporary HOME.
# The agent's part of commands/sync.md (moving files to and from Tartib) is played by `sync_via`.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
lore="$repo_root/skills/lore/scripts/lore.py"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"; mkdir -p "$HOME"
unset LORE_STORE 2>/dev/null || true
log="$tmp/log"
A="$tmp/mac"; B="$tmp/linux"; hub="$tmp/hub"; mkdir -p "$hub"
export SCRIPTS="$repo_root/skills/lore/scripts"

fail() { echo "FAIL: $*" >&2; echo "--- last output ---" >&2; cat "$log" >&2 || true; exit 1; }
ok()   { "$@" >"$log" 2>&1 || fail "$* exited non-zero"; }
LA() { python3 "$lore" --store "$A" "$@"; }
LB() { python3 "$lore" --store "$B" "$@"; }
entries() {   # every entry, normalised, in one sorted list: what "the same memory" means
  for f in "$1"/*.md; do
    case "$(basename "$f")" in INDEX.md|profile.md|profile.hub.md) continue;; esac
    { grep -h '^- ' "$f" || true; } | sed -E 's/ (promoted|decayed)=[^ ]*//g; s/ cat=[^ ]*//'
  done | sort
}
# The agent's part: pull every hub file, merge, export, push what changed, record the sync.
sync_via() {
  local store="$1" day="$2" pull push
  pull="$(mktemp -d)"; push="$(mktemp -d)"
  cp -a "$hub/." "$pull/" 2>/dev/null || true
  if [[ -n "$(ls -A "$pull")" ]]; then python3 "$lore" --store "$store" --today "$day" merge --remote "$pull" >"$log" 2>&1 || fail "merge failed"; fi
  python3 "$lore" --store "$store" --today "$day" export --out "$push" >"$log" 2>&1 || fail "export failed"
  python3 "$lore" --store "$store" --today "$day" sync-status > "$tmp/status.json" || fail "sync-status failed"
  for f in $(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["push"]))' "$tmp/status.json"); do
    [[ -f "$push/$f" ]] && cp "$push/$f" "$hub/$f"
  done
  echo '{}' > "$tmp/seen.json"
  python3 "$lore" --store "$store" --today "$day" sync-done --pushed "$push" --remote-seen "$tmp/seen.json" >"$log" 2>&1 || fail "sync-done failed"
}

for s in "$A" "$B"; do ok python3 "$lore" --store "$s" --today 2026-10-01 init; printf 'hub: tartib\nhub_space: agent-memory\n' >> "$s/config"; done

# 1. Different histories on each machine.
ok LA --today 2026-10-01 add --cat git --text "Never run git reset in the main checkout" --explicit
ok LA --today 2026-10-02 add --cat tools --text "Use pnpm, not npm, in node projects"
ok LB --today 2026-10-01 add --cat ui --text "Prefer toggle switches over checkboxes" --explicit
ok LB --today 2026-10-03 add --cat tools --text "Use pnpm, not npm, in node projects"
ok LB --today 2026-10-03 add --cat tools --text "Use pnpm, not npm, in node projects"
ok LB --today 2026-10-01 add --cat git --text "Never run git reset in the main checkout"   # a candidate here, confirmed on A
for s in A B; do ok "L$s" --today 2026-10-03 maintain; done

# 2. The index asks for a sync only when one is due.
grep -q 'Memory sync is due' "$A/INDEX.md" || fail "a never-synced store does not ask for a sync"

# 3. Merging each other's exports, in either order, gives the same memory (order independent).
ok LA export --out "$tmp/exA"; ok LB export --out "$tmp/exB"
cp -a "$A" "$tmp/A1"; cp -a "$B" "$tmp/B1"
ok python3 "$lore" --store "$tmp/A1" --today 2026-10-04 merge --remote "$tmp/exB"
ok python3 "$lore" --store "$tmp/B1" --today 2026-10-04 merge --remote "$tmp/exA"
diff <(entries "$tmp/A1") <(entries "$tmp/B1") > "$tmp/d" || { cat "$tmp/d" > "$log"; fail "the two orders of merge disagree"; }
grep -q 'Use pnpm, not npm, in node projects\. Confidence: 0\.60 .*days=2 n=2' "$tmp/A1/tools.md" \
  || fail "merge did not combine the two copies (highest confidence and counts, not their sum)"
grep 'Never run git reset' "$tmp/B1/git.md" | grep -q 'promoted=2026-10-01' \
  || fail "the confirmed copy did not win: the rule was promoted again instead of keeping its date"
# Idempotent: merging the same export again changes nothing.
entries "$tmp/A1" > "$tmp/once"
ok python3 "$lore" --store "$tmp/A1" --today 2026-10-04 merge --remote "$tmp/exB"
diff "$tmp/once" <(entries "$tmp/A1") >/dev/null || fail "a second merge of the same export changed the memory"

# 4. Through the hub: Mac syncs, Linux syncs, Mac syncs again; both end equal.
sync_via "$A" 2026-10-04; sync_via "$B" 2026-10-04; sync_via "$A" 2026-10-04
diff <(entries "$A") <(entries "$B") > "$tmp/d" || { cat "$tmp/d" > "$log"; fail "machines differ after syncing through the hub"; }
grep -q 'Memory sync is due' "$A/INDEX.md" && fail "the index still asks for a sync right after one"
python3 "$lore" --store "$A" --today 2026-10-04 sync-status | grep -q '"push": \[\]' || fail "nothing should be left to push"

# 5. A removal travels as a tombstone instead of coming back.
gid="$(LA list --cat git | cut -f1)"
ok LA --today 2026-10-05 drop "$gid"
sync_via "$A" 2026-10-05; sync_via "$B" 2026-10-05
grep -q 'git reset' "$B/git.md" && fail "a rule dropped on one machine came back on the other"
grep -q "^$gid	" "$B/blocklist" || fail "the blocklist did not travel"
ok LB --today 2026-10-06 add --cat ui --text "Short placeholder rule for the lock" --explicit
ok LB --today 2026-10-06 maintain
sync_via "$B" 2026-10-06; sync_via "$A" 2026-10-06   # both machines have it now
grep -q 'placeholder' "$A/ui.md" || fail "setup: the placeholder did not reach the other machine"
python3 - "$B" <<'PY'   # a removal under the lock, as maintain or review makes it
import sys, os
sys.path.insert(0, os.environ["SCRIPTS"]); import lore
s = lore.Store(sys.argv[1], lore.dt.date(2026, 10, 6))
with s.locked():
    t, rw, es = s.read_category("ui"); s.write_category("ui", t, rw, [e for e in es if "placeholder" not in e.text])
PY
grep -q "	2026-10-06$" "$B/tombstones" || fail "a removal under the lock left no tombstone"
sync_via "$B" 2026-10-06; sync_via "$A" 2026-10-06
grep -q 'placeholder' "$A/ui.md" "$A/candidates.md" && fail "a tombstoned rule survived the sync"

# 6. Seen again after its tombstone, a rule comes back (the tombstone is older than the sighting).
ok LA --today 2026-10-08 add --cat ui --text "Short placeholder rule for the lock" --explicit
sync_via "$A" 2026-10-08; sync_via "$B" 2026-10-08
grep -q 'placeholder' "$B/candidates.md" "$B/ui.md" || fail "a rule seen again after its tombstone did not come back"

# 7. The pushed hashes are recorded, not the live ones: a change made during a sync is pushed later.
pull="$(mktemp -d)"; push="$(mktemp -d)"
ok LA --today 2026-10-09 export --out "$push"
ok LA --today 2026-10-09 add --cat git --text "Never force push to main"   # lands mid-sync
echo '{}' > "$tmp/seen.json"
ok LA --today 2026-10-09 sync-done --pushed "$push" --remote-seen "$tmp/seen.json"
LA --today 2026-10-09 sync-status | grep -q '"candidates.md"' || fail "a change made during a sync was recorded as pushed"

# 8. profile.md: the side that changed wins; if both changed, the hub copy is kept beside it.
echo "- Works in UTC." >> "$B/profile.md"
sync_via "$B" 2026-10-10; sync_via "$A" 2026-10-10
grep -q 'Works in UTC' "$A/profile.md" || fail "a profile change on one machine did not travel"
echo "- Mac edit." >> "$A/profile.md"; echo "- Linux edit." >> "$B/profile.md"
sync_via "$A" 2026-10-11; sync_via "$B" 2026-10-11
grep -q 'Linux edit' "$B/profile.md" || fail "a local profile edit was overwritten"
grep -q 'Mac edit' "$B/profile.hub.md" || fail "the hub's profile was not kept beside the local one"

# 9. Without a hub in the config, nothing asks for a sync.
ok python3 "$lore" --store "$tmp/solo" --today 2026-10-11 init
grep -q 'Memory sync is due' "$tmp/solo/INDEX.md" && fail "a store with no hub asks for a sync"

echo "test-sync: all checks passed"
