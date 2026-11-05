#!/usr/bin/env bash
# lore 2.0 hub tests: attaching a hub (test push, public refusal through a fake gh), auto-push,
# an offline hub retried and reported, two machines on one bare repo ending equal, the layout
# conflict, and the session-end step chained by the real hook. No network: every hub is a local
# bare repo, GitHub URLs are rewritten to local paths, gh is a fake. Temporary HOME.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
scripts="$repo_root/skills/lore/scripts"
lore="$scripts/lore.py"
tmp="$(mktemp -d)"
trap '[[ -n "${KEEP:-}" ]] || rm -rf "$tmp"' EXIT
export HOME="$tmp/home"; mkdir -p "$HOME"
# GitHub URLs resolve to local bare repos under $tmp/gh, so nothing can reach the network.
printf '[url "%s/gh/"]\n\tinsteadOf = https://github.com/\n' "$tmp" > "$tmp/gitconfig"
export GIT_CONFIG_GLOBAL="$tmp/gitconfig" GIT_CONFIG_NOSYSTEM=1
unset LORE_STORE LORE_STORE2 LORE_GH_CMD LORE_GIT_TIMEOUT LORE_SYNC_CMD 2>/dev/null || true
# Canon (P3) runs in `check --live` and at session end: a fake that fixes nothing keeps every real
# agent CLI out of reach (XDG_DATA_HOME could point lore at the real mise installs).
unset XDG_DATA_HOME MISE_DATA_DIR 2>/dev/null || true
cat > "$tmp/canon-none.sh" <<'FAKE'
#!/bin/sh
echo '{"ops": [], "answer": "nothing to fix"}'
FAKE
chmod +x "$tmp/canon-none.sh"; export LORE_CANON_CMD="$tmp/canon-none.sh"
log="$tmp/log"
fail() { echo "FAIL: $*" >&2; echo "--- last output ---" >&2; cat "$log" >&2 || true; exit 1; }
ok()   { "$@" >"$log" 2>&1 || fail "$* exited non-zero"; }
has() { grep -qxF -- "$1" "$log" || fail "${2:-output lacks the line: $1}"; }
A="$tmp/a"; B="$tmp/b"; HUB="$tmp/hub.git"
LA() { python3 "$lore" --store2 "$A" "$@"; }
LB() { python3 "$lore" --store2 "$B" "$@"; }
remote_url() { git -C "$1" config --get remote.hub.url || true; }

# The fake gh: visibility from FAKE_GH_VIS; create makes a local bare repo behind the GitHub URL.
mkdir -p "$tmp/bin" "$tmp/gh/fixture-owner"
cat > "$tmp/bin/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$tmp/gh.log"
case "\$1 \$2" in
  "repo view")
    if [[ "\$5" == url,sshUrl,visibility ]]; then
      echo '{"url":"https://github.com/fixture-owner/'"\${3#*/}"'","sshUrl":"git@github.com:fixture-owner/'"\${3#*/}"'.git","visibility":"PRIVATE"}'
    else echo "{\"visibility\":\"\${FAKE_GH_VIS:-PRIVATE}\"}"; fi ;;
  "repo create") git init -q --bare -b main "$tmp/gh/fixture-owner/\${3#*/}.git" ;;
  "config get") echo https ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/gh"

# 1. A fresh store without a hub works on local git alone.
ok LA --today 2026-10-01 store init
ok LA hub status
has "hub: none (local git only)"
printf -- '- Run the real command before claiming done.\n' >> "$A/core.md"
ok LA store commit
has "hub: none (local git only)"
[[ "$(git -C "$A" rev-list --count HEAD)" == 2 ]] || fail "no-hub commit"

# 2. hub set refuses a repository gh reports as public, before any push; nothing is changed.
export LORE_GH_CMD="$tmp/bin/gh"
git init -q --bare -b main "$tmp/gh/fixture-owner/open-memory.git"
if FAKE_GH_VIS=PUBLIC LA hub set https://github.com/fixture-owner/open-memory.git >"$log" 2>&1; then fail "a public repo was accepted"; fi
has "Error: refused: https://github.com/fixture-owner/open-memory.git is a public repository; the hub must be private"
[[ -z "$(remote_url "$A")" ]] || fail "a refused hub was left configured"
[[ -z "$(git -C "$tmp/gh/fixture-owner/open-memory.git" for-each-ref)" ]] || fail "something was pushed to a public repo"
grep -qxF "repo view fixture-owner/open-memory --json visibility" "$tmp/gh.log" || fail "gh was not asked for the visibility"

# 3. Without gh, visibility is not checked and lore says so; a failing test push sets nothing
# and loses nothing (a hand edit made before it is committed, not rolled back).
printf -- '- Pending hand edit before the hub.\n' >> "$A/core.md"
if LORE_GH_CMD= PATH="/usr/bin:/bin" python3 "$lore" --store2 "$A" hub set "$tmp/missing.git" >"$log" 2>&1; then
  fail "a hub whose test push fails was accepted"
fi
has "warning: not a GitHub URL, so its visibility was not checked; make sure it is private"
grep -qE "^Error: hub not set: the test push failed: git fetch failed: " "$log" || fail "no clear test-push error"
[[ -z "$(remote_url "$A")" ]] || fail "a hub with a failed test push stayed configured"
grep -qxF -- '- Pending hand edit before the hub.' "$A/core.md" || fail "a failed hub set lost a hand edit"
[[ "$(git -C "$A" log -1 --format=%s)" == "edit core.md" ]] || fail "the hand edit was not committed before the test push"
[[ -x /usr/bin/gh || -x /bin/gh ]] || {
  git init -q --bare -b main "$tmp/gh/fixture-owner/plain.git"
  LORE_GH_CMD= PATH="/usr/bin:/bin" python3 "$lore" --store2 "$tmp/c" store init >"$log" 2>&1 || fail "init c"
  LORE_GH_CMD= PATH="/usr/bin:/bin" python3 "$lore" --store2 "$tmp/c" hub set https://github.com/fixture-owner/plain.git >"$log" 2>&1 || fail "hub set without gh"
  has "warning: gh is not installed, so the repository's visibility was not checked; make sure it is private"
}

# 4. hub set on a private repo: the test push sends the whole store; commits then push themselves.
git init -q --bare -b main "$HUB"
ok LA hub set "$HUB"
has "hub set: $HUB (test push ok)"
[[ "$(git -C "$HUB" rev-parse main)" == "$(git -C "$A" rev-parse HEAD)" ]] || fail "the test push did not send the store"
mkdir -p "$A/gotchas"; printf '# Git\n\n- Never force-push a shared branch.\n- Read the diff before committing.\n' > "$A/gotchas/git.md"
ok LA store commit
has "hub: pushed to $HUB"
[[ "$(git -C "$HUB" log -1 --format=%s main)" == "add gotchas/git.md" ]] || fail "a commit was not pushed"
ok LA hub status
has "not pushed: 0 commit(s)"

# 5. hub create: only after a yes (refused without a terminal), private, then set as the hub.
ok LB --today 2026-10-01 store init
if LB hub create </dev/null >"$log" 2>&1; then fail "hub create ran without a yes"; fi
has "Error: not a terminal; run again with --yes to create the repository"
[[ -d "$tmp/gh/fixture-owner/lore-memory.git" ]] && fail "a repo was created without a yes"
ok LB hub create --name fixture-owner/lore-memory --yes
grep -qxF "repo create fixture-owner/lore-memory --private --description lore memory (private)" "$tmp/gh.log" || fail "gh repo create was not private"
has "hub set: https://github.com/fixture-owner/lore-memory.git (test push ok)"
[[ "$(git -C "$tmp/gh/fixture-owner/lore-memory.git" rev-list --count main)" == 1 ]] || fail "hub create did not push"
git -C "$B" remote remove hub; rm -rf "$B"
unset LORE_GH_CMD

