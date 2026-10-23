#!/usr/bin/env bash
# lore 2.0 P3 lint tests: each gate fires on its own fixture with the exact finding and stays
# silent on a clean store; thresholds at their exact edges; config keys move them; `due` and the
# once-a-day limit; `mark_run`'s file mode. Read-only: lint writes nothing. Never a model, never
# the network. Temporary HOME; git sees no global config.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap '[[ -n "${KEEP:-}" ]] || rm -rf "$tmp"' EXIT
export HOME="$tmp/home"; mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset LORE_STORE LORE_STORE2 LORE_GH_CMD LORE_GIT_TIMEOUT 2>/dev/null || true
export LORE_SCRIPTS="$repo_root/skills/lore/scripts" TMP_ROOT="$tmp" PYTHONDONTWRITEBYTECODE=1
export PYTHONPATH="$repo_root/tests/fixtures/lint"
mkdir "$tmp/cwd"; cd "$tmp/cwd"   # a write that falls back to the working folder lands here, not in the repo
section() { echo "-- $1"; python3 -; }

# 1. a clean store: no findings, one note that the stale gate is off, Canon not due.
section "clean store" <<'PY'
from harness import *
st = new_store("clean")
f = L.lint(st)
eq(list(f), [], "a clean store has no findings")
eq(list(f.notes), ["stale gate off: no read data has been recorded on any machine"], "the stale gate says it is off, once")
eq(L.due(st, f, now="2026-10-01T12:00:00+00:00"),
   {"run": False, "urgent": False, "gates": [], "reason": "no findings"}, "no findings, no run")
print("ok")
PY

# 2. each gate on its own fixture, with the exact finding and nothing else.
section "gates on fixtures" <<'PY'
from harness import *
GIT = "gotchas/git.md"

st = new_store("contradiction", "contradiction")
want = ids(st, GIT)[1]
eq(list(L.lint(st)), [{"gate": "contradiction", "file": GIT, "rule_ids": [want],
                       "detail": 'flagged against "Commit without reading the diff when in a hurry."'}], "contradiction")

st = new_store("core-budget", "core-budget")
by_text = {e["text"]: i for i, e in lore_store.load_meta(st, "core.md")["rules"].items()}
dropped = [by_text[r] for r in lore_store.parse_rules(st.read("core.md"))[1][5:]]   # the last three, in file order
eq(list(L.lint(st)), [{"gate": "core-budget", "file": "core.md", "rule_ids": dropped,
                       "detail": "3 core rule(s) do not fit the 200-token index"}], "core-budget names the rules the index dropped")

st = new_store("broken-link", "broken-link")
eq(list(L.lint(st)), [
    {"gate": "broken-link", "file": GIT, "rule_ids": [], "detail": "links to gotchas/missing.md, which does not exist"},
    {"gate": "broken-link", "file": GIT, "rule_ids": [], "detail": "links to retired/gotchas/old.md, which is not a rule file"}], "broken-link")

# an orphan is not hidden by INDEX.md listing and linking it; a file with a read_when and no
# incoming link is not an orphan
st = new_store("orphan", "orphan")
index = st.read("INDEX.md")
eq(index.count("gotchas/docker.md"), 2, "the fixture's INDEX.md lists and links the orphan")
eq(list(L.lint(st)), [{"gate": "orphan", "file": "gotchas/docker.md", "rule_ids": [],
                       "detail": "no incoming link and no read_when"}], "orphan")
eq(st.read("INDEX.md"), index, "lint left INDEX.md alone")
st2 = new_store("orphan-built", "orphan")   # and the index lore builds itself lists every file too
lore_store.write_index(st2)
assert "`gotchas/docker.md`" in st2.read("INDEX.md"), "a built index lists the file"
eq(gates(L.lint(st2)), [("orphan", "gotchas/docker.md")], "orphan with a built index")
put(st2, "gotchas/docker.md", ["Pin the base image tag instead of using latest.", "Run containers as a non-root user."], read_when="touching Docker")
eq(list(L.lint(st2)), [], "a read_when alone makes a file not an orphan")
put(st2, "gotchas/docker.md", ["Pin the base image tag instead of using latest.", "Run containers as a non-root user."])
put(st2, "gotchas/shell.md", ["Quote every variable expansion in a script.", "Send long output to a log file and read it whole."],
    links=["gotchas/docker.md"], read_when="writing a shell script")
eq(list(L.lint(st2)), [], "an incoming link from another topic file alone makes a file not an orphan")
put(st2, "gotchas/shell.md", ["Quote every variable expansion in a script.", "Send long output to a log file and read it whole."],
    read_when="writing a shell script")
put(st2, "gotchas/docker.md", ["Pin the base image tag instead of using latest.", "Run containers as a non-root user."], links=["gotchas/docker.md"])
eq(gates(L.lint(st2)), [("orphan", "gotchas/docker.md")], "a file's link to itself is no incoming link")
put(st2, "core.md", ["Run the real command before claiming a task is done."], title="Core", links=["gotchas/docker.md"])
eq(gates(L.lint(st2)), [("orphan", "gotchas/docker.md")], "core.md is not a link source")

st = new_store("duplicate", "duplicate-identical")
a, b = ids(st, "gotchas/docker.md")[0], ids(st, GIT)[3]
eq(list(L.lint(st)), [{"gate": "duplicate", "file": "gotchas/docker.md", "rule_ids": [a, b],
                       "detail": f"rules {a} and {b} in gotchas/docker.md and gotchas/git.md: identical text"}], "identical text in two files")
print("ok")
PY

# 3. duplicates: the overlap edge, short rules, the same rule twice in a file, config keys.
section "duplicate edges" <<'PY'
from harness import *
D = "gotchas/docker.md"
def store(name, a, b, **cfg):
    st = new_store(name)
    put(st, D, [a, b], links=["gotchas/git.md"], read_when="touching Docker")
    if cfg:
        st.write(".lore/config", "".join(f"{k}: {v}\n" for k, v in cfg.items()))
    return st
