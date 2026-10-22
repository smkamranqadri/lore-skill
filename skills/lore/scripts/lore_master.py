"""lore 2.0 Loremaster: files queued items into the store through a model's JSON operations.

The model only answers; code does the rest. select_context picks what the model sees (the index
plus the topic files nearest the items, under a size cap), build_prompt wraps it in the
instructions from prompts/loremaster.md, parse_reply reads the answer, validate checks every
operation against the store before anything is written (all or nothing), and apply writes one
batch as one commit. A retirement or a layout proposal is never applied: it waits in the Inbox
(.git/lore/inbox/, this machine only) beside the hand edits and layout proposals P1 leaves.

The caller holds the store's run lock (the session-end step, `lore inbox`). Standard library only.
"""

import contextlib
import datetime as dt
import glob
import hashlib
import json
import os
import re

import lore
import lore_store

PROMPT_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "prompts", "loremaster.md")
CONTEXT_CAP = 24000
CONTEXT_FILES = 3
TEXT_MAX = 300      # a rule, a contradiction, a reason: one line
QUOTE_MAX = 2000
SUBJECT_MAX = 72
STOP = {"the", "and", "for", "with", "when", "that", "this", "from", "into", "are", "was", "not",
        "you", "your", "its", "before", "after", "every", "always", "never", "use", "any", "all",
        "one", "only", "than", "then", "them", "they", "what", "each", "can", "has", "have"}

# op: (required fields, optional fields); every field's type is in FIELD_TYPES
OPS = {
    "add": ({"file", "text", "explicit", "quote", "session"}, {"core"}),
    "describe": ({"file", "read_when"}, set()),
    "link": ({"file", "to"}, set()),
    "unlink": ({"file", "to"}, set()),
    "move": ({"rule_id", "to"}, set()),
    "supersede": ({"rule_id", "text", "quote"}, set()),
    "flag-contradiction": ({"rule_id", "with_text"}, set()),
    "retire": ({"rule_id", "reason"}, set()),
    "propose-layout": ({"top", "reason"}, set()),
}
FIELD_TYPES = {"explicit": bool, "core": bool, "top": list}   # every other field is a string
MAY_BE_EMPTY = {"quote", "session"}
LINE_MAX = {"text": TEXT_MAX, "with_text": TEXT_MAX, "reason": TEXT_MAX, "read_when": 200,
            "quote": QUOTE_MAX, "session": 200, "file": 200, "to": 200, "rule_id": 40}


class ReplyError(lore.LoreError):
    pass


class OpsError(lore.LoreError):
    def __init__(self, messages):
        super().__init__("; ".join(messages))
        self.messages = messages


def _safe(value, limit=60):
    """A value fit to echo in a message: secrets redacted, one line, short."""
    t = " ".join(lore.redact(str(value)).split())
    return t if len(t) <= limit else t[:limit - 3] + "..."


def _tidy(text):
    return " ".join(str(text).split())


def _cap(subject):
    return subject if len(subject) <= SUBJECT_MAX else subject[:SUBJECT_MAX - 3].rsplit(" ", 1)[0] + " ..."


def _title(rel):
    return lore_store.TITLES.get(rel) or os.path.basename(rel)[:-3].replace("-", " ").capitalize()


# ---- the store as the model sees it -----------------------------------------------------------

