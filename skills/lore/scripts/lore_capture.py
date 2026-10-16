"""lore capture: turn finished sessions into candidate learnings, and install the hooks that feed it.

The host hook (lore-hook.sh) only queues its payload and starts `lore.py harvest` detached. Here:

1. Read the queue. Each entry names a host and a transcript; entries from per-turn Stop hooks wait
   until that transcript has been idle for `settle` seconds, so one session costs one pass.
2. With --sweep (session start), also pick up transcripts nothing queued (an untrusted Codex hook,
   a crash, a host whose hooks did not fire), but never those older than the first sweep.
3. Read each transcript from its saved offset and keep only the user's own messages.
4. A regex keeps messages that look like a correction or a preference; most sessions stop here
   with no model call.
5. The cheapest available extractor turns the hits into JSON items. Global items become
   candidates; project facts are dropped and noted (they belong in that project's KIS).
6. maintain, regenerate the index (which says when a sync is due), deliver it to every host.
"""

import datetime as dt
import fcntl
import glob
import json
import os
import re
import shutil
import subprocess
import tempfile
import time

import lore

SETTLE_DEFAULT = 600
EXTRACT_TIMEOUT = 180
MAX_FAILS = 3
MSG_MAX = 12000   # one message, the same as a whole batch; longer ones are cut and logged
SNIPPETS_MAX = 12000
KNOWN_MAX = 6000
ITEMS_MAX = 20
EXTRACTORS_DEFAULT = "codex,claude,cmd,agy"

TRIGGER_RE = re.compile(
    r"(?i)(\bno\b|\bnope\b|\bdon'?t\b|\bdo not\b|\bnever\b|\balways\b|\bstop\b|\binstead\b|"
    r"\bactually\b|\bprefer\b|\bwrong\b|\bremember\s*:|\bi (told|said)\b|\bagain\b)")

PROMPT = """You extract durable lessons about how this user wants coding agents to work, from the
user's own messages below. Return ONLY a JSON array, nothing else. Each item is an object:
  "rule": one imperative sentence under 25 words that would hold in ANY project
  "category": one of {cats}, or a new short lowercase-dash name
  "quote": the user's own words that show it, at most 15 words
  "explicit": true only if the user said remember, always or never about it
  "scope": "global", or "project" when it is true only for this repository (its stack, paths,
           deploy steps, URLs, people)
  "contradicts": the id of a known rule this one replaces, or null
Skip one-off task instructions, questions, and anything that is not a preference or a lesson.
Never include secrets, credentials, tokens or personal data. Return [] when nothing qualifies.

Known rules (id: text), do not repeat them unless the user repeated them:
{known}

User messages (one per block):
{messages}
"""


class ExtractError(Exception):
    pass


def log(msg):
    print(f"{dt.datetime.now().isoformat(timespec='seconds')} {msg}", flush=True)


# ---- transcripts ------------------------------------------------------------------------------

def _text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for c in content:
            if isinstance(c, dict) and c.get("type") in (None, "text", "input_text") and isinstance(c.get("text"), str):
                parts.append(c["text"])
            elif isinstance(c, str):
                parts.append(c)
        return "\n".join(parts)
    return ""


def user_text(fmt, rec):
    """The user's own words in one transcript record, or '' for anything else."""
    if not isinstance(rec, dict):
        return ""
    if fmt == "claude":
        if rec.get("type") != "user" or rec.get("isMeta"):
            return ""
        msg = rec.get("message") or {}
        content = msg.get("content")
        if isinstance(content, list) and any(isinstance(c, dict) and c.get("type") == "tool_result" for c in content):
            return ""
        t = _text_of(content)
    elif fmt == "codex":
        p = rec.get("payload") or {}
        if rec.get("type") != "event_msg" or p.get("type") != "user_message":
            return ""
        t = p.get("message") if isinstance(p.get("message"), str) else ""
    elif fmt == "agy":
        if rec.get("type") != "USER_INPUT":
            return ""
        t = _text_of(rec.get("content"))
        # agy wraps the prompt: <USER_REQUEST>...</USER_REQUEST>, then metadata blocks.
        m = re.search(r"<USER_REQUEST>\s*(.*?)\s*</USER_REQUEST>", t, re.S)
        if m:
            t = m.group(1)
    else:  # generic: a top-level or nested message whose role or type is user
        msg = rec.get("message") if isinstance(rec.get("message"), dict) else rec
        if msg.get("role") != "user" and rec.get("type") != "user" and msg.get("type") != "user":
            return ""
        t = _text_of(msg.get("content", msg.get("text", "")))
    t = (t or "").strip()
    if not t or t.startswith("<"):   # command echoes, system reminders, injected context
        return ""
    if len(t) > MSG_MAX:
        log(f"harvest: a {len(t)}-character message was cut to {MSG_MAX}")
    return t[:MSG_MAX]