A8 = "alpha beta gamma delta epsilon zeta eta theta"
# 8 shared words and one different word each: 8 of 10, exactly 80%: at the threshold, a duplicate
st = store("dup-at", A8 + " iota", A8 + " lambda")
i, j = ids(st, D)
eq(list(L.lint(st)), [{"gate": "duplicate", "file": D, "rule_ids": [i, j],
                       "detail": f"rules {i} and {j} in {D}: 80% of their words in common"}], "at the overlap threshold")
# 7 shared and one different each: 7 of 9, just under: not a duplicate
A7 = "alpha beta gamma delta epsilon zeta eta"
eq(list(L.lint(store("dup-under", A7 + " iota", A7 + " lambda"))), [], "just under the overlap threshold")
# a hand-written line with no sidecar entry yet is compared too, under the id it will be given
st = new_store("dup-hand")
put(st, D, ["Pin the base image tag instead of using latest.", "Run containers as a non-root user."], links=["gotchas/git.md"], read_when="touching Docker")
st.write(D, st.read(D) + "- Pin the base image tag, instead of using LATEST.\n")
i = ids(st, D)[0]
eq([x["rule_ids"] for x in L.lint(st)], [[i, lore.entry_id("Pin the base image tag, instead of using LATEST.")]], "a rule line without a sidecar entry takes the id its text will get")
# case and punctuation do not matter; the same rule twice in one file counts
st = store("dup-same-file", "Pin the base image tag instead of using latest.", "pin the BASE image tag, instead of using latest")
i, j = ids(st, D)
eq(list(L.lint(st)), [{"gate": "duplicate", "file": D, "rule_ids": [i, j],
                       "detail": f"rules {i} and {j} in {D}: identical text"}], "identical text twice in one file")
# identical text always counts, even when too short for the overlap check
st = store("dup-short", "Run tests first.", "run TESTS first")
eq(gates(L.lint(st)), [("duplicate", D)], "identical short rules")
# short rules never count by overlap, unless the minimum is lowered
st = store("dup-min", "alpha beta gamma", "alpha beta delta", lint_overlap="0.5")
eq(list(L.lint(st)), [], "a 3-word rule is under the minimum word count")
st = store("dup-min-low", "alpha beta gamma", "alpha beta delta", lint_overlap="0.5", lint_overlap_min_words="3")
eq(gates(L.lint(st)), [("duplicate", D)], "the minimum word count is a config key")
# the overlap threshold is a config key; a bad value falls back to the default
eq(list(L.lint(store("dup-cfg-high", A8 + " iota", A8 + " lambda", lint_overlap="0.9"))), [], "a higher lint_overlap")
eq(gates(L.lint(store("dup-cfg-low", A7 + " iota", A7 + " lambda", lint_overlap="0.75"))), [("duplicate", D)], "a lower lint_overlap")
for bad in ("lots", "0", "-1", "1.5"):
    eq(len(L.lint(store("dup-cfg-bad", A8 + " iota", A8 + " lambda", lint_overlap=bad))), 1, f"lint_overlap {bad!r} falls back to 0.8")
# identical means equal normalised text, never equal word sets: another order of a short rule is no duplicate
eq(list(L.lint(store("dup-reorder-short", "Tests before deploy.", "Deploy before tests."))), [], "the same three words in another order")
st = store("dup-reorder", "Run the tests before you deploy.", "Deploy before you run the tests.")
i, j = ids(st, D)
eq([x["detail"] for x in L.lint(st)], [f"rules {i} and {j} in {D}: 100% of their words in common"], "the same long rule in another order is overlap, not identical text")
st = store("dup-repeat", "Always check the diff.", "Always check check the diff.")
i, j = ids(st, D)
eq([x["detail"] for x in L.lint(st)], [f"rules {i} and {j} in {D}: 100% of their words in common"], "a repeated word is overlap, not identical text")
# text with no words matches nothing, itself included
eq(list(L.lint(store("dup-empty", "!!!", "..."))), [], "two rules with no words")
eq(list(L.lint(store("dup-empty-same", "!!!", "!!!"))), [], "the same rule with no words twice")
lim0 = L.limits(new_store("dup-lim"))
eq(L._same(L._Rule("f", "a", "!!!"), L._Rule("f", "b", "!!!"), lim0), None, "text with no words is never identical text")
# the prefilter: equal short text is a candidate pair, short rules sharing words are not
eq(L._candidates([L._Rule("f", "a", "Run tests first."), L._Rule("f", "b", "run TESTS first")], lim0), [(0, 1)], "equal short text is a candidate pair")
eq(L._candidates([L._Rule("f", "a", "alpha beta"), L._Rule("f", "b", "beta alpha")], lim0), [], "short rules are not candidates for overlap")

# the candidate prefilter finds exactly the pairs an all-pairs comparison finds
import random
def allpairs(files, lim):
    rules = [L._Rule(f.rel, eid, r) for f in files for eid, r in zip(f.ids, f.rules)]
    out = []
    for n, a in enumerate(rules):
        for b in rules[n + 1:]:
            same = L._same(a, b, lim)
            if same:
                where = a.file if a.file == b.file else f"{a.file} and {b.file}"
                out.append(L._finding("duplicate", a.file, [a.id, b.id], f"rules {a.id} and {b.id} in {where}: {same}"))
    return out
def same_output(st, lim, what):
    files = L._files(st)
    got, want = L._duplicates(files, lim), allpairs(files, lim)
    eq(got, want, what)
    return len(got)
for scn in ("duplicate-identical", "orphan", "contradiction", "broken-link", "core-budget"):
    same_output(new_store("eq-" + scn, scn), L.limits(new_store("eq-lim")), f"fixture {scn}")
rng = random.Random(20261023)
vocab = [f"w{n}" for n in range(30)]
st = new_store("eq-random")
for n in range(10):
    put(st, f"gotchas/r{n}.md", [" ".join(rng.choice(vocab) for _ in range(rng.randint(2, 9))) for _ in range(15)], links=["gotchas/git.md"], read_when="a fixture")
total = 0
for overlap in (0.3, 0.5, 0.8, 1.0):
    for minw in (1, 2, 4):
        lim = dict(L.limits(st), OVERLAP=overlap, OVERLAP_MIN_WORDS=minw)
        total += same_output(st, lim, f"random store, overlap {overlap}, minimum words {minw}")
