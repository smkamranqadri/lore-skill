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
import secrets
import shutil
import signal
import subprocess
import sys
import tempfile

import lore
import lore_store
import lore_sync
from lore_store import Store2, GitError

REMOTE = "hub"
FAILS_REPORTED = 3
GH_TIMEOUT = 60
REMEMBER_MAX = 1000
LOREMASTER_MODELS_DEFAULT = "claude,codex"
CANON_MODELS_DEFAULT = "claude,codex"
JSON_ROLES = ("loremaster", "canon")   # roles that answer with the Loremaster's JSON operations
MISE_SKIP = {"exec", "command", "env", "nice", "nohup", "builtin"}   # words that run the next one
CHECK_PROMPT = 'Reply with only this JSON and nothing else: {"ops": [], "answer": "ok"}'
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
    integrate(store, REMOTE, "tidy after merging the hub")
    store.git("push", "-q", REMOTE, f"HEAD:refs/heads/{lore_store.BRANCH}")


def integrate(store, remote, subject):
    """Fetch `remote` and replay the local commits onto its branch with lore's merge policy, then
    tidy and commit what tidying changed (as `subject`). The hub's sync, and Canon's landing from
    its private checkout. Raises LoreError; leaves no rebase behind."""
    lore_store.recover(store)
    store.git("fetch", "-q", remote)
    ref = f"refs/remotes/{remote}/{lore_store.BRANCH}"
    if _has_ref(store, ref):
        rebase(store, ref)
        lore_store.tidy(store)
        lore_store.commit(store, subject)


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
        return NO_HUB
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
        if file_step(store, trigger, force):
            log("store-run: " + push_step(store, force))
        if canon_step(store, trigger, force):
            log("store-run: " + push_step(store, force))


def canon_step(store, trigger, force=False):
    """Session end, after the filing: Canon when lint's gates say it is due (lore_canon.step).
    Returns True when it made a commit. Never raises."""
    try:
        sys.modules.setdefault("lore", lore)
        import lore_canon
        return lore_canon.step(store, trigger, force)
    except Exception as err:   # the step must never break the session-end run
        log(f"store-run: canon FAILED: {type(err).__name__}: {lore.redact(str(err))[:300]} ({trigger})")
        return False


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


# ---- lore remember and the filing step --------------------------------------------------------

def remember_dir(store):
    return store.local("remember")


def private_dir(path):
    """The directory, created or tightened to 0700 whatever the umask."""
    os.makedirs(path, exist_ok=True)
    os.chmod(path, 0o700)
    return path


def write_private(path, text):
    """Write a file atomically, created exclusively as 0600 (the temporary file too)."""
    tmp = os.path.join(os.path.dirname(path), ".in-" + os.path.basename(path))
    with contextlib.suppress(FileNotFoundError):
        os.unlink(tmp)
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.replace(tmp, path)


def cmd_remember(_, args):
    """Queue one item for the Loremaster, on this machine only. No model call, no commit."""
    store = open_store(args)
    store.require()
    text = " ".join((args.text or "").split())
    if not text:
        raise lore.LoreError("usage: lore remember \"<text>\" [--explicit] [--quote Q]")
    if len(text) > REMEMBER_MAX:
        raise lore.LoreError(f"too long ({len(text)} characters, at most {REMEMBER_MAX}); say it shorter")
    if lore.SECRET_RE.search(text) or lore.SECRET_RE.search(args.quote or ""):
        raise lore.LoreError("refused: that looks like a secret; nothing was queued")
    item = {"text": text, "explicit": bool(args.explicit), "quote": " ".join((args.quote or "").split())[:300],
            "session": args.session or os.environ.get("LORE_SESSION", ""),
            "host": args.host or os.environ.get("LORE_HOST", ""), "created": lore_store.now_iso()}
    d = private_dir(remember_dir(store))
    name = f"{dt.datetime.now().strftime('%Y%m%dT%H%M%S%f')}-{secrets.token_hex(3)}.json"
    write_private(os.path.join(d, name), json.dumps(item, sort_keys=True) + "\n")
    print("queued; it is filed at the end of this session")


