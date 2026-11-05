"""lore 2.0 Canon: the dream. Code finds what is wrong (lore_lint's gates); a strong model fixes it.

At session end, after the Loremaster's filing, lint runs; when its gates say Canon is due, one
model call gets the findings and the files they name (each rule with its original quote) and
answers with the Loremaster's JSON operations, restricted to Canon's (reword, split, merge,
describe, link, unlink, move, retire). Canon never writes the owner's working tree: it works in
its own private checkout of the store (a local clone in .git/lore/canon, built from HEAD for each
run and removed after it). There code validates the whole batch first (all or nothing), then
applies each operation as its own commit, `canon: <op> <file>`, so every change can be reverted
on its own; a later operation is checked against the store as the earlier ones left it. The
commits then land like a second machine's: the owner's own changes are committed, the checkout
replays its commits onto the store with the hub's merge drivers (lore_hub.integrate), and the
store fast-forwards. A conflict that policy cannot settle drops Canon's commits (the owner's side
wins; logged, not a failure); a failed or rejected run discards the checkout and nothing else.
A retirement waits in the Inbox, and one the owner rejected is not asked again on the same
evidence. When nothing is due there is no model call, and every call counts as the day's run.
The caller holds the store's run lock. Standard library only.
"""

import contextlib
import copy
import datetime as dt
import json
import os
import shutil
import sys

import lore
import lore_hub
import lore_master
import lore_store
from lore_hub import log

PROMPT_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "prompts", "canon.md")
CONTEXT_CAP = 48000
CANON_OPS = lore_master.CANON_OPS


def lint_module():
    """lore_lint, or None when it is not installed."""
    sys.modules.setdefault("lore", lore)
    try:
        import lore_lint
    except ImportError:
        return None
    return lore_lint


# ---- the prompt -------------------------------------------------------------------------------

def holders(m, rid):
    """[(file, entry)] of every rule with this id."""
    return [(r, m.entries(r)[rid]) for r in m.files if rid in m.entries(r)]


def opposing(m, text):
    """[(file, id, entry)] of every rule whose words are `text` (a contradiction flag's other side)."""
    key = lore.normalise(text)
    return [(r, eid, e) for r in m.files for eid, e in m.entries(r).items() if lore.normalise(e.get("text", "")) == key]


def flags(entry):
    return [str(x["with"]) for x in entry.get("contradictions") or [] if isinstance(x, dict) and x.get("with")]


def named_files(m, findings):
    """The rule files the findings name, in finding order: each finding's file, the files that
    hold its rule ids, and for a contradiction the files that hold the other side."""
    out = []
    for f in findings:
        rels = [f.get("file")]
        for rid in f.get("rule_ids") or []:
            for r, e in holders(m, rid):
                rels.append(r)
                if f.get("gate") == "contradiction":
                    rels += [o for w in flags(e) for o, _, _ in opposing(m, w)]
        out += [r for r in rels if r in m.files and r not in out]
    return out


def rule_record(rel, eid, entry, lead="- "):
    """One rule as Canon sees it, never split: (its key, its line and its original quote below it).
    The key is the exact entry, (file, id, words): what showing it authorises."""
    pad = " " * len(lead)
    return ((rel, eid, entry.get("text", "")),
            [f"{lead}[{eid}] {entry.get('text', '')}",
             f"{pad}original quote: {json.dumps(lore_master.original_quote(entry), ensure_ascii=False)}"])


def file_block(m, rel):
    """(head lines, records) of one file as Canon sees it: read_when, links both ways, size, then
    every rule as a record (its id, its line and its original quote). The caller redacts."""
    meta, text = m.files[rel]["meta"], m.files[rel]["text"] or ""
    rules = lore_store.parse_rules(text)[1]
    into = sorted(r for r in m.files if r != rel and rel in m.links(r))
    head = [f"### {rel}", "", f"read_when: {meta.get('read_when') or '(none)'}",
            f"links to: {', '.join(sorted(m.links(rel))) or '(none)'}",
            f"linked from: {', '.join(into) or '(none)'}",
            f"size: {len(rules)} rules, {len(text)} characters", ""]
    by_text = {e["text"]: (eid, e) for eid, e in m.entries(rel).items()}
    return head, [rule_record(rel, *by_text[t]) for t in dict.fromkeys(rules)]


