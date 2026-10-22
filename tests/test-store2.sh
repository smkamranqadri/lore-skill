#!/usr/bin/env bash
# lore 2.0 store tests: init, plain rule files and sidecars, hand edits, the index, commits, the
# secret scan, headless git under a hostile global config, setup and the `lore` shim.
# Temporary HOME; git never sees a global config except the hostile one built here.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
scripts="$repo_root/skills/lore/scripts"
lore="$scripts/lore.py"
tmp="$(mktemp -d)"
trap '[[ -n "${KEEP:-}" ]] || rm -rf "$tmp"' EXIT
export HOME="$tmp/home"; mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset LORE_STORE LORE_STORE2 LORE_GH_CMD LORE_GIT_TIMEOUT 2>/dev/null || true
log="$tmp/log"; S="$tmp/store"
fail() { echo "FAIL: $*" >&2; echo "--- last output ---" >&2; cat "$log" >&2 || true; exit 1; }
ok()   { "$@" >"$log" 2>&1 || fail "$* exited non-zero"; }
L() { python3 "$lore" --store2 "$S" "$@"; }
has() { grep -qxF -- "$1" "$log" || fail "${2:-output lacks the line: $1}"; }
py() { (cd "$scripts" && python3 -c "import sys, lore; sys.modules.setdefault('lore', lore); import lore_store; $1"); }

# 1. init: layout, rule files, sidecars, attributes, local identity, one commit.
ok L --today 2026-10-01 store init
has "created the lore 2.0 store at $S"
for f in core.md profile.md .lore/layout.json .lore/config .lore/meta/core.json .lore/meta/profile.json \
         .gitattributes .gitignore how-i-work/.gitkeep preferences/.gitkeep safety/.gitkeep stack/.gitkeep gotchas/.gitkeep; do
  [[ -f "$S/$f" ]] || fail "init did not create $f"
