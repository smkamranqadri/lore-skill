"""Helpers for tests/test-ui-server.sh, on top of tests/fixtures/canon's
harness (stores with a local bare hub, a fake Canon, exact checks). Fictional names only; never a
real model, the network or the owner's home.
"""

import json
import os
import subprocess

from harness import *  # noqa: F401,F403
from harness import M, TMP, eq, fail, git, lore_store

LORE = os.path.join(os.environ["LORE_SCRIPTS"], "lore.py")


def cli(st, *args, today="2026-10-01"):
    """`lore --store2 <st> <args>` in a new process: (exit code, stdout and stderr as lines)."""
    p = subprocess.run(["python3", LORE, "--today", today, "--store2", st.root] + list(args),
                       capture_output=True, text=True)
    return p.returncode, (p.stdout + p.stderr).splitlines()


def full(st, rev="HEAD"):
    return git(st.root, "rev-parse", rev)


def short(st, rev="HEAD"):
    return git(st.root, "rev-parse", "--short", rev)


def show(st, rev, path):
    """A file as `rev` has it, or None."""
    p = subprocess.run(["git", "-C", st.root, "show", f"{rev}:{path}"], capture_output=True, text=True)
    return p.stdout if p.returncode == 0 else None


def show_meta(st, rev, rel):
    text = show(st, rev, lore_store.meta_rel(rel))
    return json.loads(text) if text else None


def count(st):
    return int(git(st.root, "rev-list", "--count", "HEAD"))
