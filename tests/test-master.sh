#!/usr/bin/env bash
# lore 2.0 Loremaster core tests: the operations and their validator (all or nothing, exact
# messages), apply as one commit per batch, sidecars kept consistent, reply parsing, the prompt's
# context cap, file_items with a fake model, the Inbox, and links merged across two stores on one
# hub. Never a real model (run_model is a Python function), never the network: the hub is a local
# bare repo. Temporary HOME; git sees no global config.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap '[[ -n "${KEEP:-}" ]] || rm -rf "$tmp"' EXIT
export HOME="$tmp/home"; mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset LORE_STORE LORE_STORE2 LORE_GH_CMD LORE_GIT_TIMEOUT LORE_LOREMASTER_CMD 2>/dev/null || true
export LORE_SCRIPTS="$repo_root/skills/lore/scripts" TMP_ROOT="$tmp" PYTHONDONTWRITEBYTECODE=1
export PYTHONPATH="$repo_root/tests/fixtures/master"
section() { echo "-- $1"; python3 -; }

# 1. validate: every op valid and invalid, with exact messages; nothing is written by validate.
section "validate" <<'PY'
from harness import *
st = new_store("v")
seed = [add("gotchas/git.md", "Never force-push a shared branch."),
        add("gotchas/git.md", "Read the diff before committing."),
        add("how-i-work/reviews.md", "Ask a second model to review every plan."),
        add("core.md", "Run the real command before claiming done.", core=True),
        {"op": "describe", "file": "gotchas/git.md", "read_when": "a git command misbehaves"}]
M.apply(st, seed, source="seed")
g1 = rule_id(st, "gotchas/git.md", "Never force-push a shared branch.")
g2 = rule_id(st, "gotchas/git.md", "Read the diff before committing.")
r1 = rule_id(st, "how-i-work/reviews.md", "Ask a second model to review every plan.")
c1 = rule_id(st, "core.md", "Run the real command before claiming done.")
I = [item("Never use sudo in scripts."), item("Prefer small commits.", explicit=False),
     item("Never force-push main or a shared branch.", quote="dont force push main or any shared branch")]
before = snapshot(st)
DOCKER = "gotchas/docker.md"
top7 = ["profile.md", "how-i-work/", "preferences/", "safety/", "stack/", "gotchas/", "tools/"]
valid = [
    [add(DOCKER, "Never use sudo in scripts.")],
    [add(DOCKER, "Never use sudo in scripts."), {"op": "describe", "file": DOCKER, "read_when": "touching Docker"},
     {"op": "link", "file": DOCKER, "to": "gotchas/git.md"}],
    [add("core.md", "Never use sudo in scripts.", core=True)],
    [add("how-i-work/commits.md", "Prefer small commits.", explicit=False, session="")],
    [{"op": "describe", "file": "how-i-work/reviews.md", "read_when": "planning a review"}],
    [{"op": "link", "file": "gotchas/git.md", "to": "how-i-work/reviews.md"},
     {"op": "unlink", "file": "gotchas/git.md", "to": "how-i-work/reviews.md"}],
    [{"op": "move", "rule_id": g2, "to": "how-i-work/reviews.md"}],
    [{"op": "supersede", "rule_id": g1, "text": "Never force-push main or a shared branch.",
      "quote": "dont force push main or any shared branch"}],
    [{"op": "flag-contradiction", "rule_id": g2, "with_text": "Commit without reading the diff in a hurry."}],
    [{"op": "retire", "rule_id": r1, "reason": "the user withdrew it"}],
    [{"op": "propose-layout", "top": top7, "reason": "tools gather many rules"}],
    [{"op": "supersede", "rule_id": g1, "text": "Never force-push main or a shared branch.",
      "quote": "dont force push main or any shared branch"}, {"op": "move", "rule_id": g1, "to": "how-i-work/reviews.md"}],
]
for n, ops in enumerate(valid, 1):
    eq(M.validate(st, ops, I), [], f"valid batch {n}")
