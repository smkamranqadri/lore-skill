#!/usr/bin/env bash
# lore 2.0 P5a eval tests: `lore eval loremaster|canon` on the frozen fixture with fake models only.
# The fixture's hash is pinned (a changed fixture fails, and a change needs the owner). A fake
# Loremaster that answers perfectly meets every bar with exact n/d; fakes that misfile, link
# nothing, dump one file, skip rules, or reply with prose or an error miss the right bar or exit 2
# and still write a report; each threshold is held at its boundary (54/60 and 16/20 pass, 53/60
# and 15/20 miss); the meaning spot-check lists the same 15 ids every run; Canon's fake fixes each
# gate, only proposes retirements (reported in Inbox), or does nothing. The owner's store is
# hash-compared before and after, a path that is or holds a store is refused, and every model call
# is recorded. Never a real model, never the network: LORE_LOREMASTER_CMD and LORE_CANON_CMD are
# fakes, HOME is temporary, git runs with no global config.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap '[[ -n "${KEEP:-}" ]] || rm -rf "$tmp"' EXIT
export HOME="$tmp/home"; mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 PYTHONDONTWRITEBYTECODE=1
unset LORE_STORE LORE_STORE2 LORE_GH_CMD LORE_GIT_TIMEOUT LORE_SYNC_CMD LORE_EXTRACT_CMD LORE_REVIEW_CMD \
  LORE_LOREMASTER_CMD LORE_CANON_CMD LORE_MODEL_TIMEOUT 2>/dev/null || true
export TMPDIR="$tmp/tmpdir"; mkdir -p "$TMPDIR"

lore="$repo_root/skills/lore/scripts/lore.py"
fixture="$repo_root/tests/fixtures/eval"
FIXTURE_SHA="f28910751f19e8527e6f2f32ac2b2f622e9a804eee727e44306eb524f07e97e1"
fail() { echo "FAIL: $*" >&2; exit 1; }
want() { [[ "$1" == "$2" ]] || fail "$3: got [$1], want [$2]"; }

# ---- the fakes --------------------------------------------------------------------------------

# A fake Loremaster: one line per call in $FAKE_CALLS, then it files the fixture's rules as
# FAKE_LM says (perfect, scatter, nolinks, droplinks:K, dump, gotchas, misfile:K, skip:K, prose, fail, reject).
cat > "$tmp/fake-lm.py" <<'FAKE'
#!/usr/bin/env python3
import json, os, re, sys

mode = os.environ.get("FAKE_LM", "perfect")
with open(os.environ["FAKE_CALLS"], "a") as f:
    f.write(mode + "\n")
if mode == "prose":
    print("I looked at your memory and it all seems fine to me.")
    sys.exit(0)
if mode == "fail":
    print("loremaster exploded", file=sys.stderr)
    sys.exit(3)
if mode == "reject":
    print(json.dumps({"ops": [{"op": "invented"}]}))
    sys.exit(0)
prompt = open(os.environ["LORE_PROMPT_FILE"]).read()
assert '"folder"' not in prompt and '"related"' not in prompt and 'near-duplicate' not in prompt
key = json.load(open(os.environ["FAKE_KEY"]))
by_text = {r["text"]: r for r in key}
by_id = {r["id"]: r for r in key}
items = [json.loads(l.split(". ", 1)[1]) for l in prompt.split("## Items to file")[1].strip().splitlines()
         if re.match(r"\d+\. ", l)]
have = re.search(r"Topic files now: (.*)", prompt).group(1)
existing = set(re.findall(r"`([^`]+\.md)`", have))
kind = mode.split(":")[0]
arg = int(mode.split(":")[1]) if ":" in mode else 0

parent = {r["id"]: r["id"] for r in key}
def find(i):
    while parent[i] != i:
        i = parent[i]
    return i
for r in key:
    for o in r["related"]:
        parent[find(r["id"])] = find(o)
members = {}
for r in key:
    members.setdefault((r["folder"], find(r["id"])), []).append(r["id"])
pairs = sorted({tuple(sorted((r["id"], o))) for r in key for o in r["related"]})

def file_for(r):
    folder = r["folder"]
    if folder == "profile.md":
        return "profile.md"
    if kind in ("scatter", "nolinks", "droplinks"):
        return f"{folder}/{r['id']}.md"
    if kind == "dump":
        return "gotchas/dump.md"
    group = members[(folder, find(r["id"]))]
    slug = f"topic-{min(group)}" if len(group) > 1 else "general"
    if kind == "misfile" and folder == "how-i-work" and int(r["id"][1:]) <= arg:
        return "gotchas/misfiled.md"
    if kind == "gotchas":
        return f"gotchas/{folder.replace('.md', '')}-{slug}.md"
    return f"{folder}/{slug}.md"

ops, created = [], set()
for it in items:
    r = by_text[it["text"]]
    if kind == "duplicates" and r["id"] in ("r02", "r11", "r25"):
        continue
    if kind == "skip" and int(r["id"][1:]) <= arg:
        continue
    f = file_for(r)
    ops.append({"op": "add", "file": f, "text": r["text"], "explicit": it["explicit"], "quote": r["text"],
                "session": "eval"})
    if f not in existing and f not in created:
        created.add(f)
        ops.append({"op": "describe", "file": f, "read_when": "you work on " + f[:-3].replace("/", " ")})
if kind not in ("nolinks", "dump"):
    here = existing | created
    for n, (a, b) in enumerate(pairs):
        fa, fb = file_for(by_id[a]), file_for(by_id[b])
        if kind == "droplinks" and n < arg:
            continue
        if fa != fb and fa in here and fb in here:
            ops.append({"op": "link", "file": fa, "to": fb})
reply = {"ops": ops, "answer": f"filed {len(items)}"}
if kind == "duplicates":
    duplicates = []
    for n, it in enumerate(items, 1):
        r = by_text[it["text"]]
        if r["id"] == "r02":
            duplicates.append({"input": n, "earlier_input": 1})
        if r["id"] == "r25":
            duplicates.append({"input": n, "earlier_input": 1})
        if r["id"] == "r11":
            blocks = re.split(r"(?m)^### ", prompt.split("## Topic files nearest")[1].split("## Items to file")[0])
            shown = [(b.splitlines()[0], m.group(1)) for b in blocks[1:] for m in [re.search(r"(?m)^- \[([0-9a-f]{8})\] ", b)] if m]
            assert shown, "previous batch rule is shown"
            duplicates.append({"input": n, "file": shown[0][0], "rule_id": shown[0][1]})
    reply["duplicates"] = duplicates