def evidence_records(m, findings):
    """For each contradiction finding, the flagged rule and every rule holding the words it is
    flagged against, wherever they live, each with its original quote: [(key, lines, keys shown)]."""
    out = []
    for n, f in enumerate(findings, 1):
        if f.get("gate") != "contradiction":
            continue
        for rid in f.get("rule_ids") or []:
            for rel, e in holders(m, rid):
                key, lines = rule_record(rel, rid, e, f"finding {n}: flagged rule in {rel}: ")
                for w in flags(e):
                    sides = opposing(m, w)
                    if not sides:
                        lines += [f"  flagged against words no rule holds now: {json.dumps(w, ensure_ascii=False)}"]
                    for orel, oid, o in sides:
                        lines += rule_record(orel, oid, o, f"  flagged against, in {orel}: ")[1]
                out.append((key, lines, [key] + [(orel, oid, o.get("text", "")) for w in flags(e) for orel, oid, o in opposing(m, w)]))
    return out


def fit_records(head, records, room):
    """(text, shown keys, omitted keys): the head and then whole records while they fit in `room`
    characters, never a rule without its quote; what does not fit is named by id."""
    text = "".join(lore.redact(l) + "\n" for l in head)
    if len(text) > room:
        return "", [], [eid for eid, _ in records]
    shown, omitted = [], []
    for eid, lines in records:
        block = "".join(lore.redact(l) + "\n" for l in lines)
        if not omitted and len(text) + len(block) <= room:
            text += block
            shown.append(eid)
        else:
            omitted.append(eid)
    if omitted:
        text += f"({len(omitted)} more rule(s) not shown, over the prompt size cap: {', '.join(k[1] for k in omitted)}; " \
                f"they are not to be reworded this run)\n"
    return text, shown, omitted


def finding_line(n, f):
    ids = f" [{', '.join(f.get('rule_ids') or [])}]" if f.get("rule_ids") else ""
    return f"{n}. {f['gate']}: {f.get('file') or '(store)'}{ids}: {' '.join(str(f.get('detail', '')).split())}"


def build_prompt(store, findings, cap_chars=CONTEXT_CAP):
    """The prompt Canon gets for `findings` (see compose)."""
    return compose(store, findings, cap_chars)[0]


def compose(store, findings, cap_chars=CONTEXT_CAP):
    """(prompt, entries shown with their original quote, as (file, id, words)): the instructions, the layout, the index,
    the findings, each contradiction's evidence (both sides, with their quotes), then the files
    the findings name, by whole rule records within cap_chars. Everything is redacted: nothing
    secret reaches a model."""
    with open(PROMPT_FILE) as f:
        head = f.read().rstrip("\n")
    try:
        index = lore_store.build_index(store)[0]
    except lore_store.IndexBudgetError:
        index = store.read("INDEX.md") or ""
    m = lore_master._Model(store)
    parts = [head, "", "## Layout", "",
             "Top level: " + ", ".join(f"`{t}`" for t in m.top) + ", and `core.md` (rules for every task).",
             "Topic files now: " + (", ".join(f"`{r}`" for r in m.files if r != "core.md") or "none"),
             "", "## Index", "", index.rstrip("\n") or "(empty)", "", "## Findings", ""]
    parts += [finding_line(n, f) for n, f in enumerate(findings, 1)]
    room, shown = cap_chars, set()
    evidence = evidence_records(m, findings)
    if evidence:
        parts += ["", "## Contradictions: each flagged rule and the rule(s) it is flagged against, with their original quotes", ""]
        for key, lines, keys in evidence:
            text, ok, _ = fit_records([], [(key, lines)], room)
            room -= len(text)
            parts.append(text.rstrip("\n") if ok else "(not shown: over the prompt size cap)")
            shown.update(keys if ok else [])
    parts += ["", "## Files the findings name (rule ids in brackets, each rule's original quote below it)", ""]
    for rel in named_files(m, findings):
        head, records = file_block(m, rel)
        text, ok, _ = fit_records(head, records, room)
        room -= len(text)
        shown.update(ok)
        parts.append(text.rstrip("\n") if text else f"### {rel}\n\n(not shown: over the prompt size cap)")
        parts.append("")
    return lore.redact("\n".join(parts) + "\n"), shown