SECRET = "token=fixture-not-real-123"
GHP = "ghp_fixturefixturefixture00"
A = lambda **kw: dict(add(DOCKER, "Never use sudo in scripts."), **kw)
invalid = [
    ({"op": "add"}, ["ops must be a list"]),
    (["x"], ["op 1: not an object"]),
    ([{"op": "zap"}], ["op 1: unknown op 'zap'"]),
    ([{"file": DOCKER}], ["op 1: unknown op 'None'"]),
    ([{"op": GHP}], ["op 1: unknown op '[REDACTED]'"]),
    ([A(category="docker")], ["op 1 (add): unknown field(s) category"]),
    ([{k: v for k, v in A().items() if k != "session"}], ["op 1 (add): missing field(s) session"]),
    ([A(explicit="yes")], ["op 1 (add): explicit must be true or false"]),
    ([A(core=1)], ["op 1 (add): core must be true or false"]),
    ([A(text=5)], ["op 1 (add): text must be a string"]),
    ([{"op": "propose-layout", "top": "tools/", "reason": "r"}], ["op 1 (propose-layout): top must be a list"]),
    ([A(text="Never use sudo\nin scripts.")], ["op 1 (add): text must be one line"]),
    ([A(text="   ")], ["op 1 (add): text is empty"]),
    ([A(text="x" * 301)], ["op 1 (add): text is longer than 300 characters"]),
    ([A(text="Set " + SECRET + " in CI.")], ["op 1 (add): a secret-looking string in text (not shown)"]),
    ([A(quote="my " + SECRET)], ["op 1 (add): a secret-looking string in quote (not shown)"]),
    ([A(file="gotchas/" + GHP.lower() + ".md")], ["op 1 (add): a secret-looking string in file (not shown)"]),
    ([{"op": "propose-layout", "top": ["profile.md", GHP + "/"], "reason": "r"}],
     ["op 1 (propose-layout): a secret-looking string in top (not shown)"]),
    ([A(file="../x.md")], ["op 1 (add): file '../x.md' escapes the store"]),
    ([A(file="gotchas/../../x.md")], ["op 1 (add): file 'gotchas/../../x.md' escapes the store"]),
    ([A(file="/etc/x.md")], ["op 1 (add): file '/etc/x.md' escapes the store"]),
    ([A(file="gotchas\\x.md")], ["op 1 (add): file 'gotchas\\\\x.md' escapes the store"]),
    ([A(file=".lore/meta/x.md")], ["op 1 (add): file '.lore/meta/x.md' is inside .lore/"]),
    ([A(file="gotchas/.lore/x.md")], ["op 1 (add): file 'gotchas/.lore/x.md' is inside .lore/"]),
    ([A(file="gotchas/docker.txt")], ["op 1 (add): file 'gotchas/docker.txt' is not a .md file"]),
    ([A(file="gotchas/Docker.md")], ["op 1 (add): file 'gotchas/Docker.md' is not a valid file name (lowercase letters, digits, - . _)"]),
    ([A(file="gotchas//docker.md")], ["op 1 (add): file 'gotchas//docker.md' is not a valid file name (lowercase letters, digits, - . _)"]),
    ([A(file="notes/docker.md")], ["op 1 (add): file 'notes/docker.md' is not in the layout"]),
    ([A(file="docker.md")], ["op 1 (add): file 'docker.md' is not in the layout"]),
    ([A(file="INDEX.md")], ["op 1 (add): file 'INDEX.md' is not a valid file name (lowercase letters, digits, - . _)"]),
    ([A(file="index.md")], ["op 1 (add): file 'index.md' is not in the layout"]),
    ([{"op": "link", "file": "gotchas/git.md", "to": "../git.md"}], ["op 1 (link): to '../git.md' escapes the store"]),
    ([{"op": "move", "rule_id": g1, "to": "secrets/x.md"}], ["op 1 (move): to 'secrets/x.md' is not in the layout"]),
    ([A(core=True, explicit=False)], ["op 1 (add): core needs explicit: true (only a rule stated outright goes to core)"]),
    ([A(core=True)], ["op 1 (add): core: true needs file core.md"]),
    ([A(file="core.md")], ["op 1 (add): core.md takes a rule only with core: true"]),
    ([A(file="core.md", core=False)], ["op 1 (add): core.md takes a rule only with core: true"]),
    ([add("core.md", "Prefer small commits.", explicit=True, core=True)],
     ["op 1 (add): explicit is true but its item is not explicit"]),
    ([A(quote="something the user never said")], ["op 1 (add): quote is not the words of any queued item"]),
    ([A(quote="")], ["op 1 (add): quote is not the words of any queued item"]),
    ([add(DOCKER, "never FORCE-push a shared branch", quote="Never use sudo in scripts.")],
     [f"op 1 (add): duplicate of rule {g1} in gotchas/git.md"]),
    ([A(), add("gotchas/shell.md", "Never use sudo in scripts!", quote="Never use sudo in scripts.")],
     [f"op 2 (add): duplicate of rule {lore_store.new_id('Never use sudo in scripts.', set())} in gotchas/docker.md"]),
    ([{"op": "describe", "file": DOCKER, "read_when": "touching Docker"}],
     ["op 1 (describe): gotchas/docker.md does not exist (a new topic file is created only by add)"]),
    ([{"op": "link", "file": "gotchas/git.md", "to": DOCKER}],
     ["op 1 (link): gotchas/docker.md does not exist (a new topic file is created only by add)"]),
    ([{"op": "unlink", "file": DOCKER, "to": "gotchas/git.md"}],
     ["op 1 (unlink): gotchas/docker.md does not exist (a new topic file is created only by add)"]),
    ([{"op": "move", "rule_id": g1, "to": DOCKER}],
     ["op 1 (move): gotchas/docker.md does not exist (a new topic file is created only by add)"]),
    ([{"op": "describe", "file": "core.md", "read_when": "always"}],
     ["op 1 (describe): core.md takes no read_when or links (it is always loaded)"]),
    ([{"op": "link", "file": "gotchas/git.md", "to": "core.md"}],
     ["op 1 (link): core.md takes no read_when or links (it is always loaded)"]),
    ([{"op": "link", "file": "gotchas/git.md", "to": "gotchas/git.md"}], ["op 1 (link): a topic cannot link to itself"]),
    ([{"op": "describe", "file": "gotchas/git.md", "read_when": "Read when "}], ["op 1 (describe): read_when is empty"]),
    ([{"op": "describe", "file": "gotchas/git.md", "read_when": ""}], ["op 1 (describe): read_when is empty"]),
    ([{"op": "move", "rule_id": "deadbeef", "to": "gotchas/git.md"}], ["op 1 (move): no rule with id 'deadbeef'"]),
    ([{"op": "supersede", "rule_id": "deadbeef", "text": "x", "quote": "Prefer small commits."}],
     ["op 1 (supersede): no rule with id 'deadbeef'"]),
    ([{"op": "flag-contradiction", "rule_id": "deadbeef", "with_text": "x"}], ["op 1 (flag-contradiction): no rule with id 'deadbeef'"]),
    ([{"op": "retire", "rule_id": "deadbeef", "reason": "old"}], ["op 1 (retire): no rule with id 'deadbeef'"]),
    ([{"op": "retire", "rule_id": r1, "reason": " "}], ["op 1 (retire): reason is empty"]),
    ([{"op": "move", "rule_id": c1, "to": "gotchas/git.md"}], ["op 1 (move): core.md changes only through the inbox"]),
    ([{"op": "move", "rule_id": g1, "to": "core.md"}], ["op 1 (move): core.md changes only through the inbox"]),
    ([{"op": "move", "rule_id": g1, "to": "gotchas/git.md"}], [f"op 1 (move): rule {g1} is already in gotchas/git.md"]),
    ([{"op": "supersede", "rule_id": g1, "text": "never force push a shared branch", "quote": "Prefer small commits."}],
     ["op 1 (supersede): the text is unchanged"]),
    ([{"op": "supersede", "rule_id": g1, "text": "Read the diff before committing!", "quote": "Prefer small commits."}],
     [f"op 1 (supersede): duplicate of rule {g2} in gotchas/git.md"]),
    ([{"op": "supersede", "rule_id": g1, "text": "Never force-push main.", "quote": "made up"}],
     ["op 1 (supersede): quote is not the words of any queued item"]),
    ([{"op": "propose-layout", "top": [], "reason": "r"}], ["op 1 (propose-layout): top must be a non-empty list of names"]),
    ([{"op": "propose-layout", "top": ["profile.md", 3], "reason": "r"}], ["op 1 (propose-layout): top must be a non-empty list of names"]),
    ([{"op": "propose-layout", "top": ["profile.md", "Bad/", "core.md", "stack/", "stack/", "notes"], "reason": "r"}],
     ["op 1 (propose-layout): top entry 'Bad/' is not a folder/ or a file.md name",
      "op 1 (propose-layout): core.md is not a layout entry",
      "op 1 (propose-layout): top entry 'notes' is not a folder/ or a file.md name",
      "op 1 (propose-layout): top lists an entry twice"]),
    # several problems: each reported once, in order; the valid op between them is not
    ([{"op": "zap"}, A(), A(file="../x.md")], ["op 1: unknown op 'zap'", "op 3 (add): file '../x.md' escapes the store"]),
]
for n, (ops, want) in enumerate(invalid, 1):
    got = M.validate(st, ops, I)
    eq(got, want, f"invalid batch {n}")
    for msg in got:
        if "fixture-not-real" in msg or "fixturefixture" in msg:
            fail(f"a message echoes a secret: {msg}")
