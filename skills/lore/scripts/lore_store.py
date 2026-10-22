"""lore 2.0 store: a git repo of plain rule files, with the metadata kept beside them.

    core.md, profile.md, how-i-work/<topic>.md, ...   rule files: an optional `# Title`, then
                                                      `- rule` lines, nothing else
    .lore/layout.json         the top level (files and folders), data, not code
    .lore/meta/<path>.json    one sidecar per rule file: read_when, per rule metadata, reads per
                              machine; never read by agents
    .lore/config              `key: value` lines (budget)
    INDEX.md                  built by code from the three above; not tracked, rebuilt everywhere
    .git/lore/                this machine only: its id, push state, the session queue, proposals

A rule line is matched to its sidecar entry by text. A line without an entry was written by hand:
it is adopted with a new id and flagged `hand_edit` until the owner has seen it (the P2 Inbox).

Every git call is headless (no prompt, no signing, no hooks, a timeout), and every commit is
scanned for secrets first. The merge policy for two machines on one hub lives here too, as git
merge drivers that lore passes on each call: rule files merge by line, sidecars per rule and per
field, layout.json takes the hub's side and keeps the local one as a proposal.
Standard library only.
"""

import datetime as dt
import fcntl
import hashlib
import json
import os
import re
import secrets
import shlex
import signal
import subprocess
import sys
import tempfile
import contextlib

import lore
import lore_sync

STORE2_DEFAULT = os.path.join(os.path.expanduser("~"), ".agents", "lore")
DEFAULT_LAYOUT = {"top": ["profile.md", "how-i-work/", "preferences/", "safety/", "stack/", "gotchas/"]}
TITLES = {"core.md": "Core", "profile.md": "Profile"}
NAME_RE = re.compile(r"^[a-z][a-z0-9-]{0,39}$")
PART_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,79}$")
BRANCH = "main"
IDENTITY = ("lore", "lore@localhost")
GITATTRIBUTES = """# lore's merge policy; lore passes the drivers on every git call it makes
*.md merge=lore-rules
.lore/meta/**/*.json merge=lore-meta
.lore/layout.json merge=lore-layout
"""
GITIGNORE = "# built by lore on every machine, never merged\n/INDEX.md\n"
HEADLESS = ["-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false", "-c", "push.gpgsign=false",
            "-c", "core.hooksPath=", "-c", "core.editor=true", "-c", "core.askPass=",
            "-c", "credential.interactive=false", "-c", "rebase.autoStash=false"]
DATES_KEPT = lore.DATES_KEPT


class GitError(lore.LoreError):
    timed_out = False


class IndexBudgetError(lore.LoreError):
    pass


def store_root(args=None):
    root = getattr(args, "store2", None) or os.environ.get("LORE_STORE2") or STORE2_DEFAULT
    return os.path.abspath(os.path.expanduser(root))


def now_iso():
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()


EPOCH = dt.datetime.min.replace(tzinfo=dt.timezone.utc)


def instant(stamp):
    """A timestamp as an aware UTC datetime, so stamps from machines in different time zones
    compare by the moment they name. A stamp without a zone is taken as UTC; a bad one is oldest."""
    try:
        t = dt.datetime.fromisoformat(stamp)
    except (TypeError, ValueError):
        return EPOCH
    return (t if t.tzinfo else t.replace(tzinfo=dt.timezone.utc)).astimezone(dt.timezone.utc)


# ---- git, headless ----------------------------------------------------------------------------

def git_timeout():
    try:
        return float(os.environ.get("LORE_GIT_TIMEOUT") or lore_sync.SYNC_TIMEOUT)
    except ValueError:
        return float(lore_sync.SYNC_TIMEOUT)


def _drivers():
    me, py = shlex.quote(os.path.abspath(__file__)), shlex.quote(sys.executable)
    out = []
    for kind in ("rules", "meta", "layout"):
        out += ["-c", f"merge.lore-{kind}.name=lore {kind}",
                "-c", f"merge.lore-{kind}.driver={py} {me} merge-driver {kind} %O %A %B %P"]
    return out


def clean_err(text):
    """Git's error output without a credential in a URL or anything secret-looking."""
    text = re.sub(r"://[^/@\s]+@", "://***@", text or "")
    lines = [l.strip() for l in lore.redact(text).splitlines() if l.strip()]
    return lines[-1] if lines else "no output"