class _Model:
    """Every rule file and sidecar, in memory, matched the way lore_store.reconcile matches them
    (so ids agree with what the next tidy writes). Operations change this copy only."""

    def __init__(self, store):
        self.store = store
        self.day = store.day.isoformat()
        self.top = store.layout()
        self.files = {}
        for rel in store.rule_files():
            text = store.read(rel)
            meta = lore_store.load_meta(store, rel)
            lore_store.match_rules(meta, lore_store.parse_rules(text)[1], self.day)
            self.files[rel] = {"text": text, "meta": meta}
        self.touched = []
        self.inbox = []

    def entries(self, rel):
        return self.files[rel]["meta"]["rules"]

    def touch(self, rel):
        if rel not in self.touched:
            self.touched.append(rel)

    def find(self, rid):
        """(file, entry) of a rule id, or an error message."""
        hits = [rel for rel in self.files if rid in self.entries(rel)]
        if not hits:
            return None, f"no rule with id {_safe(rid)!r}"
        if len(hits) > 1:
            return None, f"rule id {_safe(rid)} is in more than one file ({', '.join(hits)})"
        return hits[0], None

    def duplicate(self, text, skip=None):
        """(file, id) of a rule with the same words, or None."""
        key = lore.normalise(text)
        for rel in self.files:
            for eid, e in self.entries(rel).items():
                if eid != skip and lore.normalise(e.get("text", "")) == key:
                    return rel, eid
        return None

    def ids(self):
        return {eid for rel in self.files for eid in self.entries(rel)}

    def copies(self, rel, text):
        return lore_store.parse_rules(self.files[rel]["text"])[1].count(text)

    def create(self, rel):
        self.files[rel] = {"text": None, "meta": {"rules": {}, "reads": {}, "last_read": {}}}


def symlinked(store, rel):
    """The first part of `rel` (a path inside the store) that is a symlink, or None. A write
    through one could land outside the store or in .lore/."""
    parts = rel.split("/")
    for i in range(1, len(parts) + 1):
        if os.path.islink(os.path.join(store.root, *parts[:i])):
            return "/".join(parts[:i])
    return None


def path_error(rel, top):
    """Why `rel` is not a rule file path inside the layout, or None."""
    parts = rel.split("/")
    if ".." in rel or rel.startswith("/") or "\\" in rel:
        return "escapes the store"
    if ".lore" in parts or rel.startswith(".lore"):
        return "is inside .lore/"
    if not rel.endswith(".md"):
        return "is not a .md file"
    if not all(lore_store.PART_RE.match(p) for p in parts):
        return "is not a valid file name (lowercase letters, digits, - . _)"
    if len(parts) == 1:
        return None if rel == "core.md" or rel in top else "is not in the layout"
    return None if parts[0] + "/" in top else "is not in the layout"


def layout_errors(top):
    """What is wrong with a proposed top level (the checks Store2.layout makes), or []."""
    if not isinstance(top, list) or not top or not all(isinstance(t, str) for t in top):
        return ["top must be a non-empty list of names"]
    errs = []
    for t in top:
        name = t[:-1] if t.endswith("/") else (t[:-3] if t.endswith(".md") else None)
        if t in ("core.md", "INDEX.md"):
            errs.append(f"{t} is not a layout entry")
        elif not name or not lore_store.NAME_RE.match(name):
            errs.append(f"top entry {_safe(t)!r} is not a folder/ or a file.md name")
    if len(set(top)) != len(top):
        errs.append("top lists an entry twice")
    return errs


def _shape(n, op):
    """Shape errors of one op (name, fields, types, one line, no secret); [] when it is sound."""
    if not isinstance(op, dict):
        return [f"op {n}: not an object"]
    kind = op.get("op")
    if not isinstance(kind, str) or kind not in OPS:
        return [f"op {n}: unknown op {_safe(kind)!r}"]
    need, optional = OPS[kind]
    pre = f"op {n} ({kind}):"
    errs = []
    extra = set(op) - need - optional - {"op"}
    if extra:
        errs.append(f"{pre} unknown field(s) {', '.join(sorted(_safe(k) for k in extra))}")
    missing = need - set(op)
    if missing:
        errs.append(f"{pre} missing field(s) {', '.join(sorted(missing))}")
    for k in sorted((need | optional) & set(op)):
        v, want = op[k], FIELD_TYPES.get(k, str)
        if not isinstance(v, want):
            errs.append(f"{pre} {k} must be {dict(bool='true or false', list='a list').get(want.__name__, 'a string')}")
            continue
        values = v if isinstance(v, list) else [v] if isinstance(v, str) else []
        if any(isinstance(x, str) and lore.SECRET_RE.search(x) for x in values):
            errs.append(f"{pre} a secret-looking string in {k} (not shown)")
        elif isinstance(v, str):
            if "\n" in v or "\r" in v:
                errs.append(f"{pre} {k} must be one line")
            elif not v.strip() and k not in MAY_BE_EMPTY:
                errs.append(f"{pre} {k} is empty")
            elif len(v) > LINE_MAX[k]:
                errs.append(f"{pre} {k} is longer than {LINE_MAX[k]} characters")
    return errs