# without items, quotes and explicit are not checked against a queue
eq(M.validate(st, [A(quote="anything")]), [], "no items: quote not checked")
eq(snapshot(st), before, "validate wrote nothing")

# A hand edit not yet tidied: validate sees the id the next tidy will write; the same line in two
# files is one id in two files, so a rule_id op on it is refused as ambiguous.
amb = new_store("amb")
for rel in ("gotchas/a.md", "gotchas/b.md"):
    amb.write(rel, "- Same rule twice.\n")
hid = lore_store.new_id("Same rule twice.", set())
eq(M.validate(amb, [{"op": "retire", "rule_id": hid, "reason": "dup"}]),
   [f"op 1 (retire): rule id {hid} is in more than one file (gotchas/a.md, gotchas/b.md)"], "ambiguous id")
amb.write("gotchas/b.md", "- Another hand rule.\n")
eq(M.validate(amb, [{"op": "retire", "rule_id": hid, "reason": "dup"}]), [], "hand edit id before tidy")
lore_store.reconcile(amb)
eq(rule_id(amb, "gotchas/a.md", "Same rule twice."), hid, "tidy writes the id validate used")
print("ok")
PY

# 2. apply: each op's effect, one commit per batch, sidecars consistent with the rule lines.
section "apply" <<'PY'
from harness import *
st = new_store("a")
n0 = commits(st)
# a prose line in a rule file is kept through every edit
st.write("gotchas/git.md", "# Git\n\nSee also the team handbook.\n")
lore_store.tidy(st); lore_store.commit(st, "hand prose")
n0 = commits(st)
res = M.apply(st, [add("gotchas/git.md", "Never force-push a shared branch.", session="s-9"),
                   add("gotchas/git.md", "Read the diff before committing.", explicit=False),
                   add("gotchas/docker.md", "Never use sudo in scripts."),
                   {"op": "describe", "file": "gotchas/docker.md", "read_when": "Read when touching Docker"},
                   {"op": "link", "file": "gotchas/docker.md", "to": "gotchas/git.md"},
                   add("core.md", "Run the real command before claiming done.", core=True)], source="loremaster")
eq(commits(st), n0 + 1, "one batch, one commit")
eq(res["commit"], git(st, "rev-parse", "--short", "HEAD"), "apply returns the commit")
eq(res["inbox"], [], "no inbox items")
eq(res["changed"], [".lore/meta/core.json", ".lore/meta/gotchas/docker.json", ".lore/meta/gotchas/git.json",
                    "core.md", "gotchas/docker.md", "gotchas/git.md"], "changed paths")
eq(subject(st), "loremaster: edit core.md; add gotchas/docker.md; edit gotchas/git.md", "commit subject")
eq(st.read("gotchas/git.md"), "# Git\n\nSee also the team handbook.\n- Never force-push a shared branch.\n"
   "- Read the diff before committing.\n", "rules appended, prose kept")
eq(st.read("gotchas/docker.md"), "# Docker\n\n- Never use sudo in scripts.\n", "new topic file")
eq(st.read("core.md"), "# Core\n\n- Run the real command before claiming done.\n", "core rule")
if "- Run the real command before claiming done." not in st.read("INDEX.md").splitlines():
    fail("the index does not carry the new core rule")
dm = meta(st, "gotchas/docker.md")
eq((dm["read_when"], dm["links"]), ("touching Docker", ["gotchas/git.md"]), "describe and link")
g1 = rule_id(st, "gotchas/git.md", "Never force-push a shared branch.")
e = meta(st, "gotchas/git.md")["rules"][g1]
eq({k: e[k] for k in ("text", "created", "explicit", "count", "dates", "confidence", "sessions", "quote")},
   {"text": "Never force-push a shared branch.", "created": "2026-10-01", "explicit": True, "count": 1,
    "dates": ["2026-10-01"], "confidence": lore.NEW_EXPLICIT, "sessions": ["s-9"],
    "quote": "Never force-push a shared branch."}, "add's sidecar entry")
g2 = rule_id(st, "gotchas/git.md", "Read the diff before committing.")
eq(meta(st, "gotchas/git.md")["rules"][g2]["confidence"], lore.NEW_CANDIDATE, "a non-explicit rule starts lower")
eq(g1, lore_store.new_id("Never force-push a shared branch.", set()), "ids are lore_store's")
consistent(st)
eq(git(st, "status", "--porcelain"), "", "nothing left uncommitted")

# move: line and sidecar entry go together, the id is kept, the source keeps its prose
n = commits(st)
M.apply(st, [{"op": "move", "rule_id": g2, "to": "gotchas/docker.md"}], source="loremaster")
eq(commits(st), n + 1, "move is one commit")
eq(st.read("gotchas/git.md"), "# Git\n\nSee also the team handbook.\n- Never force-push a shared branch.\n", "moved out")
eq(st.read("gotchas/docker.md"), "# Docker\n\n- Never use sudo in scripts.\n- Read the diff before committing.\n", "moved in")
eq(g2 in meta(st, "gotchas/git.md")["rules"], False, "entry left the source sidecar")
eq(meta(st, "gotchas/docker.md")["rules"][g2]["text"], "Read the diff before committing.", "entry moved with its id")
eq(meta(st, "gotchas/docker.md")["rules"][g2]["created"], "2026-10-01", "the moved entry keeps its metadata")
consistent(st)

# supersede: replaced in place, id kept, contradictions cleared, the old words gone everywhere
M.apply(st, [add("gotchas/git.md", "Pull before you push.")], source="loremaster")
M.apply(st, [{"op": "flag-contradiction", "rule_id": g1, "with_text": "Force-push when you own the branch."},
             {"op": "flag-contradiction", "rule_id": g1, "with_text": "Force-push when you own the branch."}], source="loremaster")