def git(root, *args, check=True, timeout=None, stdin=None, raw=False):
    """Run git headless: no terminal prompt, no askpass, ssh in batch mode, no signing, no hooks,
    no editor, no controlling terminal, and a timeout that kills the whole process group.
    `stdin` is fed to git; with `raw` the output is bytes."""
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0", GIT_SSH_COMMAND="ssh -o BatchMode=yes",
               GIT_EDITOR="true", GIT_SEQUENCE_EDITOR="true", GIT_ASKPASS="", SSH_ASKPASS="",
               GCM_INTERACTIVE="never")
    t = timeout or git_timeout()
    p = subprocess.Popen(["git", "-C", root] + HEADLESS + _drivers() + list(args), env=env,
                         stdin=subprocess.DEVNULL if stdin is None else subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=not raw,
                         start_new_session=True)
    try:
        out, err = p.communicate(input=stdin, timeout=t)
    except subprocess.TimeoutExpired:
        with contextlib.suppress(OSError):
            os.killpg(p.pid, signal.SIGKILL)
        p.communicate()
        err = GitError(f"git {args[0]} timed out after {t:g}s (no answer; nothing was prompted)")
        err.timed_out = True
        raise err
    if check and p.returncode:
        msg = err or out
        msg = msg.decode(errors="replace") if isinstance(msg, bytes) else msg
        raise GitError(f"git {args[0]} failed: {clean_err(msg)}")
    return p.returncode, out, err


# ---- the store --------------------------------------------------------------------------------

class Store2:
    def __init__(self, root, day=None):
        self.root = root
        self.day = day or dt.date.today()

    def path(self, rel):
        p = os.path.normpath(os.path.join(self.root, rel))
        if os.path.commonpath([p, self.root]) != self.root:
            raise lore.LoreError(f"refusing a path outside the store: {rel}")
        return p

    def local(self, *parts):
        return os.path.join(self.root, ".git", "lore", *parts)

    def exists(self):
        return os.path.isdir(os.path.join(self.root, ".git")) and os.path.isfile(self.path(".lore/layout.json"))

    def require(self):
        if not self.exists():
            raise lore.LoreError(f"no lore 2.0 store at {self.root}; run `lore store init`")

    def git(self, *args, **kw):
        return git(self.root, *args, **kw)

    def write(self, rel, content):
        target = self.path(rel)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(target), prefix=".tmp-")
        with os.fdopen(fd, "w") as f:
            f.write(content)
        os.replace(tmp, target)

    def read(self, rel):
        try:
            with open(self.path(rel)) as f:
                return f.read()
        except FileNotFoundError:
            return None

    @contextlib.contextmanager
    def locked(self, wait=True):
        """The store's run lock, in .git/lore. With wait False, None is yielded when it is busy."""
        os.makedirs(self.local(), exist_ok=True)
        with open(self.local("run.lock"), "w") as lk:
            try:
                fcntl.flock(lk, fcntl.LOCK_EX | (0 if wait else fcntl.LOCK_NB))
            except OSError:
                yield None
                return
            yield lk

    def machine(self):
        """A stable id for this machine, kept outside git so a clone gets its own."""
        p = self.local("machine")
        try:
            with open(p) as f:
                m = f.read().strip()
            if re.fullmatch(r"m-[0-9a-f]{8}", m):
                return m
        except FileNotFoundError:
            pass
        m = "m-" + secrets.token_hex(4)
        os.makedirs(self.local(), exist_ok=True)
        with open(p, "w") as f:
            f.write(m + "\n")
        return m

    def config(self):
        cfg = {"budget": str(lore.BUDGET_DEFAULT)}
        for line in (self.read(".lore/config") or "").splitlines():
            if ":" in line and not line.lstrip().startswith("#"):
                k, v = line.split(":", 1)
                cfg[k.strip()] = v.strip()
        return cfg

    def layout(self):
        try:
            data = json.loads(self.read(".lore/layout.json") or "")
        except ValueError:
            raise lore.LoreError(".lore/layout.json is not valid JSON")
        top = data.get("top") if isinstance(data, dict) else None
        if not isinstance(top, list) or not top:
            raise lore.LoreError(".lore/layout.json needs a non-empty 'top' list")
        for t in top:
            name = t[:-1] if isinstance(t, str) and t.endswith("/") else (t[:-3] if isinstance(t, str) and t.endswith(".md") else None)
            if not name or not NAME_RE.match(name) or t in ("core.md", "INDEX.md"):
                raise lore.LoreError(f".lore/layout.json: bad top-level entry {t!r}")
        return top

    def rule_files(self):
        """core.md, then every rule file the layout covers, as paths relative to the store."""
        out = ["core.md"] if os.path.isfile(self.path("core.md")) else []
        for t in self.layout():
            if t.endswith(".md"):
                if os.path.isfile(self.path(t)):
                    out.append(t)
                continue
            base = self.path(t[:-1])
            found = []
            for d, dirs, files in os.walk(base):
                dirs[:] = sorted(x for x in dirs if PART_RE.match(x))
                for fn in files:
                    rel = os.path.relpath(os.path.join(d, fn), self.root).replace(os.sep, "/")
                    if fn.endswith(".md") and PART_RE.match(fn):
                        found.append(rel)
            out += sorted(found)
        return out

    def outside_layout(self):
        """Markdown files at the top that the layout does not cover (reported, never indexed)."""
        known = {"core.md", "INDEX.md"} | {t for t in self.layout() if t.endswith(".md")}
        return sorted(fn for fn in os.listdir(self.root) if fn.endswith(".md") and fn not in known)


