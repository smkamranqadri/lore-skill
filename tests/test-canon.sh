#!/usr/bin/env bash
# lore 2.0 P3 Canon tests: Canon's operations (reword, split, merge) with exact validation, the
# original quote, retired/, the Canon run (validate all, one commit per op in a private checkout,
# landed through the hub's merge policy after the owner's own changes, pushed to a bare hub), each
# lint gate's fixture fixed by a fake Canon reply, no call on a quiet store, rejected and failing
# replies (nothing written, backoff), `lore lint`, `lore canon`, `lore canon-log`, and the
# role commands (`canon:` lines, mise wrappers resolved to their install, `check --live` reading
# the JSON roles' replies). Never a real model: LORE_CANON_CMD is a fake, and the wrapper section
# runs with a PATH of fictional scripts only. Never the network: every hub is a local bare repo.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap '[[ -n "${KEEP:-}" ]] || rm -rf "$tmp"' EXIT
export HOME="$tmp/home"; mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset LORE_STORE LORE_STORE2 LORE_GH_CMD LORE_GIT_TIMEOUT LORE_SYNC_CMD LORE_EXTRACT_CMD LORE_REVIEW_CMD \
  LORE_LOREMASTER_CMD LORE_CANON_CMD LORE_MODEL_TIMEOUT MISE_DATA_DIR XDG_DATA_HOME 2>/dev/null || true

# A scratch copy of the skill.
cp -r "$repo_root/skills/lore" "$tmp/skill"
lore="$tmp/skill/scripts/lore.py"
export LORE_SCRIPTS="$tmp/skill/scripts" TMP_ROOT="$tmp" PYTHONDONTWRITEBYTECODE=1
export PYTHONPATH="$repo_root/tests/fixtures/canon"

# The fake Canon: one line per call, the prompt kept, then the answer FAKE_CANON asks for.
cat > "$tmp/fake-canon.sh" <<FAKE
#!/usr/bin/env bash
n=\$(( \$(wc -l < "$tmp/canon-calls" 2>/dev/null || echo 0) + 1 ))
echo "\$n \${FAKE_CANON:-reply}" >> "$tmp/canon-calls"
[[ -z "\${FAKE_CANON_EDIT:-}" ]] || printf '%s\n' '- The owner prefers amber themes.' >> "\$FAKE_CANON_EDIT"
cp "\$LORE_PROMPT_FILE" "$tmp/canon-prompt.\$n"
case "\${FAKE_CANON:-reply}" in
  reply) cat "\$FAKE_CANON_REPLY" ;;
  empty-ops) printf '{"ops": [], "answer": "ok"}\n' ;;
  bad-ops) printf '{"ops": [{"op": "add", "file": "stack/x.md", "text": "Invented.", "explicit": true, "quote": "q", "session": ""}]}\n' ;;
  prose) echo "I looked at the memory and it all seems fine to me." ;;
  empty) ;;
  fail) echo "canon exploded" >&2; exit 3 ;;
esac
FAKE
chmod +x "$tmp/fake-canon.sh"
export LORE_CANON_CMD="$tmp/fake-canon.sh"
section() { echo "-- $1"; python3 -; }

# 1. The new ops: exact validation, their effects, the original quote, retired/, role op sets.
section "ops" <<'PY'
from harness import *
st = new_store("ops", hub=False)
G, W, P = "gotchas/git.md", "stack/widget.md", "how-i-work/planning.md"
seed(st, [add(G, "Never force-push a shared branch.", quote="dont force push shared branches"),
          add(G, "Pull before you push."), add(W, "Pin the widget version."), add(W, "Cache widget builds."),
          add(W, "Lint widget configs."), add(P, "Write the plan before the code."),
          describe(W, "using the widget tool"), {"op": "link", "file": G, "to": W}])
g1, g2 = rule_id(st, G, "Never force-push a shared branch."), rule_id(st, G, "Pull before you push.")
w1, w2, w3 = (rule_id(st, W, t) for t in ("Pin the widget version.", "Cache widget builds.", "Lint widget configs."))
p1 = rule_id(st, P, "Write the plan before the code.")
SECRET = "token=fixture-not-real-123"
before = snapshot(st)
split = lambda *parts, f=W: {"op": "split", "file": f, "into": [{"file": x, "rule_ids": ids} for x, ids in parts]}
invalid = [
    ({"op": "reword", "rule_id": g1, "text": "Never  force-push a shared branch!"}, "op 1 (reword): the text is unchanged"),
    ({"op": "reword", "rule_id": "deadbeef", "text": "New words."}, "op 1 (reword): no rule with id 'deadbeef'"),
    ({"op": "reword", "rule_id": g1, "text": "Pull before you push."}, f"op 1 (reword): duplicate of rule {g2} in {G}"),
    ({"op": "reword", "rule_id": g1, "text": "Set " + SECRET + " first."}, "op 1 (reword): a secret-looking string in text (not shown)"),
    ({"op": "reword", "rule_id": g1, "text": "New words.", "file": W}, f"op 1 (reword): no rule with id '{g1}' in {W}"),
    ({"op": "reword", "rule_id": g1, "text": "New words.", "file": "../x.md"}, "op 1 (reword): file '../x.md' escapes the store"),
    ({"op": "reword", "rule_id": g1}, "op 1 (reword): missing field(s) text"),
    ({"op": "reword", "rule_id": g1, "text": "New words.", "quote": "q"}, "op 1 (reword): unknown field(s) quote"),
    ({"op": "split", "file": W, "into": "stack/a.md"}, "op 1 (split): into must be a list"),
    (split(), "op 1 (split): into is empty"),
    (split(("stack/a.md", [w1, w2, w3]), f="stack/none.md"), "op 1 (split): stack/none.md does not exist"),
    (split(("stack/a.md", [p1]), f="core.md"), "op 1 (split): core.md is not split (it changes only through the inbox)"),
    ({"op": "split", "file": W, "into": [{"file": "stack/a.md"}]}, "op 1 (split): into 1: needs exactly the fields file and rule_ids"),
    ({"op": "split", "file": W, "into": [{"file": "stack/a.md", "rule_ids": []}]},
     "op 1 (split): into 1: file must be a string and rule_ids a non-empty list of rule ids"),
    (split(("../a.md", [w1, w2, w3])), "op 1 (split): into 1: file '../a.md' escapes the store"),
    (split(("notes/a.md", [w1, w2, w3])), "op 1 (split): into 1: file 'notes/a.md' is not in the layout"),
    (split(("stack/ghp_fixturefixturefixture00.md", [w1, w2, w3])), "op 1 (split): into 1: a secret-looking string (not shown)"),
    (split(("core.md", [w1, w2, w3])), "op 1 (split): into 1: core.md takes no part of a split"),
    (split(("stack/a.md", [w1]), ("stack/a.md", [w2, w3])), "op 1 (split): into 2: stack/a.md is named twice"),
    (split(("stack/a.md", [w1, w2]), ("stack/b.md", [w2, w3])), f"op 1 (split): rule {w2} is in more than one part"),
    (split(("stack/a.md", [w1, w2, w3, g1])), f"op 1 (split): rule {g1} is not in {W}"),
    (split(("stack/a.md", [w1]), ("stack/b.md", [w3])), f"op 1 (split): rule(s) {w2} of {W} are in no part (a split takes each rule exactly once)"),
    (split((W, [w1, w2, w3])), "op 1 (split): a split names at least one file besides the one it splits"),
    ({"op": "merge", "from": W, "to": "stack/none.md"}, "op 1 (merge): stack/none.md does not exist"),
    ({"op": "merge", "from": "../x.md", "to": W}, "op 1 (merge): from '../x.md' escapes the store"),
    ({"op": "merge", "from": W, "to": W}, "op 1 (merge): a file cannot be merged into itself"),
    ({"op": "merge", "from": W, "to": "core.md"}, "op 1 (merge): core.md is not merged (it changes only through the inbox)"),
    ({"op": "merge", "from": "stack/" + SECRET + ".md", "to": W}, "op 1 (merge): a secret-looking string in from (not shown)"),
    ({"op": "merge", "from": W}, "op 1 (merge): missing field(s) to"),
    ({"op": "unlink", "file": G, "to": "stack/none.md"}, "op 1 (unlink): stack/none.md does not exist (a new topic file is created only by add)"),
]
for n, (op, want) in enumerate(invalid, 1):
    eq(M.validate(st, [op]), [want], f"invalid op {n}")
eq(M.validate(st, [{"op": "propose-layout", "top": ["profile.md", "retired/"], "reason": "r"}]),
   ["op 1 (propose-layout): retired/ is kept for retired rules and is not a layout entry"], "retired/ is not a layout entry")
eq(snapshot(st), before, "validate wrote nothing")

# a rule whose line is in its file twice is not reworded, split or merged; a part may not already hold a rule
orig_w, orig_p, orig_pm = st.read(W), st.read(P), st.read(lore_store.meta_rel(P))
st.write(W, orig_w + "- Cache widget builds.\n")
for op in ({"op": "reword", "rule_id": w2, "text": "Cache every widget build."},
           split(("stack/a.md", [w1, w2, w3])), {"op": "merge", "from": W, "to": P}):
    eq(M.validate(st, [op]), [f"op 1 ({op['op']}): rule {w2} is in {W} more than once; remove the extra line first"], f"doubled line: {op['op']}")
st.write(W, orig_w)
st.write(P, orig_p + "- Lint widget configs.\n")
eq(M.validate(st, [split(("stack/a.md", [w1, w2]), (P, [w3]))]), [f"op 1 (split): {P} already has a rule with id {w3}"], "a part holding the rule")
m = json.loads(st.read(lore_store.meta_rel(P))); m["rules"]["0a0a0a0a"] = dict(text="Lint widget configs.")
st.write(lore_store.meta_rel(P), lore_store.dump_meta(m))
eq(M.validate(st, [split(("stack/a.md", [w1, w2]), (P, [w3]))]), [f"op 1 (split): {P} already has the words of rule {w3}"], "a part holding the words")
st.write(lore_store.meta_rel(P), orig_pm)
st.write(P, orig_p)
eq(snapshot(st), before, "fixture lines taken out again")

# a symlinked folder is refused for a part, a merge source and a merge target
os.makedirs(os.path.join(TMP, "outside"), exist_ok=True)
os.symlink(os.path.join(TMP, "outside"), st.path("stack/link"))
eq(M.validate(st, [split(("stack/link/a.md", [w1, w2, w3]))]),
   ["op 1 (split): into 1: file 'stack/link/a.md' passes through the symlink stack/link"], "split through a symlink")
eq(M.validate(st, [{"op": "merge", "from": W, "to": "stack/link/a.md"}]),
   ["op 1 (merge): to 'stack/link/a.md' passes through the symlink stack/link"], "merge into a symlink")
eq(M.validate(st, [{"op": "merge", "from": "stack/link/a.md", "to": W}]),
   ["op 1 (merge): from 'stack/link/a.md' passes through the symlink stack/link"], "merge from a symlink")
os.unlink(st.path("stack/link"))

# the role op sets: Canon never adds or supersedes; the Loremaster never rewords, splits or merges
eq(M.validate(st, [add(W, "An invented rule.")], allowed=M.CANON_OPS), ["op 1: add is not an operation this role may use"], "canon add")
eq(M.validate(st, [{"op": "supersede", "rule_id": g2, "text": "x", "quote": "x"}], allowed=M.CANON_OPS),
   ["op 1: supersede is not an operation this role may use"], "canon supersede")
for op in ({"op": "reword", "rule_id": g1, "text": "New words."}, split(("stack/a.md", [w1, w2, w3])), {"op": "merge", "from": W, "to": P}):
    eq(M.validate(st, [op], allowed=M.LOREMASTER_OPS), [f"op 1: {op['op']} is not an operation this role may use"], f"loremaster {op['op']}")
res = M.file_items(st, [{"text": "x", "explicit": True, "quote": "x", "session": ""}],
                   lambda prompt: json.dumps({"ops": [{"op": "reword", "rule_id": g1, "text": "New words."}]}))
eq(res["rejected"], ["op 1: reword is not an operation this role may use"], "file_items refuses a Canon op")
eq(snapshot(st), before, "nothing written by refused batches")

# the original quote: add records it; reword keeps it (twice); supersede sets it to the new words
eq(meta(st, G)["rules"][g1]["original_quote"], "dont force push shared branches", "add records the quote")
eq(meta(st, G)["rules"][g2]["original_quote"], "Pull before you push.", "add records the quote it was given")
n = int(git(st.root, "rev-list", "--count", "HEAD"))
M.apply(st, [{"op": "reword", "rule_id": g1, "text": "Do not force-push a shared branch."}], source="canon")
M.apply(st, [{"op": "reword", "rule_id": g1, "text": "Do not force-push a branch others use."}], source="canon")
e = meta(st, G)["rules"][g1]
eq((e["text"], e["quote"], e["original_quote"], e["reworded"], int(git(st.root, "rev-list", "--count", "HEAD"))),
   ("Do not force-push a branch others use.", "dont force push shared branches", "dont force push shared branches",
    "2026-10-01", n + 2), "two rewords keep the original quote")
eq(st.read(G), "# Git\n\n- Do not force-push a branch others use.\n- Pull before you push.\n", "reworded in place")
M.apply(st, [{"op": "flag-contradiction", "rule_id": g1, "with_text": "Force-push freely."}], source="seed")
M.apply(st, [{"op": "reword", "rule_id": g1, "text": "Never force-push a branch others use."}], source="canon")
eq(len(meta(st, G)["rules"][g1].get("contradictions", [])), 1, "a reword keeps a contradiction flag")
M.apply(st, [{"op": "supersede", "rule_id": g2, "text": "Pull with rebase before you push.", "quote": "always rebase on pull"}], source="seed")
eq(meta(st, G)["rules"][g2]["original_quote"], "always rebase on pull", "supersede re-anchors the original quote")
M.apply(st, [{"op": "reword", "rule_id": g2, "text": "Pull with rebase, then push."}], source="canon")
eq(meta(st, G)["rules"][g2]["original_quote"], "always rebase on pull", "a reword after a supersede keeps the new anchor")
# an entry from before P3 (no original_quote) falls back to its quote, and a reword records it
m = meta(st, P); m["rules"][p1].pop("original_quote"); m["rules"][p1]["quote"] = "plan first"
lore_store.save_meta(st, P, m); commit_hand(st)
M.apply(st, [{"op": "reword", "rule_id": p1, "text": "Plan before you code."}], source="canon")
eq(meta(st, P)["rules"][p1]["original_quote"], "plan first", "a pre-P3 rule's quote becomes its original")
consistent(st)

# split: every rule to one part (ids, quotes kept); the old path stays, title only, and links to the parts
seed(st, [{"op": "link", "file": P, "to": W}])
q1 = meta(st, W)["rules"][w1]
M.apply(st, [split(("stack/widget-build.md", [w2, w1]), ("stack/widget-lint.md", [w3]))], source="canon")
eq(st.read(W), "# Widget\n\n", "the old path is kept, title only")
eq(st.read("stack/widget-build.md"), "# Widget build\n\n- Pin the widget version.\n- Cache widget builds.\n", "part 1 in file order")
eq(st.read("stack/widget-lint.md"), "# Widget lint\n\n- Lint widget configs.\n", "part 2")
eq((meta(st, W)["links"], meta(st, W)["read_when"], meta(st, W)["rules"]),
   (["stack/widget-build.md", "stack/widget-lint.md"], "using the widget tool", {}), "the old path links to the parts")