def _quoted(op, items):
    """The queued items whose words the op's quote is (its quote, or its text without one)."""
    q = _tidy(op.get("quote", ""))
    return [i for i in items if q and q == _tidy(i.get("quote") or i.get("text") or "")]


def _run(store, ops, items=None):
    """Play the ops on a copy of the store. Returns (model, errors)."""
    if not isinstance(ops, list):
        return None, ["ops must be a list"]
    m = _Model(store)
    errs = []
    for n, op in enumerate(ops, 1):
        bad = _shape(n, op)
        if bad:
            errs += bad
            continue
        errs += [f"op {n} ({op['op']}): {e}" for e in _step(m, op["op"], op, items)]
    return m, errs


def _step(m, kind, op, items):
    """One op on the model; returns its errors (and changes nothing when there are any)."""
    now, day = lore_store.now_iso(), m.day
    for field in ("file", "to"):
        if field in op:
            why = path_error(op[field], m.top)
            if why:
                return [f"{field} {_safe(op[field])!r} {why}"]
            for target in (op[field], lore_store.meta_rel(op[field])):
                link = symlinked(m.store, target)
                if link:
                    return [f"{field} {_safe(op[field])!r} passes through the symlink {_safe(link)}"]
    if kind == "add":
        rel, text = op["file"], _tidy(op["text"])
        if op.get("core") and not op["explicit"]:
            return ["core needs explicit: true (only a rule stated outright goes to core)"]
        if op.get("core") and rel != "core.md":
            return ["core: true needs file core.md"]
        if rel == "core.md" and not op.get("core"):
            return ["core.md takes a rule only with core: true"]
        if items is not None:
            src = _quoted(op, items)
            if not src:
                return ["quote is not the words of any queued item"]
            if op["explicit"] and not any(i.get("explicit") for i in src):
                return ["explicit is true but its item is not explicit"]
        dup = m.duplicate(text)
        if dup:
            return [f"duplicate of rule {dup[1]} in {dup[0]}"]
        if rel not in m.files:
            m.create(rel)
        entries = m.entries(rel)
        eid = lore_store.new_id(text, m.ids())   # unique in the whole store, this batch included
        entries[eid] = {"text": text, "created": day, "explicit": op["explicit"], "count": 1, "dates": [day],
                        "confidence": lore.NEW_EXPLICIT if op["explicit"] else lore.NEW_CANDIDATE,
                        "sessions": [op["session"]] if op["session"] else [], "updated": now,
                        "quote": _tidy(op["quote"])}
        m.files[rel]["text"] = lore_store.add_rule_line(m.files[rel]["text"], text, _title(rel))
        m.touch(rel)
        return []
    if kind in ("describe", "link", "unlink"):
        missing = [op[f] for f in ("file", "to") if f in op and op[f] not in m.files]
        if missing:
            return [f"{_safe(missing[0])} does not exist (a new topic file is created only by add)"]
        if "core.md" in (op["file"], op.get("to")):
            return ["core.md takes no read_when or links (it is always loaded)"]
        meta = m.files[op["file"]]["meta"]
        if kind == "describe":
            rw = re.sub(r"(?i)^read when\b\s*", "", _tidy(op["read_when"]))
            if not rw:
                return ["read_when is empty"]
            meta.update(read_when=rw, read_when_updated=now)
        elif op["file"] == op["to"]:
            return ["a topic cannot link to itself"]
        else:
            links = set(meta.get("links") or [])
            links = links | {op["to"]} if kind == "link" else links - {op["to"]}
            meta["links"] = sorted(links)
        m.touch(op["file"])
        return []
    if kind == "propose-layout":
        errs = layout_errors(op["top"])
        if not errs:
            m.inbox.append(("layout", {"top": list(op["top"]), "reason": _tidy(op["reason"])}))
        return errs
    rel, why = m.find(op["rule_id"])
    if why:
        return [why]
    eid, entries = op["rule_id"], m.entries(rel)
    entry = entries[eid]
    if kind == "move":
        to = op["to"]
        if to not in m.files:
            return [f"{_safe(to)} does not exist (a new topic file is created only by add)"]
        if "core.md" in (rel, to):
            return ["core.md changes only through the inbox"]
        if to == rel:
            return [f"rule {eid} is already in {to}"]
        if m.copies(rel, entry["text"]) > 1:
            return [f"rule {eid} is in {rel} more than once; remove the extra line first"]
        m.files[rel]["text"] = lore_store.remove_rule_line(m.files[rel]["text"], entry["text"])
        del entries[eid]
        m.entries(to)[eid] = dict(entry, updated=now)   # find() made sure no other file has the id
        m.files[to]["text"] = lore_store.add_rule_line(m.files[to]["text"], entry["text"], _title(to))
        m.touch(rel)
        m.touch(to)
        return []
    if kind == "supersede":
        text = _tidy(op["text"])
        if lore.normalise(text) == lore.normalise(entry["text"]):
            return ["the text is unchanged"]
        if items is not None:
            src = _quoted(op, items)
            if not src:
                return ["quote is not the words of any queued item"]
            if rel == "core.md" and not any(i.get("explicit") for i in src):
                return ["a core rule is reworded only from an explicit item (only a rule stated outright goes to core)"]
        if m.copies(rel, entry["text"]) > 1:
            return [f"rule {eid} is in {rel} more than once; remove the extra line first"]
        dup = m.duplicate(text, skip=eid)
        if dup:
            return [f"duplicate of rule {dup[1]} in {dup[0]}"]
        m.files[rel]["text"] = lore_store.replace_rule_line(m.files[rel]["text"], entry["text"], text)
        entry.pop("contradictions", None)   # the old wording is gone, and what it clashed with
        entry.update(text=text, quote=_tidy(op["quote"]), updated=now, superseded=day)
        m.touch(rel)
        return []
    if kind == "flag-contradiction":
        flags = entry.setdefault("contradictions", [])
        w = _tidy(op["with_text"])
        if w not in [f.get("with") for f in flags if isinstance(f, dict)]:
            flags.append({"with": w, "flagged": day})
        entry["updated"] = now
        m.touch(rel)
        return []
    if kind == "retire":
        m.inbox.append(("retire", {"rule_id": eid, "file": rel, "text": entry["text"],
                                   "reason": _tidy(op["reason"])}))
        return []
    raise AssertionError(kind)   # pragma: no cover