# ---- a run ------------------------------------------------------------------------------------

def held(store, findings):
    """Split the findings: {"kept": for Canon, "inbox": waiting on a pending Inbox retirement,
    "answered": settled by a retirement the owner rejected on the same evidence (the same finding:
    gate, file-qualified entries and words, see lore_master.key), "dropped": stale
    Inbox items removed}. A pending retirement counts only while its file, id and words still
    match the store; one that no longer does can never be accepted, so it is dropped and stops
    holding anything back."""
    m = lore_master._Model(store)
    pending, dropped = [], []
    for i in lore_master.inbox_list(store):
        if i["kind"] != "retire":
            continue
        p = i["payload"]
        e = m.entries(p.get("file")).get(p.get("rule_id")) if p.get("file") in m.files else None
        if e and e.get("text") == p.get("text"):
            pending.append(i)
        else:
            lore_master._drop(store, i)
            dropped.append(i)
    ids = {i["payload"]["rule_id"] for i in pending}
    texts = {lore.normalise(str(i["payload"]["text"])) for i in pending}
    no = lore_master.rejected(store)
    out = {"kept": [], "inbox": [], "answered": [], "dropped": dropped}
    keys = [lore_master.key(a) if a else None for a in lore_master.entries(store, m, findings)] if no else []
    for n, f in enumerate(findings):
        rids = f.get("rule_ids") or []
        rules = [(r, rid) for rid in rids for r, _ in holders(m, rid)]
        if f.get("gate") == "contradiction":
            rules += [(o, oid) for r, rid in list(rules) for w in flags(m.entries(r)[rid]) for o, oid, _ in opposing(m, w)]
        if any(r in ids for r in rids) or (f.get("gate") == "contradiction" and
                                           any(lore.normalise(m.entries(r)[rid].get("text", "")) in texts for r, rid in rules)):
            out["inbox"].append(f)
        elif no and keys[n] in no:
            out["answered"].append(f)
        else:
            out["kept"].append(f)
    return out


def waiting(store, findings):
    """(findings Canon should see, findings the owner holds: a pending retirement or a rejected one)."""
    h = held(store, findings)
    return h["kept"], h["inbox"] + h["answered"]


def held_lines(h):
    """What the held findings and dropped items say, one line each."""
    out = [f"dropped inbox item {i['id']}: rule {i['payload'].get('rule_id')} is no longer in "
           f"{i['payload'].get('file')} with those words" for i in h["dropped"]]
    if h["inbox"]:
        out.append(f"{len(h['inbox'])} finding(s) wait for the owner in the inbox")
    if h["answered"]:
        out.append(f"{len(h['answered'])} finding(s) the owner already answered (a rejected retirement; "
                   f"asked again when the evidence changes)")
    return [lore.redact(x) for x in out]


def head(store):
    return store.git("rev-parse", "HEAD")[1].strip()


def subject(store, op):
    return lore_master._cap(f"canon: {op['op']} {lore_master.op_file(store, op)}")


PRIVATE = "canon"   # Canon's private checkout, in .git/lore


def discard(path):
    """Remove Canon's private checkout; a symlink planted in its place is removed, never followed."""
    if os.path.islink(path):
        os.unlink(path)
    elif os.path.isdir(path):
        shutil.rmtree(path)


@contextlib.contextmanager
def private(store):
    """Canon's own checkout of the store at HEAD, removed afterwards whatever happens. A local clone
    (not a worktree: it has its own .git, so lore's git code, the merge drivers, the secret scan
    and the rebase recovery run in it unchanged, and it shares no index, HEAD or machine-local
    state with the owner's store), committing as the store does."""
    path = store.local(PRIVATE)
    discard(path)
    try:
        store.git("clone", "-q", "--no-local", "--template=", "--", store.root, path)   # by protocol: safe while git repacks the store
        pv = lore_store.Store2(path, store.day)
        for key, default in zip(("user.name", "user.email"), lore_store.IDENTITY):
            rc, out, _ = store.git("config", "--get", key, check=False)
            pv.git("config", key, out.strip() if rc == 0 and out.strip() else default)
        index = store.read("INDEX.md")   # never tracked: the prompt's fallback when it cannot be rebuilt
        if index is not None:
            pv.write("INDEX.md", index)
        yield pv
    finally:
        discard(path)