# 6. An offline hub: the commit stays local, the push is retried on the next run, and after three
# failed runs in a row hub status and the session-end log say so. A backed-off run waits.
mv "$HUB" "$tmp/hub.off"
printf -- '- Keep replies short.\n' >> "$A/core.md"
if LA store commit >"$log" 2>&1; then fail "an offline push exited zero"; fi
grep -qE '^hub: push FAILED \(git fetch failed: .+\); push failed 1 run\(s\) in a row; retried on the next run$' "$log" || fail "first failure line"
LA store run --trigger test:SessionEnd --force >"$log" 2>&1 || fail "store run failed"
grep -qE ' store-run: hub: push FAILED \(git fetch failed: .+\); push failed 2 run\(s\) in a row; retried on the next run$' "$log" || fail "second failure"
LA store run --trigger test:SessionEnd --force >"$log" 2>&1 || fail "store run failed"
grep -qE ' store-run: hub: push FAILED \(git fetch failed: .+\); push has failed 3 runs in a row; see `lore hub status`$' "$log" || fail "third failure not reported"
LA store run --trigger test:SessionEnd >"$log" 2>&1 || fail "store run failed"
grep -qE ' store-run: hub: push waits, backing off after a failed run \(under 120 min ago\); push has failed 3 runs in a row; see `lore hub status`$' "$log" \
  || fail "no backoff after a failure"
ok LA hub status
has "not pushed: 1 commit(s)"
has 'failing: push has failed 3 runs in a row; see `lore hub status`'
grep -qE '^last error: git fetch failed: ' "$log" || fail "status lacks the last error"
mv "$tmp/hub.off" "$HUB"
LA store run --trigger test:SessionEnd --force >"$log" 2>&1 || fail "store run failed"
grep -qE " store-run: hub: pushed to $HUB$" "$log" || fail "the retry did not push"
[[ "$(git -C "$HUB" rev-parse main)" == "$(git -C "$A" rev-parse HEAD)" ]] || fail "the retried commit is not on the hub"
ok LA hub status
grep -q '^failing:' "$log" && fail "failures still reported after a good push"

# 7. Two machines on one hub. B joins (its own first commit replays onto the hub's history), both
# change the same rule file and the same sidecar (read counts for the same file from each
# machine), each commits and pushes, and after one more run each, both stores are equal.
py() { (cd "$scripts" && python3 -c "import sys, lore; sys.modules.setdefault('lore', lore); import lore_store; $1"); }
ok LB --today 2026-10-02 store init
ok LB hub set "$HUB"
[[ -f "$B/gotchas/git.md" ]] || fail "joining the hub did not bring its files"
printf '# Git\n\n- Never force-push a shared branch.\n- Name branches after the task.\n' > "$A/gotchas/git.md"
printf -- '- Prefer small commits.\n' >> "$B/gotchas/git.md"
py "s = lore_store.Store2('$A'); lore_store.record_reads(s, {'gotchas/git.md': 2, 'profile.md': 1}, s.machine())"
py "s = lore_store.Store2('$B'); lore_store.record_reads(s, {'gotchas/git.md': 5}, s.machine())"
ok LA store commit
has "hub: pushed to $HUB"
ok LB store commit
has "hub: pushed to $HUB"
ok LA store commit
has "nothing to commit"
has "hub: pushed to $HUB"
[[ "$(git -C "$A" rev-parse HEAD)" == "$(git -C "$B" rev-parse HEAD)" ]] || fail "the two stores are on different commits"
diff -r --exclude=.git --exclude=INDEX.md "$A" "$B" >"$log" || fail "the two stores differ"
printf '# Git\n\n- Never force-push a shared branch.\n- Name branches after the task.\n- Prefer small commits.\n' > "$tmp/git.want"
cmp -s "$A/gotchas/git.md" "$tmp/git.want" || { diff "$tmp/git.want" "$A/gotchas/git.md" >"$log" || true; fail "rule files did not merge by line"; }
ma="$(cat "$A/.git/lore/machine")"; mb="$(cat "$B/.git/lore/machine")"
python3 - "$A/.lore/meta/gotchas/git.json" "$ma" "$mb" <<'PY' || fail "read counts from two machines"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["reads"] == {sys.argv[2]: 2, sys.argv[3]: 5}, d["reads"]
assert set(d["last_read"]) == {sys.argv[2], sys.argv[3]}, d["last_read"]
assert sorted(r["text"] for r in d["rules"].values()) == \
    ["Name branches after the task.", "Never force-push a shared branch.", "Prefer small commits."], d["rules"]
PY
grep -q "Read the diff before committing" "$B/gotchas/git.md" "$B/.lore/meta/gotchas/git.json" && fail "a rule removed on one machine came back"

# 8. A layout conflict: the hub's layout is kept, the local one waits as a proposal.
python3 - "$A/.lore/layout.json" projects/ <<'PY'
import json, sys; d = json.load(open(sys.argv[1])); d["top"].append(sys.argv[2]); open(sys.argv[1], "w").write(json.dumps(d, indent=1) + "\n")
PY
python3 - "$B/.lore/layout.json" tools/ <<'PY'
import json, sys; d = json.load(open(sys.argv[1])); d["top"].append(sys.argv[2]); open(sys.argv[1], "w").write(json.dumps(d, indent=1) + "\n")
PY
cp "$A/.lore/layout.json" "$tmp/layout.hub"; cp "$B/.lore/layout.json" "$tmp/layout.local"
ok LA store commit
ok LB store commit
has "hub: pushed to $HUB"
cmp -s "$B/.lore/layout.json" "$tmp/layout.hub" || fail "the hub's layout was not kept"
[[ "$(ls "$B/.git/lore/proposals" | wc -l | tr -d ' ')" == 1 ]] || fail "not exactly one layout proposal"
cmp -s "$B"/.git/lore/proposals/layout-*.json "$tmp/layout.local" || fail "the proposal is not the local layout"
ok LB store status
grep -qxF "layout proposal: $(ls "$B"/.git/lore/proposals/layout-*.json) (the hub's layout was kept)" "$log" || fail "status lacks the proposal"