def validate(store, ops, items=None):
    """Every problem with a batch of ops, checked against the store in order; [] means valid.
    With the queued `items`, each quote must be an item's words and `explicit` its item's flag.
    Messages never echo a secret."""
    return _run(store, ops, items)[1]


# ---- writing ----------------------------------------------------------------------------------

def _sidecars(store):
    out = []
    for d, _, names in os.walk(store.path(".lore/meta")):
        out += [os.path.relpath(os.path.join(d, fn), store.root).replace(os.sep, "/") for fn in names]
    return out


def _commit_writes(store, writes, subject):
    """Write {relpath: text, or None to delete}, tidy and commit it as one change. On any failure
    every file is put back as it was (the sidecars tidy touched too) and the error is raised.
    Returns (sha or None, changed)."""
    links = [p for p in writes if symlinked(store, p)]
    if links:   # checked again here, before any write: no write or rollback follows a symlink
        raise lore.LoreError(f"refused to write through a symlink: {', '.join(_safe(p) for p in sorted(links))}")
    before = {p: store.read(p) for p in writes}
    changed = sorted(p for p, t in writes.items() if before[p] != t)
    if not changed:
        return None, []
    for p in _sidecars(store) + ["INDEX.md"]:
        before.setdefault(p, store.read(p))
    try:
        for p in changed:
            if writes[p] is None:
                os.unlink(store.path(p))
            else:
                store.write(p, writes[p])
        lore_store.tidy(store)
        done = lore_store.commit(store, subject)
    except BaseException:
        for p in _sidecars(store):
            before.setdefault(p, None)   # a sidecar tidy created goes again
        for p in sorted(before):
            if symlinked(store, p):
                continue
            if before[p] is None:
                with contextlib.suppress(FileNotFoundError):
                    os.unlink(store.path(p))
            else:
                store.write(p, before[p])
        with contextlib.suppress(lore.LoreError):
            store.git("reset", "-q", check=False)
        raise
    return (done[0] if done else None), changed


