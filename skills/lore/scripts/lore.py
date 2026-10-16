#!/usr/bin/env python3
"""The lore memory store: entries, candidates, promotion, decay and the start-up index.

One Markdown file per category under the store (default ~/.agents/memory), one entry per line:

    - Run the real command before claiming done. Confidence: 0.85 <!-- id=1a2b3c4d first=... -->

The part before the comment is valid Command Code taste syntax; the comment carries what lore
needs (first and last seen dates, distinct days, count, flags, a short source quote). New
learnings land in candidates.md and move to their category once seen on two different days, or
at once when stated explicitly. INDEX.md is regenerated from the categories after every change
and is the only file a host loads at start. Standard library only.
"""

import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
import shutil
import json
import math
import os
import re
import sys
import tempfile

STORE_DEFAULT = os.path.join(os.path.expanduser("~"), ".agents", "memory")
RESERVED = {"index", "candidates", "blocklist", "config", "profile"}
CATEGORY_RE = re.compile(r"^[a-z][a-z0-9-]{0,39}$")
ENTRY_RE = re.compile(r"^- (?P<text>.+?) Confidence: (?P<conf>[0-9]*\.?[0-9]+)(?: <!-- (?P<meta>.*) -->)?\s*$")
META_RE = re.compile(r'(\w+)=("(?:[^"]*)"|\S+)')

NEW_CANDIDATE = 0.30
NEW_EXPLICIT = 0.60
REPEAT_STEP = 0.15
CONF_CAP = 0.95
PROMOTED_FLOOR = 0.60
INLINE_FLOOR = 0.80
REMOVE_BELOW = 0.40
CONTRADICT_STEP = 0.30
DECAY_STEP = 0.05
DECAY_DAYS = 30
CANDIDATE_TTL_DAYS = 28
CATEGORY_CAP = 25
NEW_WINDOW_DAYS = 7
BUDGET_DEFAULT = 1500
SRC_MAX = 120
TOMBSTONE_DAYS = 90
DATES_KEPT = 8
SKILL_DIR = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))


class LoreError(Exception):
    pass


def tokens(text):
    """Rough token estimate: four characters per token."""
    return math.ceil(len(text) / 4)


def normalise(text):
    t = re.sub(r"[^a-z0-9 ]+", " ", text.lower())
    return " ".join(t.split())


def entry_id(text):
    return hashlib.sha1(normalise(text).encode()).hexdigest()[:8]


def tidy_text(text):
    t = " ".join(text.split())
    if not t:
        raise LoreError("empty rule text")
    if "<!--" in t or "-->" in t or "Confidence:" in t:
        raise LoreError("rule text may not contain '<!--', '-->' or 'Confidence:'")
    if t[-1] not in ".!?":
        t += "."
    return t


def parse_date(s):
    try:
        return dt.date.fromisoformat(s)
    except ValueError:
        raise LoreError(f"not a date (YYYY-MM-DD): {s}")


class Entry:
    def __init__(self, text, conf, **meta):
        self.text = text
        self.conf = conf
        self.id = meta.get("id") or entry_id(text)
        self.first = meta.get("first", "")
        self.last = meta.get("last", "")
        self.days = int(meta.get("days", 1))
        self.n = int(meta.get("n", 1))
        self.decayed = meta.get("decayed", "")
        self.promoted = meta.get("promoted", "")
        cat = meta.get("cat", "")
        self.cat = cat if CATEGORY_RE.match(cat) and cat not in RESERVED else ""   # metadata may come from another machine
        self.src = meta.get("src", "")
        self.flags = set(f for f in meta.get("flags", "").split(",") if f)
        # The most recent distinct days it was seen, so two machines merging know whether their
        # sightings were on the same day or on different ones.
        self.dates = set(d for d in meta.get("dates", "").split(",") if d) or ({self.last} if self.last else set())
        # Short hashes of the sessions it was seen in: a day counts only from a session not seen
        # before, so one session running past midnight is not two sightings.
        self.sess = set(x for x in meta.get("sess", "").split(",") if re.fullmatch(r"[0-9a-f]{8}", x))

    @classmethod
    def parse(cls, line):
        m = ENTRY_RE.match(line)
        if not m:
            return None
        meta = {}
        for k, v in META_RE.findall(m.group("meta") or ""):
            meta[k] = v[1:-1] if v.startswith('"') else v
        return cls(m.group("text"), float(m.group("conf")), **meta)

    def render(self, with_cat=False):
        parts = [f"id={self.id}", f"first={self.first}", f"last={self.last}",
                 f"days={self.days}", f"n={self.n}"]
        if self.dates:
            parts.append("dates=" + ",".join(sorted(self.dates)[-DATES_KEPT:]))
        if self.sess:
            parts.append("sess=" + ",".join(sorted(self.sess)[:DATES_KEPT]))
        if self.decayed:
            parts.append(f"decayed={self.decayed}")
        if self.promoted:
            parts.append(f"promoted={self.promoted}")
        if with_cat:
            parts.append(f"cat={self.cat}")
        if self.flags:
            parts.append("flags=" + ",".join(sorted(self.flags)))
        if self.src:
            parts.append(f'src="{self.src}"')
        return f"- {self.text} Confidence: {self.conf:.2f} <!-- {' '.join(parts)} -->"