# 9. Session end: the real hook queues the payload for the 2.0 store and chains the 2.0 step after
# the 1.x harvest and sync-run. No 2.0 store: a logged skip. With one: the session's read counts
# from the real transcript reader (lore_reads), one commit, a push.
S1="$tmp/home/.agents/memory"
python3 "$lore" --store "$S1" init >"$log" 2>&1 || fail "1.x init"
export LORE_STORE="$S1" LORE_EXTRACT_CMD="echo []" LORE_REVIEW_CMD="echo []"
hook="$scripts/lore-hook.sh"
wait_for() {   # wait_for <pattern> <count>: until harvest.log has that many matching lines
  for _ in $(seq 1 150); do [[ "$(grep -c -- "$1" "$S1/harvest.log" 2>/dev/null || true)" -ge "$2" ]] && return 0; sleep 0.2; done
  fail "harvest.log never reached $2 line(s) matching: $1"
}
LORE_STORE2="$tmp/none" bash -c "echo '{\"session_id\":\"s0\",\"transcript_path\":\"/nonexistent\"}' | '$hook' claude SessionEnd"
wait_for "store-run: skipped, no lore 2.0 store at $tmp/none (claude:SessionEnd)" 1
grep -q '"trigger": "claude:SessionEnd"' "$S1/sync-log.jsonl" || fail "1.x sync-run no longer runs first"
# A fictional Claude transcript: git.md read twice, profile.md once; a sidecar read, a read outside
# the store and an edit, none of which count.
rd() { printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_%s","name":"%s","input":{"file_path":"%s"%s}}]},"sessionId":"s1"}\n' "$@"; }
{ printf '{"type":"user","message":{"role":"user","content":"Fix the fixture build."},"sessionId":"s1"}\n'
  rd 1 Read "$A/gotchas/git.md" ""
  rd 2 Read "$A/gotchas/git.md" ""
  rd 3 Read "$A/profile.md" ""
  rd 4 Read "$A/.lore/meta/gotchas/git.json" ""
  rd 5 Read "$tmp/elsewhere/notes.md" ""
  rd 6 Edit "$A/core.md" ',"old_string":"a","new_string":"b"'
} > "$tmp/t.jsonl"
printf -- '- Close one-time agents when their work merges.\n' >> "$A/core.md"
before="$(git -C "$A" rev-list --count HEAD)"
LORE_STORE2="$A" bash -c "echo '{\"session_id\":\"s1\",\"transcript_path\":\"$tmp/t.jsonl\"}' | '$hook' claude SessionEnd"
wait_for "store-run: hub: " 1
[[ -z "$(ls "$A/.git/lore/queue")" ]] || fail "the 2.0 queue was not drained"
grep -qE " store-run: committed [0-9a-f]+ edit core.md; metadata of gotchas/git.md, profile.md \(claude:SessionEnd\)$" "$S1/harvest.log" \
  || fail "the session end did not commit its reads with the edit"
grep -qE " store-run: hub: pushed to $HUB$" "$S1/harvest.log" || fail "the session end did not push"
[[ "$(git -C "$HUB" rev-parse main)" == "$(git -C "$A" rev-parse HEAD)" ]] || fail "the session's commit is not on the hub"
[[ "$(git -C "$A" rev-list --count HEAD)" -gt "$before" ]] || fail "no new commit"
reads_are() {   # reads_are <sidecar> <expected reads map as JSON>
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["reads"]; w=json.loads(sys.argv[2]); sys.exit(0 if d == w else (print(d) or 1))' "$1" "$2" \
    || fail "reads in $1 are not $2"
}
reads_are "$A/.lore/meta/gotchas/git.json" "{\"$ma\": 4, \"$mb\": 5}"
reads_are "$A/.lore/meta/profile.json" "{\"$ma\": 2}"
reads_are "$A/.lore/meta/core.json" "{}"
# The same transcript at a later event of the session is not counted twice.
LORE_STORE2="$A" bash -c "echo '{\"session_id\":\"s1\",\"transcript_path\":\"$tmp/t.jsonl\"}' | '$hook' claude SessionEnd"
wait_for "store-run: hub: " 2
[[ "$(grep -c " store-run: nothing to commit (claude:SessionEnd)$" "$S1/harvest.log")" == 1 ]] || fail "a transcript was counted twice"
reads_are "$A/.lore/meta/gotchas/git.json" "{\"$ma\": 4, \"$mb\": 5}"

# 10. Review fixes, on a fresh pair of stores C and D sharing HUB2.
C="$tmp/c2"; D="$tmp/d2"; HUB2="$tmp/hub2.git"
LC() { python3 "$lore" --store2 "$C" "$@"; }
LD() { python3 "$lore" --store2 "$D" "$@"; }
git init -q --bare -b main "$HUB2"
ok LC store init; ok LC hub set "$HUB2"
ok LD store init; ok LD hub set "$HUB2"
mc="$(cat "$C/.git/lore/machine")"

# F2: a rebase that times out (inside a merge driver) is aborted; the local commit stays; the next
# run recovers and pushes. A git wrapper slows the drivers down for rebases, and the abort past the
# 2 s timeout, which recovery must outlast.
printf -- '- Prefer small commits.\n' >> "$C/core.md"; ok LC store commit
printf -- '- Read the diff.\n' >> "$D/core.md"
real_git="$(command -v git)"; mkdir -p "$tmp/slowgit"
cat > "$tmp/slowgit/git" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do [[ "\$a" == --abort ]] && { sleep 3; exec "$real_git" "\$@"; }; done   # an abort slower than the timeout
out=()
for a in "\$@"; do
  [[ "\$a" == rebase ]] && out+=(-c "merge.lore-rules.driver=sleep 20" -c "merge.lore-meta.driver=sleep 20")
  out+=("\$a")
done
exec "$real_git" "\${out[@]}"
EOF
chmod +x "$tmp/slowgit/git"
start=$SECONDS
if PATH="$tmp/slowgit:$PATH" LORE_GIT_TIMEOUT=2 python3 "$lore" --store2 "$D" store commit >"$log" 2>&1; then fail "a timed-out rebase exited zero"; fi
(( SECONDS - start < 15 )) || fail "the timed-out rebase took $((SECONDS - start))s"
grep -qE '^hub: push FAILED \(git rebase timed out after 2s \(no answer; nothing was prompted\)\); push failed 1 run\(s\) in a row; retried on the next run$' "$log" \
  || fail "no rebase timeout reported"
[[ ! -e "$D/.git/rebase-merge" && ! -e "$D/.git/rebase-apply" && ! -e "$D/.git/index.lock" ]] || fail "the timed-out rebase was left active"
[[ "$(git -C "$D" log -1 --format=%s)" == "edit core.md" && "$(git -C "$D" symbolic-ref --short HEAD)" == main ]] || fail "the local commit was not kept on main"
grep -qxF -- '- Read the diff.' "$D/core.md" || fail "the local rule was lost"
ok LD store run --trigger test:SessionEnd --force
grep -qE " store-run: hub: pushed to $HUB2$" "$log" || fail "the next run did not recover"
ok LC store commit
[[ "$(git -C "$C" rev-parse HEAD)" == "$(git -C "$D" rev-parse HEAD)" ]] || fail "C and D differ after the recovery"
printf '# Core\n\n- Prefer small commits.\n- Read the diff.\n' > "$tmp/core.want"
cmp -s "$D/core.md" "$tmp/core.want" || { diff "$tmp/core.want" "$D/core.md" >"$log" || true; fail "core.md after the recovery"; }

# F3: one machine deletes a topic file while the other adds a rule to it: the base rule stays
# deleted, the new rule stays, sidecar included, and both stores converge.
mkdir -p "$C/gotchas"; printf '# Fixture\n\n- Keep the fixture small.\n' > "$C/gotchas/fixture.md"
ok LC store commit
ok LD store run --trigger test:SessionEnd --force
[[ -f "$D/gotchas/fixture.md" ]] || fail "D did not get the topic file"
rm "$C/gotchas/fixture.md"; ok LC store commit
printf -- '- Name fixtures after the case.\n' >> "$D/gotchas/fixture.md"
ok LD store commit
has "hub: pushed to $HUB2"
ok LC store commit
has "hub: pushed to $HUB2"
[[ "$(git -C "$C" rev-parse HEAD)" == "$(git -C "$D" rev-parse HEAD)" ]] || fail "C and D did not converge"
diff -r --exclude=.git --exclude=INDEX.md "$C" "$D" >"$log" || fail "C and D differ after a modify/delete"
printf '# Fixture\n\n- Name fixtures after the case.\n' > "$tmp/fixture.want"
cmp -s "$C/gotchas/fixture.md" "$tmp/fixture.want" || { diff "$tmp/fixture.want" "$C/gotchas/fixture.md" >"$log" || true; fail "modify/delete did not keep only the new rule"; }
[[ "$(python3 -c 'import json,sys; print(sorted(r["text"] for r in json.load(open(sys.argv[1]))["rules"].values()))' "$C/.lore/meta/gotchas/fixture.json")" == \
   "['Name fixtures after the case.']" ]] || fail "the sidecar after a modify/delete"
# Deleted on one machine while the other removed its last rule: the file is gone on both.
rm "$C/gotchas/fixture.md"; ok LC store commit
printf '# Fixture\n' > "$D/gotchas/fixture.md"
ok LD store commit
has "hub: pushed to $HUB2"
ok LC store commit
[[ "$(git -C "$C" rev-parse HEAD)" == "$(git -C "$D" rev-parse HEAD)" ]] || fail "C and D did not converge on a double removal"
[[ ! -e "$D/gotchas/fixture.md" && ! -e "$D/.lore/meta/gotchas/fixture.json" ]] || fail "a file emptied on one side and deleted on the other came back"

# F4: a read count that cannot be saved stays queued; after the repair the next run counts it once.
# The session read core.md and profile.md; profile's sidecar is broken, and core.md, saved first in
# order, must not be counted twice by the retry.
for f in core.md profile.md; do
  printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_9","name":"Read","input":{"file_path":"%s"}}]},"sessionId":"s9"}\n' "$C/$f"
done > "$tmp/t9.jsonl"
q() { mkdir -p "$C/.git/lore/queue"; printf '{"lore_host":"claude","lore_event":"SessionEnd","payload":{"session_id":"s9","transcript_path":"%s"}}\n' "$tmp/t9.jsonl" > "$C/.git/lore/queue/$1.json"; }
q first
cp "$C/.lore/meta/profile.json" "$tmp/profile.json.orig"; printf '{' > "$C/.lore/meta/profile.json"
ok LC store run --trigger claude:SessionEnd
grep -q " store-run: .lore/meta/profile.json is not valid JSON; this session's reads stay queued for the next run (claude:SessionEnd)$" "$log" \
  || fail "a failed read save was not reported"
[[ -f "$C/.git/lore/queue/first.json" ]] || fail "the queue entry was dropped before the reads were saved"
cp "$tmp/profile.json.orig" "$C/.lore/meta/profile.json"
q retry
ok LC store run --trigger claude:SessionEnd
reads_are "$C/.lore/meta/profile.json" "{\"$mc\": 1}"
reads_are "$C/.lore/meta/core.json" "{\"$mc\": 1}"
[[ -z "$(ls "$C/.git/lore/queue")" ]] || fail "the queue was not drained after the repair"
q again
ok LC store run --trigger claude:SessionEnd
reads_are "$C/.lore/meta/profile.json" "{\"$mc\": 1}"
reads_are "$C/.lore/meta/core.json" "{\"$mc\": 1}"

# 11. The hub's integration does not rebase across a local merge (a plain rebase drops a merge and
# what only it added): it refuses, naming the merge, and leaves everything as it was. With nothing
# new on the hub there is nothing to rebase and the merge pushes as it is.
pair() {   # pair <name>: stores X and Y on a fresh hub
  P="$tmp/$1"; mkdir -p "$P"; PX="$P/x"; PY="$P/y"; PH="$P/hub.git"
  git init -q --bare -b main "$PH"
  python3 "$lore" --store2 "$PX" store init >"$log" 2>&1 || fail "$1: init X"
  python3 "$lore" --store2 "$PX" hub set "$PH" >"$log" 2>&1 || fail "$1: hub set X"
  python3 "$lore" --store2 "$PY" store init >"$log" 2>&1 || fail "$1: init Y"
  python3 "$lore" --store2 "$PY" hub set "$PH" >"$log" 2>&1 || fail "$1: hub set Y"
}
lx() { python3 "$lore" --store2 "$PX" "$@"; }
ly() { python3 "$lore" --store2 "$PY" "$@"; }
owner_merge() {   # owner_merge <store> <file> <text>: a --no-ff merge with a file only the merge commit adds
  local s="$1"
  git -C "$s" checkout -q -b fixture-side
  printf 'Fixture side note.\n' > "$s/side-note.txt"; git -C "$s" add -- side-note.txt; git -C "$s" commit -q -m "fixture side note"
  git -C "$s" checkout -q main
  printf 'Fixture main note.\n' > "$s/main-note.txt"; git -C "$s" add -- main-note.txt; git -C "$s" commit -q -m "fixture main note"
  git -C "$s" merge -q --no-ff --no-commit fixture-side >/dev/null 2>&1
  printf '%s\n' "$3" > "$s/$2"; git -C "$s" add -- "$2"
  git -C "$s" commit -q -m "fixture owner merge"
}
hub_has() { git -C "$1" cat-file -e "main:$2" 2>/dev/null; }
fails_of() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["push_fails"])' "$1/.git/lore/state.json"; }