def unshown(store, ops, shown):
    """A reword may only touch an entry Canon was shown with its original quote: each reword's
    target is traced back through the batch's moves, splits and merges to the entry it was at the
    start, (file, id, words), which must be in `shown`. A same id in another file is another
    entry. Run on a batch that validates."""
    m = lore_master._Model(store)
    origin = {(r, eid): (r, eid, e.get("text", "")) for r in m.files for eid, e in m.entries(r).items()}
    errs = []
    for n, op in enumerate(ops, 1):
        if op["op"] == "reword":
            rel, _ = m.find(op["rule_id"], op.get("file"))
            if origin.get((rel, op["rule_id"])) not in shown:
                errs.append(f"op {n} (reword): rule {lore_master._safe(op['rule_id'])} in {rel} was not shown with its "
                            f"original quote (over the prompt size cap); it is not reworded this run")
        done = len(m.moved)
        lore_master._step(m, op["op"], op, None)
        for eid, src, dst in m.moved[done:]:
            origin[(dst, eid)] = origin.pop((src, eid), None)
    return errs


def apply_each(pv, ops):
    """Apply each op in the private checkout as its own commit. Returns the Inbox items the ops
    propose, each where its rule ends (only the moves after it was proposed carry it), and every
    rule move in op order, for the store once the commits land."""
    proposed, moved = [], []
    for op in ops:
        r = lore_master.apply(pv, [op], source="canon", allowed=CANON_OPS, subject=subject(pv, op), queue=False)
        proposed += [(k, p, len(moved)) for k, p in r["pending"]]
        moved += r["moved"]
    queue = []
    for kind, payload, since in proposed:
        if kind == "retire":
            payload = dict(payload, file=lore_master.follow(payload["file"], payload["rule_id"], moved[since:]))
        queue.append([kind, payload])   # the same proposal twice is one Inbox item
    return queue, moved


OWNER_INDEX = "canon-index"   # in .git/lore: the index of the owner's commit before landing
LANDING = "canon-landing.json"   # in .git/lore: what a landing run leaves to write to the Inbox


def commit_owner(store):
    """The owner's own changes as one commit, as at session end, staged in a private index
    (.git/lore/canon-index), never in theirs: a refusal (a secret, binary content) leaves their
    index as it is, and after the commit their index only catches up where it still held HEAD's
    version, so whatever they staged before or during the attempt stays staged. The commit is made
    only while HEAD is still what it was. Returns (sha, subject) or None; raises LoreError."""
    base, idx = head(store), store.local(OWNER_INDEX)
    view = copy.copy(store)
    view.staging = idx   # the secret scan reads the private index
    try:
        store.git("read-tree", base, index=idx)
        store.git("add", "-A", index=idx)
        _, out, _ = store.git("diff", "--cached", "--name-status", "--no-renames", "-z", base, index=idx)
        parts = out.split("\0")
        changes = [(parts[i], parts[i + 1]) for i in range(0, len(parts) - 1, 2)]
        if not changes:
            return None
        bad = lore_store.refused_files(view, changes)
        if bad:
            raise lore.LoreError(lore_store.refusal(bad))
        subj = lore_store.describe(changes)
        tree = store.git("write-tree", index=idx)[1].strip()
        sha = store.git("commit-tree", tree, "-p", base, "-m", subj)[1].strip()
        store.git("update-ref", "-m", f"commit: {subj}", "HEAD", sha, base)   # refused if HEAD moved
        catch_up(store, base, [p for _, p in changes])
        return store.git("rev-parse", "--short", sha)[1].strip(), subj
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(idx)


def catch_up(store, base, paths):
    """Bring the owner's index to HEAD for `paths`, only where it still held `base`'s version (they
    staged nothing of their own there)."""
    spec = [":(literal)" + p for p in paths]

    def entries(out, at):
        recs = [r.split("\t", 1) for r in out.split("\0") if "\t" in r]
        return {path: (info.split()[0], info.split()[at]) for info, path in recs}
    was = entries(store.git("ls-tree", "-r", "-z", base, "--", *spec)[1], 2)
    now = entries(store.git("ls-files", "-s", "-z", "--", *spec)[1], 1)
    theirs = [":(literal)" + p for p in paths if now.get(p) == was.get(p)]
    if theirs:
        store.git("reset", "-q", "HEAD", "--", *theirs)