e = meta(st, "stack/widget-build.md")["rules"][w1]
eq({k: e[k] for k in ("text", "created", "quote", "original_quote")}, {k: q1[k] for k in ("text", "created", "quote", "original_quote")}, "a split keeps the entry")
eq((meta(st, G)["links"], meta(st, P)["links"]), ([W], [W]), "links to the old path are untouched")
eq([f for f in lore_lint.lint(st) if f["gate"] == "broken-link"], [], "no broken link after a split")
index = st.read("INDEX.md")
for rel in (W, "stack/widget-build.md", "stack/widget-lint.md"):
    if f"- `{rel}`: read when" not in index:
        fail(f"the index lost {rel}")
# a split that keeps part of the rules at the old path
seed(st, [add("stack/widget-lint.md", "Lint widget plugins."), add("stack/widget-lint.md", "Lint widget themes.")])
l1, l2, l3 = (rule_id(st, "stack/widget-lint.md", t) for t in ("Lint widget configs.", "Lint widget plugins.", "Lint widget themes."))
M.apply(st, [split(("stack/widget-lint.md", [l1, l3]), ("stack/widget-plugins.md", [l2]), f="stack/widget-lint.md")], source="canon")
eq((st.read("stack/widget-lint.md"), meta(st, "stack/widget-lint.md")["links"]),
   ("# Widget lint\n\n- Lint widget configs.\n- Lint widget themes.\n", ["stack/widget-plugins.md"]), "a split keeping part at the old path")
# a file written by hand without a title keeps its path as a title-only file
st.write("stack/bare.md", "- Bare rule one.\n- Bare rule two.\n"); commit_hand(st)
b1, b2 = rule_id(st, "stack/bare.md", "Bare rule one."), rule_id(st, "stack/bare.md", "Bare rule two.")
M.apply(st, [split(("stack/bare-one.md", [b1]), ("stack/bare-two.md", [b2]), f="stack/bare.md")], source="canon")
eq(st.read("stack/bare.md"), "# Bare\n\n", "a split-out file without a title gets one")
consistent(st)

# merge: rules (ids kept) and links move to the target, incoming links rewritten, the file and sidecar gone
seed(st, [{"op": "link", "file": "stack/widget-build.md", "to": "stack/widget-plugins.md"},
          {"op": "link", "file": "stack/widget-plugins.md", "to": P},
          {"op": "link", "file": "stack/widget-lint.md", "to": "stack/widget-build.md"}])
M.apply(st, [{"op": "merge", "from": "stack/widget-plugins.md", "to": "stack/widget-build.md"}], source="canon")
eq((os.path.exists(st.path("stack/widget-plugins.md")), os.path.exists(st.path(".lore/meta/stack/widget-plugins.json"))),
   (False, False), "the merged file and its sidecar are gone")
eq(st.read("stack/widget-build.md"), "# Widget build\n\n- Pin the widget version.\n- Cache widget builds.\n- Lint widget plugins.\n", "rules folded in")
eq(rule_id(st, "stack/widget-build.md", "Lint widget plugins."), l2, "the id is kept")
eq(meta(st, "stack/widget-build.md")["links"], [P], "the target takes the source's links, not itself")
eq((meta(st, "stack/widget-lint.md")["links"], meta(st, W)["links"]),
   (["stack/widget-build.md"], ["stack/widget-build.md", "stack/widget-lint.md"]), "incoming links rewritten to the target")
st.write(P, st.read(P) + "- Cache widget builds.\n"); commit_hand(st)
c2 = rule_id(st, "stack/widget-build.md", "Cache widget builds.")
eq(M.validate(st, [{"op": "merge", "from": P, "to": "stack/widget-build.md"}]),
   [f"op 1 (merge): rule {c2} of {P} is already in stack/widget-build.md; retire one copy first"], "merge refuses a duplicate")
consistent(st)

# a broken link (its target gone) can be unlinked; the same id in two files is addressed by file
os.unlink(st.path("stack/widget-lint.md")); commit_hand(st)
eq(M.validate(st, [{"op": "unlink", "file": W, "to": "stack/widget-lint.md"}]), [], "unlink a broken link")
eq(M.validate(st, [{"op": "link", "file": W, "to": "stack/widget-lint.md"}]),
   ["op 1 (link): stack/widget-lint.md does not exist (a new topic file is created only by add)"], "but never link to it")
eq(M.validate(st, [{"op": "retire", "rule_id": c2, "reason": "dup"}]),
   [f"op 1 (retire): rule id {c2} is in more than one file ({P}, stack/widget-build.md)"], "ambiguous id")
eq(M.validate(st, [{"op": "retire", "rule_id": c2, "reason": "dup", "file": P}]), [], "the file picks the copy")

# an accepted retirement moves the rule to retired/<same path>: out of the index and of lint, kept in git
r = M.apply(st, [{"op": "retire", "rule_id": c2, "file": P, "reason": "duplicates stack/widget-build.md"}], source="canon")["inbox"][0]
eq([(i["kind"], i["payload"]["file"]) for i in M.inbox_list(st) if i["id"] == r], [("retire", P)], "retire queued for that file")
kept = meta(st, P)["rules"][c2]
res = M.inbox_accept(st, r)
eq(sorted(res["changed"]), sorted([P, ".lore/meta/how-i-work/planning.json", "retired/" + P, "retired/how-i-work/planning.json"]),
   "retire writes four files")
eq(json.loads(st.read("retired/how-i-work/planning.json")), {"rules": {c2: dict(kept, retired="2026-10-01", retired_reason="duplicates stack/widget-build.md")}},
   "the retired rule's whole entry is kept beside it")
archived = st.read("retired/how-i-work/planning.json")
lore_store.tidy(st)
eq((git(st.root, "status", "--porcelain"), st.read("retired/how-i-work/planning.json")), ("", archived), "reconciliation keeps the retired entry")
eq(st.read("retired/" + P), "# Planning\n\n- Cache widget builds.\n", "the rule is in retired/")
eq(st.read(P), "# Planning\n\n- Plan before you code.\n", "and out of its file")
eq(git(st.root, "ls-files", "retired/").splitlines(), ["retired/how-i-work/planning.json", "retired/" + P], "retired/ is in git")
eq((c2 in meta(st, "stack/widget-build.md")["rules"], "retired/" + P in st.rule_files()), (True, False), "the other copy stays; retired/ is no rule file")
if any("retired/" in (f["file"] or "") for f in lore_lint.lint(st)) or "retired/" in st.read("INDEX.md"):
    fail("retired/ reached lint or the index")
# accepting a retirement settles the contradiction flags raised against the retired words
flagged = rule_id(st, G, "Never force-push a branch others use.")
seed(st, [add(W, "Force-push freely.")])
fid = rule_id(st, W, "Force-push freely.")
r = M.apply(st, [{"op": "retire", "rule_id": fid, "reason": "contradicts the git rule"}], source="canon")["inbox"][0]
M.inbox_accept(st, r)
eq("contradictions" in meta(st, G)["rules"][flagged], False, "the flag against the retired rule is settled")
eq(st.read("retired/" + W), "# Widget\n\n- Force-push freely.\n", "retired/ keeps the folder layout")
seed(st, [add(W, "Force-push freely.")])
r = M.apply(st, [{"op": "retire", "rule_id": rule_id(st, W, "Force-push freely."), "reason": "again"}], source="canon")["inbox"][0]
M.inbox_accept(st, r)
eq(st.read("retired/" + W), "# Widget\n\n- Force-push freely.\n", "the same words retired twice are kept once")
consistent(st)
print("ok")
PY

# 2. Each gate fires on its own fixture; a session end calls the fake Canon once, whose reply fixes
# it, each op its own `canon: <op> <file>` commit, pushed to the store's bare hub; the finding goes.
section "gates" <<'PY'
from harness import *
RAN = r"store-run: canon ran on \d+ finding\(s\) \([a-z, -]+\): {c} commit\(s\), {i} inbox item\(s\) \({t}\)"

def fix(st, ops, trigger, commits, inbox=0):
    """One session end with `ops` as Canon's reply: one call, `commits` new commits on the hub."""
    reply(ops)
    n, head = calls(), git(st.root, "rev-parse", "HEAD")
    lines = session_end(st, trigger)
    eq(calls(), n + 1, f"{trigger}: one Canon call")
    match(lines, RAN.format(c=len(commits), i=inbox, t=re.escape(trigger)), f"{trigger}: run logged")
    got = git(st.root, "log", "--format=%s", f"{head}..HEAD").splitlines()[::-1]
    eq(got, commits, f"{trigger}: one commit per op, in order")
    for subj in commits:
        match(lines, r"store-run: canon: committed [0-9a-f]{7,} " + re.escape(subj), f"{trigger}: commit logged")
    eq(pushed(st), True, f"{trigger}: pushed to the hub")
    eq(hub_subjects(st)[:len(commits)], commits[::-1], f"{trigger}: the hub has the commits")
    return lines

def accept_retire(st, rule):
    """The owner accepts the one pending retirement of `rule`; it lands as its own pushed commit."""
    items = [i for i in M.inbox_list(st) if i["kind"] == "retire" and i["payload"]["rule_id"] == rule]
    eq(len(items), 1, "one retire item")
    M.inbox_accept(st, items[0]["id"])
    quiet(lore_hub.push_step, st, True)
    eq((pushed(st), hub_subjects(st)[0]), (True, f"inbox: retire {rule} from {items[0]['payload']['file']}"), "accepted and pushed")

# contradiction: urgent; Canon retires the side that falls (an Inbox item); while it waits there
# Canon is not called again; accepting it moves the rule to retired/ and settles the flag
st = new_store("g-contra")
A, B = "Never force-push a shared branch.", "Force-push when you own the branch."
seed(st, [add("gotchas/git.md", A, quote="dont force push shared branches"), add("gotchas/git.md", B),
          describe("gotchas/git.md", "a git command misbehaves")])
a, b = rule_id(st, "gotchas/git.md", A), rule_id(st, "gotchas/git.md", B)
seed(st, [{"op": "flag-contradiction", "rule_id": a, "with_text": B}])
eq(gates(st, "contradiction"), [("contradiction", "gotchas/git.md")], "contradiction fires")
fix(st, [{"op": "retire", "rule_id": b, "reason": "contradicts rule " + a + ", which the person stated"}], "test:contra", [], inbox=1)
p = prompt(calls())
for want in ("1. contradiction: gotchas/git.md [" + a + "]: ", f"- [{a}] {A}\n  original quote: \"dont force push shared branches\"\n",
             "### gotchas/git.md\n\nread_when: a git command misbehaves\n", "# You are Canon"):
    if want not in p:
        fail(f"the prompt lacks {want!r}")
n = calls()
lines = session_end(st, "test:contra-wait")
eq(calls(), n, "a finding waiting in the inbox makes no call")
has(lines, "store-run: canon: 1 finding(s) wait for the owner in the inbox", "waiting logged")
match(lines, r"store-run: canon skipped, .+ \(test:contra-wait\)", "skip logged")
accept_retire(st, b)
eq((st.read("retired/gotchas/git.md"), "contradictions" in meta(st, "gotchas/git.md")["rules"][a], gates(st, "contradiction")),
   ("# Git\n\n- " + B + "\n", False, []), "contradiction fixed")
if B in st.read("INDEX.md") + st.read("gotchas/git.md"):
    fail("the retired rule is still in the index or its file")

# core-budget: urgent; Canon rewords the long core rule shorter, keeping its original quote
st = new_store("g-core")
LONG = ("Always run the whole test suite, read every failing assertion in full, find and fix the root cause, "
        "and only then say that a change is done, fixed, ready for review or safe to merge into the main branch.")
SHORT = "Run the whole suite and fix root causes before saying a change is done."
seed(st, [add("core.md", LONG, core=True), add("core.md", "Keep replies short.", core=True)])
budget = (len(lore_store.build_index(st)[0]) - 120) // 4
st.write(".lore/config", st.read(".lore/config").replace("budget: 1500", f"budget: {budget}")); commit_hand(st, "fixture budget")
eq((st.config()["budget"], gates(st, "core-budget")), (str(budget), [("core-budget", "core.md")]), "core-budget fires")
cid = rule_id(st, "core.md", LONG)
fix(st, [{"op": "reword", "rule_id": cid, "text": SHORT}], "test:core", ["canon: reword core.md"])
e = meta(st, "core.md")["rules"][cid]
eq((e["text"], e["original_quote"], gates(st, "core-budget")), (SHORT, LONG, []), "core-budget fixed, original kept")

# broken-link: a linked file deleted by hand; Canon unlinks it
st = new_store("g-link")
seed(st, [add("gotchas/git.md", "Pull before you push."), add("gotchas/git.md", "Read the diff before committing."),
          add("stack/go.md", "Run go vet before committing."), add("stack/go.md", "Pin the Go toolchain version."),
          describe("gotchas/git.md", "a git command misbehaves"), describe("stack/go.md", "writing Go"),
          {"op": "link", "file": "gotchas/git.md", "to": "stack/go.md"}])
os.unlink(st.path("stack/go.md")); commit_hand(st)
eq(gates(st, "broken-link"), [("broken-link", "gotchas/git.md")], "broken-link fires")
fix(st, [{"op": "unlink", "file": "gotchas/git.md", "to": "stack/go.md"}], "test:link", ["canon: unlink gotchas/git.md"])
eq((meta(st, "gotchas/git.md")["links"], gates(st, "broken-link")), ([], []), "broken-link fixed")

# orphan: no read_when and nothing links to it; Canon describes it
st = new_store("g-orphan")
seed(st, [add("stack/go.md", "Run go vet before committing."), add("stack/go.md", "Pin the Go toolchain version.")])
eq(gates(st, "orphan"), [("orphan", "stack/go.md")], "orphan fires")
fix(st, [describe("stack/go.md", "writing or testing Go code")], "test:orphan", ["canon: describe stack/go.md"])
eq((meta(st, "stack/go.md")["read_when"], gates(st, "orphan")), ("writing or testing Go code", []), "orphan fixed")

# duplicate: the same line in two files (one id in both); Canon retires the extra copy by file
st = new_store("g-dup")
seed(st, [add("gotchas/git.md", "Pull before you push."), add("gotchas/git.md", "Read the diff before committing."),
          add("stack/go.md", "Run go vet before committing."), add("stack/go.md", "Pin the Go toolchain version."),
          describe("gotchas/git.md", "a git command misbehaves"), describe("stack/go.md", "writing Go")])
st.write("stack/go.md", st.read("stack/go.md") + "- Pull before you push.\n"); commit_hand(st)
did = rule_id(st, "stack/go.md", "Pull before you push.")
eq((rule_id(st, "gotchas/git.md", "Pull before you push."), len(gates(st, "duplicate"))), (did, 1), "duplicate fires once")
fix(st, [{"op": "retire", "rule_id": did, "file": "stack/go.md", "reason": "duplicates the rule in gotchas/git.md"}],
    "test:dup", [], inbox=1)