# The hub has another machine's commit: the push refuses by name, twice, and nothing changes.
pair merge-refused
printf 'Fixture hub change.\n' > "$PY/hub-note.txt"; ok ly store commit
owner_merge "$PX" merge-note.txt "Fixture manual work."
before="$(git -C "$PX" rev-parse HEAD)"; hubbefore="$(git -C "$PH" rev-parse main)"
for n in 1 2; do
  if [[ $n == 1 ]]; then lx store commit >"$log" 2>&1 || true; else lx store run --trigger test:SessionEnd --force >"$log" 2>&1 || true; fi
  grep -qE '(^|store-run: )hub: push FAILED \(a local merge [0-9a-f]{7} "fixture owner merge" cannot be rebased onto the hub; lore does not replay merges\. Merge the hub in yourself, e\.g\. git -C '"$PX"' merge hub/main, then the next run pushes\); push failed '"$n"' run\(s\) in a row; retried on the next run$' "$log" \
    || fail "run $n: a local merge was not refused by name"
  [[ "$(git -C "$PX" rev-parse HEAD)" == "$before" && "$(git -C "$PX" symbolic-ref --short HEAD)" == main ]] || fail "run $n: a refused merge changed the store"
  [[ ! -e "$PX/.git/rebase-merge" && ! -e "$PX/.git/rebase-apply" && "$(cat "$PX/merge-note.txt")" == "Fixture manual work." ]] || fail "run $n: a refused merge left the rebase or lost its file"
  [[ -z "$(git -C "$PX" status --porcelain)" ]] || fail "run $n: a refused merge left the work tree dirty"
  [[ "$(git -C "$PH" rev-parse main)" == "$hubbefore" ]] || fail "run $n: a refused merge reached the hub"
  [[ "$(fails_of "$PX")" == "$n" ]] || fail "run $n: the failed push was not counted"
done

# The suggested fix, run exactly as printed (the last refusal line is in $log), keeps the merge's own
# work: the hub is then in HEAD, the next push is a fast-forward, and nothing local is lost.
cmd="$(sed -nE 's/.*e\.g\. (git -C .* merge hub\/main), then the next run pushes.*/\1/p' "$log")"
[[ "$cmd" == "git -C $PX merge hub/main" ]] || fail "the refusal line does not carry the merge command: $cmd"
eval "$cmd" >"$log" 2>&1 || fail "the suggested merge command failed"
ok lx store run --trigger test:SessionEnd --force
grep -qE " store-run: hub: pushed to $PH\$" "$log" || fail "the push after the suggested merge did not succeed"
[[ "$(fails_of "$PX")" == 0 ]] || fail "the failure count was not cleared after the suggested merge"
[[ "$(git -C "$PX" rev-parse HEAD)" == "$(git -C "$PH" rev-parse main)" ]] || fail "X and the hub differ after the suggested merge"
[[ "$(git -C "$PH" show main:merge-note.txt)" == "Fixture manual work." ]] || fail "the merge's own file did not reach the hub"
for f in hub-note.txt side-note.txt main-note.txt; do hub_has "$PH" "$f" || fail "$f is not on the hub after the suggested merge"; done
[[ "$(git -C "$PX" log --merges --format=%s | grep -cxF 'fixture owner merge')" == 1 ]] || fail "the owner's merge was lost after the suggested merge"
git -C "$PX" merge-base --is-ancestor "$before" HEAD || fail "a local commit was lost after the suggested merge"

# Nothing new on the hub: the merge is a fast-forward for the hub and pushes as it is.
pair merge-ff
ok lx store commit
owner_merge "$PX" merge-note.txt "Fixture manual work."
ok lx store commit
has "hub: pushed to $PH"
[[ "$(git -C "$PH" show main:merge-note.txt)" == "Fixture manual work." ]] || fail "the merge's own file did not reach the hub"
for f in side-note.txt main-note.txt; do hub_has "$PH" "$f" || fail "$f is not on the hub"; done
[[ "$(git -C "$PX" rev-parse HEAD)" == "$(git -C "$PH" rev-parse main)" && "$(fails_of "$PX")" == 0 ]] || fail "X and the hub differ after the fast-forward push"
[[ "$(git -C "$PX" log --merges --format=%s | grep -cxF 'fixture owner merge')" == 1 ]] || fail "the owner's merge is no longer a merge commit"