def read_user_messages(fmt, path, offset, with_lines=False):
    """User messages after line `offset`; returns (messages, new_offset). With `with_lines`,
    each message is (line number after it, text), so a caller can checkpoint part of a file.
    A file shorter than the offset was rewritten: read it from the start."""
    with open(path, errors="replace") as f:
        lines = f.readlines()
    if offset > len(lines):
        offset = 0
    out = []
    for i, line in enumerate(lines[offset:], start=offset + 1):
        try:
            t = user_text(fmt, json.loads(line))
        except (ValueError, AttributeError):
            continue
        if t:
            out.append((i, t) if with_lines else t)
    return out, len(lines)


def batches(hits, limit=SNIPPETS_MAX):
    """Consecutive (line, text) hits grouped so each batch's text fits one prompt."""
    out, cur, size = [], [], 0
    for ln, t in hits:
        if cur and size + len(t) > limit:
            out.append(cur)
            cur, size = [], 0
        cur.append((ln, t))
        size += len(t)
    if cur:
        out.append(cur)
    return out


def find_by_session(host, sid):
    if not sid or not re.fullmatch(r"[A-Za-z0-9-]{6,80}", sid):
        return None
    for p in glob.glob(os.path.expanduser(host.get("transcript_glob", ""))):
        if sid in os.path.basename(p) or sid in p.split(os.sep):
            return p
    return None


# ---- extraction -------------------------------------------------------------------------------

def build_prompt(store, hits):
    cats = ", ".join(store.categories()) or "workflow, verification, git, communication, ui, tools, safety, orchestration"
    known = []
    for e in list(store.all_confirmed().values()) + store.read_candidates():
        known.append(f"{e.id}: {e.text}")
    known_s = "\n".join(known)[:KNOWN_MAX] or "(none yet)"
    blocks, used = [], 0
    for h in hits:
        if blocks and used + len(h) > SNIPPETS_MAX:
            break
        blocks.append("---\n" + h)
        used += len(h)
    return PROMPT.format(cats=cats, known=known_s, messages="\n".join(blocks))


def parse_items(out):
    s, e = out.find("["), out.rfind("]")
    if s == -1 or e < s:
        raise ExtractError("no JSON array in the extractor output")
    try:
        items = json.loads(out[s:e + 1])
    except ValueError as err:
        raise ExtractError(f"extractor output is not JSON: {err}")
    if not isinstance(items, list):
        raise ExtractError("extractor output is not a list")
    return [i for i in items if isinstance(i, dict)][:ITEMS_MAX]


def model_chain(store, hosts, field, config_key, default, override_env):
    """[(name, shell command)] to try in order: each host adapter's `field` command, in the order
    of the store config `config_key`. The `override_env` variable replaces the chain (tests)."""
    override = os.environ.get(override_env)
    if override:
        return [("override", override)]
    names = [n.strip() for n in store.config().get(config_key, default).split(",") if n.strip()]
    chain = []
    for n in names:
        h = hosts.get(n)
        if h and h.get(field) and shutil.which(h[field].split()[0]):
            chain.append((n, h[field]))
    return chain