out = json.dumps(reply)
with open(os.environ["FAKE_CALLS"] + ".sizes", "a") as f:   # characters in and out, for the token estimate
    f.write(f"{len(prompt)} {len(out) + 1}\n")
print(out)
FAKE
chmod +x "$tmp/fake-lm.py"

# A fake Canon: one line per call, then the reply FAKE_CANON asks for.
cat > "$tmp/fake-canon.sh" <<'FAKE'
#!/usr/bin/env bash
echo "${FAKE_CANON:-reply}" >> "$FAKE_CALLS"
case "${FAKE_CANON:-reply}" in
  reply) cp "$LORE_PROMPT_FILE" "$tmp_canon_prompt"; cat "$FAKE_CANON_REPLY" ;;
  none) printf '{"ops": [], "answer": "nothing to do"}\n' ;;
  bad-ops) printf '{"ops": [{"op": "add", "file": "stack/x.md", "text": "Invented.", "explicit": true, "quote": "q", "session": ""}]}\n' ;;
  prose) echo "Everything looks fine to me." ;;
  fail) echo "canon exploded" >&2; exit 3 ;;
esac
FAKE
chmod +x "$tmp/fake-canon.sh"

# The fix for each gate of the Canon fixture, as Canon's operations (ids read from the fixture's sidecars).
cat > "$tmp/mkreply.py" <<'FAKE'
import json, os, sys
fx, which = sys.argv[1], sys.argv[2]
def meta(rel):
    return json.load(open(os.path.join(fx, "canon/.lore/meta", rel[:-3] + ".json")))
def rid(rel, text):
    hits = [i for i, e in meta(rel)["rules"].items() if e["text"] == text]
    assert len(hits) == 1, (rel, text)
    return hits[0]
def texts(rel):
    return [e["text"] for e in meta(rel)["rules"].values()]
short = ["Answer questions before changing anything.", "Keep replies short, verdict first.",
         "Never write to production without my go-ahead.", "Verify every claim yourself before repeating it.",
         "Do exactly the scope I named.", "Never print any part of a secret."]
tarn = [rid("gotchas/tarnwell.md", t) for t in texts("gotchas/tarnwell.md")]
dup = [t for t in texts("gotchas/mossdb.md") if t.endswith("itself.")][0]
A = "Ask me one question at a time and wait for my answer before asking the next."
ops = {
 "contradiction": [{"op": "retire", "rule_id": rid("how-i-work/questions.md", A), "reason": "the batch rule stands"}],
 "core-budget": [{"op": "reword", "rule_id": rid("core.md", t), "text": s} for t, s in zip(texts("core.md"), short)],
 "broken-link": [{"op": "unlink", "file": "gotchas/quillbar.md", "to": "gotchas/quillbar-legacy.md"}],
 "orphan": [{"op": "describe", "file": "gotchas/harbourlight.md", "read_when": "you restart or probe Harbourlight apps"}],
 "duplicate": [{"op": "retire", "rule_id": rid("gotchas/mossdb.md", dup), "reason": "it repeats the rule before it"}],
 "oversized": [{"op": "split", "file": "gotchas/tarnwell.md", "into": [
                   {"file": "gotchas/tarnwell.md", "rule_ids": tarn[:13]},
                   {"file": "gotchas/tarnwell-limits.md", "rule_ids": tarn[13:]}]},
               {"op": "describe", "file": "gotchas/tarnwell-limits.md", "read_when": "a Tarnwell limit or quota bites"},
               {"op": "link", "file": "gotchas/tarnwell.md", "to": "gotchas/tarnwell-limits.md"}],
 # the same fixes, but the finding only moves: every Tarnwell rule to one renamed file (still 26 rules), the
 # clashing Mossdb pair to a new file with its retirement waiting there
 "oversized-moved": [{"op": "split", "file": "gotchas/tarnwell.md", "into": [{"file": "gotchas/tarnwell-renamed.md", "rule_ids": tarn}]},
                     {"op": "describe", "file": "gotchas/tarnwell-renamed.md", "read_when": "you change Tarnwell quotas"}],
 "duplicate-moved": [{"op": "split", "file": "gotchas/mossdb.md", "into": [
                         {"file": "gotchas/mossdb.md", "rule_ids": [rid("gotchas/mossdb.md", t) for t in texts("gotchas/mossdb.md") if "now()" not in t]},
                         {"file": "gotchas/mossdb-now.md", "rule_ids": [rid("gotchas/mossdb.md", t) for t in texts("gotchas/mossdb.md") if "now()" in t]}]},
                     {"op": "describe", "file": "gotchas/mossdb-now.md", "read_when": "you rely on Mossdb now()"},
                     {"op": "link", "file": "gotchas/mossdb.md", "to": "gotchas/mossdb-now.md"},
                     {"op": "retire", "rule_id": rid("gotchas/mossdb.md", dup), "reason": "it repeats the rule before it"}],
 # a second near-duplicate pair in the seeded file: the migration and connection-pool rules reworded
 # into the same sentence, beside the retirement that covers only the first pair
 "duplicate-pair": [{"op": "reword", "rule_id": rid("gotchas/mossdb.md", "A Mossdb migration that adds an index locks the table; build the index concurrently on large tables."),
                     "text": "Mossdb backup restores require an explicit snapshot label before the recovery begins."},
                    {"op": "reword", "rule_id": rid("gotchas/mossdb.md", "Mossdb connection pools default to ten connections, which the Marrow API exhausts during the nightly import."),
                     "text": "Mossdb backup restores require an explicit snapshot label before the recovery begins itself."}],
 "thin": [{"op": "merge", "from": "gotchas/fennec-snapshots.md", "to": "gotchas/fennec.md"}],
 "stale": [{"op": "merge", "from": "gotchas/brindle-cache.md", "to": "gotchas/brindle.md"}],
}
sel = [g for g in ops if not g.endswith(("-moved", "-pair"))] if which == "all" else which.split(",")
print(json.dumps({"ops": [o for g in sel for o in ops[g]], "answer": "fixed"}))
FAKE
cat > "$tmp/j.py" <<'FAKE'
import json, sys
print(eval(sys.argv[2], {"d": json.load(open(sys.argv[1]))}))
FAKE
export LORE_LOREMASTER_CMD="$tmp/fake-lm.py" LORE_CANON_CMD="$tmp/fake-canon.sh"
export tmp_canon_prompt="$tmp/canon-prompt"
export FAKE_CALLS="$tmp/calls" FAKE_KEY="$fixture/rules.json" FAKE_CANON_REPLY="$tmp/reply.json"