assert total > 500, f"the random store is too sparse to mean anything ({total} pairs)"
# the review's shape: 3,000 distinct ten-word rules in 120 files: nothing to compare
import time
st = new_store("big", base=None)
st.write(".lore/config", "budget: 1000000\n")
for n in range(120):
    put(st, f"gotchas/big{n}.md", [" ".join(f"word{n * 25 + r}x{k}" for k in range(10)) for r in range(25)], links=[f"gotchas/big{(n + 1) % 120}.md"], read_when="a fixture", created="2026-01-01")
lim = L.limits(st)
files = L._files(st)
rules = [L._Rule(f.rel, eid, r) for f in files for eid, r in zip(f.ids, f.rules)]
eq(len(rules), 3000, "rules in the big store")
eq(L._candidates(rules, lim), [], "no candidate pairs among 3,000 distinct rules")
shared = [L._Rule("f", str(n), f"the always check of rare{n}a rare{n}b rare{n}c rare{n}d") for n in range(300)]
eq(L._candidates(shared, lim), [], "words every rule has make no candidate pairs")
t0 = time.perf_counter()
eq([x["gate"] for x in L.lint(st)], [], "the big store has no findings")
print(f"lint of 3,000 rules in 120 files: {time.perf_counter() - t0:.2f} s")
print("ok")
PY

# 4. oversized and thin: 26 rules and 4,001 characters fire, 25 and 4,000 do not; 7 days and 1 rule fire.
section "oversized and thin" <<'PY'
from harness import *
F = "gotchas/big.md"
def tok(i, n=5):   # n words no other rule shares, so nothing is a duplicate
    return " ".join(f"t{i}x{k}" for k in range(n))
def big(name, count, chars=None, **cfg):
    st = new_store(name)
    rules = [tok(i) for i in range(count)]
    if chars is not None:   # pad the last rule so the whole file is exactly `chars` characters
        base = len(lore_store.render_rules("Fixture", rules))
        assert chars >= base, (chars, base)
        rules[-1] += "z" * (chars - base)
    put(st, F, rules, links=["gotchas/git.md"], read_when="a fixture")
    if chars is not None:
        eq(len(st.read(F)), chars, "fixture file length")
    if cfg:
        st.write(".lore/config", "".join(f"{k}: {v}\n" for k, v in cfg.items()))
    return st
def one(st, gate, detail, what):
    got = [x for x in L.lint(st) if x["file"] == F]
    eq(got, [{"gate": gate, "file": F, "rule_ids": [], "detail": detail}] if detail else [], what)
one(big("o26", 26), "oversized", "26 rules (limit 25)", "26 rules")
one(big("o25", 25), "oversized", None, "25 rules")
one(big("c4001", 10, 4001), "oversized", "4,001 characters (limit 4,000)", "4,001 characters")
one(big("c4000", 10, 4000), "oversized", None, "4,000 characters")
one(big("both", 26, 4100), "oversized", "26 rules (limit 25); 4,100 characters (limit 4,000)", "both limits")
one(big("cfg-rules", 26, lint_max_rules="26"), "oversized", None, "lint_max_rules raised")
one(big("cfg-rules-low", 11, lint_max_rules="10"), "oversized", "11 rules (limit 10)", "lint_max_rules lowered")
one(big("cfg-chars", 10, 4001, lint_max_chars="4001"), "oversized", None, "lint_max_chars raised")
one(big("cfg-bad", 26, lint_max_rules="many"), "oversized", "26 rules (limit 25)", "a bad lint_max_rules falls back")
st = new_store("core-big")   # core.md is held to the budget gate, not the size gate
put(st, "core.md", [tok(i) for i in range(30)], title="Core")
eq([x for x in L.lint(st) if x["gate"] == "oversized"], [], "core.md is never oversized")

T = "gotchas/one.md"
def thin(name, rules, created, today=None, **cfg):
    st = new_store(name)
    put(st, T, rules, links=["gotchas/git.md"], read_when="a fixture", created=created)
    if cfg:
        st.write(".lore/config", "".join(f"{k}: {v}\n" for k, v in cfg.items()))
    return [x for x in L.lint(st, today=today) if x["file"] == T]
RULE = ["Quote every variable expansion in a script."]
got = thin("thin7", RULE, "2026-09-24")
eq([{k: v for k, v in x.items() if k != "rule_ids"} for x in got],
   [{"gate": "thin", "file": T, "detail": "1 rule(s), the newest 7 days old"}], "1 rule aged 7 days")
eq(len(got[0]["rule_ids"]), 1, "thin names its rule")
eq(thin("thin6", RULE, "2026-09-25"), [], "1 rule aged 6 days")
eq(thin("thin2", RULE + ["Send long output to a log file and read it whole."], "2026-09-01"), [], "2 rules, old")
eq(thin("thin0", [], "2026-09-01"), [], "no rules")
eq(thin("thin-today", RULE, "2026-09-25", today=dt.date(2026, 10, 2))[0]["detail"], "1 rule(s), the newest 7 days old", "the today argument")
eq(thin("thin-days", RULE, "2026-09-24", lint_thin_days="8"), [], "lint_thin_days raised")
eq(len(thin("thin-days-low", RULE, "2026-09-26", lint_thin_days="5")), 1, "lint_thin_days lowered")
eq(len(thin("thin-rules", RULE + ["Send long output to a log file and read it whole."], "2026-09-01", lint_thin_rules="3")), 1, "lint_thin_rules raised")
eq(thin("thin-rules-low", RULE, "2026-09-01", lint_thin_rules="1"), [], "lint_thin_rules lowered")
# the newest rule counts, not the oldest: two rules, one old and one a day old, with the limit raised to 3
st = new_store("thin-newest")
put(st, T, [("Quote every variable expansion in a script.", {"created": "2026-09-01"}),
            ("Send long output to a log file and read it whole.", {"created": "2026-09-30"})], links=["gotchas/git.md"], read_when="a fixture")