forget_run(st)
n = calls()
lines = session_end(st, "test:dup-wait")
eq(calls(), n, "a duplicate whose copy waits in the inbox makes no call")
has(lines, "store-run: canon: 1 finding(s) wait for the owner in the inbox", "waiting by id logged")
accept_retire(st, did)
eq((st.read("retired/stack/go.md"), "Pull before you push." in st.read("gotchas/git.md"), gates(st, "duplicate")),
   ("# Go\n\n- Pull before you push.\n", True, []), "duplicate fixed, one copy kept")

# oversized: 26 rules; Canon splits it in two and describes each part; the old path stays reachable
st = new_store("g-big")
words = ["amber", "basil", "cedar", "delta", "ember", "fjord", "garnet", "harbor", "indigo", "juniper", "kestrel", "lagoon",
         "maple", "nectar", "onyx", "pepper", "quartz", "raven", "saffron", "tundra", "umber", "violet", "walnut", "xenon",
         "yarrow", "zephyr"]
W = "stack/widget.md"
seed(st, [add(W, f"Set the {w} flag when building {w} widgets.") for w in words] +
         [describe(W, "using the widget tool"), add("gotchas/git.md", "Pull before you push."),
          add("gotchas/git.md", "Read the diff before committing."), describe("gotchas/git.md", "a git command misbehaves"),
          {"op": "link", "file": "gotchas/git.md", "to": W}])
eq(gates(st, "oversized"), [("oversized", W)], "oversized fires at 26 rules")
ids = [rule_id(st, W, f"Set the {w} flag when building {w} widgets.") for w in words]
fix(st, [{"op": "split", "file": W, "into": [{"file": "stack/widget-build.md", "rule_ids": ids[:13]},
                                            {"file": "stack/widget-release.md", "rule_ids": ids[13:]}]},
         describe("stack/widget-build.md", "building widgets"), describe("stack/widget-release.md", "releasing widgets")],
    "test:big", ["canon: split stack/widget.md", "canon: describe stack/widget-build.md", "canon: describe stack/widget-release.md"])
eq((st.read(W), meta(st, W)["links"], meta(st, "gotchas/git.md")["links"]),
   ("# Widget\n\n", ["stack/widget-build.md", "stack/widget-release.md"], [W]), "the old path is kept and links on")
eq((len(lore_store.parse_rules(st.read("stack/widget-build.md"))[1]), len(lore_store.parse_rules(st.read("stack/widget-release.md"))[1])),
   (13, 13), "13 rules each")
eq((gates(st, "oversized"), gates(st, "broken-link")), ([], []), "oversized fixed, no broken link")
index = st.read("INDEX.md")
for line in ("- `stack/widget.md`: read when using the widget tool (0)", "- `stack/widget-build.md`: read when building widgets (13)",
             "- `stack/widget-release.md`: read when releasing widgets (13)"):
    if line not in index.splitlines():
        fail(f"the index lacks {line!r}")

# thin: one rule, eight days old; Canon merges it into a related file; links to it follow
D0 = dt.date(2026, 9, 1)
st = new_store("g-thin", day=D0)
R, PL = "how-i-work/reviews.md", "how-i-work/planning.md"
seed(st, [add(R, "Ask a second model to review every plan.", quote="get a second opinion on plans"), describe(R, "planning a review"),
          add(PL, "Write the plan before the code."), add(PL, "Name the risks in every plan."), describe(PL, "planning work"),
          add("gotchas/git.md", "Pull before you push."), add("gotchas/git.md", "Read the diff before committing."),
          describe("gotchas/git.md", "a git command misbehaves"),
          {"op": "link", "file": "gotchas/git.md", "to": R}, {"op": "link", "file": PL, "to": R}])
rid = rule_id(st, R, "Ask a second model to review every plan.")
eq(gates(at(st, D0 + dt.timedelta(days=6)), "thin"), [], "not thin at six days")
st = at(st, D0 + dt.timedelta(days=8))
eq(gates(st, "thin"), [("thin", R)], "thin fires at eight days")
fix(st, [{"op": "merge", "from": R, "to": PL}], "test:thin", ["canon: merge how-i-work/reviews.md"])
eq((os.path.exists(st.path(R)), rule_id(st, PL, "Ask a second model to review every plan."),
    meta(st, PL)["rules"][rid]["original_quote"], meta(st, "gotchas/git.md")["links"], meta(st, PL).get("links")),
   (False, rid, "get a second opinion on plans", [PL], []), "merged; links rewritten")
eq((gates(st, "thin"), gates(st, "broken-link")), ([], []), "thin fixed, no broken link")

# stale: old.md last read 92 days ago; Canon merges it into the file that is read
st = new_store("g-stale", day=dt.date(2026, 7, 1))
seed(st, [add("stack/old.md", "Use the legacy widget flags."), add("stack/old.md", "Keep the legacy build script."),
          describe("stack/old.md", "touching the legacy build"), add("stack/go.md", "Run go vet before committing."),
          add("stack/go.md", "Pin the Go toolchain version."), describe("stack/go.md", "writing Go")])
lore_store.record_reads(st, {"stack/old.md": 1}, st.machine())
lore_store.record_reads(at(st, dt.date(2026, 9, 25)), {"stack/go.md": 3}, st.machine()); commit_hand(st, "reads")
st = at(st, dt.date(2026, 10, 1))
eq(gates(st, "stale"), [("stale", "stack/old.md")], "stale fires")
fix(st, [{"op": "merge", "from": "stack/old.md", "to": "stack/go.md"}], "test:stale", ["canon: merge stack/old.md"])
eq((gates(st, "stale"), len(lore_store.parse_rules(st.read("stack/go.md"))[1])), ([], 4), "stale fixed")
print("ok")
PY

# 3. No call when nothing is due, and every call counts as the day's run; a rejected, failing or
# non-JSON reply writes nothing and backs off; Canon never writes the owner's tree: a failure part
# way leaves the store as it was, owner edits and commits made meanwhile are kept, and what the
# merge policy cannot settle drops Canon's commits.
section "quiet and failures" <<'PY'
from harness import *
# a quiet store: no findings, a logged skip and no call
st = new_store("quiet")
seed(st, [add("gotchas/git.md", "Pull before you push."), add("gotchas/git.md", "Read the diff before committing."),
          describe("gotchas/git.md", "a git command misbehaves")])
eq(lore_lint.lint(st), [], "a quiet store has no findings")
n = calls()
lines = session_end(st, "test:quiet")
eq(calls(), n, "a quiet store makes no Canon call")
match(lines, r"store-run: canon skipped, .+ \(test:quiet\)", "the skip is logged with its reason")
eq(len(canon_lines(lines)), 1, "one canon line")
# findings, but Canon ran under 24 hours ago and none is urgent: no call
seed(st, [add("stack/go.md", "Run go vet before committing."), add("stack/go.md", "Pin the Go toolchain version.")])
lore_lint.mark_run(st)
eq(gates(st, "orphan"), [("orphan", "stack/go.md")], "an orphan")
lines = session_end(st, "test:notdue")
eq(calls(), n, "a gate inside the 24 hours makes no call")
match(lines, r"store-run: canon skipped, .+ \(test:notdue\)", "not-due skip logged")
forget_run(st)

def rejected(ops_or_mode, trigger, error):
    """A reply that must write nothing: one call, the store byte for byte as it was, a failure counted."""
    if isinstance(ops_or_mode, list):
        reply(ops_or_mode)
    else:
        mode(ops_or_mode)
    forget_run(st)   # each call counts as the day's run; `force` overrides the backoff, never the gates
    before, n, fails = snapshot(st), calls(), state(st, "canon_fails") or 0
    lines = session_end(st, trigger, force=True)
    eq(calls(), n + 1, f"{trigger}: one call")
    has(lines, f"store-run: canon FAILED, nothing written; {error} ({trigger})", f"{trigger}: logged")
    eq(snapshot(st), before, f"{trigger}: nothing written")
    eq((state(st, "canon_fails"), pushed(st)), (fails + 1, True), f"{trigger}: failure counted")

rejected([{"op": "reword", "rule_id": "deadbeef", "text": "New words."}, describe("stack/go.md", "writing Go")], "test:rej",
         "Canon's reply was rejected, nothing written: op 1 (reword): no rule with id 'deadbeef'")
rejected([describe("stack/go.md", "writing Go"), add("stack/go.md", "An invented rule.")], "test:rej-add",
         "Canon's reply was rejected, nothing written: op 2: add is not an operation this role may use")
rejected("prose", "test:prose", "ReplyError: the reply is not JSON")
rejected("empty", "test:empty", "ReplyError: the reply is empty")
rejected("fail", "test:fail", "LoreError: the model command exited 3: canon exploded")
eq(state(st, "canon_last_error"), "LoreError: the model command exited 3: canon exploded", "the last error is kept")
# a failed call still counts as the day's run: a non-urgent finding waits the interval, with no new failure
n = calls()
lines = session_end(st, "test:after-fail")
eq((calls(), state(st, "canon_fails")), (n, 5), "no call inside the interval after a failed attempt; the count unchanged")
match(lines, r"store-run: canon skipped, findings in orphan; Canon ran 0 min ago, next run in \d+ min \(test:after-fail\)", "the wait is the interval")
# backing off: no call within the window; force overrides it; after the window a good reply applies
forget_run(st)
lines = session_end(st, "test:soon")
eq(calls(), n, "no call while backing off")
has(lines, "store-run: canon waits, 1 finding(s); backing off after a failed run (under 120 min ago)", "backoff logged")
age_failure(st)
reply([describe("stack/go.md", "writing Go")])
lines = session_end(st, "test:retry")
eq((calls(), state(st, "canon_fails"), gates(st, "orphan")), (n + 1, None, []), "the retry applied and cleared the failures")
has(lines, "store-run: canon: fixed", "the answer is logged")

# Canon never writes the owner's tree: it works in a private checkout (.git/lore/canon), and its
# commits land after the owner's own changes are committed. An owner change lore refuses to commit
# (a secret) blocks that: Canon's commits are dropped (the owner's side wins), with no failure,
# and the owner's tree is exactly as found.
forget_run(st)
seed(st, [add("stack/rust.md", "Run clippy before committing."), add("stack/rust.md", "Pin the Rust toolchain.")])
st.write("stack/rust.md", st.read("stack/rust.md") + "- my api_key = fixture-not-real-123456\n")
lore_store.tidy(st)
reply([describe("stack/rust.md", "writing Rust")])
before, n = snapshot(st), calls()
lines = session_end(st, "test:dirty")
eq((calls(), state(st, "canon_fails"), snapshot(st), os.path.exists(st.local("canon"))), (n + 1, None, before, False),
   "one call, no failure, the owner's tree as found, no checkout left")
match(lines, r"store-run: canon: dropped 1 commit\(s\): refused to commit: a secret-looking string in \S+(, \S+)* \(not shown\); "
      r"remove it and commit again; the owner's side wins \(test:dirty\)", "the drop is logged")
st.write("stack/rust.md", st.read("stack/rust.md").replace("- my api_key = fixture-not-real-123456\n", "")); commit_hand(st)

# a failure part way through the ops: nothing lands, nothing is queued, the checkout is gone
fid = rule_id(st, "stack/go.md", "Pin the Go toolchain version.")
ops = [{"op": "retire", "rule_id": fid, "reason": "fixture"}, describe("stack/rust.md", "writing Rust"),
       {"op": "link", "file": "stack/rust.md", "to": "stack/go.md"}]
eq(M.validate(st, ops, allowed=M.CANON_OPS), [], "the batch is valid")
real_writes, made = M._commit_writes, []
def second_fails(store, writes, subject, edit=None, before=None):
    if before and writes:
        before()
    if writes and made:
        raise lore.LoreError("fixture: the second commit fails")
    out = real_writes(store, writes, subject)
    if out[0]:
        made.append(store.root)
        if edit:
            edit()
    return out
before = snapshot(st)
M._commit_writes = second_fails
raises(lambda: lore_canon.run(st, lore_lint.lint(st), lambda prompt: json.dumps({"ops": ops})), lore.LoreError,
       "fixture: the second commit fails", "the failure is raised")
M._commit_writes = real_writes
eq((made, snapshot(st), retires(st), os.path.exists(st.local("canon"))), ([st.local("canon")], before, [], False),
   "the first commit was made in the checkout only; nothing landed or queued, no checkout left")

# The owner edits during the call (profile.md) and between Canon's commits (the very file Canon
# rewords): the edits are committed first, Canon's commits land on top through the hub's merge
# drivers, and every owner line is kept. No failure, nothing staged or left over.
PROFILE, RUST = st.read("profile.md"), st.read("stack/rust.md")
OWNER, OWN_RUST = PROFILE + "- The owner prefers amber themes.\n", RUST + "- The owner's own rust line.\n"
pin = rule_id(st, "stack/rust.md", "Pin the Rust toolchain.")
ops2 = [{"op": "reword", "rule_id": pin, "text": "Pin the Rust toolchain version."}, describe("stack/rust.md", "writing Rust code")]
def answer(prompt):
    st.write("profile.md", OWNER)
    return json.dumps({"ops": ops2})
start, made[:] = git(st.root, "rev-parse", "HEAD"), []
M._commit_writes = lambda store, writes, subject: second_fails(store, writes, subject, edit=lambda: st.write("stack/rust.md", OWN_RUST)) \
    if not made else real_writes(store, writes, subject)
res = lore_canon.run(st, lore_lint.lint(st), answer)
M._commit_writes = real_writes
subjects = git(st.root, "log", "--reverse", "--format=%s", f"{start}..HEAD").splitlines()
eq((res["owner"][1], [s for _, s in res["commits"]], subjects, res["dropped"]),
   ("edit profile.md; edit stack/rust.md", ["canon: reword stack/rust.md", "canon: describe stack/rust.md"],
    ["edit profile.md; edit stack/rust.md", "canon: reword stack/rust.md", "canon: describe stack/rust.md"], None),
   "the owner's changes are committed first, Canon's commits land on top")
eq((st.read("profile.md"), st.read("stack/rust.md"), git(st.root, "status", "--porcelain")),
   (OWNER, "# Rust\n\n- Run clippy before committing.\n- The owner's own rust line.\n- Pin the Rust toolchain version.\n", ""),
   "both owner edits kept, Canon's reword merged in, nothing left uncommitted")
reword_sha = res["commits"][0][0]
eq([l for l in git(st.root, "diff", f"{reword_sha}^", reword_sha, "--", "stack/rust.md").splitlines() if l.startswith(("+- ", "-- "))],
   ["-- Pin the Rust toolchain.", "+- Pin the Rust toolchain version."], "Canon's commit changes only its own line")
eq(git(st.root, "show", f"{res['owner'][0]}:stack/rust.md"), OWN_RUST.rstrip("\n"), "the owner's line is in the owner's commit")
eq((meta(st, "stack/rust.md")["rules"][pin]["original_quote"], state(st, "canon_fails"), os.path.exists(st.local("canon"))),
   ("Pin the Rust toolchain.", None, False), "the reword keeps its quote; no failure; no checkout left")
consistent(st)