j() { python3 "$tmp/j.py" "$@"; }
bars() { j "$1/report.json" "{k: (b['n'], b['d'], b['met']) for k, b in d['bars'].items()}"; }
pairs() { j "$1/report.json" "[(s, sum(p['status'] == s for p in d['pairs'])) for s in ('same file', 'linked', 'not linked', 'unfiled')]"; }
gates() { j "$1/report.json" "{g: d['gates'][g]['status'] for g in ['contradiction', 'core-budget', 'broken-link', 'orphan', 'duplicate', 'oversized', 'thin', 'stale']}"; }
ncalls() { wc -l < "$FAKE_CALLS" | tr -d ' '; }
treehash() { (cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1); }
reply() { python3 "$tmp/mkreply.py" "$fixture" "$1" > "$FAKE_CANON_REPLY"; }
# ev <name> <loremaster|canon> [args]: one eval into $tmp/out-<name>; its exit code in $rc, calls reset first
ev() {
  local name="$1"; shift
  : > "$FAKE_CALLS"; : > "$FAKE_CALLS.sizes"; rc=0
  python3 "$lore" eval "$@" --out "$tmp/out-$name" > "$tmp/log-$name" 2> "$tmp/err-$name" || rc=$?
}
lm() { local mode="$1" name="$2"; shift 2; FAKE_LM="$mode" ev "$name" loremaster "$@"; }
cn() { local mode="$1" name="$2"; shift 2; FAKE_CANON="$mode" ev "$name" canon "$@"; }

# ---- the frozen fixture -----------------------------------------------------------------------

echo "-- attribution edge cases and exact index deficit"
python3 "$repo_root/tests/test-eval-attribution.py"

echo "-- frozen fixture"
got="$(cd "$fixture" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)"
[[ "$got" == "$FIXTURE_SHA" ]] || fail "the eval fixture is frozen: its hash changed (got $got, want $FIXTURE_SHA); a change needs the owner, and this test is not edited to follow it"
python3 - "$fixture" <<'PY'
import collections, json, sys
r = json.load(open(sys.argv[1] + "/rules.json"))
assert len(r) == 60 and len({x["id"] for x in r}) == 60, "60 rules, unique ids"
assert dict(collections.Counter(x["folder"] for x in r)) == {"how-i-work": 24, "gotchas": 21, "safety": 5,
        "preferences": 4, "stack": 3, "profile.md": 3}, "folder mix"
assert sum(x["explicit"] for x in r) == 6, "explicit rules"
assert len({tuple(sorted((x["id"], o))) for x in r for o in x["related"]}) == 20, "expected pairs"
assert sum("near-duplicate" in x.get("note", "") for x in r) == 8, "near-duplicate rules (4 pairs)"
assert sum("contradicts" in x.get("note", "") for x in r) == 4, "contradicting rules (2 pairs)"
assert all(8 <= len(x["text"].split()) <= 25 for x in r), "8 to 25 words each"
PY

# ---- a perfect Loremaster ---------------------------------------------------------------------

echo "-- perfect Loremaster"
real="$tmp/real-store"
python3 "$lore" --store2 "$real" store init > /dev/null
LORE_STORE2="$real" python3 "$lore" remember "an owner rule" > /dev/null
before="$(treehash "$real")"
export LORE_STORE2="$real"
lm perfect p1 --workdir "$tmp/kept-store"
want "$rc" 0 "perfect exit"
want "$(ncalls)" 6 "model calls (60 rules in batches of 10)"
want "$(bars "$tmp/out-p1")" "{'folder': (60, 60, True), 'meaning': (None, 15, None), 'oversized': (0, 23, True), 'related': (20, 20, True)}" "perfect bars"
want "$(pairs "$tmp/out-p1")" "[('same file', 19), ('linked', 1), ('not linked', 0), ('unfiled', 0)]" "perfect pair statuses"
want "$(j "$tmp/out-p1/report.json" "(d['status'], d['error'], d['calls'], len(d['batches']), d['unfiled'], d['rules_in_core'])")" "('ok', None, 6, 6, [], 0)" "perfect run"
want "$(j "$tmp/out-p1/report.json" "d['fixture']['sha256']")" "$FIXTURE_SHA" "the report's fixture hash"
want "$(j "$tmp/out-p1/report.json" "(d['fixture']['rules'], d['fixture']['expected_pairs'])")" "(60, 20)" "fixture counts in the report"
want "$(j "$tmp/out-p1/report.json" "(d['model']['name'], d['model']['command'] == '$tmp/fake-lm.py')")" "('override', True)" "role and command line"
want "$(j "$tmp/out-p1/report.json" "(d['tokens']['total'] > 0, d['tokens']['total'] == d['tokens']['prompt'] + d['tokens']['reply'], d['tokens']['basis'].startswith('estimate: '), d['wall_seconds'] >= 0)")" "(True, True, True, True)" "tokens are an estimate"
want "$(j "$tmp/out-p1/report.json" "(d['tokens']['prompt'], d['tokens']['reply'])")" "$(awk '{p += $1; r += $2} END {printf "(%d, %d)", int(p / 4), int(r / 4)}' "$FAKE_CALLS.sizes")" "tokens are characters over four"
grep -qx 'Result: ran' <(sed 's/^- //' "$tmp/out-p1/report.md") || fail "report.md result line"
grep -q '^| folder | 60/60 | 100.0% | at least 90% | PASS |$' "$tmp/out-p1/report.md" || fail "report.md folder row"
grep -q '^| related | 20/20 | 100.0% | at least 80% | PASS |$' "$tmp/out-p1/report.md" || fail "report.md related row"
grep -q '^| oversized | 0/23 | 0.0% | at most 0 files | PASS |$' "$tmp/out-p1/report.md" || fail "report.md oversized row"
grep -q '^| meaning | ?/15 |  | 15 of 15, judged by the owner | owner judges |$' "$tmp/out-p1/report.md" || fail "report.md meaning row"
grep -qx 'folder: 60/60 PASS' "$tmp/log-p1" || fail "stdout folder line"
[[ -d "$tmp/kept-store/.git" ]] || fail "--workdir keeps its store"
[[ ! -e "$HOME/.agents" ]] || fail "the eval wrote into HOME"
want "$(treehash "$real")" "$before" "the owner's store, hash before and after (LORE_STORE2 set)"