class Store:
    def __init__(self, root, day=None):
        self.root = root
        self.day = day or dt.date.today()

    def path(self, name):
        p = os.path.normpath(os.path.join(self.root, name))
        if os.path.commonpath([p, os.path.normpath(self.root)]) != os.path.normpath(self.root):
            raise LoreError(f"refusing a path outside the store: {name}")
        return p

    # ---- files ---------------------------------------------------------------------------
    def write_atomic(self, name, content):
        target = self.path(name)
        fd, tmp = tempfile.mkstemp(dir=self.root, prefix=".tmp-")
        with os.fdopen(fd, "w") as f:
            f.write(content)
        os.replace(tmp, target)

    @contextlib.contextmanager
    def locked(self):
        """Exclusive access. Every id that disappears while the lock is held gets a tombstone, so
        a sync with another machine removes it there too instead of bringing it back."""
        os.makedirs(self.root, exist_ok=True)
        with open(self.path(".lock"), "w") as lk:
            fcntl.flock(lk, fcntl.LOCK_EX)
            before = self.all_ids()
            yield
            after = self.all_ids()
            tombs = self.tombstones()
            # A removal already covered by a tombstone (one received in a merge) keeps that
            # tombstone's date; re-dating it to today would defeat a later sighting elsewhere.
            gone = [i for i in sorted(set(before) - set(after)) if not (i in tombs and tombs[i] >= before[i])]
            if gone:
                with open(self.path("tombstones"), "a") as f:
                    for eid in gone:
                        f.write(f"{eid}\t{self.day.isoformat()}\n")

    def all_ids(self):
        """id -> last-seen date, for every entry in the store."""
        ids = {e.id: e.last for e in self.read_candidates()}
        for cat in self.categories():
            ids.update({e.id: e.last for e in self.read_category(cat)[2]})
        return ids

    def tombstones(self):
        """id -> the latest date it was removed."""
        out = {}
        try:
            with open(self.path("tombstones")) as f:
                for line in f:
                    parts = line.strip().split("\t")
                    if len(parts) == 2 and re.fullmatch(r"[0-9a-f]{8}", parts[0]):
                        out[parts[0]] = max(out.get(parts[0], ""), parts[1])
        except FileNotFoundError:
            pass
        return out

    def config(self):
        cfg = {"budget": str(BUDGET_DEFAULT)}
        try:
            with open(self.path("config")) as f:
                for line in f:
                    if ":" in line and not line.lstrip().startswith("#"):
                        k, v = line.split(":", 1)
                        cfg[k.strip()] = v.strip()
        except FileNotFoundError:
            pass
        return cfg

    def categories(self):
        names = []
        if os.path.isdir(self.root):
            for fn in sorted(os.listdir(self.root)):
                stem, ext = os.path.splitext(fn)
                if ext == ".md" and stem not in RESERVED and stem != "INDEX" and CATEGORY_RE.match(stem):
                    names.append(stem)
        return names

    def read_category(self, cat):
        """Return (title, read_when, entries) for a category file; a missing file is empty."""
        title, read_when, entries = cat.replace("-", " ").capitalize(), f"the task touches {cat}", []
        try:
            with open(self.path(f"{cat}.md")) as f:
                for line in f:
                    line = line.rstrip("\n")
                    if line.startswith("# "):
                        title = line[2:].strip()
                    elif line.startswith("<!-- read-when:"):
                        read_when = line[len("<!-- read-when:"):].rstrip("->").strip()
                    else:
                        e = Entry.parse(line)
                        if e:
                            e.cat = cat
                            entries.append(e)
        except FileNotFoundError:
            pass
        return title, read_when, entries

    def write_category(self, cat, title, read_when, entries):
        if not CATEGORY_RE.match(cat) or cat in RESERVED:
            raise LoreError(f"bad category name: {cat!r}")
        entries = sorted(entries, key=lambda e: (-e.conf, e.text))
        body = [f"# {title}", f"<!-- read-when: {read_when} -->", ""]
        body += [e.render() for e in entries]
        self.write_atomic(f"{cat}.md", "\n".join(body) + "\n")

    def read_candidates(self):
        out = []
        try:
            with open(self.path("candidates.md")) as f:
                for line in f:
                    e = Entry.parse(line.rstrip("\n"))
                    if e:
                        e.cat = e.cat or "workflow"
                        out.append(e)
        except FileNotFoundError:
            pass
        return out

    def write_candidates(self, entries):
        head = ["# Candidates", "<!-- inbox written by lore; never loaded at start -->", ""]
        lines = [e.render(with_cat=True) for e in sorted(entries, key=lambda e: (e.cat, -e.conf, e.text))]
        self.write_atomic("candidates.md", "\n".join(head + lines) + "\n")

    def blocklist(self):
        ids = set()
        try:
            with open(self.path("blocklist")) as f:
                for line in f:
                    if line.strip():
                        ids.add(line.split("\t", 1)[0].strip())
        except FileNotFoundError:
            pass
        return ids

    def all_confirmed(self):
        found = {}
        for cat in self.categories():
            for e in self.read_category(cat)[2]:
                found[e.id] = e
        return found


