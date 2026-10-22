"""lore 2.0 hub and commands: `lore store ...`, `lore hub ...`, the session-end step, the shim.

The hub is an optional private git remote named `hub`. After every commit lore fetches, rebases
onto the hub (merge drivers in lore_store), tidies, and pushes. A failed push is remembered in
.git/lore/state.json and retried on the next run, after the same backoff as 1.1.0's sync-run;
after three failed runs in a row `lore hub status` and the session-end log say so.
"""

import contextlib
import datetime as dt
import glob
import json
import os
import re
import shlex
import shutil
import subprocess
import sys

import lore
import lore_store
import lore_sync
from lore_store import Store2, GitError

REMOTE = "hub"
FAILS_REPORTED = 3
GH_TIMEOUT = 60
SHIM_MARK = "# written by lore setup; `lore.py setup --remove` deletes it"
GITHUB_RE = re.compile(r"^(?:https://(?:[^@/]+@)?github\.com/|git@github\.com:|ssh://git@github\.com/)"
                       r"([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?/?$")


def log(msg):
    print(f"{dt.datetime.now().isoformat(timespec='seconds')} {msg}", flush=True)


def open_store(args):
    return Store2(lore_store.store_root(args), lore.today(args))


# ---- machine-local state ----------------------------------------------------------------------

def load_state(store):
    try:
        with open(store.local("state.json")) as f:
            st = json.load(f)
    except (FileNotFoundError, ValueError):
        st = {}
    st.setdefault("push_fails", 0)
    st.setdefault("reads_seen", {})
    return st


def save_state(store, st):
    os.makedirs(store.local(), exist_ok=True)
    tmp = store.local("state.json.tmp")
    with open(tmp, "w") as f:
        f.write(json.dumps(st, indent=1, sort_keys=True) + "\n")
    os.replace(tmp, store.local("state.json"))


def safe_url(url):
    return re.sub(r"://[^/@\s]+@", "://***@", url or "")


def hub_url(store):
    rc, out, _ = store.git("config", "--get", f"remote.{REMOTE}.url", check=False)
    return out.strip() if rc == 0 and out.strip() else None


def _has_ref(store, ref):
    return store.git("rev-parse", "--verify", "-q", ref, check=False)[0] == 0


# ---- sync: fetch, rebase, tidy, push ----------------------------------------------------------

def sync(store):
    """Bring the hub's commits in and send ours out. Raises LoreError; leaves no rebase behind."""
    lore_store.recover(store)
    store.git("fetch", "-q", REMOTE)
    remote = f"refs/remotes/{REMOTE}/{lore_store.BRANCH}"
    if _has_ref(store, remote):
        rebase(store, remote)
        lore_store.tidy(store)
        lore_store.commit(store, "tidy after merging the hub")
    store.git("push", "-q", REMOTE, f"HEAD:refs/heads/{lore_store.BRANCH}")


REBASE_STEPS = 100


def rebase(store, onto):
    """Replay local commits onto the hub, settling each stop with lore's merge policy. On any
    failure, a timeout included, the rebase is aborted so the local commits stay as they were."""
    try:
        rc, _, err = store.git("rebase", "-q", onto, check=False)
        for _ in range(REBASE_STEPS):
            if rc == 0:
                return
            if not lore_store.rebase_active(store):
                break
            if not lore_store.resolve_conflicts(store):
                if store.git("diff", "--cached", "--quiet", check=False)[0]:
                    break   # stopped with staged changes and nothing unmerged: not ours to guess
                rc, _, err = store.git("rebase", "--skip", check=False)   # the commit became empty
                continue
            rc, _, err = store.git("rebase", "--continue", check=False)
        raise GitError(f"rebase onto the hub failed: {lore_store.clean_err(err)}")
    except lore.LoreError as err:
        lore_store.recover(store, killed=getattr(err, "timed_out", False))
        raise


