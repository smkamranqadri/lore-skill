#!/usr/bin/env bash
# lore 2.0 P2 tests: `lore inbox list|accept|reject <id>`. A layout proposal (what a layout
# conflict with the hub leaves in .git/lore/proposals) is listed, accepted from the shell as its own
# commit that is pushed, or rejected leaving the store untouched. No model, no network.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap '[[ -n "${KEEP:-}" ]] || rm -rf "$tmp"' EXIT
export HOME="$tmp/home"; mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset LORE_STORE LORE_STORE2 LORE_GH_CMD LORE_GIT_TIMEOUT LORE_LOREMASTER_CMD 2>/dev/null || true
log="$tmp/log"; S="$tmp/store"; HUB="$tmp/hub.git"
fail() { echo "FAIL: $*" >&2; echo "--- last output ---" >&2; cat "$log" >&2 || true; exit 1; }
ok()   { "$@" >"$log" 2>&1 || fail "$* exited non-zero"; }
has()  { grep -qxF -- "$1" "$log" || fail "${2:-output lacks the line: $1}"; }
hasre() { grep -qE -- "$1" "$log" || fail "${2:-output lacks a line matching: $1}"; }

cp -r "$repo_root/skills/lore" "$tmp/skill"
scripts="$tmp/skill/scripts"
lore="$scripts/lore.py"
L() { python3 "$lore" --store2 "$S" "$@"; }
propose() {   # leave a layout proposal exactly as a layout conflict with the hub does
  (cd "$scripts" && python3 -c "
import sys, lore; sys.modules.setdefault('lore', lore); import lore_store
lore_store.save_proposal(sys.argv[1], sys.argv[2])" "$S" "$1")
}
layout_with() { printf '{"top": ["profile.md", "how-i-work/", "preferences/", "safety/", "stack/", "gotchas/", "%s"]}\n' "$1"; }
first_id() { awk -v k="$1" '$2 == k { print $1; exit }' "$log"; }

git init -q --bare -b main "$HUB"
ok L --today 2026-10-01 store init
ok L hub set "$HUB"

# 1. an empty inbox says so.
ok L inbox list
has "inbox: empty"

# 2. a layout proposal is listed with its id and kind; accept lands it as its own commit and pushes.
layout_with "tools/" > "$tmp/layout.new"
propose "$(cat "$tmp/layout.new")"
ok L inbox list
hasre '^[^ ]+  layout  .*tools/'
id="$(first_id layout)"; [[ -n "$id" ]] || fail "no layout item listed"
head0="$(git -C "$S" rev-parse HEAD)"
ok L inbox accept "$id"
hasre "^accepted $id: committed [0-9a-f]+$"
has "hub: pushed to $HUB"
[[ "$(git -C "$S" rev-list --count "$head0"..HEAD)" == 1 ]] || fail "accept did not land as exactly one commit"
[[ "$(git -C "$S" diff --name-only "$head0" HEAD)" == $'.lore/layout.json\ntools/.gitkeep' ]] || fail "the accept commit touched other than the layout and the new folder"
[[ "$(git -C "$S" log -1 --format=%s)" == "inbox: accept layout $id: "* ]] || fail "the accept commit subject is wrong"
grep -qF '"tools/"' "$S/.lore/layout.json" || fail "the layout does not hold the accepted folder"
[[ "$(git -C "$S" rev-parse HEAD)" == "$(git -C "$HUB" rev-parse main)" ]] || fail "the accept commit was not pushed"
[[ -z "$(git -C "$S" status --porcelain)" ]] || fail "accept left the tree dirty"
ok L inbox list
has "inbox: empty"

# 3. reject drops the item and leaves the store byte for byte as it was.
layout_with "scratch/" > "$tmp/layout.other"
propose "$(cat "$tmp/layout.other")"
ok L inbox list
id="$(first_id layout)"; [[ -n "$id" ]] || fail "the second proposal is not listed"
head1="$(git -C "$S" rev-parse HEAD)"; sum1="$(sha1sum < "$S/.lore/layout.json")"
ok L inbox reject "$id"
has "rejected $id"
[[ "$(git -C "$S" rev-parse HEAD)" == "$head1" && "$(sha1sum < "$S/.lore/layout.json")" == "$sum1" ]] || fail "reject changed the store"
ok L inbox list
has "inbox: empty"

# 3b. accept holds the store lock: with the lock taken elsewhere, accept waits instead of writing.
layout_with "locked/" > "$tmp/layout.locked"
propose "$(cat "$tmp/layout.locked")"
ok L inbox list
id="$(first_id layout)"; head2="$(git -C "$S" rev-parse HEAD)"
flock "$S/.git/lore/run.lock" sleep 6 &
holder=$!; sleep 1
if timeout 3 python3 "$lore" --store2 "$S" inbox accept "$id" >"$log" 2>&1; then fail "accept ran while the store lock was held"; fi
[[ "$(git -C "$S" rev-parse HEAD)" == "$head2" ]] || fail "accept wrote while the store lock was held"
wait "$holder" || true
# 3c. a failed push after an accept is an error, and the commit stays local.
mv "$HUB" "$HUB.gone"
if L inbox accept "$id" >"$log" 2>&1; then fail "accept passed with the hub unreachable"; fi
hasre '^hub: push FAILED '
has "Error: committed locally; the push failed"
[[ "$(git -C "$S" rev-list --count "$head2"..HEAD)" == 1 ]] || fail "the accept commit is missing after a failed push"
mv "$HUB.gone" "$HUB"
ok L store run --force --trigger test:catchup
[[ "$(git -C "$S" rev-parse HEAD)" == "$(git -C "$HUB" rev-parse main)" ]] || fail "the held-back commit did not reach the hub"
head1="$(git -C "$S" rev-parse HEAD)"

# 3d. list takes the store lock too (C's functions expect the caller to hold it): it waits behind a writer.
flock "$S/.git/lore/run.lock" sleep 6 &
holder=$!; sleep 1
rc=0; timeout 3 python3 "$lore" --store2 "$S" inbox list >"$log" 2>&1 || rc=$?
[[ "$rc" == 124 ]] || fail "inbox list returned (exit $rc) while the store lock was held"
wait "$holder" || true
ok L inbox list
has "inbox: empty"
# 3e. rejecting a hand edit is a commit; it is pushed, and a failed push is an error (F4).
printf '# Fictional\n\n- Prefer copper fictional guides.\n' > "$S/preferences/fictional.md"
ok L store commit
ok L inbox list
hasre '^h-[0-9a-f]+  hand-edit  preferences/fictional.md '
id="$(first_id hand-edit)"; head3="$(git -C "$S" rev-parse HEAD)"
ok L inbox reject "$id"
has "rejected $id"
has "hub: pushed to $HUB"
[[ "$(git -C "$S" rev-parse HEAD)" != "$head3" ]] || fail "rejecting a hand edit made no commit"
[[ "$(git -C "$S" rev-parse HEAD)" == "$(git -C "$HUB" rev-parse main)" ]] || fail "the reject commit was not pushed"
printf '# Second\n\n- Prefer brass fictional guides.\n' > "$S/preferences/second.md"
ok L store commit
ok L inbox list
id="$(first_id hand-edit)"; head4="$(git -C "$S" rev-parse HEAD)"
mv "$HUB" "$HUB.gone"
if L inbox reject "$id" >"$log" 2>&1; then fail "reject passed with the hub unreachable"; fi
hasre '^hub: push FAILED '
has "Error: committed locally; the push failed"
[[ "$(git -C "$S" rev-list --count "$head4"..HEAD)" == 1 ]] || fail "the reject commit is missing after a failed push"
mv "$HUB.gone" "$HUB"
ok L store run --force --trigger test:catchup2
head1="$(git -C "$S" rev-parse HEAD)"

# 4. a missing or unknown id is an error, and nothing changes.
if L inbox accept >"$log" 2>&1; then fail "accept without an id succeeded"; fi
has "Error: usage: lore inbox accept <id>"
if L inbox reject >"$log" 2>&1; then fail "reject without an id succeeded"; fi
has "Error: usage: lore inbox reject <id>"
if L inbox accept no-such-item >"$log" 2>&1; then fail "an unknown id was accepted"; fi
hasre '^Error: '
[[ "$(git -C "$S" rev-parse HEAD)" == "$head1" ]] || fail "a refused accept changed the store"

echo "test-inbox: all checks passed"