def _writes(m, rels):
    out = {}
    for rel in rels:
        out[rel] = m.files[rel]["text"]
        out[lore_store.meta_rel(rel)] = lore_store.dump_meta(m.files[rel]["meta"])
    return out


def _inbox_dir(store):
    return store.local("inbox")


def _queue(store, kind, payload, source):
    """Put one item in the Inbox; the same proposal twice is one item. Returns its id."""
    iid = kind[0] + "-" + hashlib.sha1(json.dumps([kind, payload], sort_keys=True).encode()).hexdigest()[:8]
    path = os.path.join(_inbox_dir(store), iid + ".json")
    if not os.path.exists(path):
        os.makedirs(_inbox_dir(store), exist_ok=True)
        with open(path, "w") as f:
            json.dump({"id": iid, "kind": kind, "created": lore_store.now_iso(), "payload": payload,
                       "source": source}, f, indent=1, sort_keys=True)
            f.write("\n")
    return iid


def apply(store, ops, *, source, items=None):
    """Validate, then apply a batch as one commit (through lore_store.commit: the secret scan
    runs, and the caller pushes). Retirements and layout proposals go to the Inbox instead.
    Raises OpsError, writing nothing, when the batch is not valid."""
    m, errs = _run(store, ops, items)
    if errs:
        raise OpsError(errs)
    sha, changed = _commit_writes(store, _writes(m, m.touched),
                                  lambda changes: _cap(f"{source}: {lore_store.describe(changes)}"))
    return {"commit": sha, "changed": changed, "inbox": [_queue(store, k, p, source) for k, p in m.inbox]}


# ---- the model's side -------------------------------------------------------------------------

def _words(text):
    return {w for w in lore.normalise(text).split() if len(w) >= 3 and w not in STOP}


def _rule_lines(m, rel):
    """A rule file as the model sees it: each rule with its id, in file order, secrets redacted."""
    by_text = {e["text"]: eid for eid, e in m.entries(rel).items()}
    rules = lore_store.parse_rules(m.files[rel]["text"])[1]
    return [lore.redact(f"- [{by_text[t]}] {t}") for t in dict.fromkeys(rules)]


def _fit(lines, room):
    """The leading lines that fit in `room` characters (each with its newline), never a part line."""
    out, used = [], 0
    for line in lines:
        if used + len(line) + 1 > room:
            break
        out.append(line)
        used += len(line) + 1
    return "".join(l + "\n" for l in out)