def queued_items(store):
    """[(path, item)] oldest first, and notes for the log. An unreadable entry is reported and left."""
    out, notes = [], []
    for p in sorted(glob.glob(os.path.join(remember_dir(store), "*.json"))):
        try:
            with open(p) as f:
                it = json.load(f)
            if not isinstance(it, dict) or not isinstance(it.get("text"), str) or not it["text"].strip():
                raise ValueError
        except (ValueError, OSError):
            notes.append(f"filing: left an unreadable queue entry {os.path.basename(p)}")
            continue
        out.append((p, it))
    return out, notes


def first_word(command):
    """(the first shell word with its quotes resolved, the rest of the command untouched), or
    (None, "") for an empty command. Handles '...', "..." and backslash like sh does."""
    i, n, word, started, quote = 0, len(command), [], False, None
    while i < n and command[i].isspace():
        i += 1
    while i < n:
        c = command[i]
        if quote is None and c.isspace():
            break
        started = True
        if quote == "'":
            if c == "'":
                quote = None
            else:
                word.append(c)
        elif c == "\\" and i + 1 < n and (quote is None or command[i + 1] in '"\\$`'):
            i += 1
            word.append(command[i])
        elif quote == '"':
            if c == '"':
                quote = None
            else:
                word.append(c)
        elif c in "'\"":
            quote = c
        else:
            word.append(c)
        i += 1
    if quote:
        raise lore.LoreError("the role command has an unclosed quote")
    return ("".join(word) if started else None), command[i:]


def absolute_command(command):
    """The command with its binary as an absolute path, so a bare PATH under a timer finds it, and
    a mise shim or wrapper replaced by the install it runs (soak 1: the wrapper hangs without a TTY)."""
    word, rest = first_word(command)
    if not word:
        raise lore.LoreError("the role command is empty")
    return shlex.quote(resolve_binary(word)) + rest


def resolve_binary(word):
    """The executable a command's first word runs. Raises LoreError when it is missing, or when it
    is a mise wrapper whose install cannot be found."""
    exe = word if os.path.isabs(word) else shutil.which(word)
    if not exe or not os.access(exe, os.X_OK):
        raise lore.LoreError(f"the role command's binary was not found: {word}")
    wrapped = mise_wrapped(exe)
    if wrapped is None:
        return exe
    real = mise_binary(*wrapped)
    if not real:
        raise lore.LoreError(f"{exe} is a mise wrapper lore cannot resolve (it hangs without a terminal); "
                             f"name the real binary in the role's config line")
    return real


def mise_wrapped(exe):
    """(tool, command) when `exe` runs its tool through mise: a mise shim (a link to the mise
    binary) or a script with a command `mise [flags] x|exec <tool> -- <command>`, read as shell
    words (quotes, an absolute or quoted path to mise, after exec, env or VAR=value). None for
    anything else; a line naming mise that cannot be read gives a tool lore cannot resolve."""
    if os.path.basename(os.path.realpath(exe)) == "mise" and os.path.basename(exe) != "mise":
        return os.path.basename(exe), os.path.basename(exe)
    try:
        with open(exe, "rb") as f:
            head = f.read(65536)
    except OSError:
        return None
    if not head.startswith(b"#!") or b"\0" in head:
        return None
    for line in head.decode("utf-8", errors="replace").splitlines()[1:]:
        if "mise" not in line:
            continue
        try:
            lexer = shlex.shlex(line, posix=True, punctuation_chars=";&|()")
            lexer.whitespace_split = True
            words = list(lexer)
        except ValueError:
            return "", ""
        found = mise_call(words)
        if found is not None:
            return found
    return None


def mise_call(words):
    """(tool, command) of the first simple command in `words` that runs mise x|exec, None when
    none does, ("", "") when one does but names no tool."""
    start = True
    for i, w in enumerate(words):
        if w and set(w) <= set(";&|()"):
            start = True
            continue
        if not start:
            continue
        if w in MISE_SKIP or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", w) or (w.startswith("-") and i and words[i - 1] in MISE_SKIP):
            continue
        start = False
        if os.path.basename(w) != "mise":
            continue
        rest = words[i + 1:]
        while rest and rest[0].startswith("-"):
            rest = rest[1:]
        if not rest or rest[0] not in ("x", "exec"):
            continue
        rest = rest[1:]
        end = next((k for k, x in enumerate(rest) if x and set(x) <= set(";&|()")), len(rest))
        rest = rest[:end]
        if "--" in rest:
            k = rest.index("--")
            tools, command = [x for x in rest[:k] if not x.startswith("-")], rest[k + 1:k + 2]
        else:
            tools, command = [x for x in rest if not x.startswith("-")][:1], []
        if not tools:
            return "", ""
        return tools[0], (command[0] if command else tools[0])
    return None


