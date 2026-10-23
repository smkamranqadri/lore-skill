"""lore 2.0 lint: the code gates that decide whether Canon runs.

Pure code, no model. `lint` reads the store and returns findings, one per problem:
{"gate", "file", "rule_ids", "detail"}, sorted by gate order, file, rule ids. `due` turns the
findings and the last Canon run into a yes or no (contradiction and core-budget skip the wait).
`mark_run` records a Canon run, machine-local, under .git/lore. Only `mark_run` writes.

Every threshold is a constant here and a `key: value` line in .lore/config (see LIMITS); a bad
value falls back to the default. Retired rules (`retired/`), the index and core.md (always
loaded, so held to the budget gate instead) are not topic files.
Standard library only.
"""

import datetime as dt
import itertools
import math
import os
import re
import secrets

import lore
import lore_store

GATES = ("contradiction", "core-budget", "broken-link", "orphan", "duplicate", "oversized", "thin", "stale")
URGENT = ("contradiction", "core-budget")

OVERLAP = 0.8            # duplicate: shared words / all words of the two rules
OVERLAP_MIN_WORDS = 4    # duplicate: both rules have at least this many words (identical text always counts)
MAX_RULES = 25           # oversized: more rules than this ...
MAX_CHARS = 4000         # ... or more characters than this
THIN_RULES = 2           # thin: fewer rules than this ...
THIN_DAYS = 7            # ... and the newest rule is at least this many days old
STALE_DAYS = 60          # stale: unread this many days
INTERVAL_HOURS = 24      # due: at most one Canon run in this many hours (unless urgent)

# config key -> (constant name, parser)
LIMITS = {
    "lint_overlap": ("OVERLAP", float),
    "lint_overlap_min_words": ("OVERLAP_MIN_WORDS", int),
    "lint_max_rules": ("MAX_RULES", int),
    "lint_max_chars": ("MAX_CHARS", int),
    "lint_thin_rules": ("THIN_RULES", int),
    "lint_thin_days": ("THIN_DAYS", int),
    "lint_stale_days": ("STALE_DAYS", int),
    "canon_interval_hours": ("INTERVAL_HOURS", float),
}
DETAIL_MAX = 100
LAST_RUN = "canon-last-run"
RETIRED = "retired/"
READ_COMMIT = r'"m-[0-9a-f]{8}": "[0-9]{4}-'   # git -G takes an extended regex: a `last_read` line, a machine id and a date


class Findings(list):
    """The findings, plus `notes`: one line for each gate that is off and why."""
    notes = ()


def limits(store):
    """The thresholds in force: the constants, overridden by valid .lore/config keys."""
    cfg = store.config()
    out = {name: globals()[name] for name, _ in LIMITS.values()}
    for key, (name, parse) in LIMITS.items():
        if key not in cfg:
            continue
        try:
            value = parse(cfg[key])
        except ValueError:
            continue
        if _usable(name, value):
            out[name] = value
    return out


def _usable(name, value):
    """A threshold must be a positive finite number the arithmetic can hold (an overlap at most 1)."""
    if not math.isfinite(value) or value <= 0:
        return False
    if name == "OVERLAP":
        return value <= 1
    if name == "INTERVAL_HOURS":
        try:
            dt.timedelta(hours=value)
        except OverflowError:
            return False
    return True


def _one(text, n=DETAIL_MAX):
    """Free text as one short line with anything secret-looking removed."""
    line = " ".join(lore.redact(str(text)).split())
    return line if len(line) <= n else line[:n - 3].rstrip() + "..."


def _date(value):
    try:
        return dt.date.fromisoformat(str(value)[:10])
    except ValueError:
        return None


def _today(store, today):
    if today is None:
        return store.day
    return today.date() if isinstance(today, dt.datetime) else today


