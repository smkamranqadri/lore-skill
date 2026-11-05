"""lore sync: keep the memory of several machines the same through a notes hub (Tartib).

Scripts cannot reach the hub (no token; the hub is an MCP). An agent session that has the hub's
MCP runs commands/sync.md, which moves files between the hub and a folder. A timer starts that
session headless (sync-run), only when the free gate says a sync is needed; this module does the
part that must be exact:

  sync-run      the gate: skip for free, or run the headless agent; every call is logged
  sync-log      summarise that log, to tune the timer interval
  sync-timer    install, remove or check the systemd user timer that calls sync-run

  sync-status   what is due: local files changed since the last sync, and the hub notes seen then
  merge         fold a folder of hub files into the local store
  export        write the store's sync files to a folder, for the agent to push
  sync-done     record the sync, so the index stops asking for one

The merge is order independent and idempotent: entries are matched by id and combined field by
field (highest confidence and counts, earliest first sighting, latest last sighting, union of
flags), blocklists and tombstones are unions, and a tombstone removes an entry unless the entry
was seen again after it. Two machines that merge each other's exports, in either order, end equal.
"""

import datetime as dt
import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

import lore

TITLE_PREFIX = "lore/"
STALE_DAYS = 1
PROFILE = "profile.md"


def sync_names(store):
    names = [f"{c}.md" for c in store.categories()] + ["candidates.md", "blocklist", "tombstones", PROFILE]
    return [n for n in names if os.path.exists(store.path(n))]