eq(meta(st, "gotchas/git.md")["rules"][g1]["contradictions"],
   [{"with": "Force-push when you own the branch.", "flagged": "2026-10-01"}], "flag recorded once")
n = commits(st)
M.apply(st, [{"op": "supersede", "rule_id": g1, "text": "Never force-push main or a shared branch.",
              "quote": "dont force push main"}], source="loremaster")
eq(commits(st), n + 1, "supersede is one commit")
eq(st.read("gotchas/git.md"), "# Git\n\nSee also the team handbook.\n- Never force-push main or a shared branch.\n"
   "- Pull before you push.\n", "replaced in place")
e = meta(st, "gotchas/git.md")["rules"][g1]
eq((e["text"], e["quote"], e.get("superseded"), "contradictions" in e),
   ("Never force-push main or a shared branch.", "dont force push main", "2026-10-01", False), "superseded entry")
out = subprocess.run(["grep", "-rlF", "Never force-push a shared branch.", "--exclude-dir=.git", st.root],
                     capture_output=True, text=True).stdout
eq(out, "", "the old text is gone from every file")
consistent(st)

# unlink, retire and propose-layout: retire and layout are inbox items, not applied, no commit
M.apply(st, [{"op": "unlink", "file": "gotchas/docker.md", "to": "gotchas/git.md"}], source="loremaster")
eq(meta(st, "gotchas/docker.md")["links"], [], "unlinked")
n = commits(st)
res = M.apply(st, [{"op": "retire", "rule_id": g1, "reason": "the user withdrew it"},
                   {"op": "propose-layout", "top": ["profile.md", "how-i-work/", "tools/"], "reason": "tools"}], source="loremaster")
eq((res["commit"], res["changed"], commits(st)), (None, [], n), "inbox ops write no rule file")
eq([i[0] for i in res["inbox"]], ["r", "l"], "two inbox items")
eq(st.read("gotchas/git.md").count("Never force-push main or a shared branch."), 1, "retire not applied")
eq(st.layout(), ["profile.md", "how-i-work/", "preferences/", "safety/", "stack/", "gotchas/"], "layout not applied")
print("ok")
PY

# 3. All or nothing: a rejected batch writes nothing; a commit refused after the writes puts every
# file back.
section "rejected" <<'PY'
from harness import *
st = new_store("r")
M.apply(st, [add("gotchas/git.md", "Never force-push a shared branch.")], source="seed")
before = snapshot(st)
bad = [add("gotchas/docker.md", "Never use sudo in scripts."),
       {"op": "describe", "file": "gotchas/docker.md", "read_when": "touching Docker"},
       add("gotchas/shell.md", "Quote every variable token=fixture-not-real-123.")]
try:
    M.apply(st, bad, source="loremaster")
    fail("an invalid batch was applied")
except M.OpsError as err:
    eq(err.messages, ["op 3 (add): a secret-looking string in quote (not shown)",
                      "op 3 (add): a secret-looking string in text (not shown)"], "the rejection")
    if "fixture-not-real" in str(err):
        fail("the rejection echoes the secret")
eq(snapshot(st), before, "a rejected batch wrote nothing")
calls = []
res = M.file_items(st, [item("Never use sudo in scripts.")], fake({"ops": bad[:2] + [add("../x.md", "Never use sudo in scripts.")]}, calls))
eq(res["rejected"], ["op 3 (add): file '../x.md' escapes the store"], "file_items reports the rejection")
eq((res["commit"], res["changed"], res["inbox"]), (None, [], []), "file_items wrote nothing")
eq(len(calls), 1, "one model call")
eq(snapshot(st), before, "a rejected file_items wrote nothing")
# A valid batch whose commit is refused (a secret planted by hand elsewhere): the batch's files and
# every sidecar tidy touched go back as they were.
st.write("safety/keys.md", "- keep ghp_fixturefixturefixture00 out\n")
before = snapshot(st)
try:
    M.apply(st, [add("gotchas/docker.md", "Never use sudo in scripts.")], source="loremaster")
    fail("a commit holding a secret went through")
except M.OpsError:
    fail("a valid batch was rejected")
except lore.LoreError as err:
    eq(str(err), "refused to commit: a secret-looking string in .lore/meta/safety/keys.json, safety/keys.md (not shown); remove it and commit again", "commit refusal")
eq(snapshot(st), before, "a refused commit left no file behind")
print("ok")
PY

# 4. Replies: fences and stray text tolerated, anything else refused; file_items end to end.
section "replies" <<'PY'
from harness import *
ok = {"ops": [], "answer": "nothing new"}
J = json.dumps(ok)
for text in (J, "```json\n" + J + "\n```", "```\n" + J + "\n```", "Here you go:\n```json\n" + J + "\n```\nDone.",
             "Use {braces} like this:\n```json\n" + J + "\n```",
             "Sure. " + J + " Bye.", "  \n" + J + "\n"):
    eq(M.parse_reply(text), ok, f"reply {text[:20]!r}")
eq(M.parse_reply('{"ops": []}'), {"ops": [], "answer": ""}, "answer is optional")
for text, msg in (("", "the reply is empty"), ("   ", "the reply is empty"), (None, "the reply is empty"),
                  ('{"ops": [', "the reply is not JSON"), ("```json\n{\"ops\": [}\n```", "the reply is not JSON"),
                  ("no json here", "the reply is not JSON"), ("[1, 2]", "the reply is not a JSON object"),
                  ('{"ops": {}}', "the reply has no ops list"), ('{"answer": "x"}', "the reply has no ops list"),
                  ('{"ops": [], "notes": 1, "ghp_fixturefixturefixture00": 2}', "unknown reply field(s): [REDACTED], notes"),
                  ('{"ops": [], "answer": 5}', "answer must be a string")):
    raises(lambda: M.parse_reply(text), M.ReplyError, msg, f"reply {text!r}")

st = new_store("f")
before = snapshot(st)
calls = []
eq(M.file_items(st, [], fake(ok, calls)), {"commit": None, "changed": [], "inbox": [], "answer": "", "rejected": []}, "no items")
eq(calls, [], "no items, no model call")
raises(lambda: M.file_items(st, [item("x rule")], fake("not json")), M.ReplyError, "the reply is not JSON", "broken reply")
eq(snapshot(st), before, "a broken reply wrote nothing")
items = [item("Never use sudo in scripts.", session="s-2"), item("Prefer small commits.", explicit=False, session="s-3")]
reply = {"ops": [add("gotchas/shell.md", "Never use sudo in scripts.", session="s-2"),
                 {"op": "describe", "file": "gotchas/shell.md", "read_when": "writing shell scripts"},
                 add("how-i-work/commits.md", "Prefer small commits.", explicit=False, session="s-3")],
         "answer": "filed 2; key ghp_fixturefixturefixture00"}