# ---- rule files and sidecars ------------------------------------------------------------------

def parse_rules(text):
    """(title or None, rule texts, other lines) of a rule file."""
    title, rules, bad = None, [], []
    for n, line in enumerate((text or "").splitlines(), 1):
        if not line.strip():
            continue
        if line.startswith("# ") and title is None and not rules:
            title = line[2:].strip()
        elif line.startswith("- ") and line[2:].strip():
            rules.append(" ".join(line[2:].split()))
        else:
            bad.append((n, line))
    return title, rules, bad


def render_rules(title, rules):
    head = f"# {title}\n\n" if title else ""
    return head + "".join(f"- {r}\n" for r in rules)


def meta_rel(rel):
    return ".lore/meta/" + rel[:-3] + ".json"


def load_meta(store, rel):
    try:
        data = json.loads(store.read(meta_rel(rel)) or "{}")
    except ValueError:
        raise lore.LoreError(f"{meta_rel(rel)} is not valid JSON")
    return data if isinstance(data, dict) else {}


def dump_meta(data):
    return json.dumps(data, indent=1, sort_keys=True, ensure_ascii=False) + "\n"


def save_meta(store, rel, data):
    """Write a sidecar only when it changed. Returns True when it did."""
    new = dump_meta(data)
    if store.read(meta_rel(rel)) == new:
        return False
    store.write(meta_rel(rel), new)
    return True


def new_id(text, taken):
    base = hashlib.sha1(lore.normalise(text).encode()).hexdigest()[:8]
    i, eid = 0, base
    while eid in taken:   # the same words under another id already: a reworded rule came back
        i += 1
        eid = hashlib.sha1(f"{base}:{i}".encode()).hexdigest()[:8]
    return eid


def reconcile(store):
    """Match every rule line to its sidecar entry by text. A line without one is adopted (a hand
    edit, flagged); an entry whose line is gone is dropped; a sidecar whose file is gone too.
    Returns what it found, for status."""
    day = store.day.isoformat()
    rep = {"adopted": [], "dropped": [], "bad": [], "changed": [], "duplicates": []}
    files = store.rule_files()
    for rel in files:
        title, rules, bad = parse_rules(store.read(rel))
        rep["bad"] += [(rel, n) for n, _ in bad]
        meta = load_meta(store, rel)
        entries = meta.setdefault("rules", {})
        by_text = {e.get("text"): eid for eid, e in entries.items() if isinstance(e, dict)}
        keep, seen = {}, set()
        for text in rules:
            if text in seen:   # the same rule twice in one file: one entry, reported
                if (rel, text) not in rep["duplicates"]:
                    rep["duplicates"].append((rel, text))
                continue
            seen.add(text)
            if text in by_text:
                keep[by_text[text]] = entries[by_text[text]]
                continue
            eid = new_id(text, set(entries) | set(keep))
            keep[eid] = {"text": text, "created": day, "explicit": True, "count": 1, "dates": [day],
                         "confidence": lore.NEW_EXPLICIT, "sessions": [], "updated": now_iso(),
                         "hand_edit": day}
            by_text[text] = eid
            rep["adopted"].append((rel, eid, text))
        rep["dropped"] += [(rel, eid) for eid in entries if eid not in keep]
        meta["rules"] = keep
        meta.setdefault("reads", {})
        meta.setdefault("last_read", {})
        if save_meta(store, rel, meta):
            rep["changed"].append(meta_rel(rel))
    wanted = {meta_rel(r) for r in files}
    mdir = store.path(".lore/meta")
    for d, _, names in os.walk(mdir):
        for fn in names:
            rel = os.path.relpath(os.path.join(d, fn), store.root).replace(os.sep, "/")
            if fn.endswith(".json") and rel not in wanted:
                os.unlink(os.path.join(d, fn))
                rep["changed"].append(rel)
    return rep