# ---- operations ------------------------------------------------------------------------------

def cmd_init(store, args):
    os.makedirs(store.root, exist_ok=True)
    made = []
    if not os.path.exists(store.path("config")):
        store.write_atomic("config", f"# lore config\nbudget: {BUDGET_DEFAULT}\n")
        made.append("config")
    if not os.path.exists(store.path("candidates.md")):
        store.write_candidates([])
        made.append("candidates.md")
    if not os.path.exists(store.path("profile.md")):
        store.write_atomic("profile.md", "# Profile\n<!-- hand-edited; lore never writes here -->\n")
        made.append("profile.md")
    regenerate_index(store, today(args))
    print("Created " + ", ".join(made) if made else "Store already initialised")


def today(args):
    return parse_date(args.today) if getattr(args, "today", None) else dt.date.today()


def session_key(session):
    return hashlib.sha1(session.encode()).hexdigest()[:8] if session else None


def seen(entry, day, session=None):
    """Count a sighting. A new day counts only from a session that has not seen it before."""
    entry.n += 1
    d = day.isoformat()
    key = session_key(session)
    if d not in entry.dates and (key is None or key not in entry.sess):
        entry.days += 1
        entry.dates.add(d)
        entry.conf = min(CONF_CAP, entry.conf + REPEAT_STEP)
    if key:
        entry.sess.add(key)
    entry.last = max(entry.last, d)


SECRET_RE = re.compile(
    r"(?i)(-----BEGIN [A-Z ]*PRIVATE KEY-----|\b(sk|rk|pk)-[A-Za-z0-9_-]{16,}|\bgh[pousr]_[A-Za-z0-9]{20,}"
    r"|\bxox[abposr]-[A-Za-z0-9-]{10,}|\bAKIA[0-9A-Z]{16}\b|\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\."
    r"|\b(password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|auth)\s*[:=]\s*\S{6,}"
    r"|\b(?=[A-Za-z0-9_-]*\d)(?=[A-Za-z0-9_-]*[A-Za-z])[A-Za-z0-9_-]{40,}\b)")


def redact(text):
    """Secret-looking strings replaced, before any text reaches a model or the store."""
    return SECRET_RE.sub("[REDACTED]", text)


def finish(store, day):
    """After a manual change: promote, regenerate the index and refresh every host's copy."""
    maintain(store, day)
    regenerate_index(store, day)


def cmd_add(store, args):
    day = today(args)
    with store.locked():
        print(add_learning(store, args.cat, args.text, args.src, args.explicit, args.contradicts, day))
        finish(store, day)
    deliver_quietly(store)


def add_learning(store, cat, text, src="", explicit=False, contradicts=None, day=None, session=None):
    """Record one learning; the caller holds the store lock. Returns a one-line status."""
    day = day or dt.date.today()
    if not CATEGORY_RE.match(cat) or cat in RESERVED:
        raise LoreError(f"bad category name: {cat}")
    if SECRET_RE.search(text):
        raise LoreError("the rule looks like it holds a secret; not stored")
    text = tidy_text(text)
    eid = entry_id(text)
    if eid in store.blocklist():
        return f"blocked {eid}"
    if contradicts:
        contradict(store, contradicts, day)
    confirmed = store.all_confirmed()
    if eid in confirmed:
        e = confirmed[eid]
        title, rw, entries = store.read_category(e.cat)
        for x in entries:
            if x.id == eid:
                seen(x, day, session)
        store.write_category(e.cat, title, rw, entries)
        regenerate_index(store, day)
        return f"bumped {eid} {e.cat}"
    cands = store.read_candidates()
    for c in cands:
        if c.id == eid:
            seen(c, day, session)
            if explicit:
                c.flags.add("explicit")
                c.conf = max(c.conf, NEW_EXPLICIT)
            store.write_candidates(cands)
            return f"bumped {eid} candidate"
    src = " ".join(redact(src or "").replace('"', "'").split())[:SRC_MAX]
    e = Entry(text, NEW_EXPLICIT if explicit else NEW_CANDIDATE, id=eid,
              first=day.isoformat(), last=day.isoformat(), days=1, n=1, cat=cat, src=src,
              flags="explicit" if explicit else "")
    if session_key(session):
        e.sess.add(session_key(session))
    cands.append(e)
    store.write_candidates(cands)
    return f"added {eid} candidate"