n = commits(st)
res = M.file_items(st, items, fake(reply, calls))
eq(len(calls), 1, "one call per batch")
eq((res["rejected"], res["answer"], commits(st)), ([], "filed 2; key [REDACTED]", n + 1), "filed in one commit")
eq(res["commit"], git(st, "rev-parse", "--short", "HEAD"), "file_items returns the commit")
eq(subject(st), "loremaster: add gotchas/shell.md; add how-i-work/commits.md", "subject")
consistent(st)
# explicit claimed for an item that was not explicit: rejected through file_items
res = M.file_items(st, [item("Prefer rebase over merge.", explicit=False)],
                   fake({"ops": [add("core.md", "Prefer rebase over merge.", core=True)]}))
eq(res["rejected"], ["op 1 (add): explicit is true but its item is not explicit"], "core needs an explicit item")
print("ok")
PY

# 5. The prompt: the index, core rules with ids, and at most three topic files by word overlap,
# within the cap, cut by whole lines only; items reach the model with secrets redacted.
section "context" <<'PY'
from harness import *
st = new_store("c")
ops = [add("core.md", "Run the real docker command before claiming done.", core=True),
       {"op": "describe", "file": "profile.md", "read_when": "you need to know who the user is"}]
topics = {"gotchas/docker.md": ["Docker compose files pin every image tag", "Docker builds use the cache mount for pip"],
          "gotchas/git.md": ["Never rebase a shared branch in git", "Docker images are never committed to git"],
          "gotchas/shell.md": ["Quote every variable in shell scripts", "Docker exec needs -it only in a terminal"],
          "how-i-work/reviews.md": ["Ask a second model for every plan review"],
          "stack/python.md": ["Pin python dependencies with hashes", "Docker python images use slim variants",
                              "Compose healthchecks call python scripts"]}
for rel, rules in topics.items():
    ops += [add(rel, r + ".") for r in rules]
    ops.append({"op": "describe", "file": rel, "read_when": "the task touches " + rel[:-3].split("/")[-1]})
M.apply(st, ops, source="seed")
items = [item("Docker compose healthchecks should pin python image tags.")]
full = M.select_context(st, items, cap_chars=10**6)
eq(sorted(full["files"]), ["gotchas/docker.md", "gotchas/git.md", "stack/python.md"], "three closest topics")
eq(len(full["files"]) <= 3 and "core.md" not in full["files"] and "how-i-work/reviews.md" not in full["files"], True, "no core, no zero overlap")
eq(full["index"], lore_store.build_index(st)[0], "the whole index when it fits")
did = rule_id(st, "gotchas/docker.md", "Docker compose files pin every image tag.")
eq(full["files"]["gotchas/docker.md"].splitlines()[0], f"- [{did}] Docker compose files pin every image tag.", "rules carry ids")
cid = rule_id(st, "core.md", "Run the real docker command before claiming done.")
eq(full["core"], f"- [{cid}] Run the real docker command before claiming done.\n", "core rules with their ids")
total = lambda c: len(c["index"]) + len(c["core"]) + sum(len(t) for t in c["files"].values())
whole = total(full)
lines = set(full["index"].splitlines()) | set(full["core"].splitlines()) | {l for t in full["files"].values() for l in t.splitlines()}
for cap in list(range(0, whole + 40, 7)) + [whole, whole - 1, len(full["index"]), len(full["index"]) + 1]:
    c = M.select_context(st, items, cap_chars=cap)
    if total(c) > cap:
        fail(f"cap {cap}: {total(c)} characters")
    for part in [c["index"], c["core"]] + list(c["files"].values()):
        if part and not part.endswith("\n"):
            fail(f"cap {cap}: a part does not end on a whole line")
        for l in part.splitlines():
            if l not in lines:
                fail(f"cap {cap}: a split line {l!r}")
    eq(c["index"], full["index"][:len(c["index"])], f"cap {cap}: the index is cut from its end")
    eq(c["core"], full["core"][:len(c["core"])], f"cap {cap}: core is cut from its end")
    for rel, t in c["files"].items():
        eq(full["files"][rel][:len(t)], t, f"cap {cap}: {rel} is cut from its end")
        if not t:
            fail(f"cap {cap}: an empty file was included")
eq(M.select_context(st, items, cap_chars=whole), full, "exactly at the cap: everything")
eq(M.select_context(st, [item("unrelated words entirely")])["files"], {}, "no overlap, no files")

prompt = M.build_prompt(st, [item("Keep key token=fixture-not-real-123 out of logs.")], full)
eq(prompt.splitlines()[0], "# You are the Loremaster", "instructions first")
if "fixture-not-real" in prompt or "[REDACTED]" not in prompt:
    fail("an item's secret reached the prompt")
for part in ["## Index", "## Items to file", "### gotchas/docker.md", "## Core rules (ids in brackets)",
             f"- [{cid}] Run the real docker command before claiming done.",
             "Top level: `profile.md`, `how-i-work/`, `preferences/`, `safety/`, `stack/`, `gotchas/`, and `core.md` (rules for every task)."]:
    if part not in prompt.splitlines():
        fail(f"the prompt lacks the line {part!r}")
print("ok")
PY

# 6. The Inbox: retirements and layout proposals from ops, hand edits, P1's layout proposals.
section "inbox" <<'PY'
from harness import *
st = new_store("i")
M.apply(st, [add("gotchas/git.md", "Never force-push a shared branch."), add("gotchas/git.md", "Pull before you push."),
             add("stack/go.md", "Run go vet before committing.")], source="seed")
g1 = rule_id(st, "gotchas/git.md", "Never force-push a shared branch.")
g2 = rule_id(st, "gotchas/git.md", "Pull before you push.")
ret = {"op": "retire", "rule_id": g1, "reason": "the user withdrew it"}
r = M.apply(st, [ret], source="loremaster")["inbox"][0]
eq(M.apply(st, [ret], source="loremaster")["inbox"], [r], "the same proposal is one item")
L = M.inbox_list(st)
eq([(i["id"], i["kind"], i["source"], i["payload"]) for i in L],
   [(r, "retire", "loremaster", {"rule_id": g1, "file": "gotchas/git.md", "text": "Never force-push a shared branch.",
                                 "reason": "the user withdrew it"})], "one retire item")