def select_context(store, items, cap_chars=CONTEXT_CAP):
    """INDEX.md, core.md's rules with their ids ("core"), and at most three topic files with the
    most words in common with the items, every rule shown with its id; everything is redacted
    first, then the whole is kept within cap_chars, cut by whole lines (index, core, topics)."""
    try:
        index = lore_store.build_index(store)[0]
    except lore_store.IndexBudgetError:
        index = store.read("INDEX.md") or ""
    m = _Model(store)
    want = set()
    for i in items:
        want |= _words(f"{i.get('text', '')} {i.get('quote', '')}")
    scored = []
    for rel in m.files:
        if rel == "core.md":
            continue
        meta = m.files[rel]["meta"]
        have = _words(" ".join([rel[:-3].replace("/", " "), str(meta.get("read_when") or "")]
                               + [e.get("text", "") for e in m.entries(rel).values()]))
        score = len(want & have)
        if score:
            scored.append((-score, rel))
    out = {"index": _fit([lore.redact(l) for l in index.splitlines()], cap_chars), "files": {}}
    used = len(out["index"])
    out["core"] = _fit(_rule_lines(m, "core.md") if "core.md" in m.files else [], cap_chars - used)
    used += len(out["core"])
    for _, rel in sorted(scored)[:CONTEXT_FILES]:
        text = _fit(_rule_lines(m, rel), cap_chars - used)
        if text:
            out["files"][rel] = text
            used += len(text)
    return out


def build_prompt(store, items, context):
    with open(PROMPT_FILE) as f:
        head = f.read().rstrip("\n")
    top = store.layout()
    parts = [head, "", "## Layout", "",
             "Top level: " + ", ".join(f"`{t}`" for t in top) + ", and `core.md` (rules for every task).",
             "Topic files now: " + (", ".join(f"`{r}`" for r in store.rule_files() if r != "core.md") or "none"),
             "", "## Index", "", context["index"].rstrip("\n") or "(empty)", "",
             "## Core rules (ids in brackets)", "", context.get("core", "").rstrip("\n") or "(none)", "",
             "## Topic files nearest the items (rule ids in brackets)", ""]
    for rel, text in context["files"].items():
        parts += [f"### {rel}", "", text.rstrip("\n"), ""]
    if not context["files"]:
        parts += ["(none share words with the items)", ""]
    parts += ["## Items to file", ""]
    for n, i in enumerate(items, 1):
        item = {k: i[k] for k in ("text", "explicit", "quote", "session") if k in i}
        parts.append(f"{n}. " + json.dumps(item, ensure_ascii=False, sort_keys=True))
    return lore.redact("\n".join(parts) + "\n")   # paths and headings too: nothing secret reaches a model


FENCE_RE = re.compile(r"```[a-zA-Z]*[ \t]*\n(.*?)\n[ \t]*```", re.S)


def parse_reply(text):
    """The reply's {"ops": [...], "answer": str}. A code fence or text around the object is
    tolerated; anything else raises ReplyError (which never quotes the reply)."""
    if not isinstance(text, str) or not text.strip():
        raise ReplyError("the reply is empty")
    t = text.strip()
    tries = [t] + [m.group(1) for m in FENCE_RE.finditer(t)]
    if 0 <= t.find("{") < t.rfind("}"):
        tries.append(t[t.find("{"):t.rfind("}") + 1])
    for c in tries:
        try:
            data = json.loads(c)
            break
        except ValueError:
            continue
    else:
        raise ReplyError("the reply is not JSON")
    if not isinstance(data, dict):
        raise ReplyError("the reply is not a JSON object")
    extra = set(data) - {"ops", "answer"}
    if extra:
        raise ReplyError(f"unknown reply field(s): {', '.join(sorted(_safe(k) for k in extra))}")
    if not isinstance(data.get("ops"), list):
        raise ReplyError("the reply has no ops list")
    if not isinstance(data.get("answer", ""), str):
        raise ReplyError("answer must be a string")
    return {"ops": data["ops"], "answer": data.get("answer", "")}