def contradict(store, target, day):
    """Lower a confirmed entry or candidate that a new learning contradicts."""
    hit = False
    for cat in store.categories():
        title, rw, entries = store.read_category(cat)
        keep = []
        for e in entries:
            if e.id == target:
                hit = True
                if "pin" not in e.flags:
                    e.conf = round(e.conf - CONTRADICT_STEP, 2)
                    e.decayed = day.isoformat()   # when confidence was last adjusted, for sync
                if e.conf < REMOVE_BELOW and "pin" not in e.flags:
                    continue
            keep.append(e)
        if hit:
            store.write_category(cat, title, rw, keep)
            return
    cands = store.read_candidates()
    left = []
    for c in cands:
        if c.id == target:
            hit = True
            continue
        left.append(c)
    if not hit:
        raise LoreError(f"no entry with id {target}")
    store.write_candidates(left)


def cmd_drop(store, args):
    key = args.target
    with store.locked():
        target_id = key if re.fullmatch(r"[0-9a-f]{8}", key) else entry_id(tidy_text(key))
        text = None
        for cat in store.categories():
            title, rw, entries = store.read_category(cat)
            if any(e.id == target_id for e in entries):
                text = next(e.text for e in entries if e.id == target_id)
                store.write_category(cat, title, rw, [e for e in entries if e.id != target_id])
        cands = store.read_candidates()
        if any(c.id == target_id for c in cands):
            text = text or next(c.text for c in cands if c.id == target_id)
            store.write_candidates([c for c in cands if c.id != target_id])
        if text is None:
            raise LoreError(f"no entry matches {key}")
        if target_id not in store.blocklist():
            with open(store.path("blocklist"), "a") as f:
                f.write(f"{target_id}\t{text}\n")
        regenerate_index(store, today(args))
        print(f"dropped {target_id} and blocklisted it")
    deliver_quietly(store)


def cmd_maintain(store, args):
    day = today(args)
    with store.locked():
        report = maintain(store, day)
        regenerate_index(store, day)
    print(" ".join(f"{k}={v}" for k, v in report.items()))


def maintain(store, day):
    report = {"promoted": 0, "expired": 0, "decayed": 0, "removed": 0, "capped": 0}
    blocked = store.blocklist()
    cands = store.read_candidates()
    confirmed = store.all_confirmed()
    staying = []
    promote_by_cat = {}
    for c in cands:
        if c.id in blocked:
            continue
        if c.days >= 2 or "explicit" in c.flags:
            if c.id not in confirmed:
                c.conf = max(c.conf, PROMOTED_FLOOR)
                c.promoted = day.isoformat()
                c.decayed = day.isoformat()
                promote_by_cat.setdefault(c.cat, []).append(c)
                report["promoted"] += 1
            continue
        if (day - parse_date(c.last)).days > CANDIDATE_TTL_DAYS:
            report["expired"] += 1
            continue
        staying.append(c)
    # Categories are written first and candidates last: a crash in between leaves a promoted
    # rule in both places (merged at the next run), never in neither.
    cats = set(store.categories()) | set(promote_by_cat)
    for cat in sorted(cats):
        title, rw, entries = store.read_category(cat)
        entries += promote_by_cat.get(cat, [])
        kept = []
        for e in entries:
            if e.id in blocked:
                continue
            if "pin" not in e.flags:
                since = max(parse_date(e.last), parse_date(e.decayed or e.last))
                steps = (day - since).days // DECAY_DAYS
                if steps > 0 and (day - parse_date(e.last)).days >= DECAY_DAYS:
                    e.conf = round(e.conf - DECAY_STEP * steps, 2)
                    e.decayed = (since + dt.timedelta(days=steps * DECAY_DAYS)).isoformat()
                    report["decayed"] += 1
                if e.conf < REMOVE_BELOW:
                    report["removed"] += 1
                    continue
            kept.append(e)
        pinned = [e for e in kept if "pin" in e.flags]
        rest = sorted((e for e in kept if "pin" not in e.flags), key=lambda e: (-e.conf, e.text))
        room = max(0, CATEGORY_CAP - len(pinned))
        report["capped"] += max(0, len(rest) - room)
        store.write_category(cat, title, rw, pinned + rest[:room])
    store.write_candidates(staying)
    tombs = store.tombstones()
    keep = {i: d for i, d in tombs.items() if (day - parse_date(d)).days <= TOMBSTONE_DAYS}
    if len(keep) != len(tombs) or os.path.exists(store.path("tombstones")):
        store.write_atomic("tombstones", "".join(f"{i}\t{d}\n" for i, d in sorted(keep.items())))
    return report