def resolved_command(command):
    """A 1.x role's command (extract, review, sync) as it runs, through the same resolver as the
    2.0 roles: a mise shim or wrapper is replaced by the install it runs, and one lore cannot
    resolve is refused (LoreError), never run. A command whose first word is already the final
    absolute binary runs unchanged, and a first word that is no executable (a shell builtin) is
    left to sh, as before."""
    word, rest = first_word(command)
    exe = word if word and os.path.isabs(word) else (shutil.which(word) if word else None)
    if not exe:
        return command
    real = resolve_binary(word)
    return command if real == word else shlex.quote(real) + rest


def mise_installs():
    data = os.environ.get("MISE_DATA_DIR") or os.path.join(
        os.environ.get("XDG_DATA_HOME") or os.path.join(os.path.expanduser("~"), ".local", "share"), "mise")
    return os.path.join(data, "installs")


def mise_binary(tool, command):
    """The executable `command` inside mise's install of `tool` (`codex`, `codex@1.2`,
    `npm:@scope/name`), under its `latest` link unless a version is named; None when absent."""
    if not tool:
        return None
    name, version = tool, "latest"
    at = tool.rfind("@")
    if at > 0 and "/" not in tool[at:]:
        name, version = tool[:at], tool[at + 1:] or "latest"
    base = os.path.join(mise_installs(), re.sub(r"[:/@]+", "-", name).strip("-"), version)
    cmd = os.path.basename(command)
    if not cmd or not os.path.isdir(base):
        return None
    tries = [os.path.join(base, cmd), os.path.join(base, "bin", cmd), os.path.join(base, "node_modules", ".bin", cmd)]
    for d, dirs, files in os.walk(base):   # then two levels down, outside node_modules
        depth = 0 if d == base else os.path.relpath(d, base).count(os.sep) + 1
        dirs[:] = sorted(x for x in dirs if x != "node_modules") if depth < 2 else []
        if cmd in files:
            tries.append(os.path.join(d, cmd))
    for t in tries:
        if os.path.isfile(t) and os.access(t, os.X_OK):
            return t
    return None


def model_timeout():
    try:
        return float(os.environ.get("LORE_MODEL_TIMEOUT") or lore_sync.SYNC_TIMEOUT)
    except ValueError:
        return float(lore_sync.SYNC_TIMEOUT)


def role_command(store, role):
    """(name, command) of a role, or (None, None). The LORE_<ROLE>_CMD variable wins, then the
    config line `<role>: <command>`, then each host adapter's `<role>:` line in the order of the
    config `<role>_models` (the 2.0 store's config for loremaster and canon, the 1.x store's for
    the rest). An adapter whose binary is missing, or is a mise wrapper lore cannot resolve, is
    passed over."""
    env = os.environ.get(f"LORE_{role.upper()}_CMD")
    if env:
        return "override", env
    cfg = store.config()
    if cfg.get(role):
        return "config", cfg[role]
    default = {"loremaster": LOREMASTER_MODELS_DEFAULT, "canon": CANON_MODELS_DEFAULT,
               "extract": "codex,claude,cmd,agy", "review": "claude,codex", "sync": "codex"}[role]
    key = {"extract": "extractors", "review": "reviewers", "sync": "sync_models"}.get(role, role + "_models")
    hosts = {h["name"]: h for h in lore.load_hosts()}
    for n in (x.strip() for x in cfg.get(key, default).split(",")):
        h = hosts.get(n)
        if h and h.get(role) and host_binary(h[role]):
            return n, h[role]
    return None, None


def host_binary(command):
    """True when the adapter line's first word is an installed executable lore can run headless."""
    return host_problem(command) is None


def host_problem(command):
    """Why an adapter line cannot run: None when it can, "" when its binary is not installed, or
    the reason it is installed but unusable (a mise wrapper lore cannot resolve)."""
    try:
        word, _ = first_word(command)
        if not word:
            return ""
        exe = word if os.path.isabs(word) else shutil.which(word)
        if not exe or not os.access(exe, os.X_OK):
            return ""
        resolve_binary(word)
    except lore.LoreError as err:
        return str(err)
    return None


