"""Helpers for tests/test-canon.sh: stores with a local bare hub, a fake Canon, exact checks.

Each section imports it (`from harness import *`). LORE_SCRIPTS names the scratch copy of the
skill's scripts, TMP_ROOT the test's temporary directory, and LORE_CANON_CMD the fake Canon
(tests/test-canon.sh writes it): it records each call in $TMP_ROOT/canon-calls, keeps each prompt, and answers by FAKE_CANON (reply: the JSON in
$FAKE_CANON_REPLY; prose; empty; fail). Never a real model, never the network.
"""

import contextlib
import datetime as dt
import hashlib
import io
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.environ["LORE_SCRIPTS"])
import lore  # noqa: E402
sys.modules.setdefault("lore", lore)
import lore_store  # noqa: E402
import lore_master as M  # noqa: E402
import lore_hub  # noqa: E402
import lore_canon  # noqa: E402
import lore_lint  # noqa: E402

DAY = dt.date(2026, 10, 1)
TMP = os.environ["TMP_ROOT"]
CALLS = os.path.join(TMP, "canon-calls")


def fail(msg):
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def eq(got, want, what):
    if got != want:
        fail(f"{what}:\n  got:  {got!r}\n  want: {want!r}")


def raises(fn, exc, msg, what):
    try:
        fn()
    except exc as err:
        eq(str(err), msg, what)
        return
    fail(f"{what}: no {exc.__name__} raised")


def git(root, *args):
    return subprocess.run(["git", "-C", root] + list(args), capture_output=True, text=True, check=True).stdout.strip()


def quiet(fn, *a, **kw):
    with contextlib.redirect_stdout(io.StringIO()):
        return fn(*a, **kw)


def new_store(name, day=DAY, hub=True):
    """An empty store, with a bare repo of its own as the hub."""
    st = lore_store.Store2(os.path.join(TMP, name), day=day)
    lore_store.init_store(st)
    if hub:
        bare = os.path.join(TMP, name + "-hub.git")
        subprocess.run(["git", "init", "-q", "--bare", "-b", "main", bare], check=True)
        quiet(lore_hub.set_hub, st, bare)
    return st


def at(st, day):
    """The same store, acting on another day."""
    return lore_store.Store2(st.root, day=day)


def hub_dir(st):
    return os.path.join(TMP, os.path.basename(st.root) + "-hub.git")


def hub_subjects(st):
    """Subjects on the hub's main, newest first."""
    return git(hub_dir(st), "log", "main", "--format=%s").splitlines()


def pushed(st):
    return git(st.root, "rev-parse", "HEAD") == git(hub_dir(st), "rev-parse", "main")


def add(file, text, explicit=True, quote=None, session="s-1", **kw):
    return dict({"op": "add", "file": file, "text": text, "explicit": explicit,
                 "quote": quote if quote is not None else text, "session": session}, **kw)


def describe(file, rw):
    return {"op": "describe", "file": file, "read_when": rw}


def seed(st, ops):
    """Apply ops as the Loremaster would and push them."""
    M.apply(st, ops, source="seed")
    quiet(lore_hub.push_step, st, True)


def commit_hand(st, msg="hand edit"):
    lore_store.tidy(st)
    lore_store.commit(st, msg)
    quiet(lore_hub.push_step, st, True)


def meta(st, rel):
    return lore_store.load_meta(st, rel)


def rule_id(st, rel, text):
    hits = [eid for eid, e in meta(st, rel)["rules"].items() if e["text"] == text]
    eq(len(hits), 1, f"entries for {text!r} in {rel}")
    return hits[0]


def gates(st, gate=None, file=None):
    """Lint's findings as (gate, file) pairs, optionally only one gate's (or one file's)."""
    return [(f["gate"], f["file"]) for f in lore_lint.lint(st)
            if (gate is None or f["gate"] == gate) and (file is None or f["file"] == file)]


def reply(ops, answer="fixed"):
    """The fake Canon's next answer."""
    p = os.path.join(TMP, "canon-reply.json")
    with open(p, "w") as f:
        json.dump({"ops": ops, "answer": answer}, f)
    os.environ["FAKE_CANON_REPLY"] = p
    os.environ["FAKE_CANON"] = "reply"


def mode(m):
    os.environ["FAKE_CANON"] = m


def calls():
    try:
        with open(CALLS) as f:
            return len(f.read().splitlines())
    except FileNotFoundError:
        return 0


def prompt(n):
    with open(os.path.join(TMP, f"canon-prompt.{n}")) as f:
        return f.read()


def session_end(st, trigger, force=False):
    """One session-end run (`lore store run`), its log lines without the time stamps."""
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        lore_hub.store_run(st, trigger, force)
    return [l.split(" ", 1)[1] for l in buf.getvalue().splitlines()]


def has(lines, line, what):
    if line not in lines:
        fail(f"{what}: no line {line!r} in:\n  " + "\n  ".join(lines))


def match(lines, pattern, what):
    """Some line matches `pattern` in full."""
    if not any(re.fullmatch(pattern, l) for l in lines):
        fail(f"{what}: no line matching {pattern!r} in:\n  " + "\n  ".join(lines))


def canon_lines(lines):
    return [l for l in lines if l.startswith("store-run: canon")]


def snapshot(st):
    """Every file of the worktree and of .git/lore (but the last-run stamp and state), hashed,
    with HEAD: equal snapshots mean Canon wrote nothing."""
    out = {"HEAD": git(st.root, "rev-parse", "HEAD"), "status": git(st.root, "status", "--porcelain")}
    for d, dirs, files in os.walk(st.root):
        rel_d = os.path.relpath(d, st.root)
        if rel_d == ".git":
            dirs[:] = [x for x in dirs if x == "lore"]
            continue
        for fn in files:
            p = os.path.join(d, fn)
            rel = os.path.relpath(p, st.root)
            if rel in (os.path.join(".git", "lore", "state.json"), os.path.join(".git", "lore", lore_lint.LAST_RUN)):
                continue
            with open(p, "rb") as f:
                out[rel] = hashlib.sha256(f.read()).hexdigest()
    return out


def state(st, key):
    return lore_hub.load_state(st).get(key)


def age_failure(st, hours=3):
    s = lore_hub.load_state(st)
    s["canon_last_fail"] = (dt.datetime.now().astimezone() - dt.timedelta(hours=hours)).isoformat(timespec="seconds")
    lore_hub.save_state(st, s)


def forget_run(st):
    """As if Canon last ran two days ago (or never), so a non-urgent gate is due again."""
    lore_lint.mark_run(st, dt.datetime.now().astimezone() - dt.timedelta(days=2))


def retires(st):
    """The retirements waiting in the Inbox."""
    return [i for i in M.inbox_list(st) if i["kind"] == "retire"]


def consistent(st):
    rep = lore_store.reconcile(st)
    eq((rep["adopted"], rep["dropped"], rep["duplicates"]), ([], [], []), "rule lines and sidecars agree")