def hand_edits(store):
    """Rules adopted from a hand edit and not yet seen by the owner: (path, id, text)."""
    out = []
    for rel in store.rule_files():
        for eid, e in sorted(load_meta(store, rel).get("rules", {}).items()):
            if isinstance(e, dict) and e.get("hand_edit"):
                out.append((rel, eid, e.get("text", "")))
    return out


def record_reads(store, counts, machine):
    """Add one session's read counts ({relpath: n}) to the sidecars, under this machine only.
    Paths that are not rule files of this store are ignored. Returns the paths changed."""
    files = set(store.rule_files())
    todo = [(rel, n) for rel, n in sorted(counts.items()) if rel in files and isinstance(n, int) and n > 0]
    metas = {rel: load_meta(store, rel) for rel, _ in todo}   # every sidecar read before any is written
    for rel, n in todo:
        meta = metas[rel]
        meta.setdefault("rules", {})
        reads = meta.setdefault("reads", {})
        reads[machine] = int(reads.get(machine, 0)) + n
        meta.setdefault("last_read", {})[machine] = store.day.isoformat()
    for rel, _ in todo:
        save_meta(store, rel, metas[rel])
    return [rel for rel, _ in todo]


# ---- the index --------------------------------------------------------------------------------

def build_index(store):
    """INDEX.md from the layout, core.md and each sidecar's read_when, under the budget.
    Returns (content, report)."""
    budget = int(store.config().get("budget", lore.BUDGET_DEFAULT))
    limit = budget * 4   # lore.tokens() is chars / 4
    head = ["# lore memory", "<!-- built by lore from core.md and .lore/; edit those, not this -->", ""]
    rep = {"no_read_when": [], "core_dropped": 0, "over_budget": False}
    lines = []
    for rel in store.rule_files():
        if rel == "core.md":
            continue
        rw = load_meta(store, rel).get("read_when")
        if not isinstance(rw, str) or not rw.strip():
            rep["no_read_when"].append(rel)
            rw = "the task touches " + rel[:-3].replace("/", " ").replace("-", " ")
        n = len(parse_rules(store.read(rel))[1])
        lines.append(f"- `{rel}`: read when {' '.join(rw.split())} ({n})")
    tail = ["", f"Read when (files in {store.root}):"] + (lines or ["- (no topic files yet)"])
    render = lambda core: "\n".join(head + ["Core rules:"] + (core or ["- (none yet)"]) + tail) + "\n"
    need = len(render([]))
    if need > limit:   # the read-when lines are not optional: refuse rather than overflow
        raise IndexBudgetError(
            f"the index needs {lore.tokens(render([]))} tokens without any core rule, over the budget of "
            f"{budget}; raise `budget:` in .lore/config or merge topic files")
    core = []
    for r in parse_rules(store.read("core.md"))[1]:
        line = f"- {r}"
        if len(render(core + [line])) > limit:
            rep["core_dropped"] += 1
            continue
        core.append(line)
    rep["over_budget"] = rep["core_dropped"] > 0
    return render(core), rep


def write_index(store):
    content, rep = build_index(store)
    if store.read("INDEX.md") != content:
        store.write("INDEX.md", content)
    rep["tokens"] = lore.tokens(content)
    rep["budget"] = int(store.config().get("budget", lore.BUDGET_DEFAULT))
    return rep


# ---- init and commit --------------------------------------------------------------------------