def regenerate_index(store, day):
    budget = int(store.config().get("budget", BUDGET_DEFAULT))
    cats = store.categories()
    head = ["# Agent memory (lore)",
            "<!-- generated by lore from the category files; edit those, not this -->",
            ""]
    sys.modules.setdefault("lore", sys.modules[__name__])
    import lore_sync
    if lore_sync.sync_wanted(store, day):   # false when no hub is configured
        head += [f"Memory sync is due: before other work, follow `{SKILL_DIR}/commands/sync.md`.", ""]
    read_when, inline_pool, new = [], [], []
    for cat in cats:
        title, rw, entries = store.read_category(cat)
        read_when.append(f"- `{cat}.md`: read when {rw} ({len(entries)})")
        for e in entries:
            if "pin" in e.flags or e.conf >= INLINE_FLOOR:
                inline_pool.append(e)
            if e.promoted and (day - parse_date(e.promoted)).days <= NEW_WINDOW_DAYS:
                new.append(e)
    tail = ["", f"Read when (files in {store.root}):"] + read_when
    if os.path.exists(store.path("profile.md")):
        tail.append("- `profile.md`: who the user is; read when it matters")
    limit = budget * 4   # tokens() is chars / 4, so the budget is a character count
    used = len("\n".join(head + ["Rules:"] + tail)) + 1   # +1: the closing newline
    if used > limit:
        raise LoreError(f"index skeleton alone exceeds the budget of {budget} tokens")
    inline_pool.sort(key=lambda e: ("pin" not in e.flags, -e.conf, e.text))
    rules, new_lines = [], []
    for e in inline_pool:
        line = f"- {e.text}"
        if used + len(line) + 1 > limit:
            if "pin" in e.flags:
                raise LoreError(f"pinned rules exceed the budget of {budget} tokens")
            continue
        rules.append(line)
        used += len(line) + 1
    if new:
        for line in ["", "New (say \"drop that\" to remove one):"] + [f"- {e.text} [{e.id}]" for e in new]:
            if used + len(line) + 1 > limit:
                break
            new_lines.append(line)
            used += len(line) + 1
        if len(new_lines) <= 2:   # a heading with no entry under it says nothing
            new_lines = []
    content = "\n".join(head + ["Rules:"] + rules + new_lines + tail) + "\n"
    store.write_atomic("INDEX.md", content)
    return content


def cmd_index(store, args):
    with store.locked():
        content = regenerate_index(store, today(args))
    budget = int(store.config().get("budget", BUDGET_DEFAULT))
    print(f"INDEX.md {tokens(content)} tokens (budget {budget})")


def cmd_pin(store, args):
    with store.locked():
        for cat in store.categories():
            title, rw, entries = store.read_category(cat)
            for e in entries:
                if e.id == args.id:
                    (e.flags.add if not args.unpin else e.flags.discard)("pin")
                    store.write_category(cat, title, rw, entries)
                    regenerate_index(store, today(args))
                    print(f"{'unpinned' if args.unpin else 'pinned'} {e.id}")
                    return
    raise LoreError(f"no confirmed entry with id {args.id}")


def cmd_list(store, args):
    rows = store.read_candidates() if args.candidates else list(store.all_confirmed().values())
    for e in sorted(rows, key=lambda e: (e.cat, -e.conf, e.text)):
        if args.cat and e.cat != args.cat:
            continue
        print(f"{e.id}\t{e.cat}\t{e.conf:.2f}\t{e.days}\t{e.text}")


def cmd_describe(store, args):
    """Set a category's title and its read-when line, which the index shows to every agent."""
    if not CATEGORY_RE.match(args.cat) or args.cat in RESERVED:
        raise LoreError(f"bad category name: {args.cat}")
    for v in (args.title, args.read_when):
        if v is not None and ("-->" in v or "\n" in v or not v.strip()):
            raise LoreError("title and read-when are one line, without '-->'")
    with store.locked():
        if not os.path.exists(store.path(f"{args.cat}.md")):
            raise LoreError(f"no category {args.cat}")
        title, rw, entries = store.read_category(args.cat)
        store.write_category(args.cat, (args.title or title).strip(), (args.read_when or rw).strip(), entries)
        regenerate_index(store, today(args))
    print(f"described {args.cat}")


# ---- bulk import (the one-time seed) ---------------------------------------------------------