# A describe changes only the sidecar: an owner save of that .md just before Canon commits is never
# in Canon's commit (it lands in the owner's own commit before it).
seed(st, [add("stack/odin.md", "Run odin check before committing."), add("stack/odin.md", "Pin the Odin version.")])
ODIN = st.read("stack/odin.md") + "- The owner's own odin line.\n"
M._commit_writes = lambda store, writes, subject: second_fails(store, writes, subject, before=lambda: st.write("stack/odin.md", ODIN))
made[:] = []
res = lore_canon.run(st, lore_lint.lint(st), lambda prompt: json.dumps({"ops": [describe("stack/odin.md", "writing Odin")]}))
M._commit_writes = real_writes
canon_sha = res["commits"][0][0]
eq((git(st.root, "show", "--name-only", "--format=", canon_sha), git(st.root, "show", f"{res['owner'][0]}:stack/odin.md"), st.read("stack/odin.md")),
   (".lore/meta/stack/odin.json", ODIN.rstrip("\n"), ODIN), "Canon's describe commit holds its sidecar only; the owner's save is the owner's commit")

# a commit the owner makes during the call stays in the history: Canon's commits land after it
OWNER2 = OWNER + "- The owner likes short replies.\n"
def commit_during(prompt):
    st.write("profile.md", OWNER2); commit_hand(st, "owner commit")
    return json.dumps({"ops": [describe("stack/odin.md", "writing or testing Odin")]})
res = lore_canon.run(st, lore_lint.lint(st), commit_during)
owner_sha = git(st.root, "rev-parse", "HEAD~1")
eq((git(st.root, "log", "-2", "--format=%s").splitlines(), res["owner"], st.read("profile.md")),
   (["canon: describe stack/odin.md", "owner commit"], None, OWNER2), "the owner's commit stands, Canon's lands on it")
eq(subprocess.run(["git", "-C", st.root, "merge-base", "--is-ancestor", owner_sha, "HEAD"]).returncode, 0, "the owner's commit is an ancestor")

# What the merge policy cannot settle: the owner's side wins and Canon's commits are dropped, with
# no failure and the owner's tree, index and HEAD as found. A sidecar the owner broke by hand (git
# commit, no lore) during the call; a rebase conflict lore cannot settle; an owner save in the way
# of the fast-forward.
def broken_commit(prompt):
    st.write(".lore/meta/stack/odin.json", "{not json\n")
    subprocess.run(["git", "-C", st.root, "commit", "-qam", "owner breaks a sidecar"], check=True)
    return json.dumps({"ops": [describe("stack/odin.md", "Odin, again")]})
res = lore_canon.run(st, lore_lint.lint(st), broken_commit)
eq((res["dropped"], res["commits"], git(st.root, "log", "-1", "--format=%s"), st.read(".lore/meta/stack/odin.json"), git(st.root, "status", "--porcelain")),
   ("1 commit(s): .lore/meta/stack/odin.json is not valid JSON", [], "owner breaks a sidecar", "{not json\n", ""),
   "a broken sidecar: Canon's commit dropped, the owner's commit and tree as they were")
git(st.root, "revert", "--no-edit", "HEAD")
quiet(lore_hub.push_step, st, True)
real_rebase = lore_hub.rebase
def no_settle(store, onto):
    if store.root == st.local("canon"):
        raise lore_store.GitError("rebase onto the hub failed: a conflict lore cannot settle in stack/vala.md")
    return real_rebase(store, onto)
lore_hub.rebase = no_settle
seed(st, [add("stack/vala.md", "Run the vala linter before committing."), add("stack/vala.md", "Pin the Vala version.")])
reply([describe("stack/vala.md", "writing Vala")]); forget_run(st)
before, n = snapshot(st), calls()
lines = session_end(st, "test:no-settle")
lore_hub.rebase = real_rebase
eq((calls(), snapshot(st), state(st, "canon_fails")), (n + 1, before, None), "a conflict lore cannot settle: one call, nothing landed, no failure")
has(lines, "store-run: canon: dropped 1 commit(s): rebase onto the hub failed: a conflict lore cannot settle in stack/vala.md; "
    "the owner's side wins (test:no-settle)", "the drop is logged")
# the same with an owner edit during the call: the owner's commit stands and is pushed, Canon's is dropped
forget_run(st)
os.environ["FAKE_CANON_EDIT"] = st.path("stack/vala.md")
lore_hub.rebase = no_settle
lines = session_end(st, "test:no-settle-edit")
lore_hub.rebase = real_rebase
del os.environ["FAKE_CANON_EDIT"]
eq((git(st.root, "log", "-1", "--format=%s"), st.read("stack/vala.md").endswith("- The owner prefers amber themes.\n"), pushed(st), state(st, "canon_fails")),
   ("edit stack/vala.md", True, True, None), "the owner's commit stands and is pushed; no failure")
match(lines, r"store-run: committed [0-9a-f]{7,} edit stack/vala\.md \(before Canon's commits land\) \(test:no-settle-edit\)", "the owner's commit is logged")
has(lines, "store-run: canon: dropped 1 commit(s): rebase onto the hub failed: a conflict lore cannot settle in stack/vala.md; "
    "the owner's side wins (test:no-settle-edit)", "that drop is logged")
seed(st, [describe("stack/vala.md", "writing Vala")])
real_integrate = lore_hub.integrate
def save_in_the_way(store, remote, subject):
    real_integrate(store, remote, subject)
    st.write("stack/odin.md", ODIN + "- Saved in the way.\n")
lore_hub.integrate = save_in_the_way
head = git(st.root, "rev-parse", "HEAD")
odin_finding = [{"gate": "oversized", "file": "stack/odin.md", "rule_ids": [], "detail": "fixture"}]   # names the file, so its rules are shown
res = lore_canon.run(st, odin_finding, lambda prompt: json.dumps({"ops": [{"op": "reword", "rule_id": rule_id(st, "stack/odin.md", "Pin the Odin version."),
                                                                             "text": "Pin the Odin compiler version."}]}))
lore_hub.integrate = real_integrate
eq((res["rejected"], res["dropped"], git(st.root, "rev-parse", "HEAD"), st.read("stack/odin.md"), git(st.root, "status", "--porcelain")),
   ([], "1 commit(s): git merge failed: Aborting", head, ODIN + "- Saved in the way.\n", "M stack/odin.md"),
   "an owner save in the way: git refuses the fast-forward, the save is kept")
st.write("stack/odin.md", ODIN); commit_hand(st)

# the checkout's machine-local state never reaches the store: no machine id is taken there, a
# retirement is queued once in the store's own Inbox (where its rule landed), and Canon commits
# under the store's identity
real_machine, took = lore_store.Store2.machine, []
def machine(self):
    if self.root != st.root:
        took.append(self.root)
    return real_machine(self)
lore_store.Store2.machine = machine
git(st.root, "config", "user.name", "Fictional Owner"); git(st.root, "config", "user.email", "owner@example.invalid")
zf = rule_id(st, "stack/odin.md", "Run odin check before committing.")
res = lore_canon.run(st, lore_lint.lint(st), lambda prompt: json.dumps(
    {"ops": [{"op": "move", "rule_id": zf, "to": "stack/rust.md"}, {"op": "retire", "rule_id": zf, "reason": "fixture"}]}))
lore_store.Store2.machine = real_machine
eq((took, [(i["id"], i["payload"]["file"]) for i in retires(st)], res["inbox"]),
   ([], [(res["inbox"][0], "stack/rust.md")], res["inbox"]), "no machine id in the checkout; one item, in the store's Inbox")
eq(git(st.root, "log", "-1", "--format=%an <%ae>"), "Fictional Owner <owner@example.invalid>", "Canon commits as the store does")
if "canon" in os.listdir(st.local()):
    fail("the private checkout was left behind")
M.inbox_reject(st, res["inbox"][0])
git(st.root, "config", "user.name", "lore"); git(st.root, "config", "user.email", "lore@localhost")

# the same kind of batch, applied: one commit per op that changes the store, the retirement in the Inbox
ops = [{"op": "retire", "rule_id": fid, "reason": "fixture"}, describe("stack/rust.md", "writing Rust"),
       {"op": "link", "file": "stack/rust.md", "to": "stack/go.md"}]
res = lore_canon.run(st, lore_lint.lint(st), lambda prompt: json.dumps({"ops": ops, "answer": "done"}))
eq(([s for _, s in res["commits"]], len(res["inbox"]), res["ops"], res["answer"]),
   (["canon: describe stack/rust.md", "canon: link stack/rust.md"], 1, 3, "done"), "run result")

# a successful session-end run marks the run: a new non-urgent finding waits for the next day
forget_run(st)
seed(st, [add("stack/zig.md", "Run zig fmt before committing."), add("stack/zig.md", "Pin the Zig version.")])
reply([describe("stack/zig.md", "writing Zig")])
n = calls()
session_end(st, "test:mark")
eq((calls(), gates(st, "orphan")), (n + 1, []), "the run applied")
seed(st, [add("stack/nim.md", "Run nimpretty before committing."), add("stack/nim.md", "Pin the Nim version.")])
lines = session_end(st, "test:after-mark")
eq(calls(), n + 1, "no second run within the day")
match(lines, r"store-run: canon skipped, .+ \(test:after-mark\)", "not due after a run")
# an error inside the Canon step is logged and never breaks the session-end run
real_step = lore_canon.step
def boom(*a, **kw):
    raise RuntimeError("fixture: the step broke")
lore_canon.step = boom
lines = session_end(st, "test:boom")
lore_canon.step = real_step
has(lines, "store-run: canon FAILED: RuntimeError: fixture: the step broke (test:boom)", "a broken step is logged")

# without lore_lint the step is a logged skip, never an error
sys.modules["lore_lint"] = None
lines = session_end(st, "test:nolint")
has(lines, "store-run: canon skipped, lint is not installed (test:nolint)", "no lint, no Canon")
print("ok")
PY

# 3b. The review's fixes (F2 is in "ops", F1 and F7 in "quiet and failures" and "commands", F5 and
# F6 in "roles"): transfers never land on an existing id or words, a merge keeps read history, a
# rejected retirement is not asked again on the same evidence, pending retirements follow their
# rule and a stale one is dropped, a flag stays while a copy of its words does, the prompt carries
# both sides of a contradiction and whole rule records only. Round 2 (F1 and F2 are in "quiet and
# failures", F6 there and here): retired/ archives merge on the hub, a rejection holds back only the
# findings it answered, a reword needs the exact entry shown, an urgent gate is not held by the day.
section "review fixes" <<'PY'
from harness import *
A, B, C = "stack/amber.md", "stack/basil.md", "stack/cedar.md"
G = "gotchas/git.md"

# F3: a move or a split onto a file whose sidecar holds the rule's id, or its words, is refused
st = new_store("f3", hub=False)
seed(st, [add(A, "Pin Cedar builds.", quote="always pin cedar"), add(A, "Cache Cedar builds."), add(B, "Lint Basil configs.")])
x, y = rule_id(st, A, "Pin Cedar builds."), rule_id(st, B, "Lint Basil configs.")
st.write(B, st.read(B) + "- Pin Cedar builds.\n"); commit_hand(st)   # a hand-added copy, adopted under the same id
eq(rule_id(st, B, "Pin Cedar builds."), x, "the copy shares the id")
M.apply(st, [{"op": "reword", "rule_id": x, "file": B, "text": "Always pin Cedar builds."}], source="canon")
reworded = meta(st, B)["rules"][x]
before = snapshot(st)
for op in ({"op": "move", "rule_id": x, "file": A, "to": B},
           {"op": "split", "file": A, "into": [{"file": B, "rule_ids": [x]}, {"file": C, "rule_ids": [rule_id(st, A, "Cache Cedar builds.")]}]}):
    eq(M.validate(st, [op]), [f"op 1 ({op['op']}): {B} already has a rule with id {x}"], f"{op['op']} onto an existing id")
    try:
        M.apply(st, [op], source="canon")
        fail(f"{op['op']} onto an existing id applied")
    except M.OpsError:
        pass
eq((snapshot(st), meta(st, B)["rules"][x]), (before, reworded), "nothing written; the reworded entry is intact")
st.write(A, st.read(A) + "- Lint Basil configs.\n"); commit_hand(st)
mb = meta(st, B); mb["rules"]["0b0b0b0b"] = mb["rules"].pop(y); lore_store.save_meta(st, B, mb)   # the same words under another id
eq(M.validate(st, [{"op": "move", "rule_id": y, "file": A, "to": B}]), [f"op 1 (move): {B} already has the words of rule {y}"],
   "move onto the same words")

# F4: a merge carries the source's read history: reads add up per machine, the last read is the later
st = new_store("f4", hub=False)
seed(st, [add(A, "Cache Amber builds."), add(B, "Pin Basil releases.")])
for rel, reads, last in ((A, {"m-aaaaaaaa": 7, "m-cccccccc": 3}, {"m-aaaaaaaa": "2026-09-20", "m-cccccccc": "2026-09-21"}),
                         (B, {"m-bbbbbbbb": 2, "m-cccccccc": 5}, {"m-bbbbbbbb": "2026-09-19", "m-cccccccc": "2026-09-22"})):
    m = meta(st, rel); m.update(reads=reads, last_read=last); lore_store.save_meta(st, rel, m)
commit_hand(st, "reads")
M.apply(st, [{"op": "merge", "from": A, "to": B}], source="canon")
eq((meta(st, B)["reads"], meta(st, B)["last_read"]),
   ({"m-aaaaaaaa": 7, "m-bbbbbbbb": 2, "m-cccccccc": 8}, {"m-aaaaaaaa": "2026-09-20", "m-bbbbbbbb": "2026-09-19", "m-cccccccc": "2026-09-22"}),
   "merge keeps every machine's reads")

# F10: retiring one copy of the opposing words keeps the flag while another copy is a rule
FIRST, SECOND = "Cache Cedar builds.", "Never cache Cedar builds."
st = new_store("f10", hub=False)
seed(st, [add(A, FIRST), add(B, SECOND)])
st.write(C, lore_store.render_rules("Cedar", [SECOND])); commit_hand(st)
a, b = rule_id(st, A, FIRST), rule_id(st, B, SECOND)
seed(st, [{"op": "flag-contradiction", "rule_id": a, "with_text": SECOND}])
M.inbox_accept(st, M.apply(st, [{"op": "retire", "rule_id": b, "file": B, "reason": "duplicates stack/cedar.md"}], source="canon")["inbox"][0])
eq(([f["with"] for f in meta(st, A)["rules"][a].get("contradictions", [])], gates(st, "contradiction")), ([SECOND], [("contradiction", A)]),
   "a copy remains: the flag stays")
M.inbox_accept(st, M.apply(st, [{"op": "retire", "rule_id": b, "file": C, "reason": "contradicts"}], source="canon")["inbox"][0])
eq(("contradictions" in meta(st, A)["rules"][a], gates(st, "contradiction")), (False, []), "the last copy retired: the flag is settled")

# F11: the prompt carries both sides of a contradiction, with their original quotes, across files
st = new_store("f11", hub=False)
seed(st, [add(A, FIRST, quote="cache every cedar build"), add(B, SECOND, quote="do not cache cedar, ever")])
a, b = rule_id(st, A, FIRST), rule_id(st, B, SECOND)
seed(st, [{"op": "flag-contradiction", "rule_id": a, "with_text": SECOND},
          {"op": "flag-contradiction", "rule_id": a, "with_text": "Cache only on Fridays."}])