eq(sorted(L[0]), ["created", "id", "kind", "payload", "source"], "item fields")
n = commits(st)
res = M.inbox_accept(st, r)
eq((res["kind"], commits(st), subject(st)), ("retire", n + 1, f"inbox: retire {g1} from gotchas/git.md"), "retire accepted")
eq(st.read("gotchas/git.md"), "# Git\n\n- Pull before you push.\n", "rule removed")
eq(g1 in meta(st, "gotchas/git.md")["rules"], False, "entry removed")
eq(M.inbox_list(st), [], "accepted item gone")
consistent(st)
raises(lambda: M.inbox_accept(st, r), lore.LoreError, f"no inbox item {r}", "accepted twice")

# a retirement whose rule changed since is refused; reject drops it with no commit
r2 = M.apply(st, [{"op": "retire", "rule_id": g2, "reason": "obsolete"}], source="loremaster")["inbox"][0]
M.apply(st, [{"op": "supersede", "rule_id": g2, "text": "Pull with rebase before you push.", "quote": "x"}], source="loremaster")
raises(lambda: M.inbox_accept(st, r2), lore.LoreError,
       f"inbox item {r2}: rule {g2} is gone from gotchas/git.md or its words changed; reject the item", "stale retire")
n = commits(st)
M.inbox_reject(st, r2)
eq((M.inbox_list(st), commits(st)), ([], n), "rejected without a commit")

# a layout proposal: accepted as its own commit; one that strands rules is refused
top = ["profile.md", "how-i-work/", "preferences/", "safety/", "stack/", "gotchas/", "tools/"]
l1 = M.apply(st, [{"op": "propose-layout", "top": top, "reason": "tools"}], source="loremaster")["inbox"][0]
l2 = M.apply(st, [{"op": "propose-layout", "top": ["profile.md", "gotchas/"], "reason": "fewer"}], source="loremaster")["inbox"][0]
eq([i["kind"] for i in M.inbox_list(st)], ["layout", "layout"], "two layout items")
raises(lambda: M.inbox_accept(st, l2), lore.LoreError,
       f"inbox item {l2}: the new layout drops content still in stack/go.md; move it first", "stranding layout")
n = commits(st)
res = M.inbox_accept(st, l1)
eq((res["kind"], commits(st), st.layout()), ("layout", n + 1, top), "layout accepted")
eq(subject(st), M._cap(f"inbox: accept layout {l1}: " + ", ".join(top)), "layout subject")
eq(git(st, "show", "--name-only", "--format=", "HEAD").splitlines(), [".lore/layout.json", "tools/.gitkeep"], "layout commit files")
M.inbox_reject(st, l2)

# hand edits: listed (even before a tidy), accepted (flag cleared) or rejected (line removed)
st.write("gotchas/git.md", st.read("gotchas/git.md") + "- Sign every tag.\n- Delete merged branches.\n")
h = {i["payload"]["text"]: i for i in M.inbox_list(st)}
eq(sorted(h), ["Delete merged branches.", "Sign every tag."], "hand edits listed")
hs = h["Sign every tag."]
eq((hs["kind"], hs["created"], hs["source"], hs["payload"]["file"]), ("hand-edit", "2026-10-01", "hand edit", "gotchas/git.md"), "hand-edit item")
n = commits(st)
M.inbox_accept(st, hs["id"])
eq(commits(st), n + 1, "accepting a hand edit is one commit")
eq("hand_edit" in meta(st, "gotchas/git.md")["rules"][hs["payload"]["rule_id"]], False, "flag cleared")
hd = [i for i in M.inbox_list(st) if i["kind"] == "hand-edit"]
eq([i["payload"]["text"] for i in hd], ["Delete merged branches."], "one hand edit left")
M.inbox_reject(st, hd[0]["id"])
eq((commits(st), st.read("gotchas/git.md")), (n + 2, "# Git\n\n- Pull with rebase before you push.\n- Sign every tag.\n"),
   "a rejected hand edit is removed in its own commit")
consistent(st)

# P1's layout proposals (left by a hub merge) are listed where they are, accepted or rejected
lore_store.save_proposal(st.root, json.dumps({"top": top + ["notes/"]}, indent=1) + "\n")
lore_store.save_proposal(st.root, json.dumps({"top": ["profile.md"]}) + "\n")
P = sorted(M.inbox_list(st), key=lambda i: -len(i["payload"]["top"]))
eq([(i["kind"], i["source"], i["payload"]["top"], i["id"][:2]) for i in P],
   [("layout", "hub merge", top + ["notes/"], "p-"), ("layout", "hub merge", ["profile.md"], "p-")], "P1 proposals")
n = commits(st)
M.inbox_accept(st, P[0]["id"])
eq((st.layout(), commits(st), os.path.exists(st.local("proposals", P[0]["payload"]["proposal"]))), (top + ["notes/"], n + 1, False),
   "a P1 proposal accepted and its file removed")
M.inbox_reject(st, P[1]["id"])
eq((M.inbox_list(st), os.listdir(st.local("proposals")), commits(st)), ([], [], n + 1), "a P1 proposal rejected")

# a P1 proposal that is not a layout cannot be accepted
lore_store.save_proposal(st.root, "{not json")
bad = M.inbox_list(st)[0]
eq((bad["kind"], bad["payload"]["top"]), ("layout", None), "a broken P1 proposal is listed")
raises(lambda: M.inbox_accept(st, bad["id"]), lore.LoreError,
       f"inbox item {bad['id']}: top must be a non-empty list of names", "a broken proposal is refused")
M.inbox_reject(st, bad["id"])

# kinds this version does not apply, and files that are not items
os.makedirs(st.local("inbox"), exist_ok=True)
with open(st.local("inbox", "c-00000001.json"), "w") as f:
    json.dump({"id": "c-00000001", "kind": "core-swap", "created": "2026-10-01T00:00:00+00:00", "payload": {}, "source": "canon"}, f)
with open(st.local("inbox", "x-renamed.json"), "w") as f:
    json.dump({"id": "c-00000001", "kind": "retire"}, f)
with open(st.local("inbox", "broken.json"), "w") as f:
    f.write("{")