# 12. An owner's unfinished git operation is never completed by lore. The suggested merge of
# section 11 can stop on a conflict; the next session end, an explicit store commit and the other
# writers must leave HEAD, the index, the work tree and the hub as they are, log one line and push
# nothing, until the owner resolves and commits (or aborts); then the next run goes on.
snap() {   # snap <store>: HEAD, index bytes, work tree, the conflicted file, the operation's state files
  printf '%s %s %s\n' "$(git -C "$1" rev-parse HEAD)" "$(sha256sum < "$1/.git/index")" "$(git -C "$1" status --porcelain=v2 | sha256sum)"
  cat "$1/conflict.txt"; ls "$1/.git" | grep -E '^(MERGE_HEAD|CHERRY_PICK_HEAD|REVERT_HEAD|rebase-merge|rebase-apply|sequencer)$' || true
  cat "$1/.git/sequencer/todo" 2>/dev/null || true
}
unfinished_pair() {   # unfinished_pair <name> <kind>: X stopped in <kind> on a conflict in conflict.txt
  pair "$1"
  printf 'one\n' > "$PX/conflict.txt"; git -C "$PX" add -- conflict.txt; git -C "$PX" commit -q -m "fixture one"
  ok lx store commit
  ok ly store run --trigger test:SessionEnd --force
  if [[ $2 == merge || $2 == unmerged ]]; then printf 'hub\n' > "$PY/conflict.txt"; else printf 'hub\n' > "$PY/hub-note.txt"; fi
  ok ly store commit
  git -C "$PX" checkout -q -b fixture-side
  if [[ $2 == merge || $2 == unmerged ]]; then printf 'side\n' > "$PX/side-note.txt"; git -C "$PX" add -- side-note.txt
  else printf 'side\n' > "$PX/conflict.txt"; fi
  git -C "$PX" commit -q -am "fixture side" || true
  git -C "$PX" checkout -q main
  printf 'two\n' > "$PX/conflict.txt"; git -C "$PX" commit -q -am "fixture two"
  case "$2" in
    merge|unmerged)   # the review's route: a local merge, refused, then the merge lore suggests, which conflicts
      git -C "$PX" merge -q --no-ff -m "fixture owner merge" fixture-side >/dev/null 2>&1
      lx store run --trigger test:SessionEnd --force >"$log" 2>&1 || true
      git -C "$PX" merge hub/main >/dev/null 2>&1 || true
      [[ $2 == merge ]] || rm "$PX/.git/MERGE_HEAD" ;;
    cherry-pick) git -C "$PX" cherry-pick fixture-side >/dev/null 2>&1 || true ;;
    revert)      git -C "$PX" revert --no-edit HEAD~1 >/dev/null 2>&1 || true ;;
    rebase)      git -C "$PX" rebase fixture-side >/dev/null 2>&1 || true ;;
  esac
  [[ -n "$(git -C "$PX" ls-files -u)" ]] || fail "$2: the fixture did not stop on a conflict"
}
for kind in merge unmerged cherry-pick revert rebase; do
  unfinished_pair "unfinished-$kind" "$kind"
  noun="$kind"; [[ $kind == unmerged ]] && noun=merge
  state="$(snap "$PX")"; hubbefore="$(git -C "$PH" rev-parse main)"; failsbefore="$(fails_of "$PX")"
  if [[ $kind == unmerged ]]; then
    want="store: unmerged paths are in $PX; resolve them and commit, then the next run continues"
  else
    want="store: an unfinished git $noun is in progress in $PX; resolve and commit it, or run git -C $PX $noun --abort, then the next run continues"
  fi
  for how in run force commit; do
    case "$how" in
      run)    lx store run --trigger test:SessionEnd >"$log" 2>&1 || fail "$kind: the session end failed" ;;
      force)  lx store run --trigger test:SessionEnd --force >"$log" 2>&1 || fail "$kind: the forced session end failed" ;;
      commit) if lx store commit >"$log" 2>&1; then fail "$kind: store commit went through"; fi ;;
    esac
    if [[ $how == commit ]]; then has "Error: $want" "$kind: store commit did not refuse by name"
    else
      [[ "$(grep -c . "$log")" == 1 ]] && grep -qE " store-run: ${want//./\\.} \(test:SessionEnd\)\$" "$log" || fail "$kind: $how: the log is not exactly the refusal line"
    fi
    [[ "$(snap "$PX")" == "$state" ]] || fail "$kind: $how: lore changed HEAD, the index, the work tree or the operation"
    [[ "$(git -C "$PH" rev-parse main)" == "$hubbefore" ]] || fail "$kind: $how: the hub changed"
  done
  [[ "$(fails_of "$PX")" == "$failsbefore" ]] || fail "$kind: a refused run counted as a failed push"
  case "$kind" in   # the owner finishes it
    merge|unmerged) printf 'owner resolved\n' > "$PX/conflict.txt"; git -C "$PX" add -- conflict.txt; git -C "$PX" commit -q -m "fixture resolved" ;;
    cherry-pick)    printf 'owner resolved\n' > "$PX/conflict.txt"; git -C "$PX" add -- conflict.txt; git -C "$PX" -c core.editor=true cherry-pick --continue >/dev/null 2>&1 ;;
    revert)         git -C "$PX" revert --abort ;;
    rebase)         git -C "$PX" rebase --abort ;;
  esac
  [[ -z "$(git -C "$PX" ls-files -u)" ]] || fail "$kind: the owner's finish left unmerged paths"
  ok lx store run --trigger test:SessionEnd --force
  if [[ $kind == unmerged ]]; then   # a plain commit, not a merge of the hub: lore goes on, and the section 11 refusal applies
    has "$(grep -m1 ' store-run: nothing to commit' "$log")" "unmerged: lore did not go on after the owner's commit"
    ! grep -q 'unmerged paths' "$log" || fail "unmerged: lore still refused after the owner's commit"
    continue
  fi
  grep -qE " store-run: hub: pushed to $PH\$" "$log" || fail "$kind: the run after the owner's finish did not push"
  [[ "$(git -C "$PX" rev-parse HEAD)" == "$(git -C "$PH" rev-parse main)" ]] || fail "$kind: X and the hub differ after the owner's finish"
  case "$kind" in merge|unmerged|cherry-pick) [[ "$(git -C "$PH" show main:conflict.txt)" == "owner resolved" ]] || fail "$kind: the owner's resolution is not on the hub" ;; esac
done

# The other writers: reads, tidy, commit, a Loremaster batch and Canon stop at the same line and
# write nothing; so does attaching a hub.
unfinished_pair unfinished-writers merge
state="$(snap "$PX")"
out="$(cd "$scripts" && python3 -c "
import sys, lore; sys.modules.setdefault('lore', lore)
import lore_store, lore_master, lore_canon, lore_hub
st = lore_store.Store2('$PX')
for name, call in (('record_reads', lambda: lore_store.record_reads(st, {'core.md': 1}, 'fixture')),
                   ('tidy', lambda: lore_store.tidy(st)),
                   ('commit', lambda: lore_store.commit(st)),
                   ('apply', lambda: lore_master.apply(st, [{'op': 'add', 'file': 'gotchas/git.md', 'text': 'Fixture rule.', 'explicit': True, 'quote': 'Fixture rule.', 'session': 's-1'}], source='fixture')),
                   ('integrate', lambda: lore_hub.integrate(st, 'hub', 'fixture')),
                   ('canon', lambda: lore_canon.step(st, 'fixture:SessionEnd', True))):
    try:
        r = call()
        print(name, 'WROTE', r)
    except lore.LoreError as err:
        print(name, err)
" 2>&1)"
line="store: an unfinished git merge is in progress in $PX; resolve and commit it, or run git -C $PX merge --abort, then the next run continues"
for n in record_reads tidy commit apply integrate; do
  grep -qxF -- "$n $line" <<<"$out" || fail "$n did not refuse an unfinished merge: $out"