found = [f for f in lore_lint.lint(st) if f["gate"] == "contradiction"]
eq([(f["file"], f["rule_ids"]) for f in found], [(A, [a])], "the finding names only the flagged rule")
p = lore_canon.build_prompt(st, found)
lead, other = f"finding 1: flagged rule in {A}: ", f"  flagged against, in {B}: "
want = ("## Contradictions: each flagged rule and the rule(s) it is flagged against, with their original quotes\n\n"
        f"{lead}[{a}] {FIRST}\n{' ' * len(lead)}original quote: \"cache every cedar build\"\n"
        f"{other}[{b}] {SECOND}\n{' ' * len(other)}original quote: \"do not cache cedar, ever\"\n"
        "  flagged against words no rule holds now: \"Cache only on Fridays.\"\n\n")
if want not in p:
    fail(f"the prompt lacks the contradiction's evidence:\n{p}")
if f"### {B}\n" not in p:
    fail("the other side's file is not in the prompt")

# F12: the file context is whole rule records; what does not fit is named; a rule shown without its
# quote never happens, and a reword of a rule not shown is refused
st = new_store("f12", hub=False)
seed(st, [add(A, f"Pin Cedar build variant {i:02}.", quote=f"Fictional instruction {i:02}: " + "keep the Cedar build pinned. " * 68)
          for i in range(27)] + [add(A, "Pin Cedar build variant 27.", quote="pin 27")])   # a short last record still waits its turn
ids = [rule_id(st, A, f"Pin Cedar build variant {i:02}.") for i in range(28)]
found = [f for f in lore_lint.lint(st) if f["gate"] == "oversized"]
p, shown = lore_canon.compose(st, found)
quote = lambda i: "  original quote: " + json.dumps(meta(st, A)["rules"][i]["original_quote"]) + "\n"
visible = [i for i in ids if f"- [{i}] " in p]
eq((visible, shown, [i for i in visible if f"- [{i}] {meta(st, A)['rules'][i]['text']}\n{quote(i)}" not in p]),
   (ids[:len(visible)], {(A, i, meta(st, A)["rules"][i]["text"]) for i in visible}, []), "whole records, in file order, each rule with its quote")
omitted = ids[len(visible):]
eq(bool(visible) and bool(omitted), True, "the cap shows some rules and leaves some out")
line = f"({len(omitted)} more rule(s) not shown, over the prompt size cap: {', '.join(omitted)}; they are not to be reworded this run)\n"
if line not in p:
    fail(f"no marker for the omitted records: {line!r}")
res = lore_canon.run(st, found, lambda prompt: json.dumps({"ops": [{"op": "reword", "rule_id": omitted[0], "text": "Pin Cedar build variant 99 always."}]}))
eq((res["rejected"], res["commits"]), ([f"op 1 (reword): rule {omitted[0]} in {A} was not shown with its original quote (over the prompt size cap); "
                                         "it is not reworded this run"], []), "a reword of a rule not shown is refused")
res = lore_canon.run(st, found, lambda prompt: json.dumps({"ops": [{"op": "reword", "rule_id": visible[0], "text": "Always pin Cedar build variant 00."}]}))
eq((res["rejected"], [s for _, s in res["commits"]]), ([], [f"canon: reword {A}"]), "a reword of a shown rule applies")

# F8: a rejected retirement is remembered by its rule and evidence; no call until the evidence changes
X, Y, Z = "Never force-push a shared branch.", "Force-push when you own the branch.", "Force-push only on Fridays."
st = new_store("f8")
seed(st, [add(G, X), add(G, Y), describe(G, "a git command misbehaves")])
a, b = rule_id(st, G, X), rule_id(st, G, Y)
seed(st, [{"op": "flag-contradiction", "rule_id": a, "with_text": Y}])
reply([{"op": "retire", "rule_id": b, "reason": "contradicts " + a}])
n = calls()
session_end(st, "test:f8-propose")
eq((calls(), [i["payload"]["rule_id"] for i in retires(st)]), (n + 1, [b]), "one call, one proposal")
M.inbox_reject(st, retires(st)[0]["id"])
eq(list(M.rejected(st).values()), [{"rule_id": b, "file": G, "gate": "contradiction", "rejected": "2026-10-01"}], "the rejection is remembered")
lines = session_end(st, "test:f8-again")
eq((calls(), retires(st)), (n + 1, []), "the next session end makes no call and proposes nothing")
has(lines, "store-run: canon: 1 finding(s) the owner already answered (a rejected retirement; asked again when the evidence changes)",
    "the answered finding is logged")
has(lines, "store-run: canon skipped, no findings (test:f8-again)", "nothing left for Canon")
M.apply(st, [{"op": "reword", "rule_id": a, "text": "Do not force-push a shared branch."}], source="canon")
eq([f["gate"] for f in lore_canon.held(st, [f for f in lore_lint.lint(st) if f["gate"] == "contradiction"])["kept"]], ["contradiction"],
   "the flagged rule in new words: the finding goes to Canon")
M.apply(st, [{"op": "reword", "rule_id": a, "text": X}], source="canon")
eq([f["gate"] for f in lore_canon.held(st, [{"gate": "thin", "file": G, "rule_ids": [b], "detail": "fixture"}])["kept"]], ["thin"],
   "a rejected retirement holds back only the gates a retirement settles")
seed(st, [add(G, Z), {"op": "flag-contradiction", "rule_id": a, "with_text": Z}])
reply([])
session_end(st, "test:f8-new")
eq(calls(), n + 2, "new evidence: Canon is asked again")
r = M.apply(st, [{"op": "retire", "rule_id": b, "reason": "contradicts " + a}], source="canon")["inbox"][0]
M.apply(st, [{"op": "reword", "rule_id": b, "text": "Force-push only a branch you own."}], source="canon")
M.inbox_reject(st, r)
eq((len(M.rejected(st)), retires(st)), (1, []), "rejecting a stale item drops it and remembers nothing")

# F9: a pending retirement follows its rule through a move, a split and a merge; once its words
# change it is stale: dropped with a log line, and the finding goes to Canon again
st = new_store("f9")
GO, PUSH, RUST = "stack/go.md", "stack/go-push.md", "stack/rust.md"
seed(st, [add(G, X), add(G, Y), add(GO, "Run go vet before committing."), add(RUST, "Run clippy before committing."),
          describe(G, "a git command misbehaves"), describe(GO, "writing Go"), describe(RUST, "writing Rust")])
a, b, v = rule_id(st, G, X), rule_id(st, G, Y), rule_id(st, GO, "Run go vet before committing.")
seed(st, [{"op": "flag-contradiction", "rule_id": a, "with_text": Y}])
r = M.apply(st, [{"op": "retire", "rule_id": b, "reason": "contradicts " + a}], source="canon")["inbox"][0]
where = lambda: [i["payload"]["file"] for i in retires(st)]
M.apply(st, [{"op": "move", "rule_id": b, "to": GO}], source="seed")
eq(where(), [GO], "a move carries the pending retirement")
M.apply(st, [{"op": "split", "file": GO, "into": [{"file": GO, "rule_ids": [v]}, {"file": PUSH, "rule_ids": [b]}]}], source="canon")
eq(where(), [PUSH], "a split carries it")
# a Canon run that moves it and then fails never touched the item or the file
real = M._commit_writes
def second_fails(store, writes, subject):
    if second_fails.made:
        raise lore.LoreError("fixture: the second commit fails")
    second_fails.made = 1
    return real(store, writes, subject)
second_fails.made = 0
M._commit_writes = second_fails
raises(lambda: lore_canon.run(st, lore_lint.lint(st), lambda prompt: json.dumps(
    {"ops": [{"op": "merge", "from": PUSH, "to": RUST}, describe(GO, "writing Go code")]})), lore.LoreError,
    "fixture: the second commit fails", "a failing run")
M._commit_writes = real
eq((second_fails.made, where(), os.path.exists(st.path(PUSH))), (1, [PUSH], True), "the failed run left the item and the file as they were")
M.apply(st, [{"op": "merge", "from": PUSH, "to": RUST}], source="canon")
eq(where(), [RUST], "a merge carries it")
M.apply(st, [{"op": "move", "rule_id": b, "to": GO}, {"op": "move", "rule_id": b, "to": G}], source="seed")
eq(where(), [G], "two hops in one batch")
M.apply(st, [{"op": "move", "rule_id": b, "to": RUST}], source="seed")
kept, wait = lore_canon.waiting(st, lore_lint.lint(st))
eq([f["gate"] for f in wait], ["contradiction"], "the pending item holds the contradiction back")
M.apply(st, [{"op": "reword", "rule_id": b, "text": "Force-push only a branch that is yours alone."}], source="canon")
reply([])
n = calls()
lines = session_end(st, "test:f9")
has(lines, f"store-run: canon: dropped inbox item {r}: rule {b} is no longer in {RUST} with those words", "the stale item is logged")
eq((calls(), retires(st)), (n + 1, []), "the stale item is gone and Canon is called")

# Round 2. F3: retired/<path>.json merges as a union of archived entries, the same whichever side
# is which; a store made before the attribute existed takes it at its next session end; two
# machines retiring different rules of one topic both land on the hub, Markdown and JSON together.
e1 = {"text": "Pin Amber builds.", "retired": "2026-10-01", "retired_reason": "left"}
e2 = dict(e1, retired_reason="right")
ab = lore_store.merge_retired({}, {"rules": {"aaaa0001": e1}}, {"rules": {"aaaa0001": e2}})
eq((ab, sorted(v["retired_reason"] for v in ab["rules"].values()), ab["rules"]["aaaa0001"]),
   (lore_store.merge_retired({}, {"rules": {"aaaa0001": e2}}, {"rules": {"aaaa0001": e1}}), ["left", "right"], e1),
   "two entries under one id: both kept, the same result either way")
eq(lore_store.merge_retired({"rules": {"aaaa0001": e1}}, {"rules": {"aaaa0001": e1, "bbbb0002": e2}}, {"rules": {"aaaa0001": dict(e1, count=2)}}),
   {"rules": {"aaaa0001": dict(e1, count=2), "bbbb0002": e2}}, "a change on one side is taken; an entry one side added is kept")
eq(lore_store.merge_kind("retired/profile.json"), "retired", "the conflict fallback knows the archive")
left = new_store("r2-f3")
P1_ATTRS = lore_store.GITATTRIBUTES.replace("retired/**/*.json merge=lore-retired\n", "")
left.write(".gitattributes", P1_ATTRS); git(left.root, "commit", "-qam", "the attributes P1 wrote")
seed(left, [add(A, FIRST), add(A, SECOND), describe(A, "building Amber")])
eq((left.read(".gitattributes"), git(left.root, "status", "--porcelain")), (lore_store.GITATTRIBUTES, ""), "an old store takes the attribute and commits it")
eq(git(left.root, "check-attr", "merge", "--", "retired/stack/amber.json"), "retired/stack/amber.json: merge: lore-retired", "the archive has its driver")
right_root = os.path.join(TMP, "r2-f3-right")
git(TMP, "clone", "-q", "-b", "main", hub_dir(left), right_root)
right = lore_store.Store2(right_root, day=DAY)
git(right_root, "config", "user.name", "lore"); git(right_root, "config", "user.email", "lore@localhost")
git(right_root, "remote", "rename", "origin", lore_hub.REMOTE)
f1, f2 = rule_id(left, A, FIRST), rule_id(left, A, SECOND)
for st, rid, why in ((left, f1, "retired on the left"), (right, f2, "retired on the right")):
    M.inbox_accept(st, M.apply(st, [{"op": "retire", "rule_id": rid, "reason": why}], source="canon")["inbox"][0])
eq((quiet(lore_hub.push_step, left, True), quiet(lore_hub.push_step, right, True), quiet(lore_hub.push_step, left, True)),
   (f"hub: pushed to {hub_dir(left)}",) * 3, "both machines sync")
hub = hub_dir(left)
archive = json.loads(git(hub, "show", "main:retired/stack/amber.json"))
eq({k: (v["text"], v["retired_reason"]) for k, v in archive["rules"].items()},
   {f1: (FIRST, "retired on the left"), f2: (SECOND, "retired on the right")}, "both archived entries on the hub, with their reasons")
eq((git(hub, "show", "main:retired/stack/amber.md"), git(hub, "show", f"main:{A}"), json.loads(git(hub, "show", "main:.lore/meta/stack/amber.json"))["rules"]),
   (f"# Amber\n\n- {FIRST}\n- {SECOND}", "# Amber", {}), "both rules archived, neither left in the topic")
eq((git(left.root, "rev-parse", "HEAD"), git(right_root, "rev-parse", "HEAD")), (git(hub, "rev-parse", "main"),) * 2, "both machines at the hub")

# F4: a rejected retirement holds back the findings it answered, as lint saw them (E's real
# overlap detector); a new near-duplicate makes new pairs, which go to Canon
st = new_store("r2-f4", hub=False)
T = ["Pin Cedar build dependencies before every release on the stable branch.",
     "Pin Cedar build dependencies before every release on the stable branch always.",
     "Pin Cedar build dependencies before every release on the stable branch explicitly."]
seed(st, [add(A, T[0]), add(B, T[1])])
t0, t1 = rule_id(st, A, T[0]), rule_id(st, B, T[1])
M.inbox_reject(st, M.apply(st, [{"op": "retire", "rule_id": t1, "file": B, "reason": "duplicates the amber rule"}], source="canon")["inbox"][0])
eq([v["gate"] for v in M.rejected(st).values()], ["duplicate"], "the answered duplicate is remembered")
seed(st, [add(C, T[2])])
t2 = rule_id(st, C, T[2])
h = lore_canon.held(st, [f for f in lore_lint.lint(st) if f["gate"] == "duplicate"])
eq((sorted(sorted(f["rule_ids"]) for f in h["kept"]), [sorted(f["rule_ids"]) for f in h["answered"]]),
   (sorted([sorted([t0, t2]), sorted([t1, t2])]), [sorted([t0, t1])]), "the new pairs go to Canon; the answered pair stays held")

# F5: the quote guard authorises the exact entry shown (file, id, words), followed through the
# batch's moves, splits and merges; the same id in another file is another entry
st = new_store("r2-f5", hub=False)
D = "stack/dune.md"
V0 = "Pin Cedar build variant 00."
seed(st, [add(A, V0, quote="pin variant zero"), add(A, "Cache Cedar builds."), add(C, "Lint Cedar configs.")])
x, lint_id = rule_id(st, A, V0), rule_id(st, C, "Lint Cedar configs.")
st.write(B, lore_store.render_rules("Basil", [V0])); commit_hand(st)   # a hand copy, adopted under the same id
M.apply(st, [{"op": "reword", "rule_id": x, "file": B, "text": "Always pin Cedar build variant 00."}], source="canon")
eq(rule_id(st, B, "Always pin Cedar build variant 00."), x, "two entries share the id, with different words")
on = lambda rel: [{"gate": "oversized", "file": rel, "rule_ids": [], "detail": "fixture"}]
eq(sorted(k for k in lore_canon.compose(st, on(A))[1] if k[1] == x), [(A, x, V0)], "only the amber entry is shown")
canon = lambda rel, ops: lore_canon.run(st, on(rel), lambda prompt: json.dumps({"ops": ops}))
refused = lambda rel: [f"op 2 (reword): rule {x} in {rel} was not shown with its original quote (over the prompt size cap); it is not reworded this run"]
res = canon(A, [describe(A, "building Cedar"), {"op": "reword", "rule_id": x, "file": B, "text": "Keep Cedar build variant 00 pinned."}])
eq((res["rejected"], res["commits"]), (refused(B), []), "the basil entry is not authorised by the amber one")
res = canon(A, [{"op": "move", "rule_id": x, "file": A, "to": C}, {"op": "reword", "rule_id": x, "file": B, "text": "Keep Cedar build variant 00 pinned."}])
eq((res["rejected"], res["commits"]), (refused(B), []), "nor after the amber entry moved")
res = canon(A, [{"op": "move", "rule_id": x, "file": A, "to": C}, {"op": "reword", "rule_id": x, "file": C, "text": "Pin Cedar build variant 00 always."}])
eq(([s for _, s in res["commits"]], res["rejected"]), ([f"canon: move {A}", f"canon: reword {C}"], []), "a move carries the authorisation")
res = canon(C, [{"op": "split", "file": C, "into": [{"file": C, "rule_ids": [lint_id]}, {"file": D, "rule_ids": [x]}]},
                {"op": "reword", "rule_id": x, "file": D, "text": "Pin Cedar build variant 00 for good."}])