eq([i["id"] for i in M.inbox_list(st)], ["c-00000001"], "only well-formed items are listed")
raises(lambda: M.inbox_accept(st, "c-00000001"), lore.LoreError,
       "inbox item c-00000001: core-swap items are not applied in this version", "core-swap")
raises(lambda: M.inbox_reject(st, "zzz"), lore.LoreError, "no inbox item zzz", "unknown id")
M.inbox_reject(st, "c-00000001")
eq(M.inbox_list(st), [], "core-swap rejected")
print("ok")
PY

# 7. Links across two stores on one hub: a union, and an unlink on one machine removes on both.
# First lore_store's rule-line helpers: one line changed, every other line kept as it was.
section "links" <<'PY'
from harness import *
import contextlib, io
import lore_hub
eq(lore_store.add_rule_line(None, "a b", "Go"), "# Go\n\n- a b\n", "add to a new file")
eq(lore_store.add_rule_line("prose", "a b"), "prose\n- a b\n", "add after a line without a newline")
eq(lore_store.remove_rule_line("# T\n\n-  spaced   rule\nprose\n- b\n", "spaced rule"), "# T\n\nprose\n- b\n", "remove by words")
eq(lore_store.replace_rule_line("- a\n- b\n", "b", "c d"), "- a\n- c d\n", "replace in place")
raises(lambda: lore_store.remove_rule_line("- a\n", "b"), lore.LoreError, "no such rule line", "remove a missing line")
raises(lambda: lore_store.replace_rule_line("- a\n", "b", "c"), lore.LoreError, "no such rule line", "replace a missing line")
eq(lore_store.merge_links(["a", "b"], ["a"], ["a", "b", "c"]), ["a", "c"], "unlink on one side, link on the other")
eq(lore_store.merge_links(None, ["x"], ["y"]), ["x", "y"], "no base: union")
eq(lore_store.merge_meta({"links": ["a"]}, {"links": ["a", "b"], "updated": "2026-10-02T00:00:00+00:00"},
                         {"links": ["c"], "updated": "2026-10-03T00:00:00+00:00"})["links"], ["b", "c"], "merge_meta merges links")
eq("links" in lore_store.merge_meta({}, {"read_when": "x"}, {"read_when": "x"}), False, "no links key when none had it")
hub = os.path.join(TMP, "hub.git")
subprocess.run(["git", "init", "-q", "--bare", "-b", "main", hub], check=True)
A, B = new_store("la"), new_store("lb")
M.apply(A, [add("gotchas/git.md", "Pull before you push."), add("gotchas/shell.md", "Quote every variable."),
            add("stack/go.md", "Run go vet."), add("stack/rust.md", "Run clippy."),
            {"op": "link", "file": "gotchas/git.md", "to": "gotchas/shell.md"},
            {"op": "link", "file": "gotchas/git.md", "to": "stack/go.md"}], source="seed")
with contextlib.redirect_stdout(io.StringIO()):
    lore_hub.set_hub(A, hub)
    lore_hub.set_hub(B, hub)
eq(meta(B, "gotchas/git.md")["links"], ["gotchas/shell.md", "stack/go.md"], "B has A's links")
M.apply(A, [{"op": "unlink", "file": "gotchas/git.md", "to": "stack/go.md"}], source="loremaster")
M.apply(B, [{"op": "link", "file": "gotchas/git.md", "to": "stack/rust.md"}], source="loremaster")
for s in (A, B, A):
    eq(lore_hub.push_step(s, force=True), f"hub: pushed to {hub}", "sync")
for s in (A, B):
    eq(meta(s, "gotchas/git.md")["links"], ["gotchas/shell.md", "stack/rust.md"], f"links on {os.path.basename(s.root)}")
    consistent(s)
eq(git(A, "rev-parse", "HEAD"), git(B, "rev-parse", "HEAD"), "both stores end equal")
print("ok")
PY

# 8. Review fixes (F1 to F8 of the P2 stream C review), one exact check each.
section "review fixes" <<'PY'
from harness import *
OLD, NEW = "Run fixture checks.", "Skip fixture checks."
T = "gotchas/fixture.md"

# F1: no op writes through a symlink, to outside the store or into .lore/; the write path checks again.
st = new_store("x1")
outside = os.path.join(TMP, "x1-outside"); os.makedirs(outside)
os.symlink(outside, st.path("gotchas/portal"))
os.symlink("../.lore/meta", st.path("gotchas/meta"))
os.symlink(outside, st.path(".lore/meta/stack"))
eq(M.validate(st, [add("gotchas/portal/escaped.md", OLD)]),
   ["op 1 (add): file 'gotchas/portal/escaped.md' passes through the symlink gotchas/portal"], "F1 outside alias")
eq(M.validate(st, [add("gotchas/meta/escaped.md", OLD)]),
   ["op 1 (add): file 'gotchas/meta/escaped.md' passes through the symlink gotchas/meta"], "F1 .lore alias")
eq(M.validate(st, [add("stack/go.md", OLD)]),
   ["op 1 (add): file 'stack/go.md' passes through the symlink .lore/meta/stack"], "F1 sidecar alias")
M.apply(st, [add(T, OLD)], source="fixture")
eq(M.validate(st, [{"op": "link", "file": T, "to": "gotchas/portal/x.md"}]),
   ["op 1 (link): to 'gotchas/portal/x.md' passes through the symlink gotchas/portal"], "F1 link target")
raises(lambda: M._commit_writes(st, {"gotchas/portal/escaped.md": "- x\n"}, "x"), lore.LoreError,
       "refused to write through a symlink: gotchas/portal/escaped.md", "F1 write guard")
eq(os.listdir(outside), [], "F1 nothing written outside the store")

# F2: rewording a core rule needs an explicit item, like adding one.
st = new_store("x2")
M.apply(st, [add("core.md", OLD, core=True)], source="fixture")
cid = rule_id(st, "core.md", OLD)
sup = {"op": "supersede", "rule_id": cid, "text": NEW, "quote": NEW}
res = M.file_items(st, [item(NEW, explicit=False)], fake({"ops": [sup]}))
eq(res["rejected"], ["op 1 (supersede): a core rule is reworded only from an explicit item (only a rule stated outright goes to core)"], "F2 refused")
eq(st.read("core.md"), f"# Core\n\n- {OLD}\n", "F2 core unchanged")
eq(M.file_items(st, [item(NEW)], fake({"ops": [sup]}))["rejected"], [], "F2 explicit item allowed")
eq(st.read("core.md"), f"# Core\n\n- {NEW}\n", "F2 core reworded")