def run_chain(chain, prompt, what):
    """Run the first command in the chain that returns a JSON array; return its items."""
    if not chain:
        raise ExtractError(f"no {what} CLI available")
    fd, pf = tempfile.mkstemp(prefix=f"lore-{what}-", suffix=".txt")
    with os.fdopen(fd, "w") as f:
        f.write(prompt)
    env = dict(os.environ, LORE_HARVEST="1", LORE_PROMPT_FILE=pf)
    errors = []
    try:
        for name, command in chain:
            try:
                r = subprocess.run(["sh", "-c", command], env=env, capture_output=True, text=True,
                                   timeout=EXTRACT_TIMEOUT, stdin=subprocess.DEVNULL)
                if r.returncode != 0:
                    raise ExtractError(f"exit {r.returncode}: {r.stderr.strip()[:200]}")
                items = parse_items(r.stdout)
                log(f"{what}: {name} returned {len(items)} item(s)")
                return items
            except (ExtractError, subprocess.TimeoutExpired) as err:
                errors.append(f"{name}: {err}")
        raise ExtractError("; ".join(errors))
    finally:
        os.unlink(pf)


def extract(store, hosts, hits):
    chain = model_chain(store, hosts, "extract", "extractors", EXTRACTORS_DEFAULT, "LORE_EXTRACT_CMD")
    return run_chain(chain, build_prompt(store, hits), "extract")


def apply_items(store, items, day, cwd, session=None):
    added = 0
    for it in items:
        rule = it.get("rule")
        if not isinstance(rule, str) or not rule.strip():
            continue
        if it.get("scope") == "project":
            with open(store.path("notices"), "a") as f:
                f.write(f"{day.isoformat()}\t{cwd or '?'}\tproject fact, belongs in that project's KIS: {' '.join(rule.split())}\n")
            continue
        cat = str(it.get("category") or "workflow").strip().lower().replace(" ", "-")
        if not lore.CATEGORY_RE.match(cat) or cat in lore.RESERVED:
            cat = "workflow"
        contra = it.get("contradicts")
        contra = contra if isinstance(contra, str) and re.fullmatch(r"[0-9a-f]{8}", contra) else None
        try:
            status = lore.add_learning(store, cat, rule, str(it.get("quote") or ""),
                                       bool(it.get("explicit")), contra, day, session)
            log(f"apply: {status} [{cat}] {rule.strip()[:80]}")
            added += 1
        except lore.LoreError as err:
            if contra:   # the id it named is gone; keep the learning itself
                try:
                    lore.add_learning(store, cat, rule, str(it.get("quote") or ""), bool(it.get("explicit")), None, day, session)
                    added += 1
                except lore.LoreError as err2:
                    log(f"apply: skipped ({err2})")
            else:
                log(f"apply: skipped ({err})")
    return added


# ---- harvest ----------------------------------------------------------------------------------

def load_state(store):
    try:
        with open(store.path("harvest-state.json")) as f:
            st = json.load(f)
    except (FileNotFoundError, ValueError):
        st = {}
    st.setdefault("offsets", {})
    st.setdefault("fails", {})
    return st


WAIT_ROUNDS = 3