def push_step(store, force=False):
    """After a commit: sync with the hub, unless none is set or a recent failure says wait.
    Returns one status line; raises nothing."""
    url = hub_url(store)
    if not url:
        return "hub: none (local git only)"
    st = load_state(store)
    if st["push_fails"] and not force and st.get("last_fail"):
        age = (dt.datetime.now().astimezone() - dt.datetime.fromisoformat(st["last_fail"])).total_seconds()
        if age < lore_sync.BACKOFF_MIN * 60:
            return (f"hub: push waits, backing off after a failed run (under {lore_sync.BACKOFF_MIN} min ago); "
                    + fails_line(st))
    try:
        sync(store)
    except lore.LoreError as err:
        st["push_fails"] += 1
        st["last_fail"] = lore_store.now_iso()
        st["last_error"] = str(err)
        save_state(store, st)
        return f"hub: push FAILED ({err}); " + fails_line(st)
    st.update(push_fails=0, last_push=lore_store.now_iso())
    st.pop("last_error", None)
    save_state(store, st)
    return f"hub: pushed to {safe_url(url)}"


def fails_line(st):
    n = st.get("push_fails", 0)
    if n >= FAILS_REPORTED:
        return f"push has failed {n} runs in a row; see `lore hub status`"
    return f"push failed {n} run(s) in a row; retried on the next run"


# ---- GitHub through gh ------------------------------------------------------------------------

def gh_bin():
    return os.environ.get("LORE_GH_CMD") or shutil.which("gh")


def gh(*args):
    exe = gh_bin()
    if not exe:
        raise lore.LoreError("gh is not installed")
    try:
        r = subprocess.run([exe] + list(args), capture_output=True, text=True, timeout=GH_TIMEOUT,
                           stdin=subprocess.DEVNULL, env=dict(os.environ, GH_PROMPT_DISABLED="1"))
    except subprocess.TimeoutExpired:
        raise lore.LoreError(f"gh {args[0]} timed out after {GH_TIMEOUT}s")
    if r.returncode:
        raise lore.LoreError(f"gh {' '.join(args[:2])} failed: {lore_store.clean_err(r.stderr or r.stdout)}")
    return r.stdout


def visibility(url):
    """(visibility or None, a warning when it was not checked)."""
    m = GITHUB_RE.match(url)
    if not m:
        return None, "not a GitHub URL, so its visibility was not checked; make sure it is private"
    if not gh_bin():
        return None, "gh is not installed, so the repository's visibility was not checked; make sure it is private"
    try:
        v = json.loads(gh("repo", "view", f"{m.group(1)}/{m.group(2)}", "--json", "visibility")).get("visibility")
    except (lore.LoreError, ValueError, AttributeError) as err:
        return None, f"visibility was not checked ({err}); make sure the repository is private"
    return str(v).upper(), None


def set_hub(store, url):
    """Attach a hub: refuse a public GitHub repo, then one test push. On failure, nothing changes."""
    store.require()
    if not url or url.startswith("-") or any(c.isspace() for c in url):
        raise lore.LoreError("give the hub as one git URL")
    vis, warn = visibility(url)
    if vis == "PUBLIC":
        raise lore.LoreError(f"refused: {safe_url(url)} is a public repository; the hub must be private")
    if warn:
        print(f"warning: {warn}")
    lore_store.tidy(store)
    lore_store.commit(store)   # pending edits go in first, so a rollback below can never lose them
    old = hub_url(store)
    _, head, _ = store.git("rev-parse", "HEAD")
    store.git("remote", "set-url" if old else "add", REMOTE, url)
    try:
        sync(store)
    except lore.LoreError as err:
        store.git("reset", "-q", "--hard", head.strip(), check=False)
        store.git("remote", "set-url", REMOTE, old) if old else store.git("remote", "remove", REMOTE, check=False)
        raise lore.LoreError(f"hub not set: the test push failed: {err}")
    st = load_state(store)
    st.update(push_fails=0, last_push=lore_store.now_iso())
    st.pop("last_error", None)
    save_state(store, st)
    print(f"hub set: {safe_url(url)} (test push ok)")