def journal(store, tip, queue, moved):
    """Record, before Canon's commits land, what to write to the Inbox once they have: the items to
    queue, where each pending retirement goes, and the commit they wait for (machine-local)."""
    data = {"tip": tip, "queue": queue, "relocate": lore_master._relocations(store, moved)}
    path = store.local(LANDING)
    with open(path + ".tmp", "w") as f:
        json.dump(data, f, indent=1, sort_keys=True)
        f.write("\n")
    os.replace(path + ".tmp", path)


def publish(store):
    """Write what a run left in the landing record, once its commit is on HEAD (a record whose
    commit never landed is dropped): pending retirements moved, new items queued. Idempotent, so a
    run that failed or was killed part way is finished by the next one. Returns the queued ids,
    or None when there was nothing to write."""
    path = store.local(LANDING)
    try:
        with open(path) as f:
            data = json.load(f)
    except FileNotFoundError:
        return None
    except ValueError:
        data = {}
    ids = None
    if data.get("tip") and store.git("merge-base", "--is-ancestor", data["tip"], "HEAD", check=False)[0] == 0:
        lore_master._set_files(store, data.get("relocate") or {})
        ids = [lore_master._queue(store, k, p, "canon") for k, p in data.get("queue") or []]
    os.unlink(path)
    return ids


def land(store, pv, res, queue, moved):
    """Canon's commits land like a second machine's: the owner's own changes are committed first
    (as at session end; res["owner"]), the checkout replays its commits onto the store's HEAD with
    the hub's merge policy, the landing record is written, and the store fast-forwards to the
    result (git refuses, writing nothing, if an owner edit is in the way). Returns [(sha, subject)]
    landed. Raises LoreError with the owner's tree, index and HEAD as they were (but for that owner
    commit)."""
    lore_store.tidy(store)
    res["owner"] = commit_owner(store)
    start = head(store)
    lore_hub.integrate(pv, "origin", "tidy after landing Canon's commits")
    tip = head(pv)
    store.git("fetch", "-q", "--", pv.root, "HEAD")
    journal(store, tip, queue, moved)   # a refused fast-forward leaves it unlanded: the next publish drops it
    store.git("merge", "-q", "--ff-only", tip)
    with contextlib.suppress(lore.LoreError):
        lore_store.write_index(store)   # built from the files, never tracked
    _, out, _ = store.git("log", "--reverse", "--format=%h%x09%s", f"{start}..HEAD")
    return [tuple(l.split("\t", 1)) for l in out.splitlines()]


def run(store, findings, run_model):
    """One Canon call on `findings`, then validate, apply in the private checkout and land.
    Returns {"commits": [(sha, subject)] landed, "inbox": [ids], "ops": n, "answer", "rejected":
    [messages], "owner": the owner's commit made before landing or None, "dropped": why Canon's
    commits did not land, or None, "unpublished": why Inbox items of commits that landed are not
    written yet (the next run writes them), or None}; with any rejection nothing is written.
    Raises LoreError (a reply that is not JSON included) with nothing of Canon's kept."""
    res = {"commits": [], "inbox": [], "ops": 0, "answer": "", "rejected": [], "owner": None, "dropped": None,
           "unpublished": None}
    publish(store)   # what an earlier run left, first
    with private(store) as pv:
        start = head(pv)
        prompt, shown = compose(pv, findings)
        attempted(store)
        reply = lore_master.parse_reply(run_model(prompt))
        res["answer"] = lore.redact(" ".join(reply["answer"].split()))
        errs = lore_master.validate(pv, reply["ops"], allowed=CANON_OPS) or unshown(pv, reply["ops"], shown)
        if errs:
            return dict(res, rejected=errs)
        res["ops"] = len(reply["ops"])
        queue, moved = apply_each(pv, reply["ops"])
        if head(pv) != start:
            made = len(pv.git("rev-list", f"{start}..HEAD")[1].split())
            try:
                res["commits"] = land(store, pv, res, queue, moved)
            except lore.LoreError as err:
                return dict(res, dropped=f"{made} commit(s): {lore.redact(str(err))}"[:400])
        else:
            journal(store, head(store), queue, moved)
    try:
        res["inbox"] = publish(store) or []
    except Exception as err:   # the commits are on HEAD: say so; the record stays for the next run
        res["unpublished"] = f"{type(err).__name__}: {lore.redact(str(err))}"[:300]
    return res