eq(([s for _, s in res["commits"]], res["rejected"]), ([f"canon: split {C}", f"canon: reword {D}"], []), "a split carries it")
res = canon(D, [{"op": "merge", "from": D, "to": A},
                {"op": "reword", "rule_id": x, "file": A, "text": "Always pin Cedar variant 00."}])
eq(([s for _, s in res["commits"]], res["rejected"]), ([f"canon: merge {D}", f"canon: reword {A}"], []), "a merge carries it")
eq((meta(st, A)["rules"][x]["text"], meta(st, A)["rules"][x]["original_quote"], meta(st, B)["rules"][x]["text"]),
   ("Always pin Cedar variant 00.", "pin variant zero", "Always pin Cedar build variant 00."), "the amber entry reworded, the basil one untouched")

# The archive's driver (what git runs) and the conflict fallback (what lore settles when git ran
# none) each give the same union; a side that is not a JSON object is never merged
drv = os.path.join(TMP, "r2-driver")
git(TMP, "init", "-q", "-b", "main", drv)
git(drv, "config", "user.name", "lore"); git(drv, "config", "user.email", "lore@localhost")
with open(os.path.join(drv, ".gitattributes"), "w") as f:
    f.write(lore_store.GITATTRIBUTES)
git(drv, "add", "-A"); git(drv, "commit", "-qm", "base")
ARCHIVE = os.path.join(drv, "retired", "stack", "amber.json")
for branch, entry in (("left", e1), ("right", e2)):
    git(drv, "checkout", "-q", "-b", branch, "main")
    os.makedirs(os.path.dirname(ARCHIVE), exist_ok=True)
    with open(ARCHIVE, "w") as f:
        f.write(lore_store.dump_meta({"rules": {"aaaa0001": entry}}))
    git(drv, "add", "-A"); git(drv, "commit", "-qm", branch)
union, right_sha = lore_store.dump_meta(ab), git(drv, "rev-parse", "HEAD")
rc = lore_store.git(drv, "merge", "-q", "--no-edit", "left", check=False)[0]
eq((rc, open(ARCHIVE).read()), (0, union), "git runs the archive's driver: the union")
git(drv, "reset", "-q", "--hard", right_sha)
rc = subprocess.run(["git", "-C", drv, "merge", "-q", "--no-edit", "left"], capture_output=True).returncode
eq((rc, lore_store.resolve_conflicts(lore_store.Store2(drv)), open(ARCHIVE).read()), (1, True, union),
   "with no driver, the conflict fallback settles the archive the same way")
git(drv, "merge", "--abort")
sides = []
for name, text in (("o", ""), ("a", "[]\n"), ("b", lore_store.dump_meta({"rules": {"aaaa0001": e1}}))):
    sides.append(os.path.join(TMP, "r2-side-" + name))
    with open(sides[-1], "w") as f:
        f.write(text)
eq(lore_store.merge_driver("retired", *sides, "retired/stack/amber.json"), 1, "a side that is not a JSON object is not merged")

# F4: a rejection keeps only the findings a retirement settles: a core rule over the index budget
# is still Canon's to shorten after its duplicate's retirement was rejected
st = new_store("r2-f4-core", hub=False)
LONG = ("Always run the whole test suite, read every failing assertion in full, find and fix the root cause, "
        "and only then say that a change is done, fixed, ready for review or safe to merge into the main branch.")
seed(st, [add("core.md", LONG, core=True), add("core.md", "Keep replies short.", core=True)])
st.write(G, lore_store.render_rules("Git", [LONG])); commit_hand(st)   # a hand copy, adopted under the same id
cid = rule_id(st, "core.md", LONG)
budget = (len(lore_store.build_index(st)[0]) - 120) // 4
st.write(".lore/config", st.read(".lore/config").replace("budget: 1500", f"budget: {budget}")); commit_hand(st, "fixture budget")
eq(sorted((f["gate"], f["file"], f["rule_ids"]) for f in lore_lint.lint(st) if cid in f["rule_ids"]),
   [("core-budget", "core.md", [cid]), ("duplicate", "core.md", [cid, cid])], "the core rule is in two findings")
M.inbox_reject(st, M.apply(st, [{"op": "retire", "rule_id": cid, "file": "core.md", "reason": "duplicates the git rule"}], source="canon")["inbox"][0])
h = lore_canon.held(st, [f for f in lore_lint.lint(st) if cid in f["rule_ids"]])
eq(([f["gate"] for f in h["kept"]], [f["gate"] for f in h["answered"]]), (["core-budget"], ["duplicate"]),
   "only the duplicate is answered; the budget finding still goes to Canon")

# Canon's checkout: one a killed run left is cleared first, and a symlink planted in its place is
# removed, never followed; a pending retirement follows its rule when Canon's move lands; an owner
# commit between the replay and the fast-forward drops Canon's commits (never a merge commit)
st = new_store("r2-checkout", hub=False)
GO2 = "stack/go.md"
seed(st, [add(G, X), add(G, Y), describe(G, "a git command misbehaves"), add(GO2, "Run go vet before committing."), describe(GO2, "writing Go")])
os.makedirs(st.local("canon", "leftover"))
with open(st.local("canon", "leftover", "file"), "w") as f:
    f.write("left by a killed run\n")
res = canon(GO2, [describe(GO2, "writing Go code")])
eq(([s for _, s in res["commits"]], os.path.exists(st.local("canon"))), ([f"canon: describe {GO2}"], False), "a leftover checkout is cleared first")
outside = os.path.join(TMP, "r2-outside")
os.makedirs(outside)
with open(os.path.join(outside, "keep"), "w") as f:
    f.write("keep\n")
os.symlink(outside, st.local("canon"))
res = canon(GO2, [describe(GO2, "writing or testing Go code")])
eq(([s for _, s in res["commits"]], os.path.lexists(st.local("canon")), os.listdir(outside)), ([f"canon: describe {GO2}"], False, ["keep"]),
   "a symlink in its place is removed, never followed")
b = rule_id(st, G, Y)
r = M.apply(st, [{"op": "retire", "rule_id": b, "reason": "fixture"}], source="canon")["inbox"][0]
res = canon(G, [{"op": "move", "rule_id": b, "to": GO2}])
eq(([s for _, s in res["commits"]], [(i["id"], i["payload"]["file"]) for i in retires(st)]), ([f"canon: move {G}"], [(r, GO2)]),
   "the pending retirement follows its rule when Canon's move lands")
real_integrate = lore_hub.integrate
def commit_in_the_way(store, remote, subject):
    real_integrate(store, remote, subject)
    st.write("profile.md", st.read("profile.md") + "- The owner commits in the way.\n"); commit_hand(st, "owner commit in the way")
lore_hub.integrate = commit_in_the_way
res = canon(GO2, [describe(GO2, "Go, once more")])
lore_hub.integrate = real_integrate
eq((bool(re.fullmatch(r"1 commit\(s\): git merge failed: .*fast-forward.*", res["dropped"] or "")), res["commits"],
    git(st.root, "log", "-1", "--format=%s"), git(st.root, "status", "--porcelain")),
   (True, [], "owner commit in the way", ""), "an owner commit after the replay: Canon's commit dropped, no merge commit")

# the prompt's index: when it cannot be rebuilt (over its budget), the store's last one is shown
st = new_store("r2-index", hub=False)
seed(st, [add(G, X), describe(G, "a git command misbehaves")])
old_index = st.read("INDEX.md")
st.write(".lore/config", st.read(".lore/config").replace("budget: 1500", "budget: 1")); commit_hand(st, "fixture budget")
seen = []
lore_canon.run(st, lore_lint.lint(st), lambda prompt: seen.append(prompt) or json.dumps({"ops": []}))
if "## Index\n\n" + old_index.rstrip("\n") + "\n" not in seen[0]:
    fail("the prompt lacks the store's last index")

# F6: every call counts as the day's run (see "quiet and failures"); an urgent gate still runs
st = new_store("r2-f6")
seed(st, [add(G, X), add(G, Y), describe(G, "a git command misbehaves")])
seed(st, [{"op": "flag-contradiction", "rule_id": rule_id(st, G, X), "with_text": Y}])
reply([])
n = calls()
session_end(st, "test:f6-first"); lines = session_end(st, "test:f6-second")
eq((calls(), state(st, "canon_fails")), (n + 2, None), "an urgent finding is called again inside the interval, with no failure")
match(lines, r"store-run: canon ran on 1 finding\(s\) \(contradiction\): 0 commit\(s\), 0 inbox item\(s\) \(test:f6-second\)", "the urgent run logged")

# Round 3. F1: the owner's commit before landing is staged in a private index: a refusal leaves the
# owner's index as it is, with what they staged during the attempt; after a commit their index
# catches up only where nothing of theirs is staged; the commit is made only on the HEAD it began on
st = new_store("r3-f1", hub=False)
seed(st, [add(A, FIRST), describe(A, "building Amber")])
real_scan, PROFILE = lore_store.refused_files, st.read("profile.md")
STAGED, SAVED, OWNED = (PROFILE + f"- The owner {w}.\n" for w in ("stages amber", "saves cedar", "likes short replies"))
def during_scan(act):
    def scan(store, changes):
        bad = real_scan(store, changes)
        if not scan.done and store.root == st.root:   # the owner's commit, not Canon's in its checkout
            scan.done = True
            act()
        return bad
    scan.done = False
    return scan
def stage_and_save():
    st.write("profile.md", STAGED); git(st.root, "add", "--", "profile.md"); st.write("profile.md", SAVED)
leftovers = lambda: [x for x in (lore_canon.OWNER_INDEX, lore_canon.LANDING) if os.path.exists(st.local(x))]
with open(st.path("draft.bin"), "wb") as f:
    f.write(b"fictional\0draft")
head = git(st.root, "rev-parse", "HEAD")
lore_store.refused_files = during_scan(stage_and_save)
res = canon(A, [describe(A, "building Amber code")])
lore_store.refused_files = real_scan
eq((res["dropped"], git(st.root, "show", ":profile.md"), st.read("profile.md"), git(st.root, "rev-parse", "HEAD"), leftovers()),
   ("1 commit(s): refused to commit: binary content in draft.bin (not shown); remove it and commit again", STAGED.rstrip("\n"), SAVED, head, []),
   "a refusal: the version staged during it stays staged, the saved one saved, HEAD as it was")
os.unlink(st.path("draft.bin")); git(st.root, "reset", "-q")
st.write("profile.md", OWNED)
lore_store.refused_files = during_scan(stage_and_save)
res = canon(A, [describe(A, "building Amber code")])
lore_store.refused_files = real_scan
eq((res["owner"][1], [s for _, s in res["commits"]], git(st.root, "show", "HEAD~1:profile.md"), git(st.root, "show", ":profile.md"),
    st.read("profile.md"), git(st.root, "show", ":.lore/meta/profile.json") == git(st.root, "show", "HEAD:.lore/meta/profile.json"), leftovers()),
   ("edit profile.md", [f"canon: describe {A}"], OWNED.rstrip("\n"), STAGED.rstrip("\n"), SAVED, True, []),
   "a commit: the owner's saved version committed, the one staged during it still staged, the rest of the index caught up")
git(st.root, "reset", "-q"); st.write("profile.md", OWNED); commit_hand(st, "owner tidies up")
st.write("profile.md", PROFILE)
def owner_commits():
    git(st.root, "add", "--", "profile.md"); git(st.root, "commit", "-qm", "owner commit during the attempt")
lore_store.refused_files = during_scan(owner_commits)
res = canon(A, [describe(A, "building Amber, again")])
lore_store.refused_files = real_scan
eq((bool(re.fullmatch(r"1 commit\(s\): git update-ref failed: .+", res["dropped"] or "")), res["owner"], git(st.root, "log", "-1", "--format=%s"),
    st.read("profile.md"), leftovers()),
   (True, None, "owner commit during the attempt", PROFILE, []), "HEAD moved during the attempt: no owner commit of Canon's, Canon's dropped")
commit_hand(st)

# F2: what a landed run leaves for the Inbox is recorded before the fast-forward: an Inbox write
# failing after landing is reported (the commit landed and is pushed, no failure), and the next
# session end writes it; writing twice is writing once; a record whose commit never landed is dropped
import types
st = new_store("r3-f2")
seed(st, [add(A, FIRST), add(A, SECOND)])
r1 = rule_id(st, A, FIRST)
reply([describe(A, "building Amber"), {"op": "retire", "rule_id": r1, "reason": "fixture"}]); forget_run(st)
real_queue, failed = M._queue, []
def queue_fails_once(store, kind, payload, source):
    if not failed:
        failed.append(1)
        raise OSError("fixture: the inbox is not writable")
    return real_queue(store, kind, payload, source)
M._queue = queue_fails_once
lines = session_end(st, "test:r3-f2")
M._queue = real_queue
eq((failed, retires(st), pushed(st), state(st, "canon_fails"), os.path.exists(st.local(lore_canon.LANDING))), ([1], [], True, None, True),
   "the commit landed and is pushed, no failure, the record kept")
match(lines, r"store-run: canon: committed [0-9a-f]{7,} canon: describe stack/amber\.md", "the landed commit is reported")
has(lines, "store-run: canon: inbox items not written yet (OSError: fixture: the inbox is not writable); the next run writes them (test:r3-f2)",
    "the unwritten item is reported")
if any("nothing written" in l for l in lines):
    fail("a landed run was reported as writing nothing")
lines = session_end(st, "test:r3-f2-next")
eq(([(i["payload"]["file"], i["payload"]["rule_id"]) for i in retires(st)], os.path.exists(st.local(lore_canon.LANDING))), ([(A, r1)], False),
   "the next session end writes it and drops the record")
has(lines, "store-run: canon: wrote 1 inbox item(s) of commits that landed before (test:r3-f2-next)", "the recovery is logged")
item = retires(st)[0]
lore_canon.journal(st, git(st.root, "rev-parse", "HEAD"), [["retire", item["payload"]]], [])
eq((lore_canon.publish(st), [i["id"] for i in retires(st)]), ([item["id"]], [item["id"]]), "written twice is written once")
lore_canon.journal(st, "0" * 40, [["retire", dict(item["payload"], reason="never landed")]], [])
eq((lore_canon.publish(st), [i["id"] for i in retires(st)], os.path.exists(st.local(lore_canon.LANDING))), (None, [item["id"]], False),
   "a record whose commit never landed: nothing written, the record dropped")