def harvest(store, args):
    """Drain the queue. With --wait (the hook's mode) the worker stays until per-turn sessions
    have gone idle, and re-checks the queue after letting go of the lock, so an entry queued
    while it ran is never left without a worker."""
    os.makedirs(store.path("queue"), exist_ok=True)
    for _ in range(WAIT_ROUNDS):
        lockf = open(store.path(".harvest.lock"), "w")
        try:
            fcntl.flock(lockf, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            log("harvest: another harvest is running")
            return
        try:
            seen_files = _harvest_rounds(store, args)
        finally:
            lockf.close()
        if not getattr(args, "wait", False):
            return
        if not set(glob.glob(store.path("queue/*.json"))) - seen_files:
            return   # nothing arrived while the lock was held


def _harvest_rounds(store, args):
    hosts = {h["name"]: h for h in lore.load_hosts()}
    settle = int(store.config().get("settle", SETTLE_DEFAULT))
    start = time.time()
    while True:
        now = args.now if getattr(args, "now", None) is not None else time.time()
        seen_files, next_ready = _harvest_once(store, args, hosts, settle, now)
        if not getattr(args, "wait", False) or next_ready is None:
            return seen_files
        if time.time() - start + next_ready > 2 * settle:
            log("harvest: idle wait would run too long; the next session's sweep takes over")
            return seen_files
        time.sleep(max(1.0, next_ready))


def _harvest_once(store, args, hosts, settle, now):
    """One pass. Returns (queue files seen, seconds until a deferred entry is ready, or None)."""
    day = lore.today(args)
    state = load_state(store)
    jobs, done_files, next_ready = {}, {}, None
    seen_files = set(glob.glob(store.path("queue/*.json")))
    for qf in sorted(seen_files):
        try:
            with open(qf) as f:
                data = json.load(f)
            host = hosts[data["lore_host"]]
        except (ValueError, KeyError, TypeError, OSError):
            _park(store, qf, "unreadable queue entry")
            continue
        payload = data.get("payload") if isinstance(data.get("payload"), dict) else {}
        path = payload.get(host.get("transcript_key", "transcript_path")) or \
            find_by_session(host, payload.get(host.get("session_key", "session_id")))
        if not isinstance(path, str) or not os.path.isfile(path):
            os.unlink(qf)   # nothing to read (yet); a later sweep finds the file if it appears
            continue
        turn_events = {e.strip() for e in host.get("turn_events", "").split(",") if e.strip()}
        idle = now - os.path.getmtime(path)
        if data.get("lore_event") in turn_events and not args.flush and idle < settle:
            wait = settle - idle
            next_ready = wait if next_ready is None else min(next_ready, wait)
            continue   # session still active: leave it queued
        cwd = payload.get("cwd") or (payload.get("workspacePaths") or [None])[0]
        jobs[path] = (host, cwd)
        done_files.setdefault(path, []).append(qf)

    if args.sweep or args.flush:
        if "sweep_from" not in state:
            state["sweep_from"] = now   # first sweep: a starting point, never the whole history
        else:
            for host in hosts.values():
                for p in glob.glob(os.path.expanduser(host.get("transcript_glob", ""))):
                    try:
                        m = os.path.getmtime(p)
                    except OSError:
                        continue
                    if m >= state["sweep_from"] and (args.flush or now - m >= settle) and p not in jobs:
                        jobs[p] = (host, None)

    changed = False
    for path, (host, cwd) in sorted(jobs.items()):
        offset = state["offsets"].get(path, 0)
        try:
            msgs, new_off = read_user_messages(host.get("transcript_format", "generic"), path, offset, with_lines=True)
        except OSError as err:
            log(f"harvest: cannot read {path}: {err}")
            continue
        hits = [(ln, lore.redact(t)) for ln, t in msgs if TRIGGER_RE.search(t)]
        failed = False
        for batch in batches(hits):
            try:
                items = extract(store, hosts, [t for _, t in batch])
            except ExtractError as err:
                n = state["fails"].get(path, 0) + 1
                state["fails"][path] = n
                log(f"harvest: extraction failed for {path} ({n}/{MAX_FAILS}): {err}")
                failed = True
                break
            with store.locked():
                if apply_items(store, items, day, cwd, session=path):
                    changed = True
            state["offsets"][path] = batch[-1][0]   # checkpoint: this batch is done
        if failed and state["fails"].get(path, 0) < MAX_FAILS:
            continue   # queue entries stay; the next run resumes after the last finished batch
        if failed:
            for qf in done_files.pop(path, []):
                _park(store, qf, "extraction failed")
        log(f"harvest: {host['name']} {path}: {len(msgs)} message(s), {len(hits)} hit(s)")
        state["offsets"][path] = new_off
        state["fails"].pop(path, None)
        for qf in done_files.get(path, []):
            if os.path.exists(qf):
                os.unlink(qf)

    if changed or state.get("last_maintain") != day.isoformat():   # decay runs on quiet days too
        with store.locked():
            report = lore.maintain(store, day)
            lore.regenerate_index(store, day)
        state["last_maintain"] = day.isoformat()
        log("maintain: " + " ".join(f"{k}={v}" for k, v in report.items()))
        lore.deliver_quietly(store)
    if state.get("last_review") != day.isoformat():
        try:
            log("review: " + run_review(store, hosts, state, day))
        except ExtractError as err:
            log(f"review: failed, retried by the next harvest ({err})")
    store.write_atomic("harvest-state.json", json.dumps(state, indent=1, sort_keys=True) + "\n")
    return seen_files, next_ready


def _park(store, qf, why):
    os.makedirs(store.path("queue/failed"), exist_ok=True)
    os.replace(qf, store.path(f"queue/failed/{os.path.basename(qf)}"))
    log(f"harvest: parked {os.path.basename(qf)} ({why})")


class _Args:
    def __init__(self, **kw):
        self.__dict__.update(kw)


# ---- harvest of Command Code taste -------------------------------------------------------------

TASTE_ROOTS_DEFAULT = "~/.commandcode/taste,~"
TASTE_DEPTH = 6
TASTE_SKIP = {".git", "node_modules", ".cache", ".local", "Library", ".npm", ".venv", "venv",
              "dist", "build", ".Trash", "snap"}
TASTE_LINE = re.compile(r"^\s*-\s+(?P<text>.+?)\s*Confidence:\s*(?P<conf>[0-9]*\.?[0-9]+)\s*$")

TASTE_PROMPT = ("""Another coding tool (Command Code) inferred the preferences below from this user's
sessions. Turn the ones that describe how the user wants coding agents to work into lore items.
Return ONLY a JSON array, nothing else. Each item is an object:
""" + PROMPT[PROMPT.index('  "rule"'):]).replace("User messages (one per block):", "Inferred preferences (one per block):")


def taste_files(roots):
    """Every taste.md inside a .commandcode/taste folder under the roots. Outside such a folder
    the walk stops at a fixed depth and skips hidden and build folders."""
    marker = f"{os.sep}.commandcode{os.sep}taste"
    found = set()
    for root in roots:
        root = os.path.expanduser(root.strip())
        if not root or not os.path.isdir(root):
            continue
        base = root.rstrip(os.sep).count(os.sep)
        for dirpath, dirnames, filenames in os.walk(root):
            inside = marker in dirpath + os.sep
            if inside and "taste.md" in filenames:
                found.add(os.path.realpath(os.path.join(dirpath, "taste.md")))
            if inside:
                continue   # everything below a taste folder is taste
            if dirpath.count(os.sep) - base >= TASTE_DEPTH:
                dirnames[:] = []
                continue
            dirnames[:] = [d for d in dirnames if d not in TASTE_SKIP and (not d.startswith(".") or d == ".commandcode")
                           and not (dirpath.endswith(f"{os.sep}.commandcode") and d != "taste")]
    return sorted(found)


def taste_entries(path):
    """(text, confidence) for each entry line in one taste file; index stubs have none."""
    out = []
    with open(path, errors="replace") as f:
        for line in f:
            m = TASTE_LINE.match(line)
            if m:
                try:
                    out.append((" ".join(m.group("text").split()).rstrip("."), float(m.group("conf"))))
                except ValueError:
                    pass
    return out


def project_of(path):
    """The project folder a taste file belongs to, or None for the global taste."""
    marker = f"{os.sep}.commandcode{os.sep}"
    i = path.find(marker)
    if i == -1 or os.path.realpath(path).startswith(os.path.realpath(os.path.expanduser("~/.commandcode"))):
        return None
    return path[:i]


def learn_taste(store, args):
    lockf = open(store.path(".harvest.lock"), "w")
    try:
        fcntl.flock(lockf, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise lore.LoreError("a harvest is running; try again when it ends")
    hosts = {h["name"]: h for h in lore.load_hosts()}
    roots = args.root or store.config().get("taste_roots", TASTE_ROOTS_DEFAULT).split(",")
    day = lore.today(args)
    state = load_state(store)
    seen = state.setdefault("taste", {})
    fresh, files = [], taste_files(roots)
    for path in files:
        known = seen.setdefault(path, {})
        for text, conf in taste_entries(path):
            key = lore.entry_id(text + ".")
            if key in known and conf <= known[key]:
                continue   # unchanged since the last run: not a new sighting
            fresh.append((path, text, conf, key))
    print(f"taste: {len(files)} file(s), {len(fresh)} new or strengthened entr{'y' if len(fresh) == 1 else 'ies'}")
    if not fresh:
        store.write_atomic("harvest-state.json", json.dumps(state, indent=1, sort_keys=True) + "\n")
        return
    labelled = []
    for i, (path, text, conf, _) in enumerate(fresh):
        proj = project_of(path)
        labelled.append((i, f"[{'project ' + os.path.basename(proj) if proj else 'global'}, confidence {conf:.2f}] "
                            + lore.redact(text)))
    chain = model_chain(store, hosts, "extract", "extractors", EXTRACTORS_DEFAULT, "LORE_EXTRACT_CMD")
    cats = ", ".join(store.categories()) or "workflow, verification, git, communication, ui, tools, safety, orchestration"
    added, failure = 0, None
    for batch in batches(labelled):
        known_rules = "\n".join(f"{e.id}: {e.text}" for e in list(store.all_confirmed().values()) + store.read_candidates())
        prompt = TASTE_PROMPT.format(cats=cats, known=known_rules[:KNOWN_MAX] or "(none yet)",
                                     messages="\n".join("---\n" + b for _, b in batch))
        try:
            items = run_chain(chain, prompt, "extract")
        except ExtractError as err:
            failure = err
            break
        with store.locked():
            added += apply_items(store, items, day, "taste")
        for i, _ in batch:   # recorded only once its batch was extracted
            path, _, conf, key = fresh[i]
            seen[path][key] = conf
        store.write_atomic("harvest-state.json", json.dumps(state, indent=1, sort_keys=True) + "\n")
    with store.locked():
        report = lore.maintain(store, day)
        lore.regenerate_index(store, day)
    lore.deliver_quietly(store)
    if failure:
        raise lore.LoreError(f"taste harvest stopped, unfinished entries not recorded: {failure}")
    print(f"taste: {added} item(s) applied; promoted={report['promoted']}")


# ---- daily review -----------------------------------------------------------------------------

REVIEWERS_DEFAULT = "claude,codex"
CONTEXT_MAX = 8000

REVIEW_PROMPT = """You review an automatic memory of how one user wants coding agents to work. It is
loaded into every agent session on every machine, so a wrong, vague or duplicated rule costs more
than a missing one. Return ONLY a JSON array of operations, nothing else:
  {{"op":"merge","ids":["<id>","<id>"],"text":"<one rule>","category":"<name>","reason":"<why>"}}
      for near-duplicates
  {{"op":"rewrite","id":"<id>","text":"<rule>","category":"<name>","reason":"<why>"}}
      for a vague rule, a wrong category, or one side of a contradiction: rewrite contradicting
      rules so each says when it applies
  {{"op":"reject","id":"<id>","reason":"<why>"}}
      for anything that is not a durable cross-project preference or lesson: a one-off
      instruction, a fact about one project, a secret or personal data, or a clearly wrong rule
Use only the ids listed under "To review"; the other rules are context. Never invent a rule the
user did not express. Leave good entries alone. Each rule is one imperative sentence under 25
words. Return [] when everything is fine.

To review (id [category] confidence, days seen: rule  | user's words):
{review}

Other rules already in memory, for context (id: rule):
{context}
"""


def review_targets(store, reviewed):
    """Candidates, plus confirmed rules not reviewed yet or seen again since their review.
    `reviewed` maps an id to the last-seen date it had when it was reviewed."""
    cands = store.read_candidates()
    fresh = [e for e in store.all_confirmed().values() if reviewed.get(e.id) != e.last]
    return cands + fresh


def _load_all(store):
    cats = {c: list(store.read_category(c)) for c in store.categories()}
    return cats, store.read_candidates()


def _locate(cats, cands, eid):
    for c, (_, _, entries) in cats.items():
        for e in entries:
            if e.id == eid:
                return "cat", c, e
    for e in cands:
        if e.id == eid:
            return "cand", e.cat, e
    return None


def _remove(cats, cands, loc):
    kind, cat, e = loc
    if kind == "cat":
        cats[cat][2].remove(e)
    else:
        cands.remove(e)


def _place(cats, cands, e, confirmed, cat):
    e.cat = cat
    if confirmed:
        if cat not in cats:
            cats[cat] = [cat.replace("-", " ").capitalize(), f"the task touches {cat}", []]
        cats[cat][2].append(e)
    else:
        cands.append(e)


def _clean_cat(value, fallback):
    c = str(value or fallback).strip().lower().replace(" ", "-")
    return c if lore.CATEGORY_RE.match(c) and c not in lore.RESERVED else fallback


def apply_review_ops(store, ops, allowed):
    """Apply review operations to ids in `allowed` only. Returns the log lines of what changed."""
    cats, cands = _load_all(store)
    blocked = store.blocklist()
    done = []
    for op in ops:
        kind = op.get("op")
        why = " ".join(str(op.get("reason") or "").split())[:160]
        try:
            if kind == "reject":
                eid = str(op.get("id"))
                loc = _locate(cats, cands, eid) if eid in allowed else None
                if not loc:
                    continue
                _remove(cats, cands, loc)
                done.append(f"reject {eid} ({why}): {loc[2].text}")
            elif kind in ("rewrite", "merge"):
                ids = [str(op.get("id"))] if kind == "rewrite" else [str(i) for i in op.get("ids") or []]
                locs = [_locate(cats, cands, i) for i in dict.fromkeys(ids) if i in allowed]
                locs = [l for l in locs if l]
                if not locs or (kind == "merge" and len(locs) < 2):
                    continue
                text = lore.tidy_text(str(op.get("text") or ""))
                new_id = lore.entry_id(text)
                old = [l[2] for l in locs]
                # Check the whole operation before touching anything: a refused one changes nothing.
                if new_id in blocked or lore.SECRET_RE.search(text):
                    log(f"review: refused {kind} of {','.join(e.id for e in old)} onto blocked or secret-looking text ({why})")
                    continue
                for l in locs:
                    _remove(cats, cands, l)
                existing = _locate(cats, cands, new_id)
                if existing:   # the rewritten text is already a rule: fold into it
                    _remove(cats, cands, existing)
                    old.append(existing[2])
                confirmed = any(l[0] == "cat" for l in locs) or bool(existing and existing[0] == "cat")
                base = max(old, key=lambda e: e.conf)
                firsts = [x.first for x in old if x.first]
                e = lore.Entry(text, max(x.conf for x in old), id=new_id,
                               first=min(firsts) if firsts else "", last=max(x.last for x in old),
                               days=max(x.days for x in old), n=sum(x.n for x in old),
                               decayed=base.decayed, promoted=max((x.promoted for x in old), default=""),
                               src=next((x.src for x in old if x.src), ""),
                               flags=",".join(sorted(set().union(*[x.flags for x in old]))))
                union = set().union(*[x.dates for x in old])
                e.days = max(e.days, len(union))
                e.dates = set(sorted(union)[-lore.DATES_KEPT:])
                _place(cats, cands, e, confirmed, _clean_cat(op.get("category"), base.cat or "workflow"))
                done.append(f"{kind} {','.join(x.id for x in old)} -> {new_id} ({why}): {text}")
        except (lore.LoreError, TypeError, ValueError) as err:
            log(f"review: skipped an operation ({err})")
    if done:
        for cat, (title, rw, entries) in cats.items():
            store.write_category(cat, title, rw, entries)
        store.write_candidates(cands)
    return done


def run_review(store, hosts, state, day, force=False):
    """The once-a-day review; sets state['last_review'] only when it completed."""
    if not force and state.get("last_review") == day.isoformat():
        return "already reviewed today"
    reviewed = state.setdefault("reviewed", {})
    targets = review_targets(store, reviewed)
    if not targets:
        state["last_review"] = day.isoformat()
        return "nothing to review"
    allowed = {e.id for e in targets}
    review = "\n".join(f"{e.id} [{e.cat}] {e.conf:.2f}, {e.days}d: {e.text}" + (f"  | {e.src}" if e.src else "")
                       for e in targets)
    context = "\n".join(f"{e.id}: {e.text}" for e in store.all_confirmed().values()
                        if e.id not in allowed)[:CONTEXT_MAX] or "(none)"
    chain = model_chain(store, hosts, "review", "reviewers", REVIEWERS_DEFAULT, "LORE_REVIEW_CMD")
    ops = run_chain(chain, REVIEW_PROMPT.format(review=review, context=context), "review")
    with store.locked():
        done = apply_review_ops(store, ops, allowed)
        if done:
            lore.maintain(store, day)
            lore.regenerate_index(store, day)
    with open(store.path("review.log"), "a") as f:
        f.write(f"## {day.isoformat()}: {len(targets)} reviewed, {len(done)} changed\n")
        for line in done:
            f.write(f"- {line}\n")
    if done:
        try:
            lore.cmd_deliver(store, _Args(host=None, check=False, remove=False))
        except lore.LoreError as err:
            log(f"deliver: {err}")
    state["last_review"] = day.isoformat()
    state["reviewed"] = {e.id: e.last for e in store.all_confirmed().values()}   # as they stand now
    return f"{len(targets)} reviewed, {len(done)} changed"


def review(store, args):
    lockf = open(store.path(".harvest.lock"), "w")
    try:
        fcntl.flock(lockf, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise lore.LoreError("a harvest is running; try again when it ends")
    hosts = {h["name"]: h for h in lore.load_hosts()}
    state = load_state(store)
    try:
        print("review: " + run_review(store, hosts, state, lore.today(args), force=args.force))
    except ExtractError as err:
        raise lore.LoreError(f"review failed: {err}")
    finally:
        store.write_atomic("harvest-state.json", json.dumps(state, indent=1, sort_keys=True) + "\n")


# ---- hook install -----------------------------------------------------------------------------

HOOK_SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lore-hook.sh")
HOOK_MARK = "lore-hook.sh"


def _hook_command(host, event):
    return f"bash '{HOOK_SCRIPT}' {host['name']} {event}"


def _is_ours(handler):
    return isinstance(handler, dict) and HOOK_MARK in str(handler.get("command", ""))


def _without_ours(obj, fmt):
    if fmt == "agy":
        obj.pop("lore", None)
        return obj
    hooks = obj.get("hooks")
    if not isinstance(hooks, dict):
        return obj
    for event in list(hooks):
        groups = hooks[event]
        if not isinstance(groups, list):
            continue
        kept = []
        for g in groups:
            if isinstance(g, dict) and isinstance(g.get("hooks"), list):
                g = dict(g, hooks=[h for h in g["hooks"] if not _is_ours(h)])
                if not g["hooks"]:
                    continue
            kept.append(g)
        if kept:
            hooks[event] = kept
        else:
            del hooks[event]
    if not hooks:
        del obj["hooks"]
    return obj


def _with_ours(obj, host):
    fmt = host.get("hooks_format", "claude")
    obj = _without_ours(obj, fmt)
    events = [e.strip() for e in host.get("hook_events", "").split(",") if e.strip()]
    if fmt == "agy":
        obj["lore"] = {e: [{"type": "command", "command": _hook_command(host, e), "timeout": 10}] for e in events}
        return obj
    hooks = obj.setdefault("hooks", {})
    for e in events:
        hooks.setdefault(e, []).append(
            {"hooks": [{"type": "command", "command": _hook_command(host, e), "timeout": 10}]})
    return obj


def hooks(store, args):
    for host in lore.load_hosts(args.host):
        name = host["name"]
        if not os.path.isdir(os.path.expanduser(host["home_dir"])):
            print(f"{name}: skipped, not installed ({host['home_dir']} absent)")
            continue
        if not host.get("hooks_file"):
            print(f"{name}: no hooks_file in its adapter")
            continue
        path = os.path.expanduser(host["hooks_file"])
        try:
            with open(path) as f:
                raw = f.read()
            obj = json.loads(raw) if raw.strip() else {}
        except FileNotFoundError:
            raw, obj = "", {}
        except ValueError:
            raise lore.LoreError(f"{name}: {path} is not valid JSON; fix it by hand")
        if not isinstance(obj, dict):
            raise lore.LoreError(f"{name}: {path} is not a JSON object")
        fmt = host.get("hooks_format", "claude")
        if args.action == "check":
            want = json.dumps(_with_ours(json.loads(json.dumps(obj)), host), sort_keys=True)
            have = json.dumps(obj, sort_keys=True)
            print(f"{name}: {'installed' if want == have else 'missing or stale'} ({path})")
            if want != have:
                args.stale = True
            continue
        new = _without_ours(obj, fmt) if args.action == "remove" else _with_ours(obj, host)
        out = json.dumps(new, indent=2, ensure_ascii=False) + "\n"
        if out == raw or (args.action == "remove" and not raw):
            print(f"{name}: unchanged ({path})")
            continue
        os.makedirs(os.path.dirname(path), exist_ok=True)
        lore.write_beside(path, out)
        print(f"{name}: hooks {'removed from' if args.action == 'remove' else 'installed in'} {path}")
        if name == "codex" and args.action == "install":
            print("codex: open /hooks once in Codex and trust lore's hooks; until then the session-start sweep covers it")
    if getattr(args, "stale", False):
        raise lore.LoreError("hooks missing or stale; run hooks install")