st.write(".lore/config", "lint_thin_rules: 3\n")
eq([x["file"] for x in L.lint(st) if x["gate"] == "thin" and x["file"] == T], [], "a day-old rule keeps the file from being thin")
# core.md is never thin; a rule with an unreadable created date is never thin
st = new_store("thin-core")
put(st, "core.md", ["Run the real command before claiming a task is done."], title="Core")
put(st, T, RULE, links=["gotchas/git.md"], read_when="a fixture", created="yesterday")
eq([x for x in L.lint(st) if x["gate"] == "thin"], [], "core.md and an undated rule are not thin")
# a top-level file of the layout never counts as thin; a topic file inside a folder does
import json
st = new_store("thin-top")
st.write(".lore/layout.json", json.dumps({"top": lore_store.DEFAULT_LAYOUT["top"] + ["extras.md"]}))
put(st, "profile.md", ["The user builds small developer tools in Python and TypeScript."], read_when="who the user is", created="2026-09-01")
put(st, "extras.md", ["Keep this one rule on its own."], read_when="a fixture", created="2026-09-01")
put(st, T, RULE, links=["gotchas/git.md"], read_when="a fixture", created="2026-09-01")
put(st, "gotchas/deep/nested.md", ["Send long output to a log file and read it whole."], links=["gotchas/git.md"], read_when="a fixture", created="2026-09-01")
eq([x["file"] for x in L.lint(st) if x["gate"] == "thin"], ["gotchas/deep/nested.md", T], "thin applies inside folders only")
print("ok")
PY

# 5. stale: 60 days fires, 59 does not; off with no read data anywhere; never-read files count from tracking.
section "stale" <<'PY'
from harness import *
import json, os
G = "gotchas/git.md"
GR = ["Never force-push a shared branch.", "Read the whole diff before committing it.", "Quote a glob in zsh so the shell does not expand it."]
def git_read(name, last_read, **kw):
    st = new_store(name)
    put(st, G, GR, links=["how-i-work/reviews.md"], read_when="a git command misbehaves", last_read=last_read, reads={"m-aaaaaaaa": 3}, **kw)
    return st
st = git_read("stale60", {"m-aaaaaaaa": "2026-08-02"})
f = L.lint(st)
eq(list(f), [{"gate": "stale", "file": G, "rule_ids": [], "detail": "unread for 60 days (last read 2026-08-02)"}], "stale at 60 days")
eq(list(f.notes), [], "no note when the gate is on")
eq(list(L.lint(git_read("stale59", {"m-aaaaaaaa": "2026-08-03"}))), [], "not stale at 59 days")
eq(len(L.lint(git_read("stale-today", {"m-aaaaaaaa": "2026-08-03"}), today=dt.date(2026, 10, 2))), 1, "the today argument")
# two machines: the newer read counts
eq(list(L.lint(git_read("stale-2m", {"m-aaaaaaaa": "2026-08-02", "m-bbbbbbbb": "2026-08-03"}))), [], "the newest read of any machine counts")
# a store with no read data on any machine never looks stale, however old the rules are
st = new_store("stale-off")
RV = ["Ask a second model to review every plan before building.", "Keep one implementer per task and review the diff afterwards."]
PF = ["The user builds small developer tools in Python and TypeScript.", "The user prefers short direct answers without preamble."]
for rel, rules in (("profile.md", PF), (G, GR), ("how-i-work/reviews.md", RV)):
    put(st, rel, rules, links=["how-i-work/reviews.md" if rel != "how-i-work/reviews.md" else G], read_when="a fixture", created="2026-01-01")
f = L.lint(st)
eq([x["gate"] for x in f], [], "no stale finding without read data")
eq(list(f.notes), ["stale gate off: no read data has been recorded on any machine"], "and it says so, once")
# a file nobody read, in a store where reads are tracked: counted from the later of its newest rule
# and the first recorded read, so a store that only just began tracking is not all stale
def tracked(name, first_read):
    st = new_store(name)
    put(st, "profile.md", PF, links=[G], read_when="a fixture", created="2026-01-01", last_read={"m-aaaaaaaa": first_read}, reads={"m-aaaaaaaa": 1})
    put(st, G, GR, links=["profile.md"], read_when="a fixture", created="2026-01-01")
    return st
eq(list(L.lint(tracked("tracked-new", "2026-09-30"))), [], "reads began yesterday: nothing unread for 60 days yet")
eq(list(L.lint(tracked("tracked-old", "2026-07-03"))),
   [{"gate": "stale", "file": G, "rule_ids": [], "detail": "unread for 90 days (never read since tracking began)"},
    {"gate": "stale", "file": "profile.md", "rule_ids": [], "detail": "unread for 90 days (last read 2026-07-03)"}], "tracking began 90 days ago")
st = new_store("zero-reads")
put(st, G, GR, links=["profile.md"], read_when="a fixture", created="2026-01-01", reads={"m-aaaaaaaa": 0})
f = L.lint(st)
eq((len(f.notes), [x["gate"] for x in f]), (1, []), "a read count of zero is no read data")
# a read count with no date still means reads are tracked
st = new_store("counts-only")
put(st, G, GR, links=["profile.md"], read_when="a fixture", created="2026-01-01", reads={"m-aaaaaaaa": 2})
f = L.lint(st)
eq((list(f.notes), [x["gate"] for x in f]), ([], ["stale"]), "counts without dates turn the gate on")
# the stale window is a config key; core.md and empty files are never stale
st = git_read("stale-cfg", {"m-aaaaaaaa": "2026-08-02"})
st.write(".lore/config", "lint_stale_days: 61\n")
eq(list(L.lint(st)), [], "lint_stale_days raised")
st = git_read("stale-cfg-low", {"m-aaaaaaaa": "2026-08-30"})   # 32 days; the other files count from 2026-09-01
st.write(".lore/config", "lint_stale_days: 31\n")
eq([x["file"] for x in L.lint(st)], [G], "lint_stale_days lowered")
st = git_read("stale-core", {"m-aaaaaaaa": "2026-08-02"})
put(st, "core.md", ["Run the real command before claiming a task is done."], title="Core", last_read={"m-aaaaaaaa": "2026-01-01"}, reads={"m-aaaaaaaa": 9})
put(st, "gotchas/empty.md", [], links=[G], read_when="a fixture", last_read={"m-aaaaaaaa": "2026-01-01"}, reads={"m-aaaaaaaa": 9})
eq([x["file"] for x in L.lint(st) if x["gate"] == "stale"], [G], "core.md and an empty file are never stale")
# the baseline for a never-read file comes from git history: the first commit that recorded a read.
# An active file read every few days must not keep a neglected file from going stale.
import subprocess
def commit_at(st, when, msg):
    os.environ["GIT_COMMITTER_DATE"] = os.environ["GIT_AUTHOR_DATE"] = when
    try:
        lore_store.commit(st, msg)
    finally:
        del os.environ["GIT_COMMITTER_DATE"], os.environ["GIT_AUTHOR_DATE"]