class _File:
    """One rule file as lint sees it: its rules with their ids, and its sidecar."""

    def __init__(self, store, rel):
        self.rel = rel
        self.text = store.read(rel) or ""
        self.rules = lore_store.parse_rules(self.text)[1]
        self.meta = lore_store.load_meta(store, rel)
        entries = {e.get("text"): (eid, e) for eid, e in (self.meta.get("rules") or {}).items() if isinstance(e, dict)}
        self.ids = [entries[r][0] if r in entries else lore.entry_id(r) for r in self.rules]
        self.entries = [entries[r][1] if r in entries else {} for r in self.rules]

    def links(self):
        links = self.meta.get("links")
        return [x for x in links if isinstance(x, str)] if isinstance(links, list) else []

    def read_when(self):
        rw = self.meta.get("read_when")
        return rw.strip() if isinstance(rw, str) else ""

    def last_reads(self):
        lr = self.meta.get("last_read")
        days = [_date(v) for v in lr.values()] if isinstance(lr, dict) else []
        return [d for d in days if d]

    def has_reads(self):
        reads = self.meta.get("reads")
        counted = isinstance(reads, dict) and any(isinstance(n, int) and n > 0 for n in reads.values())
        return counted or bool(self.last_reads())


def _files(store):
    return [_File(store, rel) for rel in store.rule_files() if not rel.startswith(RETIRED)]


def _finding(gate, file, rule_ids, detail):
    return {"gate": gate, "file": file, "rule_ids": list(rule_ids), "detail": _one(detail)}


def _contradictions(files):
    out = []
    for f in files:
        for eid, e in zip(f.ids, f.entries):
            flags = [x.get("with") for x in (e.get("contradictions") or []) if isinstance(x, dict) and x.get("with")]
            if flags:
                more = f" (+{len(flags) - 1} more)" if len(flags) > 1 else ""
                out.append(_finding("contradiction", f.rel, [eid], f'flagged against "{_one(flags[0], 60)}"{more}'))
    return out


def _core_budget(store, files):
    try:
        content, rep = lore_store.build_index(store)
    except lore_store.IndexBudgetError:
        budget = int(store.config().get("budget", lore.BUDGET_DEFAULT))
        return [_finding("core-budget", "core.md", [], f"the index is over its {budget}-token budget even without core rules")]
    if rep["core_dropped"] <= 0:
        return []
    shown = set(content.splitlines())
    core = next((f for f in files if f.rel == "core.md"), None)
    dropped = [eid for eid, r in zip(core.ids, core.rules) if f"- {r}" not in shown] if core else []
    budget = int(store.config().get("budget", lore.BUDGET_DEFAULT))
    return [_finding("core-budget", "core.md", dropped, f"{rep['core_dropped']} core rule(s) do not fit the {budget}-token index")]


def _broken_links(store, files):
    out, known = [], {f.rel for f in files}
    for f in files:
        for target in sorted(set(f.links())):
            if target in known:
                continue
            try:
                exists = os.path.isfile(store.path(target))
            except lore.LoreError:
                exists = False
            why = "which is not a rule file" if exists else "which does not exist"
            out.append(_finding("broken-link", f.rel, [], f"links to {_one(target, 60)}, {why}"))
    return out


def _orphans(files):
    """Linked from another topic file's sidecar, or described by a read_when. The index lists
    every file whatever its read_when, so it says nothing about either."""
    linked = {t for f in files if f.rel != "core.md" for t in f.links() if t != f.rel}
    return [_finding("orphan", f.rel, [], "no incoming link and no read_when")
            for f in files if f.rel != "core.md" and f.rel not in linked and not f.read_when()]


class _Rule:
    """One rule for the duplicate check: where it is, its id, its normalised text and word set."""

    def __init__(self, file, eid, text):
        self.file, self.id = file, eid
        self.norm = lore.normalise(text)
        self.words = frozenset(self.norm.split())


def _same(a, b, lim):
    """Why two rules count as duplicates, or None. Identical means equal normalised text (word
    order and repeats kept); otherwise the shared fraction of the two word sets, for rules with
    enough words to say anything."""
    if a.norm and a.norm == b.norm:
        return "identical text"
    if min(len(a.words), len(b.words)) >= lim["OVERLAP_MIN_WORDS"]:
        shared = len(a.words & b.words)
        union = len(a.words | b.words)
        if shared / union >= lim["OVERLAP"]:
            return f"{shared / union:.0%} of their words in common"
    return None