echo "-- eval duplicate claims remain provisional"
lm duplicates dup1
want "$rc" 0 "duplicate run exit"
want "$(j "$tmp/out-dup1/report.json" "(d['bars']['folder']['n'], d['provisional']['bars']['folder']['n'], [c['id'] for c in d['provisional']['candidates']])")" "(57, 59, ['r02', 'r11', 'r25'])" "direct and provisional folder counts"
want "$(j "$tmp/out-dup1/report.json" "[(r['id'], r['filed'], r['ok']) for r in d['provisional']['rules'] if r['id'] == 'r25']")" "[('r25', ['how-i-work/general.md'], False)]" "wrong folder remains a miss"
echo "-- temp store removed"
lm perfect p1b
want "$rc" 0 "second perfect exit"
want "$(find "$TMPDIR" -mindepth 1 | wc -l | tr -d ' ')" 0 "temporary files left in TMPDIR"
want "$(treehash "$real")" "$before" "the owner's store after the second run"

# ---- a Loremaster that links through the sidecars ---------------------------------------------

echo "-- scatter, links, no links"
lm scatter s1
want "$rc" 0 "scatter exit"
want "$(bars "$tmp/out-s1")" "{'folder': (60, 60, True), 'meaning': (None, 15, None), 'oversized': (0, 58, True), 'related': (20, 20, True)}" "scatter bars"
want "$(pairs "$tmp/out-s1")" "[('same file', 0), ('linked', 20), ('not linked', 0), ('unfiled', 0)]" "every pair linked through a sidecar"
lm nolinks n1
want "$rc" 1 "no links exit"
want "$(bars "$tmp/out-n1")" "{'folder': (60, 60, True), 'meaning': (None, 15, None), 'oversized': (0, 58, True), 'related': (0, 20, False)}" "no links bars"
want "$(pairs "$tmp/out-n1")" "[('same file', 0), ('linked', 0), ('not linked', 20), ('unfiled', 0)]" "no pair linked"
grep -q '^| related | 0/20 | 0.0% | at least 80% | FAIL |$' "$tmp/out-n1/report.md" || fail "report.md names the related fraction"
grep -qx 'related: 0/20 FAIL' "$tmp/log-n1" || fail "stdout related line"

echo "-- thresholds at their boundaries"
lm droplinks:4 d4
want "$rc" 0 "16 of 20 pairs exit"
want "$(bars "$tmp/out-d4")" "{'folder': (60, 60, True), 'meaning': (None, 15, None), 'oversized': (0, 58, True), 'related': (16, 20, True)}" "16/20 meets 80%"
lm droplinks:5 d5
want "$rc" 1 "15 of 20 pairs exit"
want "$(bars "$tmp/out-d5")" "{'folder': (60, 60, True), 'meaning': (None, 15, None), 'oversized': (0, 58, True), 'related': (15, 20, False)}" "15/20 misses 80%"
lm misfile:6 m6
want "$rc" 0 "54 of 60 rules exit"
want "$(bars "$tmp/out-m6")" "{'folder': (54, 60, True), 'meaning': (None, 15, None), 'oversized': (0, 22, True), 'related': (20, 20, True)}" "54/60 meets 90%"
lm misfile:7 m7
want "$rc" 1 "53 of 60 rules exit"
want "$(bars "$tmp/out-m7")" "{'folder': (53, 60, False), 'meaning': (None, 15, None), 'oversized': (0, 22, True), 'related': (20, 20, True)}" "53/60 misses 90%"
grep -q '^| folder | 53/60 | 88.3% | at least 90% | FAIL |$' "$tmp/out-m7/report.md" || fail "report.md names the folder fraction"
grep -q '^Folder misses (7): r01 expected how-i-work, filed gotchas/misfiled.md, r02 ' "$tmp/out-m7/report.md" || fail "report.md names the misfiled rules"

echo "-- a Loremaster that files everything under gotchas, or in one file"
lm gotchas g1
want "$rc" 1 "gotchas exit"
want "$(bars "$tmp/out-g1")" "{'folder': (24, 60, False), 'meaning': (None, 15, None), 'oversized': (0, 23, True), 'related': (20, 20, True)}" "gotchas bars (21 gotchas rules plus 3 left in profile.md)"
grep -qx 'folder: 24/60 FAIL' "$tmp/log-g1" || fail "stdout folder fraction"
lm dump u1
want "$rc" 1 "one file exit"
want "$(bars "$tmp/out-u1")" "{'folder': (24, 60, False), 'meaning': (None, 15, None), 'oversized': (1, 2, False), 'related': (20, 20, True)}" "one-file bars"
want "$(j "$tmp/out-u1/report.json" "d['oversized_files']")" "['gotchas/dump.md']" "the oversized file is named"
grep -q '^| oversized | 1/2 | 50.0% | at most 0 files | FAIL |$' "$tmp/out-u1/report.md" || fail "report.md oversized row"