st = new_store("history")
put(st, "gotchas/neglected.md", ["Use cobalt for the fixture.", "Keep dunlin fixtures separate."], links=[G], read_when="a fixture", created="2026-01-01")
for day in ("2026-10-01", "2026-10-15", "2026-11-15", "2026-11-30"):
    put(st, G, GR, links=["how-i-work/reviews.md"], read_when="a git command misbehaves", last_read={"m-aaaaaaaa": day}, reads={"m-aaaaaaaa": 5})
    commit_at(st, day + "T10:00:00+00:00", "read " + day)
before = snapshot(st)
stale = lambda today: [x["file"] for x in L.lint(st, today=today) if x["gate"] == "stale"]
eq(stale(dt.date(2026, 11, 29)), [], "59 days after the first recorded read")
eq(stale(dt.date(2026, 11, 30)), ["gotchas/neglected.md", "how-i-work/reviews.md", "profile.md"], "60 days after the first recorded read, though the active file was read that day")
eq(L.tracking_start(st, L._files(st)), dt.date(2026, 10, 1), "tracking began at the first commit with a read")
eq(snapshot(st), before, "finding the baseline wrote nothing")
# reads not committed yet count too (the session end lints before it commits)
put(st, G, GR, links=["how-i-work/reviews.md"], read_when="a git command misbehaves", last_read={"m-aaaaaaaa": "2026-09-20", "m-bbbbbbbb": "2026-12-05"}, reads={"m-aaaaaaaa": 5, "m-bbbbbbbb": 1})
eq(L.tracking_start(st, L._files(st)), dt.date(2026, 9, 20), "an uncommitted read from before the first commit")
# a store with no git history to ask: counted from the rules' own dates
root = os.path.join(TMP, "gitless")
os.makedirs(os.path.join(root, ".git", "lore"))
gl = lore_store.Store2(root, day=DAY)
gl.write(".lore/layout.json", json.dumps(lore_store.DEFAULT_LAYOUT))
gl.write(".lore/config", "budget: 1000000\n")
put(gl, G, GR, links=["gotchas/neglected.md"], read_when="a fixture", last_read={"m-aaaaaaaa": "2026-12-01"}, reads={"m-aaaaaaaa": 9}, created="2026-12-01")
put(gl, "gotchas/neglected.md", ["Use cobalt for the fixture.", "Keep dunlin fixtures separate."], links=[G], read_when="a fixture", created="2026-01-01")
eq(L.tracking_start(gl, L._files(gl)), None, "no repository, no baseline")
eq([x["file"] for x in L.lint(gl, today=dt.date(2026, 12, 1)) if x["gate"] == "stale"], ["gotchas/neglected.md"], "without history a never-read file counts from its rules")
print("ok")
PY

# 6. a secret never reaches a finding; a store that cannot hold the index at all is a core-budget finding.
section "details" <<'PY'
from harness import *
import json
G = "gotchas/git.md"
SECRET = "token=fixture-not-real-123456"
st = new_store("secret")
put(st, G, [("Read the whole diff before committing it.", {"contradictions": [{"with": f"Use {SECRET} in the script.", "flagged": "2026-09-20"}]})],
    links=[SECRET + ".md", "how-i-work/reviews.md"], read_when="a git command misbehaves")
dump = repr(list(L.lint(st)))
assert SECRET not in dump and "fixture-not-real" not in dump, "a secret reached a finding"
assert "[REDACTED]" in dump, "the secret was not replaced"
st = new_store("long")
put(st, G, [("Read the whole diff before committing it.", {"contradictions": [{"with": "word " * 200, "flagged": "2026-09-20"}]})],
    links=["how-i-work/reviews.md"], read_when="a git command misbehaves")
for x in L.lint(st):
    assert "\n" not in x["detail"] and len(x["detail"]) <= 100, x
st = new_store("two-flags")
put(st, G, [("Read the whole diff before committing it.", {"contradictions": [{"with": "First clash.", "flagged": "2026-09-20"}, {"with": "Second clash.", "flagged": "2026-09-21"}]})],
    links=["how-i-work/reviews.md"], read_when="a git command misbehaves")
eq([x["detail"] for x in L.lint(st) if x["gate"] == "contradiction"], ['flagged against "First clash." (+1 more)'], "several flags on one rule")
st = new_store("no-room")
st.write(".lore/config", "budget: 20\n")
eq(list(L.lint(st)), [{"gate": "core-budget", "file": "core.md", "rule_ids": [],
                       "detail": "the index is over its 20-token budget even without core rules"}], "an index that cannot be built")
st = new_store("escape")
put(st, G, ["Never force-push a shared branch.", "Read the whole diff before committing it."], links=["../outside.md", "/etc/hostname", "how-i-work/reviews.md"],
    read_when="a git command misbehaves")
eq([x["detail"] for x in L.lint(st) if x["gate"] == "broken-link"],
   ["links to ../outside.md, which does not exist", "links to /etc/hostname, which does not exist"], "a link out of the store is broken, never followed")