def run_command(command, prompt, timeout=None):
    """Run a role command headless with the prompt in $LORE_PROMPT_FILE; return its stdout.
    Raises LoreError on a bad exit or a timeout (the whole process group is killed)."""
    timeout = timeout or model_timeout()
    command = absolute_command(command)
    fd, pf = tempfile.mkstemp(prefix="lore-role-", suffix=".txt")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(prompt)
        env = dict(os.environ, LORE_HARVEST="1", LORE_PROMPT_FILE=pf)
        p = subprocess.Popen(["sh", "-c", command], env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True, start_new_session=True)
        try:
            out, err = p.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            with contextlib.suppress(OSError):
                os.killpg(p.pid, signal.SIGKILL)
            p.communicate()
            raise lore.LoreError(f"the model command timed out after {timeout:g}s")
        if p.returncode:
            raise lore.LoreError(f"the model command exited {p.returncode}: {lore_store.clean_err(err or out)}")
        return out
    finally:
        with contextlib.suppress(OSError):
            os.unlink(pf)


def run_model(store, role="loremaster"):
    """The injected `run_model(prompt) -> str` for a model role (the Loremaster, Canon)."""
    name, command = role_command(store, role)
    if not command:
        raise lore.LoreError(f"no {role} command: no host adapter with a '{role}:' line is installed")
    return lambda prompt: run_command(command, prompt)


def filing_backing_off(st):
    if not st.get("file_fails") or not st.get("file_last_fail"):
        return False
    age = (dt.datetime.now().astimezone() - dt.datetime.fromisoformat(st["file_last_fail"])).total_seconds()
    return age < lore_sync.BACKOFF_MIN * 60


def receipts_dir(store):
    return store.local("remember-receipts")


def norm(text):
    return " ".join(str(text or "").split())


def accounted_items(ops, items):
    """The queued (path, item) pairs the applied ops account for: an add or supersede whose quote is
    that item's quote (or its text). Anything else stays queued, whatever the reply said."""
    quotes = {norm(o.get("quote")) for o in ops if isinstance(o, dict) and o.get("op") in ("add", "supersede")}
    return [(p, it) for p, it in items if norm(it.get("quote")) in quotes or norm(it.get("text")) in quotes]


def dequeue(paths):
    for p in paths:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(p)


def recover_filing(store):
    """Receipts left by a run that stopped between the commit and the dequeue: when the commit
    carrying the receipt's token is in history, the receipt's items were filed, so they leave the
    queue without another model call. A receipt whose commit never happened is dropped."""
    for rp in sorted(glob.glob(os.path.join(receipts_dir(store), "*.json"))):
        try:
            with open(rp) as f:
                rc = json.load(f)
            token, files = rc["token"], rc["files"]
            if not re.fullmatch(r"[0-9a-f]{12}", token) or not isinstance(files, list):
                raise ValueError
        except (ValueError, KeyError, OSError):
            log(f"store-run: filing: left an unreadable receipt {os.path.basename(rp)}")
            continue
        try:
            found = store.git("log", "--fixed-strings", f"--grep=loremaster {token}:", "--format=%H", "-n", "1")[1].strip()
        except GitError as err:
            log(f"store-run: filing: could not read history for receipt {token}: {err}")
            continue
        if found:
            dequeue(os.path.join(remember_dir(store), os.path.basename(x)) for x in files)
            log(f"store-run: filing: recovered receipt {token}; commit {found[:7]} had filed {len(files)} item(s), dequeued")
        else:
            log(f"store-run: filing: dropped receipt {token}; its commit never happened, the items stay queued")
        with contextlib.suppress(FileNotFoundError):
            os.unlink(rp)