done
grep -qE " store-run: canon skipped, $line \(fixture:SessionEnd\)\$" <<<"$out" || fail "canon did not skip an unfinished merge: $out"
[[ "$(snap "$PX")" == "$state" ]] || fail "a writer changed the store during an unfinished merge"
if lx hub set "$PH" >"$log" 2>&1; then fail "hub set went through during an unfinished merge"; fi
has "Error: $line" "hub set did not refuse by name"
[[ "$(snap "$PX")" == "$state" ]] || fail "hub set changed the store during an unfinished merge"

# 13. lore's own rebase versus the owner's, after a hard kill. A rebase lore started and never ended
# is lore's to abort, and only the instance lore started: a token in git's rebase directory (which an
# abort removes) must equal the one in lore's mark. Every writer ends it where it begins, before it
# reads the store or builds anything from it; the guard at the write only refuses.
LOCAL_RULE='- Keep fictional local artifacts.'
killed_rebase() {   # killed_rebase <name>: X holds a rebase onto the hub that lore started and a kill left stopped
  pair "$1"
  printf 'one\n' > "$PX/conflict.txt"; git -C "$PX" add -- conflict.txt; git -C "$PX" commit -q -m "fixture one"
  mkdir -p "$PX/gotchas"; printf '# Git\n\n- Keep fictional base artifacts.\n' > "$PX/gotchas/git.md"
  ok lx store commit
  ok ly store run --trigger test:SessionEnd --force
  printf 'hub\n' > "$PY/conflict.txt"; ok ly store commit
  printf 'two\n' > "$PX/conflict.txt"; git -C "$PX" commit -q -am "fixture two"
  printf '# Git\n\n- Keep fictional base artifacts.\n%s\n' "$LOCAL_RULE" > "$PX/gotchas/git.md"   # a later local commit, which the stopped rebase has not replayed
  (cd "$scripts" && python3 -c "
import sys, lore; sys.modules.setdefault('lore', lore)
import lore_store
st = lore_store.Store2('$PX')
lore_store.tidy(st); lore_store.commit(st)
st.git('fetch', '-q', 'hub')
lore_store.mark_rebase(st)
st.git('rebase', '-q', 'refs/remotes/hub/main', check=False)
") >"$log" 2>&1 || fail "$1: the fixture could not start lore's rebase"
  pre="$(git -C "$PX" rev-parse main)"
  [[ -e "$PX/.git/rebase-merge" && -s "$PX/.git/lore-rebase" ]] || fail "$1: the fixture is not a stopped lore rebase"
  [[ "$(cat "$PX/.git/rebase-merge/lore-token")" == "$(cat "$PX/.git/lore-rebase")" ]] || fail "$1: git's rebase directory does not hold the mark's token"
  ! grep -qxF -- "$LOCAL_RULE" "$PX/gotchas/git.md" || fail "$1: the stopped rebase already holds the local rule"
}
recovered_rebase_only() {
  [[ ! -e "$PX/.git/rebase-merge" && ! -e "$PX/.git/rebase-apply" && ! -e "$PX/.git/lore-rebase" ]] || fail "$1: lore's own stopped rebase was not ended"
  git -C "$PX" merge-base --is-ancestor "$pre" HEAD || fail "$1: the original commits are not in HEAD"
}
recovered() {   # recovered <label> [hub]: lore's rebase is gone with its mark; the original commits and the unrelated local rule are still there
  [[ ! -e "$PX/.git/rebase-merge" && ! -e "$PX/.git/rebase-apply" && ! -e "$PX/.git/lore-rebase" ]] || fail "$1: lore's own stopped rebase was not ended"
  git -C "$PX" merge-base --is-ancestor "$pre" HEAD && [[ "$(git -C "$PX" symbolic-ref --short HEAD)" == main ]] || fail "$1: ending lore's rebase did not put HEAD back"
  [[ "${2:-}" != hub ]] || ! git -C "$PX" merge-base --is-ancestor hub/main HEAD || fail "$1: the stopped rebase was completed, not ended"
  [[ -z "$(git -C "$PX" ls-files -u)" ]] || fail "$1: unmerged paths are left"
  [[ "$(git -C "$PX" show HEAD:gotchas/git.md | grep -cxF -- "$LOCAL_RULE")" == 1 ]] || fail "$1: the unrelated local rule is not in the committed file exactly once"
}
# F1/F2 (review 5): each writer that builds content from the store ends lore's rebase first, so the
# rule only the unreplayed local commit holds survives, or the action refuses.
for writer in record_reads apply inbox_accept inbox_reject hub_reject ui_accept ui_accept_local ui_reject ui_reject_local canon; do
  killed_rebase "killed-$writer"
  out="$(cd "$scripts" && python3 -c "
import sys, lore; sys.modules.setdefault('lore', lore)
import lore_store, lore_master, lore_canon, lore_ui, lore_hub
st = lore_store.Store2('$PX')
meta = lore_store.load_meta(st, 'gotchas/git.md')   # the intermediate checkout: only the base rule
eid = next(i for i, e in meta['rules'].items() if e['text'] == 'Keep fictional base artifacts.')
iid = lore_master._queue(st, 'retire', {'file': 'gotchas/git.md', 'rule_id': eid, 'text': 'Keep fictional base artifacts.', 'reason': 'Fictional.'}, 'fixture')
hid = lore_master._hid('gotchas/git.md', eid)
import json, subprocess   # the local rule's hand edit exists only in the commit the stopped rebase has not replayed
tip = json.loads(subprocess.run(['git', '-C', '$PX', 'show', 'main:' + lore_store.meta_rel('gotchas/git.md')], capture_output=True, text=True).stdout)
lid = lore_master._hid('gotchas/git.md', next(i for i, e in tip['rules'].items() if e['text'] == 'Keep fictional local artifacts.'))
calls = {'record_reads': lambda: lore_store.record_reads(st, {'gotchas/git.md': 1}, 'fixture'),
         'apply': lambda: lore_master.apply(st, [{'op': 'add', 'file': 'gotchas/git.md', 'text': 'Keep fictional new artifacts.', 'explicit': True, 'quote': 'Keep fictional new artifacts.', 'session': 's-1'}], source='fixture'),
         'inbox_accept': lambda: lore_master.inbox_accept(st, iid),
         'inbox_reject': lambda: lore_master.inbox_reject(st, hid),
         'hub_reject': lambda: print('result', lore_hub.inbox_reject(st, iid)),
         'ui_accept': lambda: lore_ui.accept(st, {'id': iid}),
         'ui_accept_local': lambda: lore_ui.accept(st, {'id': lid}),
         'ui_reject': lambda: lore_ui.reject(st, {'id': hid}),
         'ui_reject_local': lambda: lore_ui.reject(st, {'id': lid}),
         'canon': lambda: lore_canon.step(st, 'fixture:SessionEnd', True)}
try:
    calls['$writer']()
    print('went on')
except (lore.LoreError, lore_ui.ApiError) as err:
    print(err)
" 2>&1)"
  grep -q 'unfinished git rebase' <<<"$out" && fail "$writer: lore's own rebase was reported as the owner's: $out"
  if [[ $writer == ui_reject_local ]]; then
    recovered_rebase_only "$writer"   # the owner is rejecting the very rule the unreplayed commit holds
    ! git -C "$PX" show HEAD:gotchas/git.md | grep -qxF -- "$LOCAL_RULE" || fail "$writer: the rejected local rule is still in the file"
    git -C "$PX" show HEAD:gotchas/git.md | grep -qxF -- '- Keep fictional base artifacts.' || fail "$writer: the base rule was lost"
    continue
  fi
  recovered "$writer" $([[ $writer == ui_* ]] || echo hub)
  [[ $writer != ui_accept_local ]] || git -C "$PX" show HEAD:gotchas/git.md | grep -qxF -- '- Keep fictional base artifacts.' || fail "$writer: the base rule was lost"
  case "$writer" in
    hub_reject)   grep -qxF "result {'commit': None, 'push': None, 'pushed': None}" <<<"$out" || fail "hub_reject: recovery was counted as the reject's commit: $out" ;;
    apply)        [[ "$(git -C "$PX" show HEAD:gotchas/git.md | grep -cxF -- '- Keep fictional new artifacts.')" == 1 ]] || fail "apply: the new rule is not in the committed file exactly once" ;;
    inbox_reject|ui_reject) ! git -C "$PX" show HEAD:gotchas/git.md | grep -qxF -- '- Keep fictional base artifacts.' || fail "$writer: the rejected hand edit is still in the file" ;;
  esac