def init_store(store):
    """Create the store: layout, rule files, sidecars, git with a local identity, first commit.
    Returns False when it already existed."""
    if store.exists():
        return False
    if os.path.isdir(store.root) and os.listdir(store.root):
        raise lore.LoreError(f"{store.root} exists and is not a lore store; move it aside first")
    os.makedirs(store.root, exist_ok=True)
    store.write(".lore/layout.json", json.dumps(DEFAULT_LAYOUT, indent=1) + "\n")
    store.write(".lore/config", f"# lore 2.0 config\nbudget: {lore.BUDGET_DEFAULT}\n")
    store.write(".gitattributes", GITATTRIBUTES)
    store.write(".gitignore", GITIGNORE)
    store.write("core.md", render_rules("Core", []))
    for t in DEFAULT_LAYOUT["top"]:
        if t.endswith("/"):
            store.write(t + ".gitkeep", "")
        else:
            store.write(t, render_rules(TITLES.get(t, t[:-3].capitalize()), []))
    git(store.root, "init", "-q", "-b", BRANCH, "--template=")
    git(store.root, "config", "user.name", IDENTITY[0])
    git(store.root, "config", "user.email", IDENTITY[1])
    store.machine()
    reconcile(store)
    meta = load_meta(store, "profile.md")
    meta.update(read_when="you need to know who the user is", read_when_updated=now_iso())
    save_meta(store, "profile.md", meta)
    write_index(store)
    commit(store, "new lore store")
    return True


def staged(store):
    _, out, _ = store.git("diff", "--cached", "--name-status", "--no-renames", "-z")
    parts = out.split("\0")
    return [(parts[i], parts[i + 1]) for i in range(0, len(parts) - 1, 2)]


def blobs(store, spec_paths):
    """{spec: bytes or None} for blob specs like `:path` or `:2:path`, read with one git call."""
    if not spec_paths:
        return {}
    _, out, _ = store.git("cat-file", "--batch", stdin="".join(p + "\n" for p in spec_paths).encode(), raw=True)
    res, i = {}, 0
    for spec in spec_paths:
        nl = out.index(b"\n", i)
        head = out[i:nl].split()
        if len(head) == 3 and head[1] == b"blob":
            size = int(head[2])
            res[spec] = out[nl + 1:nl + 1 + size]
            i = nl + 1 + size + 1
        else:
            res[spec] = None
            i = nl + 1
    return res


def refused_files(store, changes):
    """Staged files lore will not commit: binary content (the store is text) or a secret-looking
    string anywhere in the staged blob. Returns (path, reason); the content is never kept."""
    paths = [p for st, p in changes if not st.startswith("D")]
    out = []
    for spec, data in blobs(store, [":" + p for p in paths]).items():
        if data is None:
            continue
        if b"\0" in data:
            out.append((spec[1:], "binary content"))
        elif lore.SECRET_RE.search(data.decode("utf-8", errors="replace")):
            out.append((spec[1:], "a secret-looking string"))
    return out


def describe(changes):
    """A commit subject from staged (status, path) pairs: what changed, rule files first."""
    verbs = {"A": "add", "M": "edit", "D": "remove"}
    rules = [f"{verbs.get(s[0], 'edit')} {p}" for s, p in changes if p.endswith(".md")]
    meta = [p[len(".lore/meta/"):] for s, p in changes if p.startswith(".lore/meta/")]
    other = [p for s, p in changes if not p.endswith(".md") and not p.startswith(".lore/meta/")]
    edited = {p for s, p in changes if p.endswith(".md")}
    meta = [m[:-5] + ".md" for m in meta if m[:-5] + ".md" not in edited]
    parts = rules + ([f"metadata of {', '.join(meta)}"] if meta else []) + other
    subject = "; ".join(parts) or "update"
    return subject if len(subject) <= 72 else subject[:69].rsplit(" ", 1)[0] + " ..."


def commit(store, subject=None):
    """Stage everything, refuse a secret, commit one change. Returns (sha, subject) or None.
    `subject` may be a function of the staged (status, path) pairs that returns one or None."""
    recover(store)
    store.git("add", "-A")
    changes = staged(store)
    if not changes:
        return None
    bad = refused_files(store, changes)
    if bad:
        store.git("reset", "-q")
        why = {}
        for path, reason in bad:
            why.setdefault(reason, []).append(path)
        raise lore.LoreError("refused to commit: " + "; ".join(f"{r} in {', '.join(ps)}" for r, ps in why.items())
                             + " (not shown); remove it and commit again")
    if callable(subject):
        subject = subject(changes)
    subject = subject or describe(changes)
    store.git("commit", "-q", "--no-verify", "-m", subject)
    _, sha, _ = store.git("rev-parse", "--short", "HEAD")
    return sha.strip(), subject