def recover(store, trigger):
    """Session end: finish writing what a landed run left (its landing record); logged, never raises."""
    try:
        ids = publish(store)
    except Exception as err:
        log(f"store-run: canon: inbox items of landed commits not written yet: {type(err).__name__}: "
            f"{lore.redact(str(err))[:300]} ({trigger})")
        return
    if ids:
        log(f"store-run: canon: wrote {len(ids)} inbox item(s) of commits that landed before ({trigger})")


def attempted(store):
    """Count a Canon call as the day's run before it is made (lint's last run): a non-urgent finding
    then waits the interval after it, whatever the call's outcome; never a failure."""
    lint = lint_module()
    if lint is not None:
        lint.mark_run(store)


# ---- session end ------------------------------------------------------------------------------

def backing_off(st):
    if not st.get("canon_fails") or not st.get("canon_last_fail"):
        return False
    age = (dt.datetime.now().astimezone() - dt.datetime.fromisoformat(st["canon_last_fail"])).total_seconds()
    return age < lore_hub.lore_sync.BACKOFF_MIN * 60


def record(store, error):
    """Count a failed or rejected run for the backoff (error set), or clear the count (None)."""
    st = lore_hub.load_state(store)
    if error:
        st["canon_fails"] = st.get("canon_fails", 0) + 1
        st["canon_last_fail"] = lore_store.now_iso()
        st["canon_last_error"] = error
    else:
        for k in ("canon_fails", "canon_last_fail", "canon_last_error"):
            st.pop(k, None)
    lore_hub.save_state(store, st)


def outcome(res):
    """(error or None) of a run's result: a rejected batch is an error."""
    if res.get("rejected"):
        return "Canon's reply was rejected, nothing written: " + "; ".join(str(x) for x in res["rejected"][:5])
    return None


def step(store, trigger, force=False):
    """Session end: lint; when Canon is not due, a logged skip and no model call. Otherwise one
    Canon run (the call counts as the day's run). A failure or a rejection writes nothing, is
    logged and backs off like a failed sync (`force` overrides the backoff, never the gates);
    commits the owner's side wins over are dropped and logged, not a failure. Returns True when
    it made a commit (so the caller pushes)."""
    try:
        lore_store.begin(store)   # before anything is read; no model call whose commits could not land
    except lore.LoreError as err:
        log(f"store-run: canon skipped, {err} ({trigger})")
        return False
    recover(store, trigger)
    lint = lint_module()
    if lint is None:
        log(f"store-run: canon skipped, lint is not installed ({trigger})")
        return False
    try:
        h = held(store, lint.lint(store))
        findings = h["kept"]
        for line in held_lines(h):
            log(f"store-run: canon: {line}")
        due = lint.due(store, findings)
    except Exception as err:
        log(f"store-run: canon FAILED, lint did not run: {type(err).__name__}: {lore.redact(str(err))[:300]} ({trigger})")
        return False
    if not due["run"]:
        log(f"store-run: canon skipped, {due['reason']} ({trigger})")
        return False
    if backing_off(lore_hub.load_state(store)) and not force:
        log(f"store-run: canon waits, {len(findings)} finding(s); backing off after a failed run "
            f"(under {lore_hub.lore_sync.BACKOFF_MIN} min ago)")
        return False
    try:
        res = run(store, findings, lore_hub.run_model(store, "canon"))
        error = outcome(res)
    except Exception as err:   # the step must never break the session-end run
        res, error = {}, f"{type(err).__name__}: {lore.redact(str(err))}"[:400]
    if error:
        record(store, error)
        log(f"store-run: canon FAILED, nothing written; {error} ({trigger})")
        return False
    record(store, None)
    if res["owner"]:
        log(f"store-run: committed {res['owner'][0]} {res['owner'][1]} (before Canon's commits land) ({trigger})")
    if res["dropped"]:
        log(f"store-run: canon: dropped {res['dropped']}; the owner's side wins ({trigger})")
        return bool(res["owner"])
    for sha, subj in res["commits"]:
        log(f"store-run: canon: committed {sha} {subj}")
    log(f"store-run: canon ran on {len(findings)} finding(s) ({', '.join(due['gates'])}): "
        f"{len(res['commits'])} commit(s), {len(res['inbox'])} inbox item(s) ({trigger})")
    if res["unpublished"]:
        log(f"store-run: canon: inbox items not written yet ({res['unpublished']}); the next run writes them ({trigger})")
    if res["answer"]:
        log("store-run: canon: " + res["answer"][:300])
    return bool(res["commits"] or res["owner"])