# retired rules are not linted, even when the layout covers the folder
st = new_store("retired")
st.write(".lore/layout.json", json.dumps({"top": lore_store.DEFAULT_LAYOUT["top"] + ["retired/"]}))
put(st, "retired/gotchas/old.md", ["Pin the base image tag instead of using latest."])
put(st, "retired/gotchas/older.md", ["Pin the base image tag instead of using latest."], last_read={"m-aaaaaaaa": "2026-01-01"}, reads={"m-aaaaaaaa": 2})
assert "retired/gotchas/old.md" in st.rule_files(), "the layout covers retired/"
eq(list(L.lint(st)), [], "retired rules are excluded from lint")
# today may be a datetime
st = new_store("today-dt")
put(st, "gotchas/one.md", ["Quote every variable expansion in a script."], links=["gotchas/git.md"], read_when="a fixture", created="2026-09-24")
eq(gates(L.lint(st, today=dt.datetime(2026, 10, 1, 23, 0))), [("thin", "gotchas/one.md")], "a datetime for today")
# a sidecar entry whose line is gone, and a line with no entry, are handled without error
st = new_store("unreconciled")
put(st, G, ["Never force-push a shared branch.", "Read the whole diff before committing it."], links=["how-i-work/reviews.md"], read_when="a git command misbehaves")
st.write(G, st.read(G) + "- A hand-written rule that has no sidecar entry yet.\n")
eq(list(L.lint(st)), [], "a rule line without a sidecar entry")
# every numeric key falls back to its default on a value that is not finite or cannot be held
st = new_store("cfg-bad")
defaults = L.limits(st)
for key in L.LIMITS:
    for bad in ("inf", "-inf", "nan", "1e999", "1e300", "1e18", "0", "-1", "lots", ""):
        st.write(".lore/config", f"{key}: {bad}\n")
        eq(L.limits(st), defaults, f"{key}: {bad!r}")
st.write(".lore/config", "lint_overlap: 1\ncanon_interval_hours: 1e6\nlint_max_rules: 99999999999999999999\n")
got = L.limits(st)
eq((got["OVERLAP"], got["INTERVAL_HOURS"], got["MAX_RULES"]), (1.0, 1e6, 99999999999999999999), "large and boundary values that can be held are honoured")
print("ok")
PY

# 7. findings come back sorted by gate order, file, rule ids.
section "order" <<'PY'
from harness import *
st = new_store("combo", "core-budget")
G, D, X = "gotchas/git.md", "gotchas/docker.md", "gotchas/aaa.md"
def tok(i, n=5):
    return " ".join(f"t{i}x{k}" for k in range(n))
put(st, G, ["Never force-push a shared branch.", ("Read the whole diff before committing it.", {"contradictions": [{"with": "Skip it.", "flagged": "2026-09-20"}]})],
    links=["how-i-work/reviews.md", "gotchas/gone.md"], read_when="a git command misbehaves")
put(st, D, [tok(1), tok(2)])                        # orphan
put(st, X, [tok(3)], links=[G], read_when="x")      # thin
put(st, "gotchas/zzz.md", [tok(i) for i in range(10, 36)], links=[G], read_when="z")   # oversized
put(st, "how-i-work/reviews.md", ["Ask a second model to review every plan before building.", "Ask a second model to review every plan before building."],
    links=[G], read_when="planning")                 # duplicate (twice in a file)
got = [(x["gate"], x["file"]) for x in L.lint(st)]
eq(got, [("contradiction", G), ("core-budget", "core.md"), ("broken-link", G), ("orphan", D),
         ("duplicate", "how-i-work/reviews.md"), ("oversized", "gotchas/zzz.md"), ("thin", X)], "sorted by gate order, then file")
print("ok")
PY

# 8. lint is read-only: nothing in the worktree or .git/lore changes, and git sees a clean tree.
section "read only" <<'PY'
import subprocess
from harness import *
st = new_store("ro", "orphan")
put(st, "gotchas/git.md", ["Never force-push a shared branch."], links=["gotchas/missing.md"], read_when="git", last_read={"m-aaaaaaaa": "2026-01-01"}, reads={"m-aaaaaaaa": 1})
subprocess.run(["git", "-C", st.root, "add", "-A"], check=True)
subprocess.run(["git", "-C", st.root, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "fixture"], check=True)
before = snapshot(st)
L.due(st, L.lint(st), now="2026-10-01T00:00:00+00:00")
L.lint(st)
eq(snapshot(st), before, "lint and due wrote nothing")
eq(subprocess.run(["git", "-C", st.root, "status", "--porcelain"], capture_output=True, text=True).stdout, "", "git sees a clean tree")
print("ok")
PY

# 9. due: no findings no run; a non-urgent finding runs once, then waits 24 hours; urgent ones do not wait.
section "due" <<'PY'
from harness import *
import datetime as dt
T0 = dt.datetime(2026, 10, 1, 12, 0, tzinfo=dt.timezone.utc)
h = lambda n: T0 + dt.timedelta(hours=n)
orphan = lambda name: new_store(name, "orphan")
st = orphan("due-orphan")
f = L.lint(st)
eq(L.due(st, f, now=T0), {"run": True, "urgent": False, "gates": ["orphan"], "reason": "findings in orphan; no Canon run recorded"}, "a finding and no run on record")
L.mark_run(st, now=T0)
eq(L.last_run(st), T0, "mark_run records the time")
eq(L.due(st, f, now=h(1)), {"run": False, "urgent": False, "gates": ["orphan"],
                           "reason": "findings in orphan; Canon ran 60 min ago, next run in 1380 min"}, "an hour after a run")