def cmd_import(store, args):
    """Import a JSON array of established rules (the seed). Each item: rule, category,
    confidence, and optionally explicit, pin, src, days. Rules at 0.60 or above go straight into
    their category; lower ones become candidates. Imported rules are not listed as New."""
    try:
        with open(os.path.expanduser(args.file)) as f:
            items = json.load(f)
    except (OSError, ValueError) as err:
        raise LoreError(f"cannot read {args.file}: {err}")
    if not isinstance(items, list):
        raise LoreError("the import file must hold a JSON array")
    day = today(args).isoformat()
    report = {"confirmed": 0, "candidates": 0, "merged": 0, "blocked": 0, "skipped": 0}
    reasons = []
    with store.locked():
        blocked = store.blocklist()
        cats = {c: list(store.read_category(c)) for c in store.categories()}
        cands = store.read_candidates()
        where = {e.id: e for c in cats.values() for e in c[2]}
        confirmed_ids = set(where)
        where.update({e.id: e for e in cands})
        for n, it in enumerate(items, 1):
            try:
                if not isinstance(it, dict):
                    raise LoreError("not an object")
                cat = str(it.get("category", "")).strip()
                if not CATEGORY_RE.match(cat) or cat in RESERVED:
                    raise LoreError(f"bad category {cat!r}")
                text = tidy_text(str(it.get("rule", "")))
                conf = float(it.get("confidence"))
                if not 0 < conf <= 1:
                    raise LoreError(f"confidence {conf} out of range")
            except (LoreError, TypeError, ValueError) as err:
                report["skipped"] += 1
                reasons.append(f"item {n}: {err}")
                continue
            conf = min(CONF_CAP, max(NEW_CANDIDATE, conf))
            eid = entry_id(text)
            if eid in blocked:
                report["blocked"] += 1
                continue
            flags = {f for f in ("explicit", "pin") if it.get(f) is True}
            days = max(1, min(50, int(it.get("days") or 1)))
            if eid in where:   # a duplicate, in the file or already stored: keep the strongest
                e = where[eid]
                e.conf = max(e.conf, conf)
                if eid in confirmed_ids:   # seed sightings never promote a candidate
                    e.days = max(e.days, days)
                e.flags |= flags
                report["merged"] += 1
                continue
            src = " ".join(str(it.get("src") or "").replace('"', "'").split())[:SRC_MAX]
            e = Entry(text, conf, id=eid, first=day, last=day, days=days, n=days, decayed=day,
                      src=src, flags=",".join(sorted(flags)))
            e.cat = cat
            where[eid] = e
            if conf >= PROMOTED_FLOOR:
                cats.setdefault(cat, [cat.replace("-", " ").capitalize(), f"the task touches {cat}", []])[2].append(e)
                confirmed_ids.add(eid)
                report["confirmed"] += 1
            else:   # a weak seed item earns its promotion with new sightings, like any other
                e.days, e.n = 1, 1
                cands.append(e)
                report["candidates"] += 1
        for cat, (title, rw, entries) in cats.items():
            store.write_category(cat, title, rw, entries)
        store.write_candidates(cands)
        report.update({k: v for k, v in maintain(store, today(args)).items() if k in ("capped", "promoted")})
        content = regenerate_index(store, today(args))
    print(" ".join(f"{k}={v}" for k, v in report.items()) + f" index_tokens={tokens(content)}")
    for r in reasons:
        print(f"  skipped {r}")


# ---- delivery into each host's global instruction file ---------------------------------------

HOSTS_DIR = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "hosts"))
BLOCK_START = "<!-- lore:index start -->"
BLOCK_END = "<!-- lore:index end -->"
HOST_MODES = {"import", "block"}


def load_hosts(only=None):
    hosts = []
    for fn in sorted(os.listdir(HOSTS_DIR)):
        if not fn.endswith(".conf"):
            continue
        h = {}
        with open(os.path.join(HOSTS_DIR, fn)) as f:
            for line in f:
                if ":" in line and not line.lstrip().startswith("#"):
                    k, v = line.split(":", 1)
                    h[k.strip()] = v.strip()
        for key in ("name", "home_dir", "global_file", "mode"):
            if not h.get(key):
                raise LoreError(f"host adapter {fn} lacks '{key}'")
        if h["mode"] not in HOST_MODES:
            raise LoreError(f"host adapter {fn}: mode must be import or block")
        if h["mode"] == "import" and "{index}" not in h.get("import", ""):
            raise LoreError(f"host adapter {fn}: an import adapter needs 'import' with {{index}}")
        hosts.append(h)
    if only:
        names = {h["name"] for h in hosts}
        unknown = set(only) - names
        if unknown:
            raise LoreError(f"no host adapter for: {', '.join(sorted(unknown))}")
        hosts = [h for h in hosts if h["name"] in only]
    return hosts


def host_block(store, host):
    index_path = store.path("INDEX.md")
    if host["mode"] == "import":
        inner = host["import"].replace("{index}", index_path)
    else:
        with open(index_path) as f:
            inner = f.read().rstrip("\n")
    return f"{BLOCK_START}\n{inner}\n{BLOCK_END}"


def splice(text, block):
    """Put the lore block into a global file's text; with block None, take it out.

    Only the text between the markers (and the one blank line lore adds before an appended
    block) is ever changed. Mismatched markers are refused rather than guessed at."""
    s, e = text.find(BLOCK_START), text.find(BLOCK_END)
    if (s == -1) != (e == -1) or (s != -1 and e < s) or text.count(BLOCK_START) > 1:
        raise LoreError("the lore markers in this file are broken; fix them by hand")
    if s == -1:
        if block is None:
            return text
        if not text:
            return block + "\n"
        return text + ("" if text.endswith("\n") else "\n") + "\n" + block + "\n"
    before, after = text[:s], text[e + len(BLOCK_END):]
    if block is not None:
        return before + block + after
    if after.startswith("\n"):
        after = after[1:]
    if before.endswith("\n\n"):
        before = before[:-1]
    return before + after