def sha(path):
    try:
        with open(path, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()
    except FileNotFoundError:
        return None


def load_state(store):
    try:
        with open(store.path("sync-state.json")) as f:
            st = json.load(f)
    except (FileNotFoundError, ValueError):
        st = {}
    st.setdefault("synced", {})
    st.setdefault("remote", {})
    return st


def changed_files(store, st):
    names = set(sync_names(store)) | set(st["synced"])
    return sorted(n for n in names if sha(store.path(n)) != st["synced"].get(n))


def sync_wanted(store, day):
    if not store.config().get("hub"):
        return False
    st = load_state(store)
    last = st.get("last_sync")
    if not last or (day - lore.parse_date(last)).days >= STALE_DAYS:
        return True
    return bool(changed_files(store, st))


def cmd_sync_status(store, args):
    cfg = store.config()
    st = load_state(store)
    print(json.dumps({
        "hub": cfg.get("hub", ""),
        "space": cfg.get("hub_space", ""),
        "title_prefix": TITLE_PREFIX,
        "due": sync_wanted(store, store.day),
        "last_sync": st.get("last_sync"),
        "push": changed_files(store, st),
        "remote_seen": st["remote"],
    }, indent=1, sort_keys=True))


def cmd_export(store, args):
    out = os.path.abspath(os.path.expanduser(args.out))
    os.makedirs(out, exist_ok=True)
    names = sync_names(store) if not args.only else [n for n in args.only if n in sync_names(store)]
    for n in names:
        shutil.copyfile(store.path(n), os.path.join(out, n))
    print("\n".join(names))


# ---- merge ------------------------------------------------------------------------------------

def _read_dir(rdir):
    """A folder of hub files as (categories, candidates, blocklist, tombstones, profile)."""
    rstore = lore.Store(rdir)
    cats = {c: rstore.read_category(c) for c in rstore.categories()}
    block = _blocklist_lines(rstore)
    return cats, rstore.read_candidates(), block, rstore.tombstones(), _read(os.path.join(rdir, PROFILE))


def _read(path):
    try:
        with open(path) as f:
            return f.read()
    except FileNotFoundError:
        return None


def _blocklist_lines(store):
    out = {}
    try:
        with open(store.path("blocklist")) as f:
            for line in f:
                if line.strip():
                    eid, _, text = line.rstrip("\n").partition("\t")
                    out.setdefault(eid.strip(), text)
    except FileNotFoundError:
        pass
    return out


def combine(a, b):
    """One entry from two copies of the same id; symmetric, so merge order does not matter."""
    lo, hi = sorted([a, b], key=lambda e: (e.text, e.render()))
    firsts = [x for x in (a.first, b.first) if x]
    promoted = [x for x in (a.promoted, b.promoted) if x]
    decayed = [x for x in (a.decayed, b.decayed) if x]
    # Confidence comes from the copy whose state is newest (seen or adjusted last), so a decay or
    # a contradiction on one machine is not undone by a stale, higher copy from the other. Ties
    # take the higher value, which keeps the result the same in either merge order.
    newest = max((a, b), key=lambda x: (max(x.last, x.decayed or x.last), x.conf, x.render()))
    e = lore.Entry(lo.text, newest.conf, id=a.id,
                   first=min(firsts) if firsts else "", last=max(a.last, b.last),
                   days=max(a.days, b.days), n=max(a.n, b.n),
                   decayed=max(decayed) if decayed else "", promoted=min(promoted) if promoted else "",
                   src=lo.src or hi.src, flags=",".join(sorted(a.flags | b.flags)))
    e.cat = lo.cat or hi.cat
    union = a.dates | b.dates
    e.days = max(a.days, b.days, len(union))
    e.dates = set(sorted(union)[-lore.DATES_KEPT:])
    e.sess = set(sorted(a.sess | b.sess)[:lore.DATES_KEPT])
    return e


def merge_entries(local, remote):
    """{id: (confirmed, entry)} from two such maps."""
    out = dict(local)
    for eid, (conf_r, er) in remote.items():
        if eid not in out:
            out[eid] = (conf_r, er)
            continue
        conf_l, el = out[eid]
        e = combine(el, er)
        if conf_l != conf_r:   # confirmed wins, and keeps its own category
            e.cat = (el if conf_l else er).cat
        out[eid] = (conf_l or conf_r, e)
    return out


def _entry_map(cats, cands):
    m = {}
    for c in cands:
        m[c.id] = (False, c)
    for cat, (_, _, entries) in cats.items():
        for e in entries:
            e.cat = cat
            m[e.id] = (True, e)
    return m


def cmd_merge(store, args):
    rdir = os.path.abspath(os.path.expanduser(args.remote))
    if not os.path.isdir(rdir):
        raise lore.LoreError(f"no folder {rdir}")
    rcats, rcands, rblock, rtomb, rprofile = _read_dir(rdir)
    day = store.day
    with store.locked():
        lcats = {c: store.read_category(c) for c in store.categories()}
        merged = merge_entries(_entry_map(lcats, store.read_candidates()), _entry_map(rcats, rcands))
        block = dict(_blocklist_lines(store))
        for k, v in rblock.items():
            block.setdefault(k, v)
        tomb = store.tombstones()
        for k, d in rtomb.items():
            tomb[k] = max(tomb.get(k, ""), d)
        heads = {c: (t, rw) for c, (t, rw, _) in rcats.items()}
        heads.update({c: (t, rw) for c, (t, rw, _) in lcats.items()})
        by_cat, cands = {c: [] for c in heads}, []
        for eid, (confirmed, e) in sorted(merged.items()):
            if eid in block or (eid in tomb and tomb[eid] >= e.last):
                continue
            if confirmed:
                by_cat.setdefault(e.cat, []).append(e)
            else:
                cands.append(e)
        for cat, entries in by_cat.items():
            t, rw = heads.get(cat, (cat.replace("-", " ").capitalize(), f"the task touches {cat}"))
            store.write_category(cat, t, rw, entries)
        store.write_candidates(cands)
        store.write_atomic("blocklist", "".join(f"{k}\t{v}\n" for k, v in sorted(block.items())))
        store.write_atomic("tombstones", "".join(f"{k}\t{d}\n" for k, d in sorted(tomb.items())))
        note = _merge_profile(store, rprofile)
        lore.maintain(store, day)
        lore.regenerate_index(store, day)
    if note:
        print(note)
    try:
        lore.cmd_deliver(store, _Args(host=None, check=False, remove=False))
    except lore.LoreError as err:
        print(f"deliver: {err}")
    print(f"merged: {len(merged)} entries considered")


def _merge_profile(store, remote):
    """profile.md is hand-written, so it is a whole file: take the side that changed since the
    last sync; if both did, keep the local one and save the other beside it."""
    if remote is None:
        return None
    remote = remote.rstrip("\n") + "\n"   # the hub may strip the final newline
    local = _read(store.path(PROFILE))
    if local == remote:
        return None
    base = load_state(store)["synced"].get(PROFILE)
    local_sha = hashlib.sha256((local or "").encode()).hexdigest() if local is not None else None
    if local is None or local_sha == base:
        store.write_atomic(PROFILE, remote)
        return "profile: took the hub's version"
    remote_sha = hashlib.sha256(remote.encode()).hexdigest()
    if remote_sha == base:
        return None   # only the local copy changed; the push sends it
    store.write_atomic("profile.hub.md", remote)
    return "profile: both changed; kept the local one, the hub's is in profile.hub.md"


class _Args:
    def __init__(self, **kw):
        self.__dict__.update(kw)


def cmd_sync_done(store, args):
    remote = {}
    if args.remote_seen:
        with open(os.path.expanduser(args.remote_seen)) as f:
            remote = json.load(f)
        if not isinstance(remote, dict) or not all(isinstance(v, str) for v in remote.values()):
            raise lore.LoreError("--remote-seen must be a JSON object of note title -> updated_at")
    pushed = os.path.abspath(os.path.expanduser(args.pushed))
    if not os.path.isdir(pushed):
        raise lore.LoreError(f"no folder {pushed}")
    with store.locked():
        st = load_state(store)
        # Only the hub versions this sync actually fetched or wrote are recorded; any other note
        # keeps the version seen before, so an edit made elsewhere mid-sync is still pulled later.
        remote = dict(st["remote"], **remote)
        # The hashes of what was pushed, not of the store now: a harvest that ran in between
        # must still show as a change to push next time.
        st["synced"] = {n: sha(os.path.join(pushed, n)) for n in sorted(os.listdir(pushed))
                        if os.path.isfile(os.path.join(pushed, n))}
        st["last_sync"] = store.day.isoformat()
        st["remote"] = remote
        store.write_atomic("sync-state.json", json.dumps(st, indent=1, sort_keys=True) + "\n")
        lore.regenerate_index(store, store.day)
    try:
        lore.cmd_deliver(store, _Args(host=None, check=False, remove=False))
    except lore.LoreError as err:
        print(f"deliver: {err}")
    print(f"sync recorded for {store.day.isoformat()}: {len(st['synced'])} file(s)")


# ---- scheduled run ----------------------------------------------------------------------------

SYNC_TIMEOUT = 300
BACKOFF_MIN = 120   # after a failed run, wait this long before the gate runs the agent again
SYNC_MODELS_DEFAULT = "codex"
RUNS_KEPT = 20
LOG_NAME = "sync-log.jsonl"
UNIT = "lore-sync"


def _now():
    return dt.datetime.now().astimezone().replace(microsecond=0)


def _log_line(store, rec):
    with open(store.path(LOG_NAME), "a") as f:
        f.write(json.dumps(rec, sort_keys=True) + "\n")


def _why(store, st, day):
    """Why a sync is wanted now, or None. Same test as sync_wanted, with the reason."""
    if not store.config().get("hub"):
        return None, "no hub configured"
    last = st.get("last_sync")
    if not last:
        return "never synced", ""
    if (day - lore.parse_date(last)).days >= STALE_DAYS:
        return "last sync " + last, ""
    changed = changed_files(store, st)
    if changed:
        return f"{len(changed)} local change(s)", ""
    return None, "nothing to sync"


def _backing_off(store, now):
    """True when the last logged run failed less than BACKOFF_MIN minutes ago."""
    try:
        with open(store.path(LOG_NAME)) as f:
            lines = [l for l in f if l.strip()]
    except FileNotFoundError:
        return False
    for l in reversed(lines):
        r = json.loads(l)
        if r.get("action") == "fail":
            return (now - dt.datetime.fromisoformat(r["ts"])).total_seconds() < BACKOFF_MIN * 60
        if r.get("action") == "run":
            return False
    return False


def _sync_command(store):
    override = os.environ.get("LORE_SYNC_CMD")
    if override:
        return "override", override
    if store.config().get("sync_cmd"):   # for a machine whose agent CLI needs its own invocation
        return "config", store.config()["sync_cmd"]
    hosts = {h["name"]: h for h in lore.load_hosts()}
    for n in (x.strip() for x in store.config().get("sync_models", SYNC_MODELS_DEFAULT).split(",")):
        h = hosts.get(n)
        if h and h.get("sync") and shutil.which(h["sync"].split()[0]):
            return n, h["sync"]
    return None, None


def _tokens(text):
    m = re.search(r"tokens used\s*\n?\s*([\d,]+)", text)
    return int(m.group(1).replace(",", "")) if m else None


def _keep_runs(store):
    d = store.path("sync-runs")
    names = sorted(os.listdir(d)) if os.path.isdir(d) else []
    for n in names[:-RUNS_KEPT]:
        os.unlink(os.path.join(d, n))


def cmd_sync_run(store, args):
    now = _now()
    rec = {"ts": now.isoformat(), "trigger": args.trigger}
    with open(store.path("sync-run.lock"), "w") as lk:
        try:
            fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            _log_line(store, dict(rec, action="busy"))
            print("sync-run: another run is in progress")
            return
        st = load_state(store)
        reason, skip = _why(store, st, store.day)
        if reason is None and args.force and store.config().get("hub"):
            reason, skip = "forced", ""
        if reason is not None and not args.force and _backing_off(store, now):
            reason, skip = None, f"backing off after a failed run (under {BACKOFF_MIN} min ago)"
        if reason is None:
            _log_line(store, dict(rec, action="skip", reason=skip))
            print(f"sync-run: skipped ({skip})")
            return
        name, command = _sync_command(store)
        if not command:
            _log_line(store, dict(rec, action="fail", reason=reason, error="no sync command available"))
            raise lore.LoreError("no sync command: no host adapter with a 'sync:' line is installed")
        try:
            import lore_hub   # here, not at the top: lore_hub imports this module
            command = lore_hub.resolved_command(command)   # a mise wrapper runs its install, or is refused
        except lore.LoreError as err:
            _log_line(store, dict(rec, action="fail", reason=reason, host=name, error=str(err)))
            raise
        prompt = (f"Follow {lore.SKILL_DIR}/commands/sync.md exactly, now, without asking anything. "
                  "Use the Tartib MCP tools. Reply with one line saying how many notes were pulled and pushed.")
        fd, pf = tempfile.mkstemp(prefix="lore-sync-", suffix=".txt")
        with os.fdopen(fd, "w") as f:
            f.write(prompt)
        env = dict(os.environ, LORE_HARVEST="1", LORE_PROMPT_FILE=pf)
        t0 = time.monotonic()
        out, rc = "", None
        try:
            r = subprocess.run(["sh", "-c", command], env=env, capture_output=True, text=True,
                               timeout=SYNC_TIMEOUT, stdin=subprocess.DEVNULL)
            out, rc = r.stdout + r.stderr, r.returncode
        except subprocess.TimeoutExpired as err:
            out = (err.stdout or b"").decode(errors="replace") if isinstance(err.stdout, bytes) else (err.stdout or "")
            rc = "timeout"
        finally:
            os.unlink(pf)
        secs = round(time.monotonic() - t0, 1)
        after = load_state(store)
        still, _ = _why(store, after, store.day)
        ok = rc == 0 and still is None
        os.makedirs(store.path("sync-runs"), exist_ok=True)
        with open(store.path("sync-runs/" + now.strftime("%Y%m%dT%H%M%S") + ".log"), "w") as f:
            f.write(out)
        _keep_runs(store)
        _log_line(store, dict(rec, action="run" if ok else "fail", reason=reason, host=name, rc=rc,
                              secs=secs, tokens=_tokens(out), pushed=len(changed_files(store, st)),
                              still_due=still is not None))
        print(f"sync-run: {'synced' if ok else 'FAILED'} ({reason}) in {secs}s via {name}")
        if not ok:
            raise lore.LoreError(f"sync run failed (rc {rc}); see sync-runs/ in the store")


def cmd_sync_log(store, args):
    cutoff = (_now() - dt.timedelta(days=args.days)).isoformat()
    rows = []
    try:
        with open(store.path(LOG_NAME)) as f:
            rows = [r for r in (json.loads(l) for l in f if l.strip()) if r.get("ts", "") >= cutoff]
    except FileNotFoundError:
        pass
    by = {}
    for r in rows:
        by[r["action"]] = by.get(r["action"], 0) + 1
    runs = [r for r in rows if r["action"] in ("run", "fail")]
    toks = sum(r.get("tokens") or 0 for r in runs)
    print(f"last {args.days} day(s): {len(rows)} checks")
    for a in ("skip", "run", "fail", "busy"):
        print(f"  {a:<5} {by.get(a, 0)}")
    print(f"  tokens in runs: {toks}" + (f" (about {toks // len(runs)} per run)" if runs else ""))
    if rows:
        skipped = by.get("skip", 0)
        print(f"  {round(100 * skipped / len(rows))}% of checks needed no model call")
    reasons = {}
    for r in runs:
        k = re.sub(r"\d{4}-\d\d-\d\d", "date", r.get("reason", ""))
        reasons[k] = reasons.get(k, 0) + 1
    for k, n in sorted(reasons.items(), key=lambda x: -x[1]):
        print(f"  run reason: {k} x{n}")


def _unit_dir():
    return os.path.expanduser("~/.config/systemd/user")


def cmd_sync_timer(store, args):
    d = _unit_dir()
    svc, tmr = os.path.join(d, UNIT + ".service"), os.path.join(d, UNIT + ".timer")
    script = os.path.join(lore.SKILL_DIR, "scripts", "lore.py")
    if args.action == "check":
        print(f"{svc}: {'present' if os.path.exists(svc) else 'missing'}")
        state = "missing"
        if os.path.exists(tmr):
            with open(tmr) as f:
                old = any(l.startswith("OnBootSec=") for l in f.read().splitlines())
            state = "out of date (OnBootSec never fires after a late login; run sync-timer install)" if old else "present"
        print(f"{tmr}: {state}")
        return
    sysctl = shutil.which("systemctl")
    if args.action == "remove":
        if sysctl:
            subprocess.run([sysctl, "--user", "disable", "--now", UNIT + ".timer"], capture_output=True)
        for f in (svc, tmr):
            if os.path.exists(f):
                os.unlink(f)
        if sysctl:
            subprocess.run([sysctl, "--user", "daemon-reload"], capture_output=True)
        print("lore sync timer removed")
        return
    if not re.fullmatch(r"\d+(min|h)", args.every):
        raise lore.LoreError("--every must look like 30min or 2h")
    os.makedirs(d, exist_ok=True)
    path = os.environ.get("PATH", "")
    with open(svc, "w") as f:
        f.write("[Unit]\nDescription=lore memory sync (gated; starts a model only when needed)\n\n"
                f"[Service]\nType=oneshot\nEnvironment=\"PATH={path}\"\n"
                f"ExecStart={sys.executable} {script} --store {store.root} sync-run\n")
    with open(tmr, "w") as f:
        f.write("[Unit]\nDescription=lore memory sync timer\n\n"
                f"[Timer]\nOnStartupSec=2min\nOnUnitActiveSec={args.every}\nPersistent=true\n\n"
                "[Install]\nWantedBy=timers.target\n")
    if sysctl:
        subprocess.run([sysctl, "--user", "daemon-reload"], check=True)
        subprocess.run([sysctl, "--user", "enable", "--now", UNIT + ".timer"], check=True)
        print(f"lore sync timer installed: every {args.every}")
    else:
        print(f"units written to {d}; no systemctl here, so enable them yourself or use cron")