def _candidates(rules, lim):
    """The pairs (i < j) that can be duplicates, sorted: every pair with equal normalised text, and
    every pair that shares a word within both rules' prefixes. Rules are ordered by word rarity;
    two sets with overlap ratio T share at least ceil(T * size) words, so their first
    size - ceil(T * size) + 1 words must meet. Exact, not a heuristic: `_same` decides each pair."""
    pairs = set()
    groups = {}
    for i, r in enumerate(rules):
        if r.norm:
            groups.setdefault(r.norm, []).append(i)
    for group in groups.values():
        pairs.update(itertools.combinations(group, 2))
    long = [i for i, r in enumerate(rules) if len(r.words) >= lim["OVERLAP_MIN_WORDS"]]
    freq = {}
    for i in long:
        for w in rules[i].words:
            freq[w] = freq.get(w, 0) + 1
    index = {}
    for j in long:
        words = sorted(rules[j].words, key=lambda w: (freq[w], w))
        keep = len(words) - math.ceil(lim["OVERLAP"] * len(words) - 1e-9) + 1
        meet = {i for w in words[:keep] for i in index.get(w, ())}
        pairs.update((i, j) for i in meet)
        for w in words[:keep]:
            index.setdefault(w, []).append(j)
    return sorted(pairs)


def _duplicates(files, lim):
    rules = [_Rule(f.rel, eid, r) for f in files for eid, r in zip(f.ids, f.rules)]
    out = []
    for i, j in _candidates(rules, lim):
        a, b = rules[i], rules[j]
        same = _same(a, b, lim)
        if same:
            where = a.file if a.file == b.file else f"{a.file} and {b.file}"
            out.append(_finding("duplicate", a.file, [a.id, b.id], f"rules {a.id} and {b.id} in {where}: {same}"))
    return out


def _oversized(files, lim):
    out = []
    for f in files:
        if f.rel == "core.md":
            continue
        why = []
        if len(f.rules) > lim["MAX_RULES"]:
            why.append(f"{len(f.rules)} rules (limit {lim['MAX_RULES']})")
        if len(f.text) > lim["MAX_CHARS"]:
            why.append(f"{len(f.text):,} characters (limit {lim['MAX_CHARS']:,})")
        if why:
            out.append(_finding("oversized", f.rel, [], "; ".join(why)))
    return out


def _thin(files, lim, today, top):
    """Topic files inside a top-level folder; a top-level file of the layout (profile.md) stands alone."""
    out = []
    for f in files:
        if f.rel == "core.md" or f.rel in top or len(f.rules) >= lim["THIN_RULES"]:
            continue
        newest = max((d for d in (_date(e.get("created")) for e in f.entries) if d), default=None)
        if newest and (today - newest).days >= lim["THIN_DAYS"]:
            out.append(_finding("thin", f.rel, f.ids, f"{len(f.rules)} rule(s), the newest {(today - newest).days} days old"))
    return out


def stale_status(files):
    """(on, why): the stale gate runs only when some machine has recorded a read of some file."""
    if any(f.has_reads() for f in files):
        return True, ""
    return False, "stale gate off: no read data has been recorded on any machine"


def tracking_start(store, files):
    """The day reads began to be recorded, which a never-read file cannot be older than. It is the
    day of the first commit that recorded a read in a sidecar, so it stays put however many reads
    follow; a read not committed yet counts too. None when git cannot say (no repository)."""
    try:
        _, out, _ = store.git("log", "--reverse", "--format=%cI", "-G" + READ_COMMIT, "--", ".lore/meta")
    except lore.LoreError:
        return None
    days = [_date(out.split()[0])] if out.split() else []
    days += [d for f in files for d in f.last_reads()]
    return min((d for d in days if d), default=None)


def _stale(store, files, lim, today):
    since, looked = None, False
    out = []
    for f in files:
        if f.rel == "core.md" or not f.rules:
            continue
        last = max(f.last_reads(), default=None)
        if last is None:   # never read: counted from the newest rule, but not from before reads were tracked
            if not looked:
                since, looked = tracking_start(store, files), True
            created = [d for d in (_date(e.get("created")) for e in f.entries) if d]
            last = max(created + ([since] if since else []), default=None)
            what = "never read since tracking began"
        else:
            what = f"last read {last.isoformat()}"
        if last and (today - last).days >= lim["STALE_DAYS"]:
            out.append(_finding("stale", f.rel, [], f"unread for {(today - last).days} days ({what})"))
    return out


def lint(store, today=None):
    """Every finding in the store, sorted. Read-only. `notes` on the result names a gate that is off."""
    today = _today(store, today)
    lim = limits(store)
    files = _files(store)
    found = (_contradictions(files) + _core_budget(store, files) + _broken_links(store, files)
             + _orphans(files) + _duplicates(files, lim) + _oversized(files, lim) + _thin(files, lim, today, set(store.layout())))
    on, why = stale_status(files)
    if on:
        found += _stale(store, files, lim, today)
    found.sort(key=lambda x: (GATES.index(x["gate"]), x["file"] or "", x["rule_ids"]))
    out = Findings(found)
    out.notes = () if on else (why,)
    return out