eq(L.due(st, f, now=T0)["run"], False, "at the moment of the run")
eq(L.due(st, f, now=h(24) - dt.timedelta(minutes=1))["run"], False, "one minute short of 24 hours")
d = L.due(st, f, now=h(24))
eq((d["run"], d["reason"]), (True, "findings in orphan; last Canon run 2026-10-01T12:00:00+00:00"), "at 24 hours")
eq(L.due(st, f, now=h(30))["run"], True, "after 24 hours")
eq(L.due(st, [], now=h(30)), {"run": False, "urgent": False, "gates": [], "reason": "no findings"}, "no findings after 24 hours")
# now may be naive (taken as UTC) or an ISO string
eq(L.due(st, f, now=dt.datetime(2026, 10, 1, 13, 0))["run"], False, "a naive datetime is UTC")
eq(L.due(st, f, now="2026-10-02T12:00:00+00:00")["run"], True, "an ISO string")
# the interval is a config key
st.write(".lore/config", "canon_interval_hours: 48\n")
eq(L.due(st, f, now=h(30))["run"], False, "canon_interval_hours raised")
eq(L.due(st, f, now=h(48))["run"], True, "and reached")
# garbage, or a time more than one interval ahead, is no run on record
for name, text in (("far-future", "2026-10-02T12:00:01+00:00\n"), ("garbage", "yesterday-ish\n"), ("empty", "")):
    s2 = orphan("due-" + name)
    s2.write(".git/lore/canon-last-run", text)
    d = L.due(s2, L.lint(s2), now=h(0))
    eq((d["run"], d["reason"]), (True, "findings in orphan; no Canon run recorded"), f"a {name} last-run file is no run on record")
# a clock set back since the run, by up to one interval, still counts as a run just now
s2 = orphan("due-skew")
L.mark_run(s2, now=T0)
f2 = L.lint(s2)
for back, run in ((dt.timedelta(seconds=1), False), (dt.timedelta(hours=23), False), (dt.timedelta(hours=24), False),
                  (dt.timedelta(hours=24, seconds=1), True)):
    d = L.due(s2, f2, now=T0 - back)
    eq(d["run"], run, f"{back} before the recorded run")
eq(L.due(s2, f2, now=T0 - dt.timedelta(seconds=1)),
   {"run": False, "urgent": False, "gates": ["orphan"], "reason": "findings in orphan; Canon ran 0 min ago, next run in 1440 min"}, "a one-second rollback")
s2.write(".lore/config", "canon_interval_hours: 48\n")
eq(L.due(s2, f2, now=T0 - dt.timedelta(hours=40))["run"], False, "the skew allowance is the interval in force")
eq(L.due(s2, f2, now=T0 - dt.timedelta(hours=49))["run"], True, "and no more than it")
# an urgent finding still runs when the clock went back
s3 = new_store("due-skew-urgent", "contradiction")
L.mark_run(s3, now=T0)
eq(L.due(s3, L.lint(s3), now=T0 - dt.timedelta(seconds=1))["run"], True, "urgent through a rollback")
# a bad interval falls back to 24 hours, never raises
for bad in ("inf", "-inf", "nan", "1e300", "1e18", "1e999", "0", "-3", "lots"):
    s4 = orphan("due-bad-" + bad.replace(".", "_"))
    L.mark_run(s4, now=T0)
    s4.write(".lore/config", f"canon_interval_hours: {bad}\n")
    f4 = L.lint(s4)
    eq((L.due(s4, f4, now=h(1))["run"], L.due(s4, f4, now=h(24))["run"]), (False, True), f"canon_interval_hours {bad}")
s4 = orphan("due-huge")   # large but representable: honoured, without overflowing a date
L.mark_run(s4, now=T0)
s4.write(".lore/config", "canon_interval_hours: 1000000\n")
f4 = L.lint(s4)
eq((L.due(s4, f4, now=h(25))["run"], L.due(s4, f4, now=T0 + dt.timedelta(days=3650))["run"]), (False, False), "a huge interval")
# urgent findings run inside the 24 hours
st = new_store("due-contradiction", "contradiction")
L.mark_run(st, now=T0)
d = L.due(st, L.lint(st), now=h(1))
eq(d, {"run": True, "urgent": True, "gates": ["contradiction"], "reason": "urgent: contradiction"}, "contradiction runs inside 24 hours")
st = new_store("due-core", "core-budget")
L.mark_run(st, now=T0)
d = L.due(st, L.lint(st), now=h(1))
eq((d["run"], d["urgent"], d["reason"]), (True, True, "urgent: core-budget"), "core-budget runs inside 24 hours")
eq(d["gates"], ["core-budget"], "core-budget gates")
fake = [{"gate": g, "file": None, "rule_ids": [], "detail": ""} for g in ("thin", "core-budget", "duplicate", "orphan", "contradiction")]
eq(L.due(st, fake, now=h(1)), {"run": True, "urgent": True, "gates": ["contradiction", "core-budget", "orphan", "duplicate", "thin"],
                              "reason": "urgent: contradiction, core-budget"}, "gates are listed in gate order, urgent ones named")
only = [{"gate": g, "file": None, "rule_ids": [], "detail": ""} for g in ("orphan", "thin")]
eq(L.due(st, only, now=h(1))["urgent"], False, "orphan and thin are not urgent")
print("ok")
PY

# 10. mark_run: 0600 under a permissive umask, atomic, machine-local, nothing else written.
section "mark_run" <<'PY'
import os, stat, subprocess
from harness import *
import datetime as dt
st = new_store("mark")
os.umask(0)
path = st.local("canon-last-run")
before = snapshot(st)
L.mark_run(st, now=dt.datetime(2026, 10, 2, 9, 0, tzinfo=dt.timezone.utc))
eq(oct(stat.S_IMODE(os.stat(path).st_mode)), "0o600", "mode under umask 0")
eq(open(path).read(), "2026-10-02T09:00:00+00:00\n", "contents")
after = snapshot(st)
eq(sorted(set(after) - set(before)) + sorted(k for k in before if k in after and before[k] != after[k]),
   [".git/lore/canon-last-run"], "mark_run wrote only the last-run file")
eq([n for n in os.listdir(st.local()) if ".tmp" in n], [], "no temporary file left")
L.mark_run(st, now=dt.datetime(2026, 10, 3, 9, 0, tzinfo=dt.timezone.utc))
eq(open(path).read(), "2026-10-03T09:00:00+00:00\n", "a second run replaces the first")
# a time in another zone is stored as the same instant in UTC
L.mark_run(st, now=dt.datetime(2026, 10, 4, 12, 0, tzinfo=dt.timezone(dt.timedelta(hours=3))))
eq(open(path).read(), "2026-10-04T09:00:00+00:00\n", "a time in another zone is stored in UTC")
# a failed write leaves the last run as it was and no temporary file
try:
    L.mark_run(st, now=12345)