def write_beside(path, content):
    """Atomic write next to the target, keeping its permissions. A symlinked file (a dotfiles
    setup) is written through to its target, so the link stays a link."""
    path = os.path.realpath(path)
    d = os.path.dirname(path)
    mode = os.stat(path).st_mode & 0o777 if os.path.exists(path) else 0o644
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".lore-")
    with os.fdopen(fd, "w") as f:
        f.write(content)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def deliver_quietly(store):
    """Refresh every host's copy of the index; report only problems."""
    import io
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            cmd_deliver(store, argparse.Namespace(host=None, check=False, remove=False))
    except LoreError as err:
        print(f"deliver: {err}", file=sys.stderr)


def cmd_deliver(store, args):
    if not args.remove and not os.path.exists(store.path("INDEX.md")):
        raise LoreError("no INDEX.md yet; run init")
    stale = []
    for host in load_hosts(args.host):
        name = host["name"]
        if not os.path.isdir(os.path.expanduser(host["home_dir"])):
            print(f"{name}: skipped, not installed ({host['home_dir']} absent)")
            continue
        path = os.path.expanduser(host["global_file"])
        try:
            with open(path) as f:
                text = f.read()
        except FileNotFoundError:
            text = ""
        new = splice(text, None if args.remove else host_block(store, host))
        limit = int(host.get("max_bytes", 0) or 0)
        if limit and len(new.encode()) > limit:
            raise LoreError(f"{name}: {path} would be {len(new.encode())} bytes, over its {limit}-byte cap")
        if new == text:
            print(f"{name}: up to date ({path})")
            continue
        if args.check:
            stale.append(name)
            print(f"{name}: stale ({path})")
            continue
        if args.remove and not text:
            continue
        write_beside(path, new)
        print(f"{name}: {'removed from' if args.remove else 'delivered to'} {path}")
    if stale:
        raise LoreError("stale: " + ", ".join(stale) + "; run deliver")


# ---- setup: the one command a new user runs ------------------------------------------------

def setup_plan(store):
    """(host name, files lore would write) for every installed host."""
    import lore_capture
    plan = []
    for host in load_hosts():
        if not os.path.isdir(os.path.expanduser(host["home_dir"])):
            continue
        files = [os.path.expanduser(host["global_file"])]
        if host.get("hooks_file"):
            files.append(os.path.expanduser(host["hooks_file"]))
        plan.append((host["name"], files))
    return plan


def cmd_setup(store, args):
    """Install lore for every coding agent found here: the store, the index in each global
    instruction file, and the capture hooks. Shows the plan, backs up what it touches, asks first."""
    sys.modules.setdefault("lore", sys.modules[__name__])
    import lore_capture
    plan = setup_plan(store)
    verb = "remove lore from" if args.remove else "set up lore in"
    print(f"lore will {verb}:")
    if not args.remove:
        print(f"  memory store   {store.root}{'' if os.path.isdir(store.root) else ' (new)'}")
    for name, files in plan:
        for f in files:
            print(f"  {name:<14} {f}{'' if os.path.exists(f) else ' (new)'}")
    if not plan:
        print("  (no supported coding agent found: Claude Code, Codex, Command Code or agy)")
    if args.dry_run:
        return
    if not args.yes:
        if not sys.stdin.isatty():
            raise LoreError("not a terminal; review the plan with --dry-run, then run again with --yes")
        if input("Proceed? [y/N] ").strip().lower() not in ("y", "yes"):
            print("Nothing changed.")
            return
    backup = os.path.join(os.path.dirname(store.root), "lore-backup-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S"))
    for _, files in plan:
        for f in files:
            if os.path.isfile(f):
                rel = os.path.relpath(os.path.realpath(f), os.path.expanduser("~"))
                if rel.startswith(".." + os.sep):   # outside the home folder: keep its absolute path
                    rel = os.path.realpath(f).lstrip(os.sep)
                dest = os.path.join(backup, rel)
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                shutil.copy2(f, dest)
    if os.path.isdir(backup):
        print(f"Backed up the files above to {backup}")
    if args.remove:
        cmd_deliver(store, argparse.Namespace(host=None, check=False, remove=True))
        lore_capture.hooks(store, argparse.Namespace(host=None, action="remove"))
        print(f"lore is removed from every agent. Your memory stays in {store.root}; delete it yourself if you want it gone.")
        return
    if not os.path.isdir(store.root):
        cmd_init(store, args)
    cmd_deliver(store, argparse.Namespace(host=None, check=False, remove=False))
    lore_capture.hooks(store, argparse.Namespace(host=None, action="install"))
    print("lore is set up. Every new session on these agents loads your memory, and lore learns from")
    print("your corrections on its own. Say 'remember: ...' to teach it a rule at once.")