def file_step(store, trigger, force=False):
    """Session end, after the reads: file the queued items through the Loremaster. No queue, no
    model call. An item leaves the queue only when the applied batch accounts for it (an add or
    supersede quoting it) and a receipt tied to the commit exists; everything else stays queued,
    with the reason in the log, and backs off like a failed sync. Returns True when it made a
    commit (so the caller pushes). Never raises."""
    try:
        recover_filing(store)
    except Exception as err:
        log(f"store-run: filing: receipt recovery failed: {type(err).__name__}: {lore.redact(str(err))[:200]}")
    items, notes = queued_items(store)
    for n in notes:
        log(f"store-run: {n}")
    if not items:
        log(f"store-run: filing skipped, nothing queued ({trigger})")
        return False
    st = load_state(store)
    if filing_backing_off(st) and not force:
        log(f"store-run: filing waits, {len(items)} item(s) queued; backing off after a failed run "
            f"(under {lore_sync.BACKOFF_MIN} min ago)")
        return False
    token = secrets.token_hex(6)
    receipt = os.path.join(private_dir(receipts_dir(store)), token + ".json")
    box = {}

    def record(reply):   # between the reply and the commit: the receipt that lets a crash recover
        try:
            ops = lore_master.parse_reply(reply)["ops"]
        except lore.LoreError:
            return
        box["ops"] = ops
        box["done"] = accounted_items(ops, items)
        if box["done"]:
            write_private(receipt, json.dumps({"token": token, "files": [os.path.basename(p) for p, _ in box["done"]],
                                               "created": lore_store.now_iso()}) + "\n")
    try:
        sys.modules.setdefault("lore", lore)
        import lore_master
        model = run_model(store)

        def run_and_record(prompt):
            reply = model(prompt)
            record(reply)
            return reply
        res = lore_master.file_items(store, [it for _, it in items], run_and_record, source=f"loremaster {token}")
        rejected = res.get("rejected") or []
        error = "the Loremaster's reply was rejected, nothing written: " + "; ".join(str(m) for m in rejected[:5]) if rejected else None
    except Exception as err:   # the step must never break the session-end run
        res, error = {}, f"{type(err).__name__}: {lore.redact(str(err))}"[:400]
    if error:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(receipt)
        st["file_fails"] = st.get("file_fails", 0) + 1
        st["file_last_fail"] = lore_store.now_iso()
        st["file_last_error"] = error
        save_state(store, st)
        log(f"store-run: filing FAILED, {len(items)} item(s) stay queued; {error}")
        return False
    done = box.get("done", [])
    dequeue(p for p, _ in done)
    with contextlib.suppress(FileNotFoundError):
        os.unlink(receipt)
    if len(done) < len(items):
        st["file_fails"] = st.get("file_fails", 0) + 1
        st["file_last_fail"] = lore_store.now_iso()
        st["file_last_error"] = f"the reply accounted for {len(done)} of {len(items)} item(s)"
        save_state(store, st)
        log(f"store-run: filing INCOMPLETE, {len(items) - len(done)} item(s) stay queued; "
            f"the reply accounted for {len(done)} of {len(items)} ({trigger})")
    else:
        for k in ("file_fails", "file_last_fail", "file_last_error"):
            st.pop(k, None)
        save_state(store, st)
    if done:
        log(f"store-run: filed {len(done)} item(s); commit {res.get('commit') or 'none'}, "
            f"{len(res.get('changed') or [])} file(s), {len(res.get('inbox') or [])} inbox item(s) ({trigger})")
    if res.get("answer"):
        log("store-run: loremaster: " + lore.redact(" ".join(str(res["answer"]).split()))[:300])
    return bool(res.get("commit"))


# ---- lore inbox and lore check ----------------------------------------------------------------

def inbox_summary(it):
    """One redacted line saying what an Inbox item is about."""
    p = it.get("payload") if isinstance(it.get("payload"), dict) else {}
    if it["kind"] == "layout":
        what = "top: " + ", ".join(str(x) for x in (p.get("top") or []))
    elif it["kind"] in ("retire", "hand-edit"):
        what = f"{p.get('file', '')} {p.get('rule_id', '')}: {p.get('text') or p.get('reason') or ''}"
    else:
        what = json.dumps(p, sort_keys=True)
    return lore.redact(" ".join(what.split()))[:160]


NO_HUB = "hub: none (local git only)"


def pushed(line):
    """A push_step line as the UI's `pushed`: True (pushed), None (no hub set), False (a hub is
    set and the push failed or waits on the backoff)."""
    if line == NO_HUB:
        return None
    return line.startswith("hub: pushed")


def inbox_accept(store, item_id):
    """Accept one Inbox item and push: {"kind", "commit": sha or None, "push": line, "pushed": see pushed}.
    `lore inbox accept` and the UI both call this; the caller holds the store lock."""
    sys.modules.setdefault("lore", lore)
    import lore_master
    res = lore_master.inbox_accept(store, item_id)
    line = push_step(store, force=True)
    return {"kind": res["kind"], "commit": res.get("commit"), "push": line, "pushed": pushed(line)}