except AttributeError:
    pass
else:
    fail("mark_run accepted a time that is not a time")
eq(open(path).read(), "2026-10-04T09:00:00+00:00\n", "a failed mark_run left the last run alone")
# the rename fails (a directory is in the way): the temporary file is removed
os.unlink(path)
os.mkdir(path)
os.mkdir(os.path.join(path, "keep"))
try:
    L.mark_run(st, now=dt.datetime(2026, 10, 5, 9, 0, tzinfo=dt.timezone.utc))
except OSError:
    pass
else:
    fail("mark_run replaced a directory")
eq([n for n in os.listdir(st.local()) if ".tmp" in n], [], "a failed rename left no temporary file")
os.rmdir(os.path.join(path, "keep"))
os.rmdir(path)
# the time defaults to now, in UTC
L.mark_run(st)
got = L.last_run(st)
assert got is not None and abs((dt.datetime.now(dt.timezone.utc) - got).total_seconds()) < 5, got
# the file is machine-local: git ignores .git/lore, so it is never committed
subprocess.run(["git", "-C", st.root, "add", "-A"], check=True)
names = subprocess.run(["git", "-C", st.root, "ls-files"], capture_output=True, text=True).stdout.split()
assert not any("canon-last-run" in n for n in names), names

# never through a symlink. A temporary name that is already a symlink is skipped for a fresh one.
T = dt.datetime(2026, 10, 6, 9, 0, tzinfo=dt.timezone.utc)
victim = os.path.join(TMP, "victim")
open(victim, "w").write("fictional original\n")
os.chmod(victim, 0o644)
names = iter(["plantedname", "freshname"])
real = L.secrets.token_hex
L.secrets.token_hex = lambda n: next(names)
os.symlink(victim, st.local("canon-last-run.tmp-plantedname"))
L.mark_run(st, now=T)
L.secrets.token_hex = real
eq(open(victim).read(), "fictional original\n", "a symlinked temporary name was not written through")
eq(oct(stat.S_IMODE(os.stat(victim).st_mode)), "0o644", "nor chmodded")
eq(open(path).read(), "2026-10-06T09:00:00+00:00\n", "the last run was written")
eq(sorted(n for n in os.listdir(st.local()) if ".tmp" in n), ["canon-last-run.tmp-plantedname"], "only the planted link remains")
os.unlink(st.local("canon-last-run.tmp-plantedname"))
# every name taken: it gives up instead of writing through one
L.secrets.token_hex = lambda n: "same"
os.symlink(victim, st.local("canon-last-run.tmp-same"))
try:
    L.mark_run(st, now=T)
except lore.LoreError:
    pass
else:
    fail("mark_run wrote with every temporary name taken")
L.secrets.token_hex = real
eq(open(victim).read(), "fictional original\n", "the victim is intact after giving up")
os.unlink(st.local("canon-last-run.tmp-same"))
# the last-run file itself a symlink: it is replaced, never followed
os.unlink(path)
os.symlink(victim, path)
L.mark_run(st, now=T)
assert not os.path.islink(path), "the symlink was kept"
eq(open(victim).read(), "fictional original\n", "a symlinked last-run file was not written through")
eq(open(path).read(), "2026-10-06T09:00:00+00:00\n", "and holds the run")
# last_run does not read through a symlinked file either
stamp = os.path.join(TMP, "stamp")
open(stamp, "w").write("2026-10-06T09:00:00+00:00\n")
os.unlink(path)
os.symlink(stamp, path)
eq(L.last_run(st), None, "last_run does not read through a symlinked last-run file")
os.unlink(path)
# .git/lore a symlink to a directory elsewhere: refused, nothing written there
st2 = new_store("mark-link")
outside = os.path.join(TMP, "outside")
os.mkdir(outside)
os.rename(st2.local(), st2.local() + ".real") if os.path.isdir(st2.local()) else None
os.symlink(outside, st2.local())
try:
    L.mark_run(st2, now=T)
except lore.LoreError as err:
    eq(str(err), f"refusing to use lore in {st2.root}: it is a symlink or not a directory", "the refusal")
else:
    fail("mark_run followed a symlinked .git/lore")
eq(os.listdir(outside), [], "nothing was written through a symlinked .git/lore")
open(os.path.join(outside, "canon-last-run"), "w").write("2026-10-06T09:00:00+00:00\n")
eq(L.last_run(st2), None, "last_run does not read through a symlinked .git/lore")
# .git itself a symlink
st3 = new_store("mark-git-link")
os.rename(os.path.join(st3.root, ".git"), os.path.join(TMP, "moved-git"))
os.symlink(os.path.join(TMP, "moved-git"), os.path.join(st3.root, ".git"))
before = sorted(os.listdir(os.path.join(TMP, "moved-git", "lore")))
try:
    L.mark_run(st3, now=T)
except lore.LoreError as err:
    eq(str(err), f"refusing to use .git in {st3.root}: it is a symlink or not a directory", "the refusal for .git")
else:
    fail("mark_run followed a symlinked .git")
eq(sorted(os.listdir(os.path.join(TMP, "moved-git", "lore"))), before, "nothing was written through a symlinked .git")
# no .git/lore yet: it is created, private; no .git at all: nothing is invented
st4 = new_store("mark-fresh")
import shutil
shutil.rmtree(st4.local())
L.mark_run(st4, now=T)
eq(oct(stat.S_IMODE(os.stat(st4.local()).st_mode)), "0o700", "a created .git/lore is private")
st5 = lore_store.Store2(os.path.join(TMP, "mark-nogit"), day=DAY)
os.makedirs(st5.root)
try:
    L.mark_run(st5, now=T)
except lore.LoreError as err:
    eq(str(err), f"no .git in {st5.root}; not a lore store", "the refusal without .git")
else:
    fail("mark_run invented a .git")
eq(os.listdir(st5.root), [], "and left the folder empty")
eq(os.listdir(os.getcwd()), [], "mark_run wrote nothing in the working folder")
print("ok")
PY

echo "PASS: test-lint.sh"