# ---- when Canon runs --------------------------------------------------------------------------

def _at(now):
    if now is None:
        return dt.datetime.now(dt.timezone.utc)
    if isinstance(now, str):
        return lore_store.instant(now)
    return now if now.tzinfo else now.replace(tzinfo=dt.timezone.utc)


def _lore_dir(store, create=False):
    """A descriptor for .git/lore, opened one step at a time without following a symlink, so a
    planted link at .git or .git/lore cannot send a read or write elsewhere. None when it is not
    there (and not created); lore.LoreError when something other than a directory is in the way."""
    fd = os.open(store.root, os.O_RDONLY | os.O_DIRECTORY)
    try:
        for name in (".git", "lore"):
            flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
            try:
                nxt = os.open(name, flags, dir_fd=fd)
            except FileNotFoundError:
                if not create or name == ".git":
                    return None
                os.mkdir(name, 0o700, dir_fd=fd)
                nxt = os.open(name, flags, dir_fd=fd)
            except OSError:
                raise lore.LoreError(f"refusing to use {name} in {store.root}: it is a symlink or not a directory")
            os.close(fd)
            fd = nxt
        keep, fd = fd, None
        return keep
    finally:
        if fd is not None:
            os.close(fd)


def last_run(store):
    """When Canon last ran on this machine, or None."""
    try:
        d = _lore_dir(store)
    except (lore.LoreError, OSError):
        return None
    if d is None:
        return None
    try:
        fd = os.open(LAST_RUN, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=d)
        with os.fdopen(fd) as f:
            text = f.read(256).strip()
    except OSError:
        return None
    finally:
        os.close(d)
    when = lore_store.instant(text) if text else lore_store.EPOCH
    return None if when == lore_store.EPOCH else when


def due(store, findings, now=None):
    """Whether Canon should run: {"run", "urgent", "gates", "reason"}."""
    now = _at(now)
    fired = {x["gate"] for x in findings}
    gates = [g for g in GATES if g in fired]
    urgent = [g for g in URGENT if g in fired]
    if not gates:
        return {"run": False, "urgent": False, "gates": [], "reason": "no findings"}
    if urgent:
        return {"run": True, "urgent": True, "gates": gates, "reason": f"urgent: {', '.join(urgent)}"}
    wait = dt.timedelta(hours=limits(store)["INTERVAL_HOURS"])
    last = last_run(store)
    if last is not None and last > now:   # a clock set back counts as a run just now; far ahead is garbage
        last = now if last - now <= wait else None
    if last is not None and now - last < wait:
        ago = now - last
        return {"run": False, "urgent": False, "gates": gates,
                "reason": f"findings in {', '.join(gates)}; Canon ran {int(ago.total_seconds() // 60)} min ago, "
                          f"next run in {int((wait - ago).total_seconds() // 60)} min"}
    since = "no Canon run recorded" if last is None else f"last Canon run {last.isoformat()}"
    return {"run": True, "urgent": False, "gates": gates, "reason": f"findings in {', '.join(gates)}; {since}"}


def mark_run(store, now=None):
    """Record that Canon ran at `now`. Machine-local, atomic, mode 0600, and never through a
    symlink: the directory is opened without following links, the temporary file is new with a
    random name, and the rename happens inside that directory."""
    stamp = _at(now).astimezone(dt.timezone.utc).replace(microsecond=0).isoformat() + "\n"
    d = _lore_dir(store, create=True)
    if d is None:
        raise lore.LoreError(f"no .git in {store.root}; not a lore store")
    try:
        for _ in range(5):
            tmp = f"{LAST_RUN}.tmp-{secrets.token_hex(8)}"
            try:
                fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=d)
                break
            except FileExistsError:
                continue
        else:
            raise lore.LoreError("could not create a temporary file for the last Canon run")
        try:
            with os.fdopen(fd, "w") as f:
                f.write(stamp)
            os.replace(tmp, LAST_RUN, src_dir_fd=d, dst_dir_fd=d)
        except BaseException:
            try:
                os.unlink(tmp, dir_fd=d)
            except OSError:
                pass
            raise
    finally:
        os.close(d)
