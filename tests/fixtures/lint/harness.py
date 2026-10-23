"""Helpers for tests/test-lint.sh: stores built from the fixture trees here (`clean` is the base,
a scenario directory is laid over it) or from `put`, and exact checks. Never a real model.

Each section of the test imports it (`from harness import *`); LORE_SCRIPTS names the scripts
directory and TMP_ROOT the test's temporary directory.
"""

import datetime as dt
import hashlib
import json
import os
import shutil
import sys

sys.path.insert(0, os.environ["LORE_SCRIPTS"])
import lore  # noqa: E402
sys.modules.setdefault("lore", lore)
import lore_store  # noqa: E402
import lore_lint as L  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
TMP = os.environ["TMP_ROOT"]
DAY = dt.date(2026, 10, 1)   # "today" for every fixture; the fixtures' rules were created 2026-09-01


def fail(msg):
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def eq(got, want, what):
    if got != want:
        fail(f"{what}:\n  got:  {got!r}\n  want: {want!r}")


def overlay(src, dst):
    for d, _, names in os.walk(src):
        for fn in names:
            to = os.path.join(dst, os.path.relpath(os.path.join(d, fn), src))
            os.makedirs(os.path.dirname(to), exist_ok=True)
            shutil.copyfile(os.path.join(d, fn), to)


def new_store(name, *scenarios, base="clean"):
    """A store at TMP/name holding the `clean` fixture (or `base`, None for the bare store) with
    each scenario laid over it, and its index built unless a scenario brings one."""
    st = lore_store.Store2(os.path.join(TMP, name), day=DAY)
    lore_store.init_store(st)
    for scn in ([base] if base else []) + list(scenarios):
        overlay(os.path.join(HERE, scn), st.root)
    if not os.path.exists(os.path.join(HERE, scenarios[-1] if scenarios else "-", "INDEX.md")):
        lore_store.write_index(st)
    return st


def put(st, rel, rules, links=None, read_when=None, created="2026-09-01", last_read=None, reads=None, title=None):
    """Write a rule file and its sidecar. A rule is a text or (text, {entry fields})."""
    texts = [r if isinstance(r, str) else r[0] for r in rules]
    st.write(rel, lore_store.render_rules(title or "Fixture", texts))
    entries = {}
    for r in rules:
        text, extra = (r, {}) if isinstance(r, str) else r
        entry = {"text": text, "created": created, "explicit": True, "count": 1, "dates": [created],
                 "confidence": 0.9, "sessions": [], "updated": created + "T09:00:00+00:00"}
        entry.update(extra)
        entries[lore_store.new_id(text, set(entries))] = entry
    meta = {"rules": entries, "reads": reads or {}, "last_read": last_read or {}}
    if links is not None:
        meta["links"] = links
    if read_when:
        meta["read_when"] = read_when
    lore_store.save_meta(st, rel, meta)
    return list(entries)


def ids(st, rel):
    """The rule ids of a file in the order of its lines."""
    by_text = {e["text"]: i for i, e in lore_store.load_meta(st, rel)["rules"].items()}
    return [by_text.get(r) for r in lore_store.parse_rules(st.read(rel))[1]]


def gates(findings):
    return [(f["gate"], f["file"]) for f in findings]


def snapshot(st):
    """Every file of the worktree and of .git/lore, hashed: equal snapshots mean nothing was written."""
    out = {}
    for d, dirs, files in os.walk(st.root):
        rel_d = os.path.relpath(d, st.root)
        if rel_d == ".git":
            dirs[:] = [x for x in dirs if x == "lore"]
            continue
        for fn in files:
            p = os.path.join(d, fn)
            with open(p, "rb") as f:
                out[os.path.relpath(p, st.root)] = hashlib.sha256(f.read()).hexdigest()
    return out