def create_hub(store, name, yes):
    store.require()
    if not gh_bin():
        raise lore.LoreError("gh is not installed; create a private repository yourself and run `lore hub set <url>`")
    if not re.fullmatch(r"[A-Za-z0-9_.-]{1,100}(/[A-Za-z0-9_.-]{1,100})?", name):
        raise lore.LoreError(f"bad repository name: {name}")
    if not yes:
        if not sys.stdin.isatty():
            raise lore.LoreError("not a terminal; run again with --yes to create the repository")
        if input(f"Create the private GitHub repository {name} with gh? [y/N] ").strip().lower() not in ("y", "yes"):
            print("Nothing created.")
            return
    gh("repo", "create", name, "--private", "--description", "lore memory (private)")
    try:
        info = json.loads(gh("repo", "view", name, "--json", "url,sshUrl,visibility"))
        info["url"], info["sshUrl"]
    except (ValueError, KeyError, TypeError):
        raise lore.LoreError(f"gh did not describe {name}; set the hub with `lore hub set <url>`")
    if str(info.get("visibility")).upper() != "PRIVATE":
        raise lore.LoreError(f"{name} was created but is not private; not used as the hub")
    try:
        proto = gh("config", "get", "git_protocol").strip()
    except lore.LoreError:
        proto = ""
    url = info["sshUrl"] if proto == "ssh" else info["url"].rstrip("/") + ".git"
    set_hub(store, url)


# ---- the session-end step ---------------------------------------------------------------------

def drain_queue(store):
    """Read counts from the transcripts the hook queued, as {relpath: new reads since the last
    run}, notes for the log, and `ack`: call it once the counts are saved, and only then are the
    queue entries removed and the per-transcript totals advanced. Counting is by difference, so a
    transcript seen at several events of one session is never counted twice; a run that fails
    before `ack` leaves everything to be counted again."""
    sys.modules.setdefault("lore", lore)
    import lore_capture
    try:
        import lore_reads
    except ImportError:
        lore_reads = None
    st = load_state(store)
    seen = st["reads_seen"]
    hosts = {h["name"]: h for h in lore.load_hosts()}
    total, notes, done = {}, [], []
    seen = dict(seen)
    for qf in sorted(glob.glob(store.local("queue", "*.json"))):
        done.append(qf)
        try:
            with open(qf) as f:
                data = json.load(f)
            host = hosts[data["lore_host"]]
        except (ValueError, KeyError, TypeError, OSError):
            notes.append("reads: dropped an unreadable queue entry")
            continue
        payload = data.get("payload") if isinstance(data.get("payload"), dict) else {}
        path = payload.get(host.get("transcript_key", "transcript_path")) or \
            lore_capture.find_by_session(host, payload.get(host.get("session_key", "session_id")))
        fmt = host.get("transcript_format", "generic")
        if not isinstance(path, str) or not os.path.isfile(path):
            continue
        if lore_reads is None or not lore_reads.supported(fmt):
            notes.append(f"reads: {host['name']} reports no read data")
            continue
        now = lore_reads.reads(fmt, path, store.root)
        before = seen.get(path, {})
        for rel, n in now.items():
            if n > before.get(rel, 0):
                total[rel] = total.get(rel, 0) + n - before.get(rel, 0)
        seen[path] = now

    def ack():
        st["reads_seen"] = {p: c for p, c in seen.items() if os.path.exists(p)}
        save_state(store, st)
        for qf in done:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(qf)
    return total, notes, ack