echo "-- skipped rules are unfiled, not right"
lm skip:3 k3
want "$rc" 0 "skip exit"
want "$(bars "$tmp/out-k3")" "{'folder': (57, 60, True), 'meaning': (None, 15, None), 'oversized': (0, 22, True), 'related': (18, 20, True)}" "skip bars"
want "$(j "$tmp/out-k3/report.json" "d['unfiled']")" "['r01', 'r02', 'r03']" "unfiled rules"
want "$(pairs "$tmp/out-k3")" "[('same file', 17), ('linked', 1), ('not linked', 0), ('unfiled', 2)]" "pairs with an unfiled side"

# ---- failures still write a report ------------------------------------------------------------

echo "-- failed runs"
lm prose f1
want "$rc" 2 "prose exit"
want "$(ncalls)" 1 "a failed reply is not retried"
want "$(j "$tmp/out-f1/report.json" "(d['status'], d['error'], 'bars' in d, d['calls'])")" "('failed', 'ReplyError: the reply is not JSON', False, 1)" "prose report"
grep -qx -- '- Result: FAILED: ReplyError: the reply is not JSON' "$tmp/out-f1/report.md" || fail "report.md failure line"
[[ -f "$tmp/out-f1/report.json" && -f "$tmp/out-f1/report.md" && ! -e "$tmp/out-f1/spot-check.md" ]] || fail "files of a failed run"
lm reject f3
want "$rc" 2 "a rejected reply: exit"
want "$(ncalls)" 1 "a rejected Loremaster reply stops the run: one call, not six"
want "$(j "$tmp/out-f3/report.json" "(d['status'], d['calls'], len(d['batches']), len(d['rejected']), 'bars' in d, d['error'].startswith('LoreError: the validator rejected the reply to batch 1: '))")" "('failed', 1, 1, 1, False, True)" "rejected Loremaster report"
want "$(j "$tmp/out-f3/report.json" "d['rejected'] == d['batches'][0]['rejected'] and d['error'].endswith(d['rejected'][0])")" True "the rejection message is kept in report.json"
grep -q -- '^- Result: FAILED: LoreError: the validator rejected the reply to batch 1: ' "$tmp/out-f3/report.md" || fail "report.md names the rejection"
grep -q '^| 1 | 10 | - | 0 | .*invented' "$tmp/out-f3/report.md" || fail "report.md keeps the rejected batch row"
[[ ! -e "$tmp/out-f3/spot-check.md" ]] || fail "a rejected run wrote a sheet"
lm fail f2
want "$rc" 2 "failing command exit"
want "$(j "$tmp/out-f2/report.json" "(d['status'], d['error'].startswith('LoreError: the model command exited 3: '))")" "('failed', True)" "failing command report"
want "$(find "$TMPDIR" -mindepth 1 | wc -l | tr -d ' ')" 0 "temporary files left after failures"

# ---- the meaning spot-check -------------------------------------------------------------------

echo "-- spot-check sheet"
want "$(python3 - "$fixture" <<'PY'
import hashlib, json, sys
ids = [r["id"] for r in json.load(open(sys.argv[1] + "/rules.json"))]
print(sorted(ids, key=lambda i: hashlib.sha1(i.encode()).hexdigest())[:15])
PY
)" "$(j "$tmp/out-p1/report.json" "d['spot_check']")" "the 15 ids by sha1 of the id"
sheet_ids() { grep -E '^\| [0-9]+ \| r[0-9]{2} \|' "$1/spot-check.md" | cut -d'|' -f3 | tr -d ' ' | paste -sd,; }
want "$(grep -cE '^\| [0-9]+ \| r[0-9]{2} \| .+ \| .+ \|  \|$' "$tmp/out-p1/spot-check.md")" 15 "sheet rows, each with a blank yes/no"
want "$(sheet_ids "$tmp/out-p1" | tr ',' '\n' | sort -u | wc -l | tr -d ' ')" 15 "distinct ids in the sheet"
want "$(sheet_ids "$tmp/out-p1b")" "$(sheet_ids "$tmp/out-p1")" "the same 15 ids on a second run"
want "$(sheet_ids "$tmp/out-p1")" "$(j "$tmp/out-p1/report.json" "','.join(d['spot_check'])")" "sheet and report agree"
grep -q '^| 1 | r[0-9][0-9] | .* | .* (\(profile.md\|[a-z-]*/[a-z0-9-]*\.md\)) |  |$' "$tmp/out-p1/spot-check.md" || fail "a sheet row has the original beside the filed wording and its file"
grep -q 'The tool judges nothing' "$tmp/out-p1/spot-check.md" || fail "the sheet says the tool judges nothing"
want "$(sheet_ids "$tmp/out-m7")" "$(sheet_ids "$tmp/out-p1")" "the same 15 ids whatever the filing"

# ---- isolation --------------------------------------------------------------------------------

echo "-- the owner's store is never used"
other="$tmp/other-store"
python3 "$lore" --store2 "$other" store init > /dev/null
oh="$(treehash "$other")"
want "$(treehash "$real")" "$before" "owner's store before the refusals"
lm perfect r1 --workdir "$other"
want "$rc" 2 "--workdir an existing store: exit"
grep -q "^Error: refused: --workdir $other is an existing store; the eval builds its own\$" "$tmp/err-r1" || fail "--workdir existing store message: $(cat "$tmp/err-r1")"
[[ ! -e "$tmp/out-r1" ]] || fail "a refused run wrote a report"
want "$(ncalls)" 0 "a refused run makes no model call"
lm perfect r2 --workdir "$other/inside"
want "$rc" 2 "--workdir inside an existing store: exit"
grep -q "is inside the existing store" "$tmp/err-r2" || fail "--workdir inside a store message"
rc=0; python3 "$lore" eval loremaster --out "$other/reports" 2> "$tmp/err-r3" > /dev/null || rc=$?
want "$rc" 2 "--out inside an existing store: exit"
grep -q "is inside the existing store" "$tmp/err-r3" || fail "--out inside a store message"
rc=0; python3 "$lore" --store2 "$other" eval loremaster --out "$tmp/out-r4b" 2> "$tmp/err-r4b" > /dev/null || rc=$?
want "$rc" 2 "global --store2 on eval: exit"
grep -qx 'Error: refused: eval builds its own store; --store2 is not accepted' "$tmp/err-r4b" || fail "global --store2 message"
want "$(treehash "$other")" "$oh" "the other store, after the refusals"
mkdir "$tmp/occupied"; echo x > "$tmp/occupied/f"
lm perfect r5 --workdir "$tmp/occupied"
want "$rc" 2 "--workdir not empty: exit"
grep -q 'exists and is not an empty directory' "$tmp/err-r5" || fail "--workdir not empty message"
mkdir -p "$tmp/out-r7"; echo x > "$tmp/out-r7/old.json"
lm perfect r7 --batch 10
want "$rc" 2 "--out not empty: exit"
want "$(cat "$tmp/out-r7/old.json")" x "an earlier report is never overwritten"