done
[[ "$(git -C "$S" ls-files | wc -l | tr -d ' ')" == 13 ]] || fail "init tracked other than 13 files"
[[ "$(git -C "$S" rev-list --count HEAD)" == 1 ]] || fail "init made other than one commit"
[[ "$(git -C "$S" log -1 --format='%an <%ae>|%s')" == "lore <lore@localhost>|new lore store" ]] || fail "first commit identity or subject"
[[ "$(git -C "$S" config --local user.name)" == lore ]] || fail "no local identity"
[[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["top"])' "$S/.lore/layout.json")" == \
   "['profile.md', 'how-i-work/', 'preferences/', 'safety/', 'stack/', 'gotchas/']" ]] || fail "default layout"
[[ "$(git -C "$S" check-attr merge -- core.md gotchas/git.md .lore/meta/gotchas/git.json .lore/layout.json | cut -d' ' -f3)" == \
   "$(printf 'lore-rules\nlore-rules\nlore-meta\nlore-layout')" ]] || fail "merge attributes"
git -C "$S" check-ignore -q INDEX.md || fail "INDEX.md is tracked"
grep -qE '^m-[0-9a-f]{8}$' "$S/.git/lore/machine" || fail "no machine id outside git"
[[ ! -d "$S/.git/hooks" ]] || fail "init copied hook templates"
ok L store init
has "store already initialised at $S"
mkdir -p "$tmp/occupied"; echo x > "$tmp/occupied/notes.txt"
if python3 "$lore" --store2 "$tmp/occupied" store init >"$log" 2>&1; then fail "init took over a non-empty folder"; fi
has "Error: $tmp/occupied exists and is not a lore store; move it aside first"

# 2. A hand edit: adopted with an id, flagged, reported; rule files keep no metadata.
mkdir -p "$S/gotchas"
printf '# Git\n\n- Never force-push a shared branch.\n- Read the diff before committing.\n' > "$S/gotchas/git.md"
printf -- '- Run the real command before claiming done.\n' >> "$S/core.md"
ok L --today 2026-10-02 store status
has "unmatched hand edit: core.md [$(py "print(lore_store.new_id('Run the real command before claiming done.', set()))")] Run the real command before claiming done."
[[ "$(grep -c '^unmatched hand edit: ' "$log")" == 3 ]] || fail "status did not report exactly 3 hand edits"
has "no read_when: gotchas/git.md (listed with a plain line)"
has "rule files: 3 (core rules: 1)"
python3 - "$S/.lore/meta/gotchas/git.json" <<'PY' || fail "sidecar entry for a hand edit"
import json, sys
d = json.load(open(sys.argv[1]))
e = [r for r in d["rules"].values() if r["text"] == "Never force-push a shared branch."]
assert len(d["rules"]) == 2 and len(e) == 1, d
e = e[0]
assert (e["created"], e["hand_edit"], e["count"], e["dates"], e["explicit"], e["confidence"], e["sessions"]) == \
    ("2026-10-02", "2026-10-02", 1, ["2026-10-02"], True, 0.6, []), e
assert d["reads"] == {} and d["last_read"] == {}, d
PY
ok L store commit
has "committed $(git -C "$S" rev-parse --short HEAD): edit core.md; add gotchas/git.md"
has "hub: none (local git only)"
# Status again: the same lines keep their ids; nothing is re-adopted, nothing is left to commit.
ids_before="$(python3 -c 'import json,sys; print(sorted(json.load(open(sys.argv[1]))["rules"]))' "$S/.lore/meta/gotchas/git.json")"
ok L store status
has "uncommitted: none"
[[ "$(python3 -c 'import json,sys; print(sorted(json.load(open(sys.argv[1]))["rules"]))' "$S/.lore/meta/gotchas/git.json")" == "$ids_before" ]] || fail "ids changed on a second pass"
# A removed line drops its entry; a line that is not a rule is reported, never adopted.
printf '# Git\n\n- Never force-push a shared branch.\nsome prose\n' > "$S/gotchas/git.md"
ok L store status
has "not a rule line: gotchas/git.md:4"
[[ "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["rules"]))' "$S/.lore/meta/gotchas/git.json")" == 1 ]] || fail "a removed line kept its entry"
printf '# Git\n\n- Never force-push a shared branch.\n' > "$S/gotchas/git.md"
ok L store commit -m "drop a git rule"
has "committed $(git -C "$S" rev-parse --short HEAD): drop a git rule"

# 3. Agent-visible rule files carry no metadata: a title, rule lines and blank lines only.
for f in $(cd "$S" && git ls-files '*.md'); do
  bad="$(grep -nvE '^(# .+|- .+|)$' "$S/$f" || true)"
  [[ -z "$bad" ]] || fail "$f has a line that is not a title or a rule: $bad"
  grep -qE '<!--|Confidence:|id=' "$S/$f" && fail "$f carries metadata"
done

# 4. The index: core rules, then one read-when line per topic file, under the budget.
py "
import json; s = lore_store.Store2('$S'); m = lore_store.load_meta(s, 'gotchas/git.md')
m['read_when'] = 'you run git'; lore_store.save_meta(s, 'gotchas/git.md', m)"
cat > "$tmp/index.want" <<EOF
# lore memory
<!-- built by lore from core.md and .lore/; edit those, not this -->

Core rules:
- Run the real command before claiming done.

Read when (files in $S):
- \`profile.md\`: read when you need to know who the user is (0)
- \`gotchas/git.md\`: read when you run git (1)
EOF
ok L store index
has "INDEX.md $(( ($(wc -c < "$tmp/index.want") + 3) / 4 )) tokens (budget 1500)"
cmp -s "$S/INDEX.md" "$tmp/index.want" || { diff "$tmp/index.want" "$S/INDEX.md" >"$log" || true; fail "INDEX.md differs"; }
# Over the budget: core rules are cut at the budget, the rest counted, every read-when line kept.
for i in $(seq 10 49); do printf -- '- Core rule number %s with enough words to fill part of a small budget.\n' "$i" >> "$S/core.md"; done
printf 'budget: 300\n' >> "$S/.lore/config"
ok L store index
kept="$(grep -c '^- Core rule number' "$S/INDEX.md")"
has "over budget: $((40 - kept)) core rule(s) left out of the index"
(( kept > 0 && kept < 40 )) || fail "the budget kept $kept of 40 core rules"
size="$(wc -c < "$S/INDEX.md")"
(( size <= 1200 && size + 73 > 1200 )) || fail "index is $size chars: over 300 tokens, or room was left for another rule"
grep -qxF -- '- `gotchas/git.md`: read when you run git (1)' "$S/INDEX.md" || fail "a read-when line was cut for core rules"
git -C "$S" checkout -q -- core.md .lore/config
ok L store commit
has "committed $(git -C "$S" rev-parse --short HEAD): metadata of gotchas/git.md"

# 5. The secret scan refuses the commit, names the file, never prints the match, stages nothing.
head="$(git -C "$S" rev-parse HEAD)"
printf -- '- Use api_key: fixtureSECRETvalue123 for the fixture service.\n' >> "$S/gotchas/git.md"
if L store commit >"$log" 2>&1; then fail "a secret was committed"; fi
has "Error: refused to commit: a secret-looking string in .lore/meta/gotchas/git.json, gotchas/git.md (not shown); remove it and commit again"
grep -q fixtureSECRET "$log" && fail "the secret was printed"
[[ "$(git -C "$S" rev-parse HEAD)" == "$head" ]] || fail "HEAD moved after a refused commit"
[[ -z "$(git -C "$S" diff --cached --name-only)" ]] || fail "a refused commit left files staged"
git -C "$S" grep -q fixtureSECRET HEAD -- . && fail "the secret reached a commit"
git -C "$S" checkout -q -- gotchas/git.md
ok L store commit
has "nothing to commit"

# 6. Merge policy, unit level: rules by line, sidecars per rule and field, reads per machine.
py "
o = '# Git\n\n- keep\n- gone on a\n'
a = '# Git\n\n- keep\n- new on a\n'
b = '# Git\n\n- keep\n- gone on a\n- new on b\n'
assert lore_store.merge_rule_text(o, a, b) == '# Git\n\n- keep\n- new on a\n- new on b\n', repr(lore_store.merge_rule_text(o, a, b))
r = lambda **k: dict(dict(text='x', count=2, dates=['2026-10-01'], sessions=[], created='2026-10-01', updated='t1', confidence=0.6, explicit=False), **k)
O = {'rules': {'r1': r(), 'r2': r(text='y')}, 'reads': {'m-1': 3}, 'last_read': {'m-1': '2026-10-01'}}
A = {'rules': {'r1': r(count=3, dates=['2026-10-01', '2026-10-02'], updated='t2'), 'r3': r(text='z')}, 'reads': {'m-1': 5}, 'last_read': {'m-1': '2026-10-02'}}
B = {'rules': {'r1': r(count=4, confidence=0.75, updated='t3'), 'r2': r(text='y')}, 'reads': {'m-1': 3, 'm-2': 7}, 'last_read': {'m-1': '2026-10-01', 'm-2': '2026-10-03'}}
m = lore_store.merge_meta(O, A, B)
assert sorted(m['rules']) == ['r1', 'r3'], m['rules']
assert m['rules']['r1']['count'] == 5 and m['rules']['r1']['confidence'] == 0.75, m['rules']['r1']
assert m['rules']['r1']['dates'] == ['2026-10-01', '2026-10-02'] and m['rules']['r1']['updated'] == 't3', m['rules']['r1']
assert m['reads'] == {'m-1': 5, 'm-2': 7} and m['last_read'] == {'m-1': '2026-10-02', 'm-2': '2026-10-03'}, m
" >"$log" 2>&1 || fail "merge policy units"
# A git error that carries a credential in a URL never prints it.
py "print(lore_store.clean_err(\"fatal: unable to access 'https://fixture-user:fixtureTOKEN42@example.invalid/m.git/': 403\"))" >"$log" 2>&1
has "fatal: unable to access 'https://***@example.invalid/m.git/': 403" "a credential in a git error was printed"

# 7. Headless git: a hostile global config (signing on, a hooks path, an askpass, no identity, a
# template with hooks) and no terminal; init, commit and a push to a local bare hub still work.
mkdir -p "$tmp/bin" "$tmp/hooks" "$tmp/tmpl/hooks"
printf '#!/bin/sh\necho ran >> "%s/hang.log"; sleep 60\n' "$tmp" > "$tmp/bin/hang"
for h in pre-commit commit-msg post-commit pre-push pre-rebase post-checkout; do
  printf '#!/bin/sh\necho %s >> "%s/hooks.log"; exit 1\n' "$h" "$tmp" > "$tmp/hooks/$h"
  cp "$tmp/hooks/$h" "$tmp/tmpl/hooks/$h"
done
chmod +x "$tmp/bin/hang" "$tmp"/hooks/* "$tmp"/tmpl/hooks/*
cat > "$tmp/hostile.gitconfig" <<EOF
[commit]
	gpgsign = true
[tag]
	gpgsign = true
[push]
	gpgsign = true
[gpg]
	program = $tmp/bin/hang
[core]
	hooksPath = $tmp/hooks
	askPass = $tmp/bin/hang
	editor = $tmp/bin/hang
[user]
	useConfigOnly = true
[init]
	templateDir = $tmp/tmpl
[rebase]
	autoStash = true
EOF
git init -q --bare -b main "$tmp/hostile-hub.git"
H="$tmp/hostile-store"
start=$SECONDS
hostile() { GIT_CONFIG_GLOBAL="$tmp/hostile.gitconfig" LORE_GIT_TIMEOUT=20 setsid -w python3 "$lore" --store2 "$H" "$@" </dev/null; }
hostile store init >"$log" 2>&1 || fail "init under a hostile config"
hostile hub set "$tmp/hostile-hub.git" >"$log" 2>&1 || fail "hub set under a hostile config"
printf -- '- Prefer small commits.\n' >> "$H/core.md"
hostile store commit >"$log" 2>&1 || fail "commit and push under a hostile config"
has "hub: pushed to $tmp/hostile-hub.git"
[[ "$(git -C "$tmp/hostile-hub.git" log -1 --format=%s main)" == "edit core.md" ]] || fail "the push did not reach the hub"
[[ ! -e "$tmp/hooks.log" ]] || fail "a hook ran: $(cat "$tmp/hooks.log")"
[[ ! -e "$tmp/hang.log" ]] || fail "gpg, askpass or the editor ran"
(( SECONDS - start < 60 )) || fail "headless git took $((SECONDS - start))s"

# 8. A remote that never answers: the push fails within the timeout, with a clear error, and the
# commit stays local. A fake ssh stands in for the network and records its arguments.
printf '#!/bin/sh\necho "$@" >> "%s/ssh.log"; sleep 60\n' "$tmp" > "$tmp/bin/ssh"; chmod +x "$tmp/bin/ssh"
git -C "$S" remote add hub "ssh://fixture-host.invalid/memory.git"
printf -- '- Keep replies short.\n' >> "$S/core.md"
start=$SECONDS
if PATH="$tmp/bin:$PATH" LORE_GIT_TIMEOUT=3 setsid -w python3 "$lore" --store2 "$S" store commit </dev/null >"$log" 2>&1; then
  fail "a hanging push exited zero"
fi
(( SECONDS - start < 20 )) || fail "a hanging push took $((SECONDS - start))s"
grep -qE '^hub: push FAILED \(git fetch timed out after 3s \(no answer; nothing was prompted\)\); push failed 1 run\(s\) in a row; retried on the next run$' "$log" \
  || fail "no clear timeout error"
has "Error: committed locally; the push failed"
[[ "$(git -C "$S" log -1 --format=%s)" == "edit core.md" ]] || fail "the commit was lost with the push"
grep -q -- '-o BatchMode=yes' "$tmp/ssh.log" || fail "ssh did not run in batch mode"
pgrep -f fixture-host.invalid >/dev/null && fail "the hung ssh was left running"
git -C "$S" remote remove hub

# 9. setup: the 2.0 store, no hub without a terminal, the shim; remove takes the shim only.
H2="$tmp/home2"; mkdir -p "$H2/.claude"
setup() { HOME="$H2" LORE_STORE2= python3 "$lore" setup "$@" </dev/null; }
setup --dry-run >"$log" 2>&1 || fail "setup dry run"
grep -qxF "  lore 2.0 store $H2/.agents/lore (new)" "$log" || fail "dry run lacks the 2.0 store"
grep -qxF "  lore command   $H2/.local/bin/lore (new)" "$log" || fail "dry run lacks the shim"
[[ -e "$H2/.agents/lore" || -e "$H2/.local/bin/lore" ]] && fail "a dry run wrote something"
setup --yes >"$log" 2>&1 || fail "setup --yes"
has "lore 2.0 store created: $H2/.agents/lore"
has "hub: none (local git only); add one later with \`lore hub set <url>\`"
has "lore command: $H2/.local/bin/lore"
[[ "$(sed -n 2p "$H2/.local/bin/lore")" == '# written by lore setup; `lore.py setup --remove` deletes it' ]] || fail "shim marker"
shim_args() { python3 -c 'import shlex, sys; print(shlex.split(open(sys.argv[1]).read().splitlines()[2]))' "$1"; }
[[ "$(shim_args "$H2/.local/bin/lore")" == "['exec', 'python3', '$scripts/lore.py', '\$@']" ]] || fail "shim exec line"
[[ -x "$H2/.local/bin/lore" ]] || fail "shim not executable"
HOME="$H2" "$H2/.local/bin/lore" store status >"$log" 2>&1 || fail "the shim does not run lore"
has "store: $H2/.agents/lore"
setup --remove --yes >"$log" 2>&1 || fail "setup --remove"
has "lore command removed: $H2/.local/bin/lore"
[[ ! -e "$H2/.local/bin/lore" ]] || fail "remove left the shim"
[[ -d "$H2/.agents/lore/.git" ]] || fail "remove deleted the 2.0 store"
printf '#!/bin/sh\necho mine\n' > "$H2/.local/bin/lore"; cp "$H2/.local/bin/lore" "$tmp/foreign"
setup --yes >"$log" 2>&1 || fail "setup over a foreign shim"
has "lore command: kept your existing $H2/.local/bin/lore (not written by lore)"
setup --remove --yes >"$log" 2>&1 || fail "remove with a foreign shim"
has "lore command: kept $H2/.local/bin/lore (not written by lore)"
cmp -s "$H2/.local/bin/lore" "$tmp/foreign" || fail "a file lore did not write was changed"
git init -q --bare -b main "$tmp/setup-hub.git"
setup --yes --hub "$tmp/setup-hub.git" >"$log" 2>&1 || fail "setup --hub"
has "hub set: $tmp/setup-hub.git (test push ok)"
[[ "$(git -C "$tmp/setup-hub.git" rev-list --count main)" == 1 ]] || fail "setup --hub did not push"

# 10. Review fixes.
# F1: the scan reads every staged blob: binary content is refused (the store is text), and a secret
# in a file git would only call binary or in any staged text file is refused too, never printed.
head="$(git -C "$S" rev-parse HEAD)"
printf '\0api_key: fixtureBINARYvalue99\n' > "$S/fixture.bin"
printf '\0\1\2' > "$S/plain.bin"
printf 'token = fixtureTEXTvalue77\n' > "$S/notes.txt"
cp "$S/fixture.bin" "$tmp/fixture.bin.orig"
if L store commit >"$log" 2>&1; then fail "binary or secret files were committed"; fi
has "Error: refused to commit: binary content in fixture.bin, plain.bin; a secret-looking string in notes.txt (not shown); remove it and commit again"
grep -qE 'fixtureBINARY|fixtureTEXT' "$log" && fail "a refused value was printed"
[[ "$(git -C "$S" rev-parse HEAD)" == "$head" ]] || fail "HEAD moved after a refused binary"
[[ -z "$(git -C "$S" diff --cached --name-only)" ]] || fail "a refused binary was left staged"
cmp -s "$S/fixture.bin" "$tmp/fixture.bin.orig" || fail "a refused file was changed"
rm "$S/fixture.bin" "$S/plain.bin" "$S/notes.txt"

# F5: the same rule twice in one file: no crash, one entry, reported, and the commit goes through.
printf -- '- Prefer small commits.\n- Prefer small commits.\n' >> "$S/core.md"
ok L store status
has "duplicate rule: core.md: Prefer small commits. (kept once in the metadata; remove the extra line)"
[[ "$(grep -c '^duplicate rule: ' "$log")" == 1 ]] || fail "the duplicate was not reported exactly once"
[[ "$(python3 -c 'import json,sys; print(sum(r["text"] == "Prefer small commits." for r in json.load(open(sys.argv[1]))["rules"].values()))' "$S/.lore/meta/core.json")" == 1 ]] \
  || fail "a duplicate line got two entries"
ok L store commit
sed -i '/^- Prefer small commits\.$/d' "$S/core.md"
ok L store commit

# F6: status shows a secret-bearing hand edit redacted, with the file and id to repair it.
printf -- '- Use api_key: fixtureSTATUSvalue55 for the fixture service.\n' >> "$S/core.md"
ok L store status
has "unmatched hand edit: core.md [$(py "print(lore_store.new_id('Use api_key: fixtureSTATUSvalue55 for the fixture service.', set()))")] Use [REDACTED] for the fixture service."
grep -q fixtureSTATUS "$log" && fail "status printed a secret"
git -C "$S" checkout -q -- core.md .lore/meta/core.json

# F7: the budget covers the whole index; read-when lines that alone do not fit are an error, the
# index is not written, and commits still go through.
B7="$tmp/budget-store"
ok python3 "$lore" --store2 "$B7" store init
for i in $(seq 1 12); do printf '# Topic\n\n- Prefer small commits.\n' > "$B7/gotchas/topic-$i.md"; done
printf 'budget: 80\n' >> "$B7/.lore/config"
cp "$B7/INDEX.md" "$tmp/index.before"
if python3 "$lore" --store2 "$B7" store index >"$log" 2>&1; then fail "an index over the budget was written"; fi
grep -qxE 'Error: the index needs [0-9]+ tokens without any core rule, over the budget of 80; raise `budget:` in \.lore/config or merge topic files' "$log" \
  || fail "no actionable budget error"
(( $(sed -E 's/.*needs ([0-9]+) tokens.*/\1/' "$log") > 80 )) || fail "the reported need is not over the budget"
cmp -s "$B7/INDEX.md" "$tmp/index.before" || fail "INDEX.md was rewritten over the budget"
python3 "$lore" --store2 "$B7" store commit >"$log" 2>&1 || fail "a commit failed because of the index"
grep -qxE 'index not written: the index needs [0-9]+ tokens without any core rule, over the budget of 80; .*' "$log" || fail "commit did not report the index"
grep -qE '^committed [0-9a-f]+: ' "$log" || fail "the commit did not go through"
python3 "$lore" --store2 "$B7" store status >"$log" 2>&1 || fail "status with an index over budget"
grep -qxE 'index: FAILED, not written: the index needs [0-9]+ tokens without any core rule, over the budget of 80; .*' "$log" || fail "status did not report the index failure"
[[ "$(wc -c < "$B7/INDEX.md")" -le 320 ]] || fail "an index over 80 tokens exists"

# F8: newer wins by the instant, not the string: 09:00 UTC is later than 12:00+05:00.
py "
o = {'text': 'x', 'updated': '2026-10-22T00:00:00+00:00', 'confidence': 0.6}
a = dict(o, updated='2026-10-23T12:00:00+05:00', confidence=0.7)
b = dict(o, updated='2026-10-23T09:00:00+00:00', confidence=0.8)
for x, y in ((a, b), (b, a)):
    m = lore_store.merge_rule(o, x, y)
    assert (m['confidence'], m['updated']) == (0.8, '2026-10-23T09:00:00+00:00'), m
same_a = dict(o, updated='2026-10-23T12:00:00+05:00', confidence=0.7)
same_b = dict(o, updated='2026-10-23T07:00:00+00:00', confidence=0.9)
assert lore_store.merge_rule(o, same_a, same_b)['confidence'] == lore_store.merge_rule(o, same_b, same_a)['confidence']
mo = {'read_when': 'old', 'read_when_updated': '2026-10-22T00:00:00+00:00', 'rules': {}}
ma = dict(mo, read_when='earlier', read_when_updated='2026-10-23T12:00:00+05:00')
mb = dict(mo, read_when='later', read_when_updated='2026-10-23T09:00:00+00:00')
assert lore_store.merge_meta(mo, ma, mb)['read_when'] == 'later' == lore_store.merge_meta(mo, mb, ma)['read_when']
assert lore_store.now_iso().endswith('+00:00')
" >"$log" 2>&1 || fail "newer-wins does not compare instants"

# F9: the shim runs lore from a skill folder with and without a space in its path.
for d in "$tmp/plain" "$tmp/with space"; do
  mkdir -p "$d"; cp -R "$repo_root/skills/lore" "$d/lore"; find "$d/lore" -name __pycache__ -prune -exec rm -rf {} +
  sh="$d/home"; mkdir -p "$sh"
  (cd "$d/lore/scripts" && HOME="$sh" python3 -c "import sys, lore; sys.modules['lore'] = lore; import lore_hub; lore_hub.write_shim()") >"$log" 2>&1 || fail "write_shim in $d"
  [[ "$(shim_args "$sh/.local/bin/lore")" == "['exec', 'python3', '$d/lore/scripts/lore.py', '\$@']" ]] || fail "shim arguments for $d"
  HOME="$sh" "$sh/.local/bin/lore" --store2 "$d/store" store init >"$log" 2>&1 || fail "the shim did not run lore from $d"
  has "created the lore 2.0 store at $d/store"
done

echo "test-store2: all checks passed"