left = dict(item["payload"], reason="left by an earlier run")
lore_canon.journal(st, git(st.root, "rev-parse", "HEAD"), [["retire", left]], [])
res = canon(A, [describe(A, "building Amber code")])
eq(([s for _, s in res["commits"]], sorted(i["payload"]["reason"] for i in retires(st))), ([f"canon: describe {A}"], ["fixture", "left by an earlier run"]),
   "a run first writes what an earlier one left, then lands its own")
M._drop(st, [i for i in retires(st) if i["payload"]["reason"] != "fixture"][0])
# `lore canon` says so too, and pushes what landed
seed(st, [add(B, "Lint Basil configs.")])
r2 = rule_id(st, B, "Lint Basil configs.")
reply([describe(B, "using Basil"), {"op": "retire", "rule_id": r2, "reason": "fixture"}])
failed[:] = []
M._queue = queue_fails_once
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    lore_canon.cmd_canon(None, types.SimpleNamespace(store2=st.root, today=None, force=True))
M._queue = real_queue
out = buf.getvalue().splitlines()
has(out, "canon: inbox items not written yet (OSError: fixture: the inbox is not writable); the next run writes them", "lore canon reports it")
eq((out[-1], pushed(st), os.path.exists(st.local(lore_canon.LANDING))), (f"hub: pushed to {hub_dir(st)}", True, True), "and pushes what landed")
lore_canon.publish(st)

# F3: pending retirements follow their rule in op order: A -> B -> A ends at A (a Canon run and a
# plain batch alike); one proposed during the run moves only with the ops after it
st = new_store("r3-f3", hub=False)
seed(st, [add(A, FIRST), add(B, SECOND)])
r1 = rule_id(st, A, FIRST)
old = M.apply(st, [{"op": "retire", "rule_id": r1, "file": A, "reason": "pending"}], source="canon")["inbox"][0]
res = canon(A, [{"op": "move", "rule_id": r1, "to": B}, {"op": "move", "rule_id": r1, "to": A}])
eq(([s for _, s in res["commits"]], [(i["id"], i["payload"]["file"]) for i in retires(st)]),
   ([f"canon: move {A}", f"canon: move {B}"], [(old, A)]), "a Canon run there and back: the item still at A")
M.apply(st, [{"op": "move", "rule_id": r1, "to": B}, {"op": "move", "rule_id": r1, "to": A}], source="seed")
eq([(i["id"], i["payload"]["file"]) for i in retires(st)], [(old, A)], "a plain batch there and back: still at A")
st.write(C, lore_store.render_rules("Cedar", [FIRST])); commit_hand(st)   # a copy of the rule in C, adopted under the same id
eq(rule_id(st, C, FIRST), r1, "the copy shares the id")
res = canon(A, [{"op": "move", "rule_id": r1, "file": A, "to": B}, {"op": "move", "rule_id": r1, "file": C, "to": A},
                {"op": "retire", "rule_id": r1, "file": A, "reason": "the copy that came from C"}])
eq(([s for _, s in res["commits"]], sorted((i["payload"]["reason"], i["payload"]["file"]) for i in retires(st))),
   ([f"canon: move {A}", f"canon: move {C}"], [("pending", B), ("the copy that came from C", A)]),
   "each copy's item follows its own copy; one proposed after the moves is not moved by them")

# F4: a rejection keeps the file-qualified pair it answered: a copy of A's rule adopted in C (the
# same id) makes new pairs, and the one with B goes to Canon like the one with A
st = new_store("r3-f4", hub=False)
seed(st, [add(A, T[0]), add(B, T[1])])
ta, tb = rule_id(st, A, T[0]), rule_id(st, B, T[1])
M.inbox_reject(st, M.apply(st, [{"op": "retire", "rule_id": tb, "file": B, "reason": "duplicates the amber rule"}], source="canon")["inbox"][0])
st.write(C, lore_store.render_rules("Cedar", [T[0]])); commit_hand(st)
eq(rule_id(st, C, T[0]), ta, "the copy shares the id")
h = lore_canon.held(st, [f for f in lore_lint.lint(st) if f["gate"] == "duplicate"])
where = lambda fs: sorted(f["detail"].split(":")[0] for f in fs)
eq((where(h["kept"]), where(h["answered"])),
   (sorted([f"rules {ta} and {ta} in {A} and {C}", f"rules {tb} and {ta} in {B} and {C}"]), [f"rules {ta} and {tb} in {A} and {B}"]),
   "the B/C pair goes to Canon; only the A/B pair the owner answered is held")
print("ok")
PY

# 4. The commands: `lore lint` (no model, no writes), `lore canon [--force]`, `lore canon-log`.
log="$tmp/log"; calls="$tmp/canon-calls"
fail() { echo "FAIL: $*" >&2; echo "--- last output ---" >&2; cat "$log" >&2 || true; exit 1; }
ok()   { "$@" >"$log" 2>&1 || fail "$* exited non-zero"; }
has()  { grep -qxF -- "$1" "$log" || fail "${2:-output lacks the line: $1}"; }
hasre() { grep -qE -- "$1" "$log" || fail "${2:-output lacks a line matching: $1}"; }
ncalls() { if [[ -f "$calls" ]]; then wc -l < "$calls" | tr -d ' '; else echo 0; fi; }
S="$tmp/cli"
L() { python3 "$lore" --store2 "$S" "$@"; }
echo "-- commands"
rm -f "$calls"
python3 - <<'PY'
from harness import *
st = new_store("cli")
seed(st, [add("gotchas/git.md", "Pull before you push."), add("gotchas/git.md", "Read the diff before committing."),
          describe("gotchas/git.md", "a git command misbehaves")])
PY
ok L lint
[[ "$(cat "$log")" == "lint: no findings"$'\n'"note: stale gate off: no read data has been recorded on any machine"$'\n'"due: no run: no findings" ]] \
  || fail "lint on a quiet store: $(cat "$log")"
ok L canon
[[ "$(cat "$log")" == "canon: nothing to fix; no model call" ]] || fail "canon on a quiet store"
[[ "$(ncalls)" == 0 ]] || fail "canon called the model on a quiet store"
python3 - <<'PY'
from harness import *
st = lore_store.Store2(os.path.join(TMP, "cli"), day=DAY)
seed(st, [add("stack/go.md", "Run go vet before committing."), add("stack/go.md", "Pin the Go toolchain version.")])
PY
head="$(git -C "$S" rev-parse HEAD)"; status="$(git -C "$S" status --porcelain)"
local_state() { (cd "$S/.git/lore" && find . -type f | sort | xargs sha256sum); }
before_lint="$(local_state)"
ok L lint
[[ "$(grep -c . "$log")" == 3 ]] || fail "lint printed other than one finding, the note and the due line"
has "note: stale gate off: no read data has been recorded on any machine"
hasre '^orphan: stack/go\.md: .+$'
hasre '^due: run: .+$'
[[ "$(git -C "$S" rev-parse HEAD)" == "$head" && "$(git -C "$S" status --porcelain)" == "$status" && "$(ncalls)" == 0 ]] || fail "lint wrote or called"
[[ "$(local_state)" == "$before_lint" ]] || fail "lint wrote machine-local state"
printf '{"ops": [{"op": "describe", "file": "stack/go.md", "read_when": "writing Go"}], "answer": "described"}\n' > "$tmp/r.json"
FAKE_CANON=reply FAKE_CANON_REPLY="$tmp/r.json" ok L canon
[[ "$(ncalls)" == 1 ]] || fail "canon did not call the model once"
hasre '^committed [0-9a-f]{7,} canon: describe stack/go\.md$'
has "canon: 1 finding(s), 1 op(s), 1 commit(s)"
has "canon: described"
has "hub: pushed to $tmp/cli-hub.git"
[[ "$(git -C "$S" rev-parse HEAD)" == "$(git -C "$tmp/cli-hub.git" rev-parse main)" ]] || fail "canon did not push"
# inside the 24 hours a non-urgent finding is not run without --force, and --force runs it
python3 - <<'PY'
from harness import *
st = lore_store.Store2(os.path.join(TMP, "cli"), day=DAY)
seed(st, [add("stack/rust.md", "Run clippy before committing."), add("stack/rust.md", "Pin the Rust toolchain.")])
PY
ok L canon
hasre '^due: no run: .+$'
has "canon: not run (--force runs it now)"
[[ "$(ncalls)" == 1 ]] || fail "canon ran inside the 24 hours without --force"
printf '{"ops": [{"op": "describe", "file": "stack/rust.md", "read_when": "writing Rust"}, {"op": "link", "file": "stack/rust.md", "to": "stack/go.md"}]}\n' > "$tmp/r.json"
FAKE_CANON=reply FAKE_CANON_REPLY="$tmp/r.json" ok L canon --force
[[ "$(ncalls)" == 2 ]] || fail "canon --force did not call the model"
has "canon: 1 finding(s), 2 op(s), 2 commit(s)"
# a failing Canon exits non-zero, writes nothing
python3 - <<'PY'
from harness import *
st = lore_store.Store2(os.path.join(TMP, "cli"), day=DAY)
seed(st, [add("stack/zig.md", "Run zig fmt before committing."), add("stack/zig.md", "Pin the Zig version.")])
PY
head="$(git -C "$S" rev-parse HEAD)"
if FAKE_CANON=prose L canon --force >"$log" 2>&1; then fail "a non-JSON Canon reply exited 0"; fi
has "Error: canon FAILED, nothing written: the reply is not JSON"
[[ "$(git -C "$S" rev-parse HEAD)" == "$head" && -z "$(git -C "$S" status --porcelain)" ]] || fail "a failed canon wrote"
# after a failure, a plain `lore canon` keeps the backoff (no call) even when Canon is due; --force runs it
python3 - <<'PY'
from harness import *
forget_run(lore_store.Store2(os.path.join(TMP, "cli"), day=DAY))
PY
n="$(ncalls)"
FAKE_CANON=prose ok L canon
[[ "$(cat "$log")" == "canon: not run, backing off after a failed run (under 120 min ago; --force runs it now)" ]] || fail "canon ignored the backoff"
[[ "$(ncalls)" == "$n" ]] || fail "canon called the model while backing off"
if FAKE_CANON=prose L canon --force >"$log" 2>&1; then fail "a forced non-JSON Canon reply exited 0"; fi
[[ "$(ncalls)" == "$((n + 1))" ]] || fail "canon --force did not override the backoff"
# canon-log: exactly Canon's commits, newest first, one line each; nothing else
git -C "$S" log --format=%s | grep '^canon: ' > "$tmp/want.log" || true
[[ "$(cat "$tmp/want.log")" == "canon: link stack/rust.md"$'\n'"canon: describe stack/rust.md"$'\n'"canon: describe stack/go.md" ]] || fail "unexpected Canon history: $(cat "$tmp/want.log")"
ok L canon-log --days 1
[[ "$(sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}  [0-9a-f]{7,}  //' "$log")" == "$(cat "$tmp/want.log")" ]] || fail "canon-log is not exactly the Canon commits"
[[ "$(grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}  [0-9a-f]{7,}  canon: ' "$log")" == 3 ]] || fail "canon-log line format"
[[ "$(git -C "$S" log --format=%s | wc -l | tr -d ' ')" -gt 3 ]] || fail "the fixture has no other commits to leave out"
python3 - <<'PY'
from harness import *
new_store("nocanon", hub=False)
PY
python3 "$lore" --store2 "$tmp/nocanon" canon-log >"$log" 2>&1 || fail "canon-log on a store without Canon commits"
has "canon-log: no Canon commits in the last 7 day(s)"
if L canon-log --days 0 >"$log" 2>&1; then fail "canon-log --days 0 was accepted"; fi
has "Error: --days must be 1 or more"
# an owner change lore refuses to commit, staged by the owner: Canon's commit is dropped (the owner's
# side wins; exit 0, no failure) and the owner's tree and index are exactly as found
python3 - <<'PY'
from harness import *
st = lore_store.Store2(os.path.join(TMP, "cli"), day=DAY)
seed(st, [add("stack/nim.md", "Run nimpretty before committing."), add("stack/nim.md", "Pin the Nim version.")])
st.write("stack/nim.md", st.read("stack/nim.md") + "- my api_key = fixture-not-real-123456\n")
lore_store.tidy(st)
git(st.root, "add", "stack/nim.md")
PY
head="$(git -C "$S" rev-parse HEAD)"; status="$(git -C "$S" status --porcelain)"; n="$(ncalls)"
printf '{"ops": [{"op": "describe", "file": "stack/nim.md", "read_when": "writing Nim"}]}\n' > "$tmp/r.json"
FAKE_CANON=reply FAKE_CANON_REPLY="$tmp/r.json" ok L canon --force
hasre "^canon: dropped 1 commit\(s\): refused to commit: a secret-looking string in [^ ]+(, [^ ]+)* \(not shown\); remove it and commit again; the owner's side wins$"
has "canon: 2 finding(s), 1 op(s), 0 commit(s)"   # the zig and nim orphans
[[ "$(ncalls)" == "$((n + 1))" && "$(git -C "$S" rev-parse HEAD)" == "$head" && "$(git -C "$S" status --porcelain)" == "$status" ]] \
  || fail "a dropped landing touched the owner's store"
grep -qx 'M  stack/nim.md' <<<"$status" || fail "the fixture has no staged owner change: $status"
[[ ! -e "$S/.git/lore/canon" ]] || fail "the private checkout was left behind"
# the owner's own changes are committed before Canon's commit lands, and both are pushed
python3 - <<'PY'
from harness import *
st = lore_store.Store2(os.path.join(TMP, "cli"), day=DAY)
st.write("stack/nim.md", st.read("stack/nim.md").replace("- my api_key = fixture-not-real-123456\n", ""))
git(st.root, "reset", "-q"); lore_store.tidy(st)
eq(git(st.root, "status", "--porcelain"), "", "the fixture is clean again")
st.write("stack/nim.md", st.read("stack/nim.md") + "- Run nimble test before committing.\n")
PY
FAKE_CANON=reply FAKE_CANON_REPLY="$tmp/r.json" ok L canon --force
hasre "^committed [0-9a-f]{7,} edit stack/nim\.md \(before Canon's commits land\)$"
hasre '^committed [0-9a-f]{7,} canon: describe stack/nim\.md$'
[[ "$(git -C "$S" log -2 --format=%s)" == "canon: describe stack/nim.md"$'\n'"edit stack/nim.md" ]] || fail "the owner's commit is not first"
[[ "$(git -C "$S" rev-parse HEAD)" == "$(git -C "$tmp/cli-hub.git" rev-parse main)" ]] || fail "canon did not push both"
# 5. Role commands. A PATH of fictional scripts only (and the system tools lore needs), so no real
# agent CLI can be found: `claude` and `codex` are mise wrappers like the one soak 1 hit, resolved
# to the install they run; a mise shim too; an unresolvable wrapper is flagged. Then `check --live`
# reads the JSON roles' replies as a real run does.
echo "-- roles"
rm -f "$calls"
mkdir -p "$tmp/sysbin"
for t in git bash sh env cat cp wc tr grep sed sleep ps python3; do ln -sf "$(command -v "$t")" "$tmp/sysbin/$t"; done
BIN="$HOME/.local/bin"; INST="$HOME/.local/share/mise/installs"; mkdir -p "$BIN" "$INST/claude/2.0.1" "$INST/codex/0.9.1/bin"
ln -s 2.0.1 "$INST/claude/latest"; ln -s 0.9.1 "$INST/codex/latest"
for tool in claude codex; do
  cat > "$BIN/$tool" <<WRAP
