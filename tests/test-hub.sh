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

echo "test-hub: all checks passed"