def store_run(store, trigger, force=False):
    """The 2.0 step at session end: reads, one commit, a push when a hub is set."""
    if not store.exists():
        log(f"store-run: skipped, no lore 2.0 store at {store.root} ({trigger})")
        return
    with store.locked(wait=False) as lk:
        if lk is None:
            log(f"store-run: busy, another run is in progress ({trigger})")
            return
        try:
            lore_store.recover(store)
            counts, notes, ack = drain_queue(store)
            for n in notes:
                log(f"store-run: {n}")
            changed = lore_store.record_reads(store, counts, store.machine())
        except lore.LoreError as err:
            log(f"store-run: {err}; this session's reads stay queued for the next run ({trigger})")
            return
        ack()
        try:
            rep = lore_store.tidy(store)
        except lore.LoreError as err:
            log(f"store-run: {err}; nothing committed ({trigger})")
            return
        if rep["index"].get("error"):
            log(f"store-run: index not written: {rep['index']['error']}")
        reads_only = {lore_store.meta_rel(r) for r in changed}

        def subject(changes):   # a commit of read counts only says so; anything else describes itself
            if changed and {p for _, p in changes} <= reads_only:
                return f"reads from {trigger}: " + ", ".join(changed)
            return None
        try:
            done = lore_store.commit(store, subject)
        except lore.LoreError as err:
            log(f"store-run: {err}")
            done = None
        log(f"store-run: committed {done[0]} {done[1]} ({trigger})" if done else f"store-run: nothing to commit ({trigger})")
        log("store-run: " + push_step(store, force))


# ---- commands ---------------------------------------------------------------------------------

def cmd_store(_, args):
    store = open_store(args)
    if args.action == "init":
        made = lore_store.init_store(store)
        print(f"created the lore 2.0 store at {store.root}" if made else f"store already initialised at {store.root}")
        return
    if args.action == "run":
        store_run(store, args.trigger, args.force)
        return
    store.require()
    with store.locked():
        if args.action == "index":
            rep = lore_store.write_index(store)
            print(f"INDEX.md {rep['tokens']} tokens (budget {rep['budget']})")
            for rel in rep["no_read_when"]:
                print(f"no read_when: {rel} (listed with a plain line)")
            if rep["core_dropped"]:
                print(f"over budget: {rep['core_dropped']} core rule(s) left out of the index")
        elif args.action == "commit":
            rep = lore_store.tidy(store)
            if rep["index"].get("error"):
                print(f"index not written: {rep['index']['error']}")
            done = lore_store.commit(store, args.message)
            print(f"committed {done[0]}: {done[1]}" if done else "nothing to commit")
            line = push_step(store, force=True)
            print(line)
            if "FAILED" in line:
                raise lore.LoreError("committed locally; the push failed")
        elif args.action == "status":
            status(store)


def status(store):
    rep = lore_store.tidy(store)
    _, head, _ = store.git("log", "-1", "--format=%h %s")
    print(f"store: {store.root}")
    print(f"head: {head.strip()}")
    files = store.rule_files()
    core = len(lore_store.parse_rules(store.read("core.md"))[1])
    print(f"rule files: {len(files)} (core rules: {core})")
    _, dirty, _ = store.git("status", "--porcelain")
    print("uncommitted: " + (", ".join(sorted(l[3:] for l in dirty.splitlines())) if dirty.strip() else "none"))
    for rel, eid, text in lore_store.hand_edits(store):
        print(f"unmatched hand edit: {rel} [{eid}] {lore.redact(text)}")
    for rel, text in rep["duplicates"]:
        print(f"duplicate rule: {rel}: {lore.redact(text)} (kept once in the metadata; remove the extra line)")
    for rel, n in rep["bad"]:
        print(f"not a rule line: {rel}:{n}")
    for rel in rep["index"]["no_read_when"]:
        print(f"no read_when: {rel} (listed with a plain line)")
    for rel in store.outside_layout():
        print(f"outside the layout: {rel} (not indexed)")
    for p in sorted(glob.glob(store.local("proposals", "*.json"))):
        print(f"layout proposal: {p} (the hub's layout was kept)")
    if rep["index"].get("error"):
        print(f"index: FAILED, not written: {rep['index']['error']}")
    else:
        print(f"index: {rep['index']['tokens']} tokens (budget {rep['index']['budget']})"
              + (f", {rep['index']['core_dropped']} core rule(s) over budget" if rep["index"]["core_dropped"] else ""))
    print("hub: " + (safe_url(hub_url(store)) or "none (local git only)"))