# F3: nothing secret in the store reaches the model: hand edits, core, read_when, paths; cap kept.
st = new_store("x3")
st.write(T, "- Never print token=fixture-not-real-123 in fixture builds.\n")
st.write("gotchas/ghp_fixturefixturefixture00.md", "- Review fixture builds weekly.\n")
st.write("core.md", "# Core\n\n- Keep AKIAFIXTUREFIXTURE00 out of fixture builds.\n")
lore_store.tidy(st)
m = meta(st, T); m["read_when"] = "fixture builds need secret=fixture-not-real-456"; lore_store.save_meta(st, T, m)
seen = []
M.file_items(st, [item("Review fixture builds.")], fake({"ops": []}, seen))
eq(len(seen), 1, "F3 one call")
if lore.SECRET_RE.search(seen[0]) or "fixture-not-real" in seen[0] or "FIXTUREFIXTURE" in seen[0] or "fixturefixture" in seen[0]:
    fail("F3 a secret reached the model")
with open(M.PROMPT_FILE) as f:
    eq(seen[0].startswith(f.read().rstrip("\n")), True, "F3 instructions untouched")
for cap in range(0, 900, 11):
    c = M.select_context(st, [item("Review fixture builds.")], cap_chars=cap)
    size = len(c["index"]) + len(c["core"]) + sum(len(t) for t in c["files"].values())
    if size > cap or any(lore.SECRET_RE.search(x) for x in [c["index"], c["core"]] + list(c["files"].values())):
        fail(f"F3 cap {cap}: {size} characters or a secret")

# F4: a rule whose line is in its file twice is not moved or reworded; inbox removal takes every copy.
st = new_store("x4")
M.apply(st, [add(T, OLD), add("stack/fixture.md", "Pin fixture versions.")], source="fixture")
fid = rule_id(st, T, OLD)
st.write(T, st.read(T) + f"- {OLD}\n")
before = snapshot(st)
for op in ({"op": "supersede", "rule_id": fid, "text": NEW, "quote": NEW}, {"op": "move", "rule_id": fid, "to": "stack/fixture.md"}):
    eq(M.validate(st, [op]), [f"op 1 ({op['op']}): rule {fid} is in {T} more than once; remove the extra line first"], f"F4 {op['op']}")
eq(snapshot(st), before, "F4 nothing written")
r = M.apply(st, [{"op": "retire", "rule_id": fid, "reason": "fixture"}], source="fixture")["inbox"][0]
M.inbox_accept(st, r)
eq(st.read(T), "# Fixture\n\n", "F4 retire removed both copies")
consistent(st)
st.write(T, st.read(T) + "- Hand rule.\n- Hand rule.\n")
h = [i for i in M.inbox_list(st) if i["kind"] == "hand-edit"]
eq(len(h), 1, "F4 one hand-edit item for a doubled line")
M.inbox_reject(st, h[0]["id"])
eq(st.read(T), "# Fixture\n\n", "F4 rejecting a hand edit removed both copies")
consistent(st)

# F5: ids are unique across the store: re-adding a superseded rule's old words gets a new id.
st = new_store("x5")
M.apply(st, [add(T, OLD)], source="fixture")
fid = rule_id(st, T, OLD)
M.apply(st, [{"op": "supersede", "rule_id": fid, "text": NEW, "quote": NEW}, add("stack/fixture.md", OLD)], source="fixture")
ids = [eid for rel in st.rule_files() for eid in meta(st, rel)["rules"]]
eq(len(ids), len(set(ids)), "F5 ids unique")
eq((rule_id(st, T, NEW), rule_id(st, "stack/fixture.md", OLD) != fid), (fid, True), "F5 kept id and a fresh one")
eq(M.validate(st, [{"op": "retire", "rule_id": fid, "reason": "fixture"}]), [], "F5 the kept id is not ambiguous")

# F6: a layout that drops a folder still holding any content (prose too) is refused and stays
# pending; a title-only file or .gitkeep is a placeholder.
st = new_store("x6")
st.write("gotchas/notes.md", "# Fixture notes\n\nKeep this explanatory prose.\n")
st.write("safety/empty.md", "# Empty\n")
lore_store.tidy(st); lore_store.commit(st, "fixture notes")
drop = lambda gone: [t for t in st.layout() if t not in gone]
l1 = M.apply(st, [{"op": "propose-layout", "top": drop(["gotchas/"]), "reason": "fixture"}], source="fixture")["inbox"][0]
raises(lambda: M.inbox_accept(st, l1), lore.LoreError,
       f"inbox item {l1}: the new layout drops content still in gotchas/notes.md; move it first", "F6 prose refused")
eq(("gotchas/" in st.layout(), [i["id"] for i in M.inbox_list(st)]), (True, [l1]), "F6 layout kept, item pending")
os.symlink(TMP, st.path("stack/link"))
l2 = M.apply(st, [{"op": "propose-layout", "top": drop(["stack/"]), "reason": "fixture"}], source="fixture")["inbox"][0]
raises(lambda: M.inbox_accept(st, l2), lore.LoreError,
       f"inbox item {l2}: the new layout drops content still in stack/link; move it first", "F6 a link is content")
l3 = M.apply(st, [{"op": "propose-layout", "top": drop(["safety/", "profile.md"]), "reason": "fixture"}], source="fixture")["inbox"][0]
eq(M.inbox_accept(st, l3)["kind"], "layout", "F6 placeholders only: accepted")

# F7: core rule ids reach the model; the agent-facing index is unchanged.
st = new_store("x7")
M.apply(st, [add("core.md", OLD, core=True)], source="fixture")
cid = rule_id(st, "core.md", OLD)
seen = []
M.file_items(st, [item(NEW)], fake({"ops": []}, seen))
eq(f"- [{cid}] {OLD}" in seen[0].splitlines(), True, "F7 core id in the prompt")
eq(f"- {OLD}" in st.read("INDEX.md").splitlines() and cid not in st.read("INDEX.md"), True, "F7 index has no ids")

# F8: an op name of any other JSON type is a clean rejection.
eq(M.validate(st, [{"op": []}, {"op": {}}, {"op": 5}, {"op": True}]),
   ["op 1: unknown op '[]'", "op 2: unknown op '{}'", "op 3: unknown op '5'", "op 4: unknown op 'True'"], "F8")
print("ok")
PY

echo "PASS: test-master.sh"