def file_items(store, items, run_model, *, source="loremaster"):
    """File queued items: one model call, then validate and apply its ops as one commit. Returns
    apply()'s dict plus "answer" and "rejected" (messages; nothing written when there are any).
    No items means no call. A reply that is not JSON raises ReplyError."""
    res = {"commit": None, "changed": [], "inbox": [], "answer": "", "rejected": []}
    if not items:
        return res
    reply = parse_reply(run_model(build_prompt(store, items, select_context(store, items))))
    res["answer"] = lore.redact(reply["answer"])
    errs = validate(store, reply["ops"], items)
    if errs:
        return dict(res, rejected=errs)
    res.update(apply(store, reply["ops"], source=source, items=items))
    return res


# ---- the Inbox --------------------------------------------------------------------------------

def _mtime(path):
    return dt.datetime.fromtimestamp(os.path.getmtime(path), dt.timezone.utc).replace(microsecond=0).isoformat()


def _hid(rel, eid):
    return "h-" + hashlib.sha1(f"{rel}:{eid}".encode()).hexdigest()[:8]


def inbox_list(store):
    """What waits for the owner: this machine's retirements and layout proposals, the hand edits
    not yet seen, and the layout proposals a hub merge left (P1's files, read where they are).
    Sorted oldest first. Nothing is written."""
    out = []
    for p in sorted(glob.glob(os.path.join(_inbox_dir(store), "*.json"))):
        try:
            with open(p) as f:
                item = json.load(f)
        except (OSError, ValueError):
            continue
        if isinstance(item, dict) and item.get("id") == os.path.basename(p)[:-5]:
            out.append(item)
    m = _Model(store)
    for rel in m.files:
        for eid, e in sorted(m.entries(rel).items()):
            if e.get("hand_edit"):
                out.append({"id": _hid(rel, eid), "kind": "hand-edit", "created": e["hand_edit"],
                            "payload": {"file": rel, "rule_id": eid, "text": e["text"]}, "source": "hand edit"})
    for p in sorted(glob.glob(store.local("proposals", "*.json"))):
        try:
            with open(p) as f:
                top = json.load(f).get("top")
        except (OSError, ValueError, AttributeError):
            top = None
        out.append({"id": "p-" + hashlib.sha1(os.path.basename(p).encode()).hexdigest()[:8], "kind": "layout",
                    "created": _mtime(p), "payload": {"top": top, "reason": "a hub merge kept the hub's layout; this was the local one",
                                                      "proposal": os.path.basename(p)},
                    "source": "hub merge"})
    return sorted(out, key=lambda i: (lore_store.instant(i["created"]), i["id"]))


def _item(store, item_id):
    for item in inbox_list(store):
        if item["id"] == item_id:
            return item
    raise lore.LoreError(f"no inbox item {_safe(item_id)}")


def _drop(store, item):
    """Remove an item's file: ours in .git/lore/inbox, or P1's proposal."""
    if item["id"].startswith("p-"):
        path = store.local("proposals", item["payload"]["proposal"])
    else:
        path = os.path.join(_inbox_dir(store), item["id"] + ".json")
    with contextlib.suppress(FileNotFoundError):
        os.unlink(path)


def _rule_of(store, item):
    """The model and the rule an item names, refused when it is gone or its words changed."""
    m = _Model(store)
    rel, eid = item["payload"]["file"], item["payload"]["rule_id"]
    e = m.entries(rel).get(eid) if rel in m.files else None
    if not e or e["text"] != item["payload"]["text"]:
        raise lore.LoreError(f"inbox item {item['id']}: rule {eid} is gone from {rel} or its words changed; reject the item")
    return m, rel, eid, e