echo "-- an owner's store that does not exist yet is never built in"
export LORE_STORE2="$tmp/no-such-store"
lm perfect o1 --workdir "$tmp/no-such-store/work"
want "$rc" 2 "--workdir inside the owner's store path: exit"
grep -q "is or is inside the owner's store; the eval builds its own\$" "$tmp/err-o1" || fail "owner's store path message: $(cat "$tmp/err-o1")"
lm perfect o2 --workdir "$tmp/no-such-store"
want "$rc" 2 "--workdir the owner's store path: exit"
rc=0; python3 "$lore" eval canon --out "$tmp/no-such-store/out" 2> "$tmp/err-o3" > /dev/null || rc=$?
want "$rc" 2 "--out inside the owner's store path: exit"
grep -q "^Error: refused: --out .* is or is inside the owner's store" "$tmp/err-o3" || fail "--out in the owner's store message"
[[ ! -e "$tmp/no-such-store" ]] || fail "the eval created the owner's store path"
export LORE_STORE2="$real"
want "$(treehash "$real")" "$before" "the owner's store after every Loremaster run"

# ---- a missing fixture ------------------------------------------------------------------------

echo "-- fixture problems"
lm perfect x1 --fixture "$tmp/no-fixture"
want "$rc" 2 "missing fixture: exit"
grep -q "^Error: no fixture at $tmp/no-fixture; run from a source clone or pass --fixture\$" "$tmp/err-x1" || fail "missing fixture message"
lm perfect x2 --batch 0
want "$rc" 2 "--batch 0: exit"
cp -r "$fixture" "$tmp/fx-dup"
python3 - "$tmp/fx-dup/rules.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1])); r[1]["id"] = "r01"
json.dump(r, open(sys.argv[1], "w"))
PY
rc=0; FAKE_LM=perfect python3 "$lore" eval loremaster --fixture "$tmp/fx-dup" --out "$tmp/out-x3" 2> "$tmp/err-x3" > /dev/null || rc=$?
want "$rc" 2 "a fixture with a duplicate id: exit"
cp -r "$fixture" "$tmp/fx-folder"
python3 - "$tmp/fx-folder/rules.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1])); r[0]["folder"] = "nowhere"
json.dump(r, open(sys.argv[1], "w"))
PY
rc=0; python3 "$lore" eval loremaster --fixture "$tmp/fx-folder" --out "$tmp/out-x4" > /dev/null 2>&1 || rc=$?
want "$rc" 2 "a fixture expecting a folder that does not exist: exit"
[[ -f "$tmp/out-x3/report.json" && -f "$tmp/out-x4/report.json" ]] || fail "a defective fixture still gets a report"
want "$(j "$tmp/out-x4/report.json" "d['error']")" "LoreError: fixture rule r01 expects a folder that does not exist: 'nowhere'" "the folder defect is reported, not patched"

# ---- Canon ------------------------------------------------------------------------------------

echo "-- Canon revision: frozen copy, correction and exact retirement"
v2="$repo_root/tests/fixtures/eval-canon-v2"
want "$(treehash "$v2")" "c7a6b485299892ead0c759b9cd7408c412e94e58d4967030eba920116b6e5082" "revised fixture hash"
cp -a "$fixture/canon" "$tmp/canon-original"
cp -a "$v2/canon" "$tmp/canon-revised"
cp "$tmp/canon-original/expect.json" "$tmp/canon-revised/expect.json"
cp "$tmp/canon-original/.lore/meta/how-i-work/questions.json" "$tmp/canon-revised/.lore/meta/how-i-work/questions.json"
diff -qr "$tmp/canon-original" "$tmp/canon-revised" > "$tmp/canon-diff" || fail "only contradiction evidence and expectation differ"
reply all
cn reply c-v2 --fixture "$v2" --workdir "$tmp/c-v2-store"
want "$rc" 0 "revised fixture exit"
want "$(bars "$tmp/out-c-v2")" "{'canon': (8, 8, True)}" "revised eight gates"
grep -Ex ' +original quote: "I changed my mind: stop asking one question at a time. Batch all your open questions into a single message so I can answer them together."' "$tmp/canon-prompt" >/dev/null || fail "Canon receives the explicit correction"
python3 - "$tmp/out-c-v2/report.json" <<'PYTEST'
import json, sys
r=json.load(open(sys.argv[1]))
assert r['gates']['contradiction']['status'] == 'in Inbox'
assert r['fixture']['sha256'] == 'c7a6b485299892ead0c759b9cd7408c412e94e58d4967030eba920116b6e5082'
PYTEST

python3 - "$repo_root/skills/lore/scripts" "$tmp/c-v2-store" <<'PYTEST'
import sys
sys.path.insert(0, sys.argv[1])
import lore_master, lore_store
store = lore_store.Store2(sys.argv[2])
items = lore_master.inbox_list(store)
assert [(i['payload']['file'], i['payload']['rule_id']) for i in items
        if i['kind'] == 'retire' and i['payload']['file'] == 'how-i-work/questions.md'] == [
            ('how-i-work/questions.md', '76b5ab29')]
PYTEST

