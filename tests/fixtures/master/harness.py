"""Helpers for tests/test-master.sh: a store per test, a fake model, exact checks.

Each section of the test imports it (`from harness import *`); LORE_SCRIPTS names the scripts
directory and TMP_ROOT the test's temporary directory. Never a real model: run_model is a
Python function returning canned JSON.
"""

import datetime as dt
import hashlib
import json
import os
import subprocess
import sys

sys.path.insert(0, os.environ["LORE_SCRIPTS"])
import lore  # noqa: E402
sys.modules.setdefault("lore", lore)
import lore_store  # noqa: E402
import lore_master as M  # noqa: E402

DAY = dt.date(2026, 10, 1)
TMP = os.environ["TMP_ROOT"]


def fail(msg):
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def eq(got, want, what):
    if got != want:
        fail(f"{what}:\n  got:  {got!r}\n  want: {want!r}")


def new_store(name):
    st = lore_store.Store2(os.path.join(TMP, name), day=DAY)
    lore_store.init_store(st)
    return st


def item(text, explicit=True, quote=None, session="s-1"):
    return {"text": text, "explicit": explicit, "quote": quote if quote is not None else text,
            "session": session, "host": "fixture-host", "created": "2026-10-01T09:00:00+00:00"}


def add(file, text, explicit=True, quote=None, session="s-1", **kw):
    return dict({"op": "add", "file": file, "text": text, "explicit": explicit,
                 "quote": quote if quote is not None else text, "session": session}, **kw)


def git(st, *args):
    return subprocess.run(["git", "-C", st.root] + list(args), capture_output=True, text=True, check=True).stdout.strip()


def commits(st):
    return int(git(st, "rev-list", "--count", "HEAD"))


def subject(st):
    return git(st, "log", "-1", "--format=%s")


def snapshot(st):
    """Every file of the worktree and of .git/lore, hashed, with HEAD and git status: equal
    snapshots mean nothing was written."""
    out = {"HEAD": git(st, "rev-parse", "HEAD"), "status": git(st, "status", "--porcelain")}
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


def meta(st, rel):
    return lore_store.load_meta(st, rel)


def rule_id(st, rel, text):
    hits = [eid for eid, e in meta(st, rel)["rules"].items() if e["text"] == text]
    eq(len(hits), 1, f"entries for {text!r} in {rel}")
    return hits[0]


def fake(reply, calls=None):
    """A run_model that records each prompt and answers `reply` (a dict is sent as JSON)."""
    def run(prompt):
        if calls is not None:
            calls.append(prompt)
        return reply if isinstance(reply, str) else json.dumps(reply)
    return run


def consistent(st):
    """Rule lines and sidecars agree: a tidy adopts and drops nothing."""
    rep = lore_store.reconcile(st)
    eq((rep["adopted"], rep["dropped"], rep["duplicates"]), ([], [], []), "rule lines and sidecars agree")


def raises(fn, exc, msg, what):
    try:
        fn()
    except exc as err:
        eq(str(err), msg, what)
        return
    fail(f"{what}: no {exc.__name__} raised")