def cmd_hub(_, args):
    store = open_store(args)
    if args.action == "set":
        if not args.url:
            raise lore.LoreError("usage: lore hub set <url>")
        with store.locked():
            set_hub(store, args.url)
    elif args.action == "create":
        with store.locked():
            create_hub(store, args.name, args.yes)
    else:
        store.require()
        url = hub_url(store)
        st = load_state(store)
        print("hub: " + (safe_url(url) if url else "none (local git only)"))
        if not url:
            return
        remote = f"refs/remotes/{REMOTE}/{lore_store.BRANCH}"
        rng = f"{remote}..HEAD" if _has_ref(store, remote) else "HEAD"
        _, n, _ = store.git("rev-list", "--count", rng)
        print(f"last push: {st.get('last_push') or 'never'}")
        print(f"not pushed: {n.strip()} commit(s)")
        if st["push_fails"]:
            print(f"failing: {fails_line(st)}")
            print(f"last error: {st.get('last_error', '')}")


# ---- setup: the 2.0 store, the hub question, the shim -----------------------------------------

def shim_path():
    return os.path.join(os.path.expanduser("~"), ".local", "bin", "lore")


def shim_text():
    return f"#!/bin/sh\n{SHIM_MARK}\nexec python3 {shlex.quote(os.path.join(lore.SKILL_DIR, 'scripts', 'lore.py'))} \"$@\"\n"


def ours(path):
    try:
        with open(path) as f:
            return f.read().splitlines()[1:2] == [SHIM_MARK]
    except (OSError, UnicodeDecodeError):
        return False


def setup_plan_lines(args):
    root = lore_store.store_root(args)
    shim = shim_path()
    return [f"  lore 2.0 store {root}{'' if Store2(root).exists() else ' (new)'}",
            f"  lore command   {shim}{'' if os.path.exists(shim) else ' (new)'}"]


def write_shim():
    p = shim_path()
    if (os.path.exists(p) or os.path.islink(p)) and not ours(p):
        print(f"lore command: kept your existing {p} (not written by lore)")
        return
    os.makedirs(os.path.dirname(p), exist_ok=True)
    tmp = p + ".lore-tmp"
    with open(tmp, "w") as f:
        f.write(shim_text())
    os.chmod(tmp, 0o755)
    os.replace(tmp, p)
    print(f"lore command: {p}")
    if os.path.dirname(p) not in os.environ.get("PATH", "").split(os.pathsep):
        print(f"  {os.path.dirname(p)} is not on your PATH; add it to use `lore` directly")


def remove_shim():
    p = shim_path()
    if os.path.exists(p) and ours(p):
        os.unlink(p)
        print(f"lore command removed: {p}")
    elif os.path.exists(p) or os.path.islink(p):
        print(f"lore command: kept {p} (not written by lore)")


def setup_store2(args):
    store = open_store(args)
    if lore_store.init_store(store):
        print(f"lore 2.0 store created: {store.root}")
    url = getattr(args, "hub", None)
    if url is None and not getattr(args, "no_hub", False) and sys.stdin.isatty() and not hub_url(store):
        ans = input("Hub for the lore 2.0 store: paste a private git URL, type 'create' for a new "
                    "private GitHub repository (gh), or press Enter for none: ").strip()
        if ans.lower() == "create":
            try:
                create_hub(store, "lore-memory", False)
            except lore.LoreError as err:
                print(f"hub: {err}; add one later with `lore hub set <url>`")
            ans = ""
        url = ans or None
    if url:
        try:
            set_hub(store, url)
        except lore.LoreError as err:
            print(f"hub: {err}; add one later with `lore hub set <url>`")
    elif not hub_url(store):
        print("hub: none (local git only); add one later with `lore hub set <url>`")
    write_shim()