# ---- commands ---------------------------------------------------------------------------------

def _lint_or_fail():
    lint = lint_module()
    if lint is None:
        raise lore.LoreError("lint is not installed (lore_lint.py is missing from the skill)")
    return lint


def due_line(due):
    return f"due: {'run' if due['run'] else 'no run'}{' (urgent)' if due['urgent'] else ''}: {due['reason']}"


def cmd_lint(_, args):
    """Print lint's findings and whether Canon is due. No model, no writes."""
    store = lore_hub.open_store(args)
    store.require()
    lint = _lint_or_fail()
    with store.locked():
        findings = lint.lint(store)
        for n, f in enumerate(findings, 1):
            print(lore.redact(finding_line(n, f)[len(f"{n}. "):]))
        if not findings:
            print("lint: no findings")
        for note in getattr(findings, "notes", ()):
            print(f"note: {note}")
        print(due_line(lint.due(store, findings)))


def cmd_canon(_, args):
    """Run Canon now under the lock, when lint finds something: when it is due, or always with
    --force. Pushes what it commits."""
    store = lore_hub.open_store(args)
    store.require()
    lint = _lint_or_fail()
    with store.locked():
        lore_store.begin(store)
        h = held(store, lint.lint(store))
        findings = h["kept"]
        for line in held_lines(h):
            print(f"canon: {line}")
        if not findings:
            print("canon: nothing to fix; no model call")
            return
        due = lint.due(store, findings)
        if not due["run"] and not args.force:
            print(due_line(due))
            print("canon: not run (--force runs it now)")
            return
        if backing_off(lore_hub.load_state(store)) and not args.force:
            print(f"canon: not run, backing off after a failed run (under {lore_hub.lore_sync.BACKOFF_MIN} min ago; "
                  f"--force runs it now)")
            return
        try:
            res = run(store, findings, lore_hub.run_model(store, "canon"))
            error = outcome(res)
        except lore.LoreError as err:
            res, error = {}, str(err)
        if error:
            record(store, error)
            raise lore.LoreError(f"canon FAILED, nothing written: {error}")
        record(store, None)
        if res["owner"]:
            print(f"committed {res['owner'][0]} {res['owner'][1]} (before Canon's commits land)")
        if res["dropped"]:
            print(f"canon: dropped {res['dropped']}; the owner's side wins")
        for sha, subj in res["commits"]:
            print(f"committed {sha} {subj}")
        for i in res["inbox"]:
            print(f"inbox: {i} (see `lore inbox list`)")
        if res["unpublished"]:
            print(f"canon: inbox items not written yet ({res['unpublished']}); the next run writes them")
        print(f"canon: {len(findings)} finding(s), {res['ops']} op(s), {len(res['commits'])} commit(s)")
        if res["answer"]:
            print("canon: " + res["answer"][:300])
        if res["commits"]:
            line = lore_hub.push_step(store, force=True)
            print(line)
            if "FAILED" in line:
                raise lore.LoreError("committed locally; the push failed")


def cmd_canon_log(_, args):
    """Canon's commits from git, one line each, newest first."""
    store = lore_hub.open_store(args)
    store.require()
    if args.days < 1:
        raise lore.LoreError("--days must be 1 or more")
    _, out, _ = store.git("log", f"--since={args.days} days ago", "--date=format:%Y-%m-%d %H:%M",
                          "--format=%ad%x09%h%x09%s")
    rows = [l.split("\t", 2) for l in out.splitlines() if l.count("\t") >= 2]
    rows = [r for r in rows if r[2].startswith("canon: ")]
    for when, sha, subj in rows:
        print(f"{when}  {sha}  {subj}")
    if not rows:
        print(f"canon-log: no Canon commits in the last {args.days} day(s)")