def _remove_rule(m, rel, eid):
    """Take a rule out of its file: every copy of its line, and its sidecar entry."""
    text = m.entries(rel)[eid]["text"]
    while m.copies(rel, text):
        m.files[rel]["text"] = lore_store.remove_rule_line(m.files[rel]["text"], text)
    del m.entries(rel)[eid]


def _placeholder(store, rel):
    """A file a layout entry may hold and still count as empty: `.gitkeep`, or a rule file with
    nothing but its title (what init writes)."""
    if rel.endswith("/.gitkeep") or rel == ".gitkeep":
        return True
    if os.path.islink(store.path(rel)) or not rel.endswith(".md"):
        return False
    _, rules, other = lore_store.parse_rules(store.read(rel))
    return not rules and not other


def _content(store, entry):
    """The owner's content still under a layout entry: every file, symlink or folder link that
    is not a placeholder."""
    if entry.endswith(".md"):
        return [entry] if os.path.lexists(store.path(entry)) and not _placeholder(store, entry) else []
    out = []
    for d, dirs, files in os.walk(store.path(entry[:-1])):
        dirs.sort()
        names = files + [x for x in dirs if os.path.islink(os.path.join(d, x))]
        out += sorted(p for p in (os.path.relpath(os.path.join(d, f), store.root).replace(os.sep, "/") for f in names)
                      if not _placeholder(store, p))
    return out


def _accept_layout(store, item):
    top = item["payload"].get("top")
    errs = layout_errors(top)
    if errs:
        raise lore.LoreError(f"inbox item {item['id']}: " + "; ".join(errs))
    left = [p for entry in store.layout() if entry not in top for p in _content(store, entry)]
    if left:   # the folder or file still holds the owner's content: nothing changes, the item stays
        raise lore.LoreError(f"inbox item {item['id']}: the new layout drops content still in "
                             f"{', '.join(_safe(p) for p in left)}; move it first")
    try:
        data = json.loads(store.read(".lore/layout.json") or "{}")
    except ValueError:
        data = {}
    data = dict(data if isinstance(data, dict) else {}, top=list(top))
    writes = {".lore/layout.json": json.dumps(data, indent=1) + "\n"}
    for t in top:
        if t.endswith("/") and not os.path.isdir(store.path(t[:-1])):
            writes[t + ".gitkeep"] = ""
    return _commit_writes(store, writes, _cap(f"inbox: accept layout {item['id']}: " + ", ".join(top)))


def inbox_accept(store, item_id):
    """Apply one Inbox item as its own commit: a retirement removes the rule, a layout proposal
    becomes the layout, a hand edit is kept as a rule. Returns {"commit", "changed", "kind"}."""
    item = _item(store, item_id)
    kind = item["kind"]
    if kind == "retire":
        m, rel, eid, _ = _rule_of(store, item)
        _remove_rule(m, rel, eid)
        sha, changed = _commit_writes(store, _writes(m, [rel]), _cap(f"inbox: retire {eid} from {rel}"))
    elif kind == "layout":
        sha, changed = _accept_layout(store, item)
    elif kind == "hand-edit":
        m, rel, eid, e = _rule_of(store, item)
        e.pop("hand_edit")
        sha, changed = _commit_writes(store, _writes(m, [rel]), _cap(f"inbox: keep hand edit {eid} in {rel}"))
    else:
        raise lore.LoreError(f"inbox item {item['id']}: {_safe(kind)} items are not applied in this version")
    _drop(store, item)
    return {"commit": sha, "changed": changed, "kind": kind}


def inbox_reject(store, item_id):
    """Drop one Inbox item. A rejected hand edit is taken out of its file, as its own commit;
    every other kind leaves the store as it is."""
    item = _item(store, item_id)
    if item["kind"] == "hand-edit":
        m, rel, eid, _ = _rule_of(store, item)
        _remove_rule(m, rel, eid)
        _commit_writes(store, _writes(m, [rel]), _cap(f"inbox: reject hand edit {eid} in {rel}"))
    _drop(store, item)