def inbox_reject(store, item_id):
    """Reject one Inbox item; a reject that made a commit (a hand edit) is pushed: {"commit": sha
    or None, "push": line or None, "pushed": see pushed, None without a commit}. `lore inbox
    reject` and the UI both call this; the caller holds the store lock."""
    sys.modules.setdefault("lore", lore)
    import lore_master
    head = store.git("rev-parse", "HEAD")[1].strip()
    lore_master.inbox_reject(store, item_id)
    if store.git("rev-parse", "HEAD")[1].strip() == head:
        return {"commit": None, "push": None, "pushed": None}
    line = push_step(store, force=True)
    return {"commit": store.git("rev-parse", "--short", "HEAD")[1].strip(), "push": line, "pushed": pushed(line)}


def cmd_inbox(_, args):
    store = open_store(args)
    store.require()
    sys.modules.setdefault("lore", lore)
    import lore_master
    if args.action != "list" and not args.id:
        raise lore.LoreError(f"usage: lore inbox {args.action} <id>")
    with store.locked():   # C's functions all expect the caller to hold the store lock
        if args.action == "list":
            items = lore_master.inbox_list(store)
            if not items:
                print("inbox: empty")
            for it in items:
                print(f"{it['id']}  {it['kind']}  {inbox_summary(it)}")
        elif args.action == "accept":
            res = inbox_accept(store, args.id)
            print(f"accepted {args.id}: " + (f"committed {res['commit']}" if res.get("commit") else "nothing to commit"))
            print(res["push"])
            if "FAILED" in res["push"]:
                raise lore.LoreError("committed locally; the push failed")
        else:
            res = inbox_reject(store, args.id)
            print(f"rejected {args.id}")
            if res["push"] is not None:   # a rejected hand edit is a commit
                print(res["push"])
                if "FAILED" in res["push"]:
                    raise lore.LoreError("committed locally; the push failed")


def cmd_ui(_, args):
    """Serve the UI on 127.0.0.1 in the foreground (lore_ui)."""
    store = open_store(args)
    store.require()
    sys.modules.setdefault("lore", lore)
    import lore_ui
    lore_ui.serve(store.root, args.port, getattr(args, "today", None))


def check_reply(store, role, out):
    """A role's reply to the check prompt read as the real run reads it: parsed, and its ops
    validated against the store (the expected empty ops are valid). Raises LoreError."""
    sys.modules.setdefault("lore", lore)
    import lore_master
    ops = lore_master.parse_reply(out)["ops"]
    if store.exists():
        errs = lore_master.validate(store, ops, allowed=lore_master.CANON_OPS if role == "canon" else lore_master.LOREMASTER_OPS)
        if errs:
            raise lore.LoreError(f"the reply's ops are not valid: {errs[0]}")


def cmd_check(store1, args):
    """Report each role's command; run it headless with a tiny fixed prompt only with --live."""
    store = open_store(args)
    rows = []
    for role in ("loremaster", "canon", "extract", "review", "sync"):
        name, command = role_command(store if role in JSON_ROLES else store1, role)
        if not command:
            why = "no command (no host adapter line, or its CLI is not installed)"
            skipped = [f"{h['name']}: {p}" for h in lore.load_hosts() if h.get(role) for p in [host_problem(h[role])] if p]
            rows.append((role, "unavailable", why + "".join(f"; {x}" for x in skipped), None))
            continue
        try:
            shown = absolute_command(command)
        except lore.LoreError as err:
            rows.append((role, "BROKEN", f"{name}: {err}", None))
            continue
        rows.append((role, "ok", f"{name}: {shown}", command))
    bad = False
    for role, state, detail, command in rows:
        live = ""
        if args.live and state == "ok":
            t0 = dt.datetime.now()
            try:
                out = run_command(command, CHECK_PROMPT if role in JSON_ROLES else "Reply with the single word ok.")
                live = f"  live: ok in {(dt.datetime.now() - t0).total_seconds():.1f}s, replied {len(out.strip())} characters"
                if not out.strip():
                    raise lore.LoreError("empty reply")
                if role in JSON_ROLES:
                    check_reply(store, role, out)
            except lore.LoreError as err:
                state, live, bad = "FAILED", f"  live: {err}", True
        bad = bad or state == "BROKEN"
        print(f"{role}: {state}  {detail}{live}")
    if not args.live:
        print("not run live (add --live to call each model once)")
    if bad:
        raise lore.LoreError("a role command is broken")


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