echo "-- Canon: a fake that fixes every gate"
reply all
cn reply c1
want "$rc" 0 "canon fixed exit"
want "$(ncalls)" 1 "canon makes one call"
want "$(gates "$tmp/out-c1")" "{'contradiction': 'in Inbox', 'core-budget': 'fixed', 'broken-link': 'fixed', 'orphan': 'fixed', 'duplicate': 'in Inbox', 'oversized': 'fixed', 'thin': 'fixed', 'stale': 'fixed'}" "canon gate results"
want "$(bars "$tmp/out-c1")" "{'canon': (8, 8, True)}" "canon bar"
want "$(j "$tmp/out-c1/report.json" "(d['status'], d['rejected'], d['dropped'], d['new_findings'], d['ops'], len(d['commits']), len(d['inbox']))")" "('ok', [], None, [], 15, 12, 2)" "canon run"
want "$(j "$tmp/out-c1/report.json" "(d['fixture']['sha256'], d['fixture']['gates'], d['model']['name'])")" "('$FIXTURE_SHA', 8, 'override')" "canon fixture hash and role"
grep -q '^| canon | 8/8 | 100.0% | every gate.s fix present | PASS |$' "$tmp/out-c1/report.md" || fail "report.md canon row"
grep -q '^| contradiction | how-i-work/questions.md | in Inbox | ' "$tmp/out-c1/report.md" || fail "report.md names the gate fixed through the Inbox"
grep -q '^| orphan | gotchas/harbourlight.md | fixed | ' "$tmp/out-c1/report.md" || fail "report.md names a fixed gate"
grep -qx 'canon: 8/8 PASS' "$tmp/log-c1" || fail "stdout canon line"
want "$(treehash "$real")" "$before" "the owner's store after Canon"

echo "-- Canon: only retirements, only some gates, nothing, rejected, failing"
reply duplicate
cn reply c2
want "$rc" 1 "inbox-only exit"
want "$(gates "$tmp/out-c2")" "{'contradiction': 'not fixed', 'core-budget': 'not fixed', 'broken-link': 'not fixed', 'orphan': 'not fixed', 'duplicate': 'in Inbox', 'oversized': 'not fixed', 'thin': 'not fixed', 'stale': 'not fixed'}" "a gate with only an Inbox proposal"
want "$(bars "$tmp/out-c2")" "{'canon': (1, 8, False)}" "inbox-only bar"
reply thin,stale,orphan
cn reply c3
want "$rc" 1 "three fixes exit"
want "$(bars "$tmp/out-c3")" "{'canon': (3, 8, False)}" "three fixes, retirements left to the Inbox"
want "$(gates "$tmp/out-c3")" "{'contradiction': 'not fixed', 'core-budget': 'not fixed', 'broken-link': 'not fixed', 'orphan': 'fixed', 'duplicate': 'not fixed', 'oversized': 'not fixed', 'thin': 'fixed', 'stale': 'fixed'}" "three fixed gates"
cn none c4
want "$rc" 1 "canon does nothing: exit"
want "$(gates "$tmp/out-c4")" "{'contradiction': 'not fixed', 'core-budget': 'not fixed', 'broken-link': 'not fixed', 'orphan': 'not fixed', 'duplicate': 'not fixed', 'oversized': 'not fixed', 'thin': 'not fixed', 'stale': 'not fixed'}" "every gate not fixed"
want "$(bars "$tmp/out-c4")" "{'canon': (0, 8, False)}" "do-nothing bar"
want "$(ncalls)" 1 "canon does nothing, one call"
grep -qx 'canon: 0/8 FAIL' "$tmp/log-c4" || fail "stdout canon fraction"
cn bad-ops c5
want "$rc" 2 "rejected reply: exit"
want "$(ncalls)" 1 "a rejected Canon reply, one call"
want "$(j "$tmp/out-c5/report.json" "(d['status'], d['calls'], len(d['rejected']), 'bars' in d, d['error'].startswith('LoreError: the validator rejected Canon'), d['error'].endswith(d['rejected'][0]))")" "('failed', 1, 1, False, True, True)" "a rejected reply fails the run and keeps its message"
grep -q -- "^- Result: FAILED: LoreError: the validator rejected Canon's reply: " "$tmp/out-c5/report.md" || fail "report.md names the rejection"
cn prose c6
want "$rc" 2 "canon prose: exit"
want "$(j "$tmp/out-c6/report.json" "(d['status'], d['error'], d['calls'], 'bars' in d)")" "('failed', 'ReplyError: the reply is not JSON', 1, False)" "canon prose report"
cn fail c7
want "$rc" 2 "canon failing: exit"
want "$(j "$tmp/out-c7/report.json" "d['error'].startswith('LoreError: the model command exited 3: ')")" "True" "canon failure report"
want "$(find "$TMPDIR" -mindepth 1 | wc -l | tr -d ' ')" 0 "temporary files left after Canon runs"