def rebase_active(store):
    return any(os.path.exists(os.path.join(store.root, ".git", d)) for d in ("rebase-merge", "rebase-apply"))


RECOVER_TIMEOUT = 60   # an abort is local work; it gets this long even when remote calls get less


def recover(store, killed=False):
    """A rebase left behind by a run that was killed or timed out is aborted, which puts the
    local commits back as they were; the next sync replays them. With `killed`, lore itself just
    killed the git that held the index lock, so that lock is stale and removed first."""
    lock = os.path.join(store.root, ".git", "index.lock")
    if killed and os.path.exists(lock):
        os.unlink(lock)
    if rebase_active(store):
        store.git("rebase", "--abort", check=False, timeout=max(git_timeout(), RECOVER_TIMEOUT))


def tidy(store):
    """Reconcile the sidecars and rebuild the index; the step before every commit. An index over
    the budget is reported, not written, and does not stop the commit."""
    recover(store)
    rep = reconcile(store)
    try:
        rep["index"] = write_index(store)
    except IndexBudgetError as err:
        rep["index"] = {"error": str(err), "no_read_when": [], "core_dropped": 0}
    return rep


# ---- merge drivers (git runs these during lore's rebase; %A is the hub's side) ----------------

def merge_rule_text(o, a, b):
    """Rule files by line: keep each line either side has, unless one side removed it."""
    to, _, _ = parse_rules(o)
    ta, _, _ = parse_rules(a)
    tb, _, _ = parse_rules(b)
    items = lambda t: [" ".join(l.split()) for l in (t or "").splitlines() if l.strip() and not (l.startswith("# ") and l[2:].strip() in (to, ta, tb))]
    io, ia, ib = items(o), items(a), items(b)
    so, sa, sb = set(io), set(ia), set(ib)
    out = []
    for line in ia + ib:
        if line in out or (line in so and not (line in sa and line in sb)):
            continue
        out.append(line)
    if not (a or "").strip() or not (b or "").strip():   # one side deleted the file: the other's title
        title = ta or tb
    else:
        title = tb if ta == to and tb != to else ta
    return (f"# {title}\n\n" if title else "") + "".join(l + "\n" for l in out)


def _pick(o, a, b, key, newer_a):
    """Three-way for one field: a side that left it as it was takes the other's; both changed
    takes the newer side."""
    va, vb, vo = a.get(key), b.get(key), o.get(key)
    if va == vb or vb == vo:
        return va
    if va == vo:
        return vb
    return va if newer_a else vb


def _set(out, key, value):
    if value is None:
        out.pop(key, None)
    else:
        out[key] = value


def _newer_a(a, b, key):
    """True when side a is the newer one by the instant in `key`; equal instants are broken by the
    whole value, so every machine picks the same side."""
    return (instant(a.get(key)), json.dumps(a, sort_keys=True)) >= (instant(b.get(key)), json.dumps(b, sort_keys=True))


def merge_rule(o, a, b):
    newer_a = _newer_a(a, b, "updated")
    out = {}
    for k in sorted(set(o) | set(a) | set(b)):
        _set(out, k, _pick(o, a, b, k, newer_a))
    ca, cb, co = (int(x.get("count", 0) or 0) for x in (a, b, o))
    out["count"] = ca + cb - co if o else max(ca, cb)
    created = [x.get("created") for x in (a, b) if x.get("created")]
    if created:
        out["created"] = min(created)
    out["explicit"] = bool(a.get("explicit") or b.get("explicit"))
    out["dates"] = sorted(set(a.get("dates") or []) | set(b.get("dates") or []))[-DATES_KEPT:]
    out["sessions"] = sorted(set(a.get("sessions") or []) | set(b.get("sessions") or []))[:DATES_KEPT]
    out["updated"] = (a if newer_a else b).get("updated", "")
    return out