done
# the write guard itself only refuses: it never ends a rebase, so nothing prepared before an end is written over it
killed_rebase killed-guard
state="$(snap "$PX")"; mark="$(cat "$PX/.git/lore-rebase")"
out="$(cd "$scripts" && python3 -c "
import sys, lore; sys.modules.setdefault('lore', lore)
import lore_store, lore_master
st = lore_store.Store2('$PX')
try:
    lore_master._commit_writes(st, {'core.md': '# Core\n\n- Fixture rule.\n'}, 'fixture')
    print('WROTE')
except lore.LoreError as err:
    print(err)
" 2>&1)"
[[ "$out" == "store: an unfinished git rebase is in progress in $PX; resolve and commit it, or run git -C $PX rebase --abort, then the next run continues" ]] || fail "the write guard did not refuse by name: $out"
[[ "$(snap "$PX")" == "$state" && -e "$PX/.git/rebase-merge" && "$(cat "$PX/.git/lore-rebase")" == "$mark" ]] || fail "the write guard changed the rebase, the checkout or the mark"
# the command-line entries: session end, store commit|status|index, hub set, canon
for how in run commit status index hub canon; do
  killed_rebase "entry-$how"
  case "$how" in
    run)    cmd=(store run --trigger test:SessionEnd --force) ;;
    hub)    cmd=(hub set "$PH") ;;
    canon)  cmd=(canon --force) ;;
    *)      cmd=(store "$how") ;;
  esac
  lx "${cmd[@]}" >"$log" 2>&1 || true
  ! grep -q 'unfinished git rebase' "$log" || fail "entry $how: lore's own rebase was reported as the owner's"
  recovered "entry $how"
done

# F1 (review 5): ownership is the instance lore started, not its inputs. Whatever the owner starts
# is left alone by every run and the stale mark is dropped: a mark with no rebase of lore's, an
# empty mark, a mark with another token than the one in git's rebase directory, and the owner who aborts lore's stopped rebase and restarts that very rebase.
pair stale-mark
printf 'one\n' > "$PX/conflict.txt"; git -C "$PX" add -- conflict.txt; git -C "$PX" commit -q -m "fixture one"
ok lx store commit
ok ly store run --trigger test:SessionEnd --force
printf 'hub\n' > "$PY/hub-note.txt"; ok ly store commit
# a successful lore rebase leaves no mark behind the moment it returns (the hub has a commit, X
# another); the tidy that follows would clear it too late for a kill in between
printf 'x\n' > "$PX/x-note.txt"; git -C "$PX" add -- x-note.txt; git -C "$PX" commit -q -m "fixture x note"
out="$(cd "$scripts" && python3 -c "
import sys, os, lore; sys.modules.setdefault('lore', lore)
import lore_store, lore_hub
st = lore_store.Store2('$PX')
st.git('fetch', '-q', 'hub')
lore_hub.rebase(st, 'refs/remotes/hub/main')
print('mark=' + str(os.path.exists(os.path.join('$PX', '.git', 'lore-rebase'))), 'ahead=' + st.git('rev-list', '--count', 'refs/remotes/hub/main..HEAD')[1].strip(), 'token=' + str(st.rebase_token))
" 2>&1)"
[[ "$out" == "mark=False ahead=1 token=None" ]] || fail "a finished lore rebase left its mark, or did not replay: $out"
ok lx store run --trigger test:SessionEnd --force
grep -qE " store-run: hub: pushed to $PH\$" "$log" || fail "stale mark: the rebasing run did not push"
# the owner's rebase.autoSquash does not reorder or fold the commits lore replays (lore's rebase is
# interactive underneath, which is when git honours that setting)
printf 'a\n' > "$PX/auto-note.txt"; git -C "$PX" add -- auto-note.txt; git -C "$PX" commit -q -m "fixture alpha"
printf 'b\n' >> "$PX/auto-note.txt"; git -C "$PX" commit -q -am "fixup! fixture alpha"
printf 'hub\n' > "$PY/hub-note-two.txt"; ok ly store commit
out="$(cd "$scripts" && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=rebase.autoSquash GIT_CONFIG_VALUE_0=true python3 -c "
import sys, lore; sys.modules.setdefault('lore', lore)
import lore_store, lore_hub
st = lore_store.Store2('$PX')
st.git('fetch', '-q', 'hub')
lore_hub.rebase(st, 'refs/remotes/hub/main')
print('ahead=' + st.git('rev-list', '--count', 'refs/remotes/hub/main..HEAD')[1].strip(), st.git('log', '-2', '--format=%s', '--reverse')[1].replace(chr(10), '|'))
" 2>&1)"
[[ "$out" == "ahead=2 fixture alpha|fixup! fixture alpha|" ]] || fail "the owner's autoSquash changed the commits lore replayed: $out"
owner_rebase() {   # owner_rebase <stale|half|othertoken|restarted>: a mark that is not the owner's rebase's, then the owner's rebase stops on a conflict
  if [[ $1 == othertoken ]]; then
    killed_rebase "owner-$1"
    printf 'ffffffffffffffffffffffffffffffff\n' > "$PX/.git/lore-rebase"   # the rebase directory holds a token, but not this mark's
  elif [[ $1 == restarted ]]; then
    killed_rebase "owner-$1"
    git -C "$PX" rebase --abort
    git -C "$PX" rebase refs/remotes/hub/main >/dev/null 2>&1 || true   # the same target, from the same HEAD
    [[ "$(git -C "$PX" rev-parse HEAD)" != "$pre" ]] || fail "owner $1: the fixture did not restart a rebase"
  else
    pair "owner-$1"
    printf 'one\n' > "$PX/conflict.txt"; git -C "$PX" add -- conflict.txt; git -C "$PX" commit -q -m "fixture one"
    ok lx store commit
    git -C "$PX" checkout -q -b fixture-side
    printf 'side\n' > "$PX/conflict.txt"; git -C "$PX" commit -q -am "fixture side"
    git -C "$PX" checkout -q main
    case "$1" in
      stale) (cd "$scripts" && python3 -c "
import sys, lore; sys.modules.setdefault('lore', lore)
import lore_store
lore_store.mark_rebase(lore_store.Store2('$PX'))
") >"$log" 2>&1 || fail "owner $1: could not write the mark" ;;   # a real token, in a mark with no rebase behind it
      half) : > "$PX/.git/lore-rebase" ;;   # a mark that never got its content
    esac
    printf 'two\n' > "$PX/conflict.txt"; git -C "$PX" commit -q -am "fixture two"
    git -C "$PX" rebase fixture-side >/dev/null 2>&1 || true
  fi
  [[ -e "$PX/.git/rebase-merge" && -e "$PX/.git/lore-rebase" ]] || fail "owner $1: the fixture is not a rebase beside a stale mark"
  [[ $1 == othertoken || ! -e "$PX/.git/rebase-merge/lore-token" ]] || fail "owner $1: the fixture's rebase already holds a token"
  state="$(snap "$PX")"
  want="store: an unfinished git rebase is in progress in $PX; resolve and commit it, or run git -C $PX rebase --abort, then the next run continues"
  for how in run commit; do
    if [[ $how == run ]]; then lx store run --trigger test:SessionEnd --force >"$log" 2>&1 || fail "owner $1: the session end failed"
    else if lx store commit >"$log" 2>&1; then fail "owner $1: store commit went through"; fi; fi
    grep -qF -- "$want" "$log" || fail "owner $1: $how did not refuse the owner's rebase by name"
    [[ "$(snap "$PX")" == "$state" ]] || fail "owner $1: $how changed the owner's rebase"
  done
  [[ ! -e "$PX/.git/lore-rebase" ]] || fail "owner $1: the stale mark was not dropped"
}
for case in stale half othertoken restarted; do owner_rebase "$case"; done
# the entries that act outside the store refuse before they do: no repository is created for an owner's unfinished rebase
gh_before="$(wc -l < "$tmp/gh.log")"
if lx hub create --name fixture-owner/lore-memory-two --yes >"$log" 2>&1; then fail "hub create went through during an unfinished rebase"; fi
has "Error: $want" "hub create did not refuse by name"
[[ "$(wc -l < "$tmp/gh.log")" == "$gh_before" ]] || fail "hub create called gh during an unfinished rebase"
[[ "$(snap "$PX")" == "$state" ]] || fail "hub create changed the owner's rebase"