echo "-- Canon: a finding that moves is not fixed, and one that was not seeded fails the bar"
reply contradiction,core-budget,broken-link,orphan,duplicate,oversized-moved,thin,stale
cn reply c9
want "$rc" 1 "every Tarnwell rule moved to a renamed file: exit"
want "$(gates "$tmp/out-c9")" "{'contradiction': 'in Inbox', 'core-budget': 'fixed', 'broken-link': 'fixed', 'orphan': 'fixed', 'duplicate': 'in Inbox', 'oversized': 'not fixed', 'thin': 'fixed', 'stale': 'fixed'}" "the moved oversized finding is not fixed"
want "$(bars "$tmp/out-c9")" "{'canon': (7, 8, False)}" "moved oversized bar"
want "$(j "$tmp/out-c9/report.json" "(d['status'], d['rejected'], d['new_findings'])")" "('ok', [], ['oversized gotchas/tarnwell-renamed.md'])" "the moved finding is named"
grep -q '^| canon | 7/8 | 87.5% | every gate.s fix present | FAIL |$' "$tmp/out-c9/report.md" || fail "report.md canon row, moved finding"
grep -q 'introduced findings (any one fails the bar): oversized gotchas/tarnwell-renamed.md$' "$tmp/out-c9/report.md" || fail "report.md names the introduced finding"
grep -qx 'canon: 7/8 FAIL' "$tmp/log-c9" || fail "stdout canon line, moved finding"
reply contradiction,core-budget,broken-link,orphan,duplicate-moved,oversized,thin,stale
cn reply c10
want "$rc" 1 "the clashing Mossdb pair moved, its retirement waiting: exit"
want "$(gates "$tmp/out-c10")" "{'contradiction': 'in Inbox', 'core-budget': 'fixed', 'broken-link': 'fixed', 'orphan': 'fixed', 'duplicate': 'in Inbox', 'oversized': 'fixed', 'thin': 'fixed', 'stale': 'fixed'}" "all eight gates present"
want "$(bars "$tmp/out-c10")" "{'canon': (8, 8, False)}" "a finding introduced on a new file fails the bar at 8/8"
want "$(j "$tmp/out-c10/report.json" "d['new_findings']")" "['duplicate gotchas/mossdb-now.md (376b853a, 96079fb3)']" "the introduced finding is named with its rules"
reply contradiction,core-budget,broken-link,orphan,duplicate,duplicate-pair,oversized,thin,stale
cn reply c11
want "$rc" 1 "a second duplicate pair in the seeded file: exit"
want "$(j "$tmp/out-c11/report.json" "(d['status'], d['rejected'], d['calls'])")" "('ok', [], 1)" "the second pair's reply was accepted and run"
want "$(gates "$tmp/out-c11")" "{'contradiction': 'in Inbox', 'core-budget': 'fixed', 'broken-link': 'fixed', 'orphan': 'fixed', 'duplicate': 'not fixed', 'oversized': 'fixed', 'thin': 'fixed', 'stale': 'fixed'}" "the second pair is not waiting in the Inbox"
want "$(bars "$tmp/out-c11")" "{'canon': (7, 8, False)}" "the second pair fails the bar"
want "$(j "$tmp/out-c11/report.json" "d['new_findings']")" "['duplicate gotchas/mossdb.md (0f98a0c0, 453d48eb)']" "the introduced pair is named"
grep -q '^| duplicate | gotchas/mossdb.md | not fixed | ' "$tmp/out-c11/report.md" || fail "report.md duplicate row, second pair"
grep -q 'introduced findings (any one fails the bar): duplicate gotchas/mossdb.md (0f98a0c0, 453d48eb)$' "$tmp/out-c11/report.md" || fail "report.md names the introduced pair"
grep -qx 'canon: 7/8 FAIL' "$tmp/log-c11" || fail "stdout canon line, second pair"

echo "-- Canon: a fixture that does not seed every gate once is not run"
cp -r "$fixture" "$tmp/fx-canon"
rm "$tmp/fx-canon/canon/gotchas/harbourlight.md" "$tmp/fx-canon/canon/.lore/meta/gotchas/harbourlight.json"
reply all
rc=0; FAKE_CANON=reply python3 "$lore" eval canon --fixture "$tmp/fx-canon" --out "$tmp/out-c8" > /dev/null 2>&1 || rc=$?
want "$rc" 2 "an unseeded gate: exit"
want "$(j "$tmp/out-c8/report.json" "(d['status'], d['calls'], d['error'].startswith('LoreError: the fixture does not seed every gate once and nothing else: lint finds '))")" "('failed', 0, True)" "no model call on a fixture that does not seed every gate"

echo "-- an empty --out directory, or one that cannot be created"
mkdir "$tmp/out-e1"
lm perfect e1
want "$rc" 0 "an existing empty --out, Loremaster: exit"
want "$(ncalls)" 6 "an existing empty --out, Loremaster: calls"
want "$(j "$tmp/out-e1/report.json" "d['status']")" ok "an existing empty --out, Loremaster: report"
mkdir "$tmp/out-e2"
reply all
cn reply e2
want "$rc" 0 "an existing empty --out, Canon: exit"
want "$(bars "$tmp/out-e2")" "{'canon': (8, 8, True)}" "an existing empty --out, Canon: bar"
echo x > "$tmp/afile"
: > "$FAKE_CALLS"; rc=0
FAKE_CANON=reply python3 "$lore" eval canon --out "$tmp/afile/sub" > /dev/null 2> "$tmp/err-e3" || rc=$?
want "$rc" 2 "an --out that cannot be created: exit"
grep -q '^Error: ' "$tmp/err-e3" || fail "an --out that cannot be created: message: $(cat "$tmp/err-e3")"
grep -q 'Traceback' "$tmp/err-e3" && fail "an --out that cannot be created crashed"
want "$(ncalls)" 0 "an --out that cannot be created makes no model call"
lm perfect e4 --workdir "$tmp/afile/work"
want "$rc" 2 "a --workdir that cannot be created: exit"
want "$(ncalls)" 0 "a --workdir that cannot be created makes no model call"

echo "-- the default owner store is protected while LORE_STORE2 points elsewhere"
want "$LORE_STORE2" "$real" "LORE_STORE2 is the other store"
ln -s "$HOME/.agents/lore" "$tmp/dangling"
for where in "$HOME/.agents/lore" "$HOME/.agents/lore/work" "$tmp/dangling/work"; do
  lm perfect d1 --workdir "$where"
  want "$rc" 2 "--workdir $where: exit"
  grep -q "is or is inside the owner's store; the eval builds its own\$" "$tmp/err-d1" || fail "--workdir $where message: $(cat "$tmp/err-d1")"
  want "$(ncalls)" 0 "--workdir $where: model calls"
  [[ ! -e "$HOME/.agents" && ! -e "$tmp/out-d1" ]] || fail "--workdir $where: something was created"
  rc=0; : > "$FAKE_CALLS"
  python3 "$lore" eval canon --out "$where" > /dev/null 2> "$tmp/err-d2" || rc=$?
  want "$rc" 2 "--out $where: exit"
  grep -q "^Error: refused: --out .* is or is inside the owner's store" "$tmp/err-d2" || fail "--out $where message"
  want "$(ncalls)" 0 "--out $where: model calls"
  [[ ! -e "$HOME/.agents" ]] || fail "--out $where: the default store path was created"
done
want "$(treehash "$real")" "$before" "the owner's store after the default-path refusals"

echo "-- the default fixture is the repository's"
want "$(j "$tmp/out-c1/report.json" "d['fixture']['path']")" "$fixture" "default fixture path"
echo "eval OK"