def main(argv=None):
    p = argparse.ArgumentParser(prog="lore.py", description="lore memory store")
    p.add_argument("--store", default=os.environ.get("LORE_STORE", STORE_DEFAULT))
    p.add_argument("--today", help="date to act as today (YYYY-MM-DD), for tests and replays")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("init", help="create the store (never overwrites)")
    a = sub.add_parser("add", help="record a learning as a candidate, or bump a known one")
    a.add_argument("--cat", required=True)
    a.add_argument("--text", required=True)
    a.add_argument("--src", default="")
    a.add_argument("--explicit", action="store_true", help="the user stated it (remember/always/never)")
    a.add_argument("--contradicts", metavar="ID", help="an entry this learning contradicts")
    d = sub.add_parser("drop", help="delete an entry and blocklist it")
    d.add_argument("target", help="entry id or its exact text")
    sub.add_parser("maintain", help="promote, decay, prune, cap, regenerate the index")
    sub.add_parser("index", help="regenerate INDEX.md and print its size")
    pn = sub.add_parser("pin", help="keep a confirmed entry inline and exempt from decay")
    pn.add_argument("id")
    pn.add_argument("--unpin", action="store_true")
    ls = sub.add_parser("list", help="list confirmed entries (or candidates)")
    ls.add_argument("--candidates", action="store_true")
    ls.add_argument("--cat")
    dv = sub.add_parser("deliver", help="write the index into each installed host's global file")
    dv.add_argument("--host", action="append", help="only this host (repeatable)")
    dv.add_argument("--check", action="store_true", help="change nothing; exit 1 if any host is stale")
    dv.add_argument("--remove", action="store_true", help="take the lore block out again")
    hv = sub.add_parser("harvest", help="turn queued and recent sessions into candidates (run by the hook)")
    hv.add_argument("--sweep", action="store_true", help="also scan host transcript folders")
    hv.add_argument("--flush", action="store_true", help="do not wait for idle sessions")
    hv.add_argument("--now", type=float, help="epoch seconds to act as now, for tests")
    hv.add_argument("--wait", action="store_true", help="stay until per-turn sessions go idle (the hook's mode)")
    rv = sub.add_parser("review", help="the once-a-day review of new memory by a stronger model")
    rv.add_argument("--force", action="store_true", help="review even if done today")
    lt = sub.add_parser("learn-taste", help="harvest Command Code taste files into candidates")
    lt.add_argument("--root", action="append", help="folder to search (repeatable); default: config taste_roots")
    hk = sub.add_parser("hooks", help="install, remove or check lore's hooks in each host")
    hk.add_argument("action", choices=["install", "remove", "check"])
    hk.add_argument("--host", action="append", help="only this host (repeatable)")
    ds = sub.add_parser("describe", help="set a category's title and read-when line")
    ds.add_argument("cat")
    ds.add_argument("--title")
    ds.add_argument("--read-when", dest="read_when")
    im = sub.add_parser("import", help="bulk-import established rules from a JSON array (the seed)")
    im.add_argument("--file", required=True)
    su = sub.add_parser("setup", help="set lore up for every coding agent found (or --remove it)")
    su.add_argument("--dry-run", action="store_true", help="show what would change, change nothing")
    su.add_argument("--yes", action="store_true", help="do not ask for confirmation")
    su.add_argument("--remove", action="store_true", help="take lore out of every agent (memory is kept)")
    sub.add_parser("sync-status", help="print, as JSON, whether a hub sync is due and what to push")
    ex = sub.add_parser("export", help="copy the sync files to a folder, for the agent to push")
    ex.add_argument("--out", required=True)
    ex.add_argument("--only", nargs="*", help="only these file names")
    mg = sub.add_parser("merge", help="fold a folder of hub files into the store")
    mg.add_argument("--remote", required=True)
    sd = sub.add_parser("sync-done", help="record a finished sync")
    sd.add_argument("--pushed", required=True, help="the folder export wrote and the agent pushed")
    sd.add_argument("--remote-seen", help="JSON file: hub note title -> updated_at after the push")
    args = p.parse_args(argv)
    store = Store(os.path.abspath(os.path.expanduser(args.store)), today(args))
    handlers = {"init": cmd_init, "add": cmd_add, "drop": cmd_drop, "maintain": cmd_maintain,
                "index": cmd_index, "pin": cmd_pin, "list": cmd_list, "deliver": cmd_deliver,
                "import": cmd_import, "describe": cmd_describe, "setup": cmd_setup}
    if args.cmd in ("harvest", "hooks", "review", "learn-taste"):
        sys.modules.setdefault("lore", sys.modules[__name__])   # one module, one LoreError
        import lore_capture
        handlers["harvest"] = lore_capture.harvest
        handlers["hooks"] = lore_capture.hooks
        handlers["review"] = lore_capture.review
        handlers["learn-taste"] = lore_capture.learn_taste
    if args.cmd in ("sync-status", "export", "merge", "sync-done"):
        sys.modules.setdefault("lore", sys.modules[__name__])
        import lore_sync
        handlers.update({"sync-status": lore_sync.cmd_sync_status, "export": lore_sync.cmd_export,
                         "merge": lore_sync.cmd_merge, "sync-done": lore_sync.cmd_sync_done})
    if args.cmd not in ("init", "setup") and not os.path.isdir(store.root):
        print(f"Error: no store at {store.root}; run init first", file=sys.stderr)
        return 1
    try:
        handlers[args.cmd](store, args)
    except LoreError as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