# 14. A multi-pick cherry-pick or revert (--no-commit) whose first conflict the owner has resolved and
# staged: git keeps the rest only in .git/sequencer (no CHERRY_PICK_HEAD, no unmerged entry), and the
# store is still the owner's unfinished operation. Nothing is committed or pushed until it is finished.
for kind in cherry-pick revert; do
  pair "sequencer-$kind"
  printf 'base\n' > "$PX/conflict.txt"; git -C "$PX" add -- conflict.txt; git -C "$PX" commit -q -m "fixture base"
  ok lx store commit
  if [[ $kind == cherry-pick ]]; then
    git -C "$PX" checkout -q -b fixture-side
    printf 'side\n' > "$PX/conflict.txt"; git -C "$PX" commit -q -am "fixture first pick"; first="$(git -C "$PX" rev-parse HEAD)"
    printf 'pending\n' > "$PX/pending.txt"; git -C "$PX" add -- pending.txt; git -C "$PX" commit -q -m "fixture second pick"; second="$(git -C "$PX" rev-parse HEAD)"
    git -C "$PX" checkout -q main
    printf 'local\n' > "$PX/conflict.txt"; git -C "$PX" commit -q -am "fixture local"
  else
    printf 'changed\n' > "$PX/conflict.txt"; git -C "$PX" commit -q -am "fixture first pick"; first="$(git -C "$PX" rev-parse HEAD)"
    printf 'pending\n' > "$PX/pending.txt"; git -C "$PX" add -- pending.txt; git -C "$PX" commit -q -m "fixture second pick"; second="$(git -C "$PX" rev-parse HEAD)"
    printf 'later\n' > "$PX/conflict.txt"; git -C "$PX" commit -q -am "fixture local"
  fi
  git -C "$PX" "$kind" --no-commit "$first" "$second" >/dev/null 2>&1 || true
  [[ -n "$(git -C "$PX" ls-files -u)" ]] || fail "$kind: the fixture did not stop on a conflict"
  printf 'owner resolution\n' > "$PX/conflict.txt"; git -C "$PX" add -- conflict.txt
  # a revert keeps REVERT_HEAD until the owner commits the first one, so it is left after that commit,
  # with the sequencer still holding both
  [[ $kind == cherry-pick ]] || git -C "$PX" commit -q -m "fixture resolved"
  [[ -z "$(git -C "$PX" ls-files -u)" && -s "$PX/.git/sequencer/todo" && ! -e "$PX/.git/CHERRY_PICK_HEAD" && ! -e "$PX/.git/REVERT_HEAD" ]] \
    || fail "$kind: the fixture is not a staged resolution with only the sequencer left"
  [[ "$(grep -c "^${kind/cherry-/} " "$PX/.git/sequencer/todo")" == 2 ]] || fail "$kind: the sequencer does not hold both picks"
  state="$(snap "$PX")"; hubbefore="$(git -C "$PH" rev-parse main)"; failsbefore="$(fails_of "$PX")"
  want="store: an unfinished git $kind is in progress in $PX; resolve and commit it, or run git -C $PX $kind --abort, then the next run continues"
  for how in run force commit; do
    case "$how" in
      run)    lx store run --trigger test:SessionEnd >"$log" 2>&1 || fail "$kind: the session end failed" ;;
      force)  lx store run --trigger test:SessionEnd --force >"$log" 2>&1 || fail "$kind: the forced session end failed" ;;
      commit) if lx store commit >"$log" 2>&1; then fail "$kind: store commit went through"; fi ;;
    esac
    if [[ $how == commit ]]; then has "Error: $want" "$kind: store commit did not refuse by name"
    else
      [[ "$(grep -c . "$log")" == 1 ]] && grep -qE " store-run: ${want//./\\.} \(test:SessionEnd\)\$" "$log" || fail "$kind: $how: the log is not exactly the refusal line"
    fi
    [[ "$(snap "$PX")" == "$state" ]] || fail "$kind: $how: lore changed HEAD, the index, the work tree or the sequencer"
    [[ "$(git -C "$PH" rev-parse main)" == "$hubbefore" ]] || fail "$kind: $how: the hub changed"
  done
  [[ "$(fails_of "$PX")" == "$failsbefore" ]] || fail "$kind: a refused run counted as a failed push"
  [[ $kind == revert ]] || git -C "$PX" commit -q -m "fixture resolved"   # the owner commits the first pick, then continues with the second
  git -C "$PX" -c core.editor=true "$kind" --continue >/dev/null 2>&1 || true
  [[ ! -e "$PX/.git/sequencer" && -n "$(git -C "$PX" diff --cached --name-only)" ]] || fail "$kind: the owner's continue left the sequencer, or applied nothing"
  [[ $kind == cherry-pick ]] || git -C "$PX" commit -q -m "fixture second revert"   # the last no-commit revert keeps REVERT_HEAD until committed
  ok lx store run --trigger test:SessionEnd --force   # finished: the next run goes on
  ! grep -q 'unfinished git' "$log" || fail "$kind: lore still refused after the owner's continue"
  grep -qE " store-run: hub: pushed to $PH\$" "$log" || fail "$kind: the run after the owner's continue did not push"
  [[ "$(git -C "$PH" show main:conflict.txt)" == "owner resolution" ]] || fail "$kind: the owner's resolution is not on the hub"
  if [[ $kind == cherry-pick ]]; then [[ "$(git -C "$PH" show main:pending.txt)" == "pending" ]] || fail "$kind: the second pick is not on the hub"
  else ! git -C "$PH" cat-file -e main:pending.txt 2>/dev/null || fail "$kind: the second revert is not on the hub"; fi
done
# aborting ends it just the same
pair sequencer-abort
printf 'base\n' > "$PX/conflict.txt"; git -C "$PX" add -- conflict.txt; git -C "$PX" commit -q -m "fixture base"
ok lx store commit
git -C "$PX" checkout -q -b fixture-side
printf 'side\n' > "$PX/conflict.txt"; git -C "$PX" commit -q -am "fixture first pick"; first="$(git -C "$PX" rev-parse HEAD)"
printf 'pending\n' > "$PX/pending.txt"; git -C "$PX" add -- pending.txt; git -C "$PX" commit -q -m "fixture second pick"; second="$(git -C "$PX" rev-parse HEAD)"
git -C "$PX" checkout -q main
printf 'local\n' > "$PX/conflict.txt"; git -C "$PX" commit -q -am "fixture local"
git -C "$PX" cherry-pick --no-commit "$first" "$second" >/dev/null 2>&1 || true
printf 'owner resolution\n' > "$PX/conflict.txt"; git -C "$PX" add -- conflict.txt
git -C "$PX" cherry-pick --abort
ok lx store run --trigger test:SessionEnd --force
! grep -q 'unfinished git' "$log" || fail "lore still refused after the owner's abort"
[[ "$(git -C "$PH" show main:conflict.txt)" == "local" && ! -e "$PH/pending.txt" ]] || fail "the aborted pick reached the hub"

echo "test-hub: all checks passed"