def merge_meta(o, a, b):
    """Sidecars per rule and per field. Reads are per machine: a union, the maximum per machine.
    A rule removed on either side stays removed (its line is gone from the rule file too)."""
    out = {}
    newer_a = _newer_a(a, b, "read_when_updated")
    for k in sorted((set(o) | set(a) | set(b)) - {"rules", "reads", "last_read"}):
        _set(out, k, _pick(o, a, b, k, newer_a))
    for k in ("reads", "last_read"):
        m = dict(a.get(k) or {})
        for mach, v in (b.get(k) or {}).items():
            m[mach] = max(m.get(mach, v), v)
        out[k] = m
    ro, ra, rb = (x.get("rules") or {} for x in (o, a, b))
    rules = {}
    for eid in sorted(set(ra) | set(rb)):
        if eid in ro and not (eid in ra and eid in rb):
            continue
        if eid not in ra or eid not in rb:
            rules[eid] = ra.get(eid) or rb.get(eid)
        else:
            rules[eid] = merge_rule(ro.get(eid) or {}, ra[eid], rb[eid])
    out["rules"] = rules
    return out


def merge_kind(path):
    if path == ".lore/layout.json":
        return "layout"
    if path.startswith(".lore/meta/") and path.endswith(".json"):
        return "meta"
    return "rules" if path.endswith(".md") else None


def save_proposal(root, layout):
    d = os.path.join(root, ".git", "lore", "proposals")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "layout-" + dt.datetime.now().strftime("%Y%m%dT%H%M%S%f") + ".json"), "w") as f:
        f.write(layout)


def resolve_conflicts(store):
    """Settle the conflicts a rebase stopped on with the same policy as the drivers, including the
    ones git never hands a driver: a file changed on one side and deleted on the other. A missing
    side is an empty file, so lines it removed stay removed and lines the other side added stay.
    Stage 2 is the hub's side during lore's rebase. Returns False when nothing was unmerged."""
    _, out, _ = store.git("ls-files", "-u", "-z")
    stages = {}
    for rec in filter(None, out.split("\0")):
        info, path = rec.split("\t", 1)
        stages.setdefault(path, {})[int(info.split()[2])] = True
    if not stages:
        return False
    data = blobs(store, [f":{n}:{p}" for p, st in stages.items() for n in st])
    for path, st in sorted(stages.items()):
        o, a, b = (data.get(f":{n}:{path}") if n in st else None for n in (1, 2, 3))
        kind = merge_kind(path)
        if kind is None or any(x is not None and b"\0" in x for x in (o, a, b)):
            raise GitError(f"a conflict lore cannot settle in {path}")
        to, ta, tb = (x.decode("utf-8", errors="replace") if x is not None else "" for x in (o, a, b))
        if kind == "rules":
            result = merge_rule_text(to, ta, tb)
            _, rules, other = parse_rules(result)
            gone = not rules and not other and (a is None or b is None)
        elif kind == "meta":
            try:
                result = dump_meta(merge_meta(*(json.loads(t) if t.strip() else {} for t in (to, ta, tb))))
            except ValueError:
                raise GitError(f"a conflict lore cannot settle in {path} (not valid JSON)")
            gone = False
        else:
            result = ta if a is not None else tb
            if a is not None and b is not None and ta != tb:
                save_proposal(store.root, tb)
            gone = False
        if gone:
            if os.path.exists(store.path(path)):
                os.unlink(store.path(path))
            store.git("rm", "-q", "--cached", "--ignore-unmatch", "--", path)
        else:
            store.write(path, result)
            store.git("add", "--", path)
    return True


def merge_driver(kind, o, a, b, path):
    def rd(p):
        try:
            with open(p) as f:
                return f.read()
        except OSError:
            return ""
    to, ta, tb = rd(o), rd(a), rd(b)
    if kind == "rules":
        result = merge_rule_text(to, ta, tb)
    elif kind == "meta":
        try:
            jo, ja, jb = (json.loads(t) if t.strip() else {} for t in (to, ta, tb))
        except ValueError:
            return 1
        result = dump_meta(merge_meta(jo, ja, jb))
    elif kind == "layout":
        result = ta
        if ta != tb:   # the hub's layout wins; the local one waits as a proposal for the owner
            save_proposal(os.getcwd(), tb)
    else:
        return 1
    with open(a, "w") as f:
        f.write(result)
    return 0


if __name__ == "__main__":
    if len(sys.argv) == 7 and sys.argv[1] == "merge-driver":
        sys.exit(merge_driver(*sys.argv[2:]))
    print("usage: lore_store.py merge-driver rules|meta|layout %O %A %B %P", file=sys.stderr)
    sys.exit(2)