#!/bin/bash
echo "wrapper ran" >> "$tmp/wrapper-ran"
export MISE_MINIMUM_RELEASE_AGE=0
mise use -g --quiet "$tool" || exit 1
exec mise x "$tool" -- "$tool" "\$@"
WRAP
  chmod +x "$BIN/$tool"
done
for real in "$INST/claude/2.0.1/claude" "$INST/codex/0.9.1/bin/codex"; do
  printf '#!/bin/sh\necho "$0" >> "%s/install-ran"\nexec "%s/fake-canon.sh"\n' "$tmp" "$tmp" > "$real"; chmod +x "$real"
done
P="$BIN:$tmp/sysbin"
S="$tmp/roles"
python3 - <<'PY'
from harness import *
st = new_store("roles")
seed(st, [add("stack/go.md", "Run go vet before committing."), add("stack/go.md", "Pin the Go toolchain version.")])
PY
noenv() { env -u LORE_CANON_CMD -u LORE_LOREMASTER_CMD -u LORE_EXTRACT_CMD -u LORE_REVIEW_CMD -u LORE_SYNC_CMD PATH="$P" "$@"; }
noenv python3 "$lore" --store2 "$S" check >"$log" 2>&1 || fail "check with resolvable wrappers"
[[ "$(cut -d: -f1 "$log" | tr '\n' ' ')" == "loremaster canon extract review sync not run live (add --live to call each model once) " ]] || fail "check rows: $(cat "$log")"
has "loremaster: ok  claude: $INST/claude/latest/claude -p --model sonnet --effort medium --tools \"\" --no-session-persistence --settings '{\"disableAllHooks\":true}' --output-format text < \"\$LORE_PROMPT_FILE\""
has "canon: ok  claude: $INST/claude/latest/claude -p --model opus --effort high --tools \"\" --no-session-persistence --settings '{\"disableAllHooks\":true}' --output-format text < \"\$LORE_PROMPT_FILE\""
hasre "^extract: ok  codex: $INST/codex/latest/bin/codex exec --ephemeral "
hasre "^review: ok  claude: $INST/claude/latest/claude -p --model opus "
hasre "^sync: ok  codex: $INST/codex/latest/bin/codex exec --ephemeral --disable hooks -s workspace-write "
# a version pinned in the wrapper, MISE_DATA_DIR, and a mise shim (a link to the mise binary)
sed -i 's/mise x "codex"/mise x "codex@0.9.1"/' "$BIN/codex"
noenv LORE_CANON_CMD="codex exec -" python3 "$lore" --store2 "$S" check >"$log" 2>&1 || fail "check with a pinned wrapper"
has "canon: ok  override: $INST/codex/0.9.1/bin/codex exec -"
mv "$HOME/.local/share/mise" "$tmp/mise-data"
noenv MISE_DATA_DIR="$tmp/mise-data" LORE_CANON_CMD="codex exec -" python3 "$lore" --store2 "$S" check >"$log" 2>&1 || fail "check with MISE_DATA_DIR"
has "canon: ok  override: $tmp/mise-data/installs/codex/0.9.1/bin/codex exec -"
mv "$tmp/mise-data" "$HOME/.local/share/mise"
mkdir -p "$tmp/shims" "$tmp/fakemise"; printf '#!/bin/sh\nexit 9\n' > "$tmp/fakemise/mise"; chmod +x "$tmp/fakemise/mise"
ln -s "$tmp/fakemise/mise" "$tmp/shims/codex"
env -u LORE_CANON_CMD PATH="$tmp/shims:$tmp/sysbin" LORE_CANON_CMD="codex exec -" python3 "$lore" --store2 "$S" check >"$log" 2>&1 || fail "check with a mise shim"
has "canon: ok  override: $INST/codex/latest/bin/codex exec -"
# run time: the session-end Canon runs the install, never the wrapper
printf 'canon: claude -p --model opus\n' >> "$S/.lore/config"
python3 - <<'PY'
from harness import *
st = lore_store.Store2(os.path.join(TMP, "roles"), day=DAY)
commit_hand(st, "fixture canon role")
reply([describe("stack/go.md", "writing Go")])
PY
noenv FAKE_CANON=reply FAKE_CANON_REPLY="$tmp/canon-reply.json" python3 "$lore" --store2 "$S" store run --trigger test:wrapper >"$log" 2>&1 || fail "store run with a wrapper role"
hasre '^[^ ]+ store-run: canon: committed [0-9a-f]{7,} canon: describe stack/go\.md$'
[[ "$(cat "$tmp/install-ran")" == "$INST/claude/latest/claude" ]] || fail "the install did not run once: $(cat "$tmp/install-ran" 2>/dev/null)"
[[ ! -e "$tmp/wrapper-ran" ]] || fail "the mise wrapper ran"
# the 1.x roles run the install too, through the same resolver (adapter choice and sync_cmd as before;
# the codex wrapper is pinned to 0.9.1 above)
rm -f "$tmp/install-ran" "$tmp/wrapper-ran"
noenv FAKE_CANON=empty-ops python3 - <<'PY' || fail "the 1.x roles with a resolvable wrapper"
from harness import *
import types
import lore_capture, lore_sync
for role in ("extract", "review"):
    eq(quiet(lore_capture.run_chain, [("codex", "codex exec -")], "a fictional prompt", role), [], f"{role} ran")
legacy = lore.Store(os.path.join(TMP, "legacy"), dt.date.today())
quiet(lore.cmd_init, legacy, types.SimpleNamespace(today=None))
legacy.write_atomic("config", "hub: fictional-local-hub\nsync_cmd: codex exec -\n")
try:
    quiet(lore_sync.cmd_sync_run, legacy, types.SimpleNamespace(trigger="test:sync", force=False))
except lore.LoreError:
    pass   # the fake syncs nothing; which binary ran is what counts here
PY
[[ "$(cat "$tmp/install-ran")" == "$INST/codex/0.9.1/bin/codex"$'\n'"$INST/codex/0.9.1/bin/codex"$'\n'"$INST/codex/0.9.1/bin/codex" ]] \
  || fail "extract, review and sync did not each run the install: $(cat "$tmp/install-ran" 2>/dev/null)"
[[ ! -e "$tmp/wrapper-ran" ]] || fail "a 1.x role ran the mise wrapper"
mv "$INST" "$tmp/installs-away"
rm -f "$tmp/install-ran"
noenv python3 - <<'PY' || fail "the 1.x roles with an unresolvable wrapper"
from harness import *
import types
import lore_capture, lore_sync
W = os.path.join(os.environ["HOME"], ".local/bin/codex")
why = f"{W} is a mise wrapper lore cannot resolve (it hangs without a terminal); name the real binary in the role's config line"
raises(lambda: quiet(lore_capture.run_chain, [("codex", "codex exec -")], "a fictional prompt", "extract"),
       lore_capture.ExtractError, f"codex: {why}", "extract refuses the wrapper")
legacy = lore.Store(os.path.join(TMP, "legacy"), dt.date.today())
raises(lambda: quiet(lore_sync.cmd_sync_run, legacy, types.SimpleNamespace(trigger="test:sync2", force=True)), lore.LoreError, why,
       "sync refuses the wrapper")
with open(legacy.path(lore_sync.LOG_NAME)) as f:
    last = json.loads(f.read().splitlines()[-1])
eq((last["action"], last["trigger"], last["error"]), ("fail", "test:sync2", why), "the refused sync is logged as a failure")
ok = os.path.join(TMP, "role-plain.sh")
with open(ok, "w") as f:
    f.write("#!/bin/sh\necho '[]'\n")
os.chmod(ok, 0o755)
eq(lore_hub.resolved_command(f"\"{ok}\" --flag 'a b'"), f"\"{ok}\" --flag 'a b'", "an absolute final binary runs unchanged")
eq(lore_hub.resolved_command("cd /tmp && echo '[]'"), "cd /tmp && echo '[]'", "a builtin first word is left to sh")
PY
[[ ! -e "$tmp/wrapper-ran" && ! -e "$tmp/install-ran" ]] || fail "an unresolvable wrapper ran"
mv "$tmp/installs-away" "$INST"
# wrapper detection reads shell words: a quoted absolute mise path after exec, env and VAR=value
printf '#!/bin/sh\necho "mise ran" >> "%s/mise-ran"\nexit 9\n' "$tmp" > "$tmp/fakemise/mise"
mkdir -p "$INST/cedar/1.0"
printf '#!/bin/sh\necho "$0" >> "%s/install-ran"\necho cedar-install\n' "$tmp" > "$INST/cedar/1.0/cedar"; chmod +x "$INST/cedar/1.0/cedar"
cat > "$BIN/cedar" <<WRAP
#!/bin/sh
echo "wrapper ran" >> "$tmp/wrapper-ran"
# mise x cedar -- this comment is not a command
exec env MISE_QUIET=1 "$tmp/fakemise/mise" --quiet x "cedar@1.0" -- cedar "\$@"
WRAP
cat > "$BIN/ghost" <<WRAP
#!/bin/sh
echo "wrapper ran" >> "$tmp/wrapper-ran"
exec '$tmp/fakemise/mise' exec ghost -- ghost "\$@"
WRAP
cat > "$BIN/plain" <<'WRAP'
#!/bin/sh
echo "say: mise x plain -- plain"
WRAP
printf '#!/bin/sh\necho "wrapper ran" >> "%s/wrapper-ran"\nexec mise x "broken -- broken\n' "$tmp" > "$BIN/broken"
chmod +x "$BIN/cedar" "$BIN/ghost" "$BIN/plain" "$BIN/broken"
rm -f "$tmp/install-ran"
noenv python3 - <<'PY' || fail "wrapper detection"
from harness import *
BIN, INST = os.path.join(os.environ["HOME"], ".local/bin"), os.path.join(os.environ["HOME"], ".local/share/mise/installs")
eq(lore_hub.run_command("cedar --go", "a fictional prompt").strip(), "cedar-install", "the quoted mise wrapper runs its install")
eq(lore_hub.resolve_binary("plain"), os.path.join(BIN, "plain"), "mise in a quoted word is no wrapper")
raises(lambda: lore_hub.run_command("ghost", "a fictional prompt"), lore.LoreError,
       f"{BIN}/ghost is a mise wrapper lore cannot resolve (it hangs without a terminal); name the real binary in the role's config line",
       "an unresolvable wrapper is refused")
raises(lambda: lore_hub.run_command("broken", "a fictional prompt"), lore.LoreError,
       f"{BIN}/broken is a mise wrapper lore cannot resolve (it hangs without a terminal); name the real binary in the role's config line",
       "a mise line that cannot be read is refused")
PY
[[ "$(cat "$tmp/install-ran")" == "$INST/cedar/1.0/cedar" ]] || fail "the cedar install did not run once"
[[ ! -e "$tmp/wrapper-ran" && ! -e "$tmp/mise-ran" ]] || fail "a wrapper or mise itself ran"
# an unresolvable wrapper: an adapter line is passed over and flagged; a config line is BROKEN
mv "$INST" "$tmp/installs-away"
if noenv python3 "$lore" --store2 "$S" check >"$log" 2>&1; then fail "check passed a config line naming an unresolvable wrapper"; fi
has "canon: BROKEN  config: $BIN/claude is a mise wrapper lore cannot resolve (it hangs without a terminal); name the real binary in the role's config line"
has "Error: a role command is broken"
sed -i '/^canon: /d' "$S/.lore/config"
noenv python3 "$lore" --store2 "$S" check >"$log" 2>&1 || fail "check with unresolvable adapter wrappers"
has "canon: unavailable  no command (no host adapter line, or its CLI is not installed); claude: $BIN/claude is a mise wrapper lore cannot resolve (it hangs without a terminal); name the real binary in the role's config line; codex: $BIN/codex is a mise wrapper lore cannot resolve (it hangs without a terminal); name the real binary in the role's config line"
hasre '^loremaster: unavailable  no command .*; claude: .* is a mise wrapper lore cannot resolve '
mv "$tmp/installs-away" "$INST"
# check --live: the JSON roles' replies are parsed and validated; the empty ops of the check prompt pass
printf '#!/bin/sh\necho ok\n' > "$tmp/role-ok.sh"; chmod +x "$tmp/role-ok.sh"
live() { env PATH="$P" LORE_LOREMASTER_CMD="$tmp/fake-canon.sh" LORE_CANON_CMD="$tmp/fake-canon.sh" LORE_EXTRACT_CMD="$tmp/role-ok.sh" \
  LORE_REVIEW_CMD="$tmp/role-ok.sh" LORE_SYNC_CMD="$tmp/role-ok.sh" FAKE_CANON="$1" python3 "$lore" --store2 "$S" check --live; }
rm -f "$calls"
live empty-ops >"$log" 2>&1 || fail "check --live with valid JSON replies"
hasre "^loremaster: ok  override: $tmp/fake-canon\.sh  live: ok in [0-9.]+s, replied [0-9]+ characters$"
hasre "^canon: ok  override: $tmp/fake-canon\.sh  live: ok in [0-9.]+s, replied [0-9]+ characters$"
[[ "$(ncalls)" == 2 ]] || fail "check --live did not call each JSON role once"
grep -qxF 'Reply with only this JSON and nothing else: {"ops": [], "answer": "ok"}' "$tmp/canon-prompt.2" || fail "the check prompt"
for m in prose empty bad-ops; do
  if live "$m" >"$log" 2>&1; then fail "check --live passed a $m reply"; fi
  has "Error: a role command is broken"
done
live prose >"$log" 2>&1 || true
has "loremaster: FAILED  override: $tmp/fake-canon.sh  live: the reply is not JSON"
has "canon: FAILED  override: $tmp/fake-canon.sh  live: the reply is not JSON"
live empty >"$log" 2>&1 || true
has "canon: FAILED  override: $tmp/fake-canon.sh  live: empty reply"
live bad-ops >"$log" 2>&1 || true
has "canon: FAILED  override: $tmp/fake-canon.sh  live: the reply's ops are not valid: op 1: add is not an operation this role may use"
hasre "^extract: ok  override: $tmp/role-ok\.sh  live: ok in "

# The shipped adapter lines: Canon on Claude opus high and Codex gpt-6.1-sol high, headless,
# ephemeral, tool-less or read-only, hooks off; Command Code and agy listed outside the default order.
hosts="$repo_root/skills/lore/hosts"
grep -qxF 'canon: claude -p --model opus --effort high --tools "" --no-session-persistence --settings '"'"'{"disableAllHooks":true}'"'"' --output-format text < "$LORE_PROMPT_FILE"' "$hosts/claude.conf" || fail "claude.conf canon line"
grep -qxF 'canon: codex exec --ephemeral --disable hooks -s read-only --skip-git-repo-check -m gpt-6.1-sol -c model_reasoning_effort=high - < "$LORE_PROMPT_FILE"' "$hosts/codex.conf" || fail "codex.conf canon line"
for h in cmd agy; do [[ "$(grep -cE '^canon: .*LORE_PROMPT_FILE' "$hosts/$h.conf")" == 1 ]] || fail "$h.conf has no single canon line"; done
echo "test-canon: all checks passed"
