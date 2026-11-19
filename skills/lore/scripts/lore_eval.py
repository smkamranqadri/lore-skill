"""lore 2.0 eval: `lore eval loremaster|canon` measures the plan's quality bars on a frozen fixture.

Each run builds its own temporary store (a local git identity, no hub) and never opens the owner's
store: a path argument that is, holds or sits inside a store is refused, and so is --store2.
`loremaster` queues the fixture's rules the way `lore remember` does and files them through
lore_master.file_items with the role's model, in batches. It then measures the folder, oversized
and related bars and writes the meaning spot-check sheet; the tool never judges meaning. `canon`
copies the Canon fixture (every lint gate seeded once) into the temp store, runs Canon once through
the role's model, as `lore canon --force` does, and re-lints the whole store: a seeded gate is fixed
only when none of its findings remains anywhere, and a finding that was not seeded fails the bar. A
failing reply, or one the validator rejects, fails the run and is reported, never retried (a
Loremaster run stops at the first rejected batch). Exit 0: every bar the tool can compute is met;
1: one is not; 2: the run failed or did not start. The report is written whenever the run started.
Standard library only.
"""

import contextlib
import datetime as dt
import hashlib
import json
import os
import shutil
import sys
import tempfile
import time
from fractions import Fraction

import lore
import lore_canon
import lore_eval_attribution
import lore_hub
import lore_lint
import lore_master
import lore_store

# The plan's fixed bars (2.0 plan, Acceptance): reported as measured fractions, never moved.
FOLDER_MIN = Fraction(9, 10)    # fixture rules filed in their expected top-level folder, over all rules
RELATED_MIN = Fraction(4, 5)    # expected related pairs linked (or in one file), over expected pairs
OVERSIZED_MAX = 0               # topic files lint's oversized gate reports after filing
MEANING_N = 15                  # spot-checked rules; all 15 must keep their meaning, judged by the owner

EXIT_MET, EXIT_MISSED, EXIT_FAILED = 0, 1, 2
BATCH = 10   # fixture rules per Loremaster call: several calls, so the size cap and file selection get exercised
FIXED_DAY = dt.date(2026, 10, 1)   # the store's "today": the Canon fixture's ages are relative to it
FOLDERS = ("how-i-work", "preferences", "safety", "stack", "gotchas", "profile.md")
FIXTURE = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..",
                                        "tests", "fixtures", "eval"))
TOKEN_BASIS = "estimate: prompt and reply characters over four; the host CLIs report no token counts"


# ---- the fixture ------------------------------------------------------------------------------

def fixture_hash(root):
    """sha256 over `<sha256>  ./<path>` lines of every file under root, sorted by path: the same
    bytes as `find . -type f | LC_ALL=C sort | xargs sha256sum | sha256sum` run inside root."""
    lines = []
    for d, _, names in os.walk(root):
        for fn in names:
            p = os.path.join(d, fn)
            with open(p, "rb") as f:
                lines.append((os.path.relpath(p, root).replace(os.sep, "/"), hashlib.sha256(f.read()).hexdigest()))
    return hashlib.sha256("".join(f"{h}  ./{rel}\n" for rel, h in sorted(lines)).encode()).hexdigest()


def load_rules(root):
    """The Loremaster fixture's rules, checked: a defect in the answer key is reported, never patched."""
    try:
        with open(os.path.join(root, "rules.json")) as f:
            rules = json.load(f)
    except (OSError, ValueError) as err:
        raise lore.LoreError(f"fixture rules.json is unreadable: {err}")
    if not isinstance(rules, list) or not rules:
        raise lore.LoreError("fixture rules.json is not a non-empty list")
    ids = set()
    for r in rules:
        ok = (isinstance(r, dict) and isinstance(r.get("id"), str) and isinstance(r.get("text"), str)
              and isinstance(r.get("explicit"), bool) and isinstance(r.get("related"), list))
        if not ok:
            raise lore.LoreError(f"fixture rule is malformed: {str(r)[:80]}")
        if r["id"] in ids:
            raise lore.LoreError(f"fixture has a duplicate id: {r['id']}")
        if r.get("folder") not in FOLDERS:
            raise lore.LoreError(f"fixture rule {r['id']} expects a folder that does not exist: {r.get('folder')!r}")
        ids.add(r["id"])
    for r in rules:
        for other in r["related"]:
            if other not in ids or other == r["id"]:
                raise lore.LoreError(f"fixture rule {r['id']} lists an unknown or own related id: {other!r}")
    return rules


def pairs_of(rules):
    """The expected related pairs, each once, as sorted id tuples."""
    return sorted({tuple(sorted((r["id"], o))) for r in rules for o in r["related"]})


def spot_ids(rules, n=MEANING_N):
    """The meaning spot-check: the first n ids by sha1 of the id, a fixed choice."""
    return sorted((r["id"] for r in rules), key=lambda i: hashlib.sha1(i.encode()).hexdigest())[:n]


# ---- isolation --------------------------------------------------------------------------------

def _real(path):
    return os.path.realpath(os.path.abspath(os.path.expanduser(path)))


def _inside(path, base):
    return path == base or path.startswith(base.rstrip(os.sep) + os.sep)


def owner_stores():
    """Both places the owner's store can be: the default under the current HOME and the LORE_STORE2
    override. Both stay protected whichever is selected, and whether or not either exists yet.
    _real resolves symlinks of the deepest existing ancestor and keeps the parts that do not exist."""
    return {_real(os.path.join("~", ".agents", "lore")), _real(lore_store.store_root())}


def refuse_owner_store(path, what):
    """The eval never builds in, writes to or reads the owner's store, even one that does not exist yet."""
    real = _real(path)
    if any(_inside(real, base) for base in owner_stores()):
        raise lore.LoreError(f"refused: {what} {path} is or is inside the owner's store; the eval builds its own")


def refuse_existing_store(path, what):
    """A path that is, or sits inside, a lore store is never used."""
    p = _real(path)
    if os.path.isdir(os.path.join(p, ".git")) or os.path.isfile(os.path.join(p, ".lore", "layout.json")):
        raise lore.LoreError(f"refused: {what} {path} is an existing store; the eval builds its own")
    while os.path.dirname(p) != p:
        p = os.path.dirname(p)
        if os.path.isfile(os.path.join(p, ".lore", "layout.json")):
            raise lore.LoreError(f"refused: {what} {path} is inside the existing store {p}; the eval builds its own")


def check_dir(path, what):
    """Why a directory may not be the eval's own: the owner's store, an existing store, or not empty."""
    refuse_owner_store(path, what)
    refuse_existing_store(path, what)
    if os.path.exists(path) and (not os.path.isdir(path) or os.listdir(path)):
        raise lore.LoreError(f"refused: {what} {path} exists and is not an empty directory")


def fresh_dir(path, what):
    """An empty or new directory for the eval's own use."""
    check_dir(path, what)
    os.makedirs(path, exist_ok=True)
    return path


@contextlib.contextmanager
def temp_store(workdir=None):
    """A new store with a local git identity and no hub, removed afterwards (a --workdir is kept)."""
    tmp = None
    if workdir:
        root = fresh_dir(workdir, "--workdir")
    else:
        tmp = tempfile.mkdtemp(prefix="lore-eval-")
        root = os.path.join(tmp, "store")
        refuse_owner_store(root, "the temporary store")
    try:
        store = lore_store.Store2(root, day=FIXED_DAY)
        lore_store.init_store(store)
        yield store
    finally:
        if tmp:
            shutil.rmtree(tmp, ignore_errors=True)


# ---- the model --------------------------------------------------------------------------------

class Meter:
    """Counts a role's calls and the characters going in and out (the token estimate)."""

    def __init__(self):
        self.calls = self.prompt = self.reply = 0

    def wrap(self, model):
        def run(prompt):
            self.calls += 1
            self.prompt += len(prompt)
            reply = model(prompt)
            self.reply += len(reply or "")
            return reply
        return run

    def tokens(self):
        prompt, reply = self.prompt // 4, self.reply // 4
        return {"prompt": prompt, "reply": reply, "total": prompt + reply, "basis": TOKEN_BASIS}


def role_info(store, role):
    """The role's model as it will run: name, the command line and its resolved form."""
    name, command = lore_hub.role_command(store, role)
    if not command:
        raise lore.LoreError(f"no {role} command: no host adapter with a '{role}:' line is installed")
    try:
        resolved = lore_hub.absolute_command(command)
    except lore.LoreError:
        resolved = None   # the run itself fails with the reason
    return {"name": name, "command": lore.redact(command), "resolved": lore.redact(resolved) if resolved else None}


def failure(err):
    return f"{type(err).__name__}: {lore.redact(str(err))}"[:400]


# ---- the Loremaster eval ----------------------------------------------------------------------

def queue_items(store, rules):
    """Queue each rule as `lore remember` does (no quote, session "eval"); the items in queue order."""
    d = lore_hub.private_dir(lore_hub.remember_dir(store))
    for n, r in enumerate(rules, 1):
        item = {"text": " ".join(r["text"].split()), "explicit": r["explicit"], "quote": "", "session": "eval",
                "host": "eval", "created": lore_store.now_iso()}
        lore_hub.write_private(os.path.join(d, f"eval-{n:04d}.json"), json.dumps(item, sort_keys=True) + "\n")
    items, notes = lore_hub.queued_items(store)
    if notes or len(items) != len(rules):
        raise lore.LoreError(f"queued {len(items)} of {len(rules)} items: {'; '.join(notes)}")
    return [it for _, it in items]


def top_of(rel):
    return rel.split("/", 1)[0] if "/" in rel else rel


def filed_places(store, rules):
    """({rule id: [(file, filed wording)]}, the model of the store): a fixture rule is found by the
    original quote its entry keeps, which the Loremaster copies from the item's words."""
    m = lore_master._Model(store)
    by_quote = {}
    for rel in m.files:
        for entry in m.entries(rel).values():
            by_quote.setdefault(lore.normalise(lore_master.original_quote(entry)), []).append((rel, entry.get("text", "")))
    return {r["id"]: by_quote.get(lore.normalise(r["text"]), []) for r in rules}, m


def pair_status(a, b, links):
    """How an expected pair ended up: in one file, linked either way, not linked, or a side is unfiled."""
    fa, fb = {f for f, _ in a}, {f for f, _ in b}
    if not fa or not fb:
        return "unfiled"
    if fa & fb:
        return "same file"
    if any(y in links.get(x, ()) or x in links.get(y, ()) for x in fa for y in fb):
        return "linked"
    return "not linked"


def met(n, d, floor):
    return d > 0 and Fraction(n, d) >= floor


def bar(n, d, need, ok):
    return {"n": n, "d": d, "percent": round(100 * n / d, 1) if d else None, "need": need, "met": ok}


def measure_loremaster(store, rules, where=None):
    """The bars, per-rule and per-pair detail and the spot-check rows, from the store after filing."""
    direct, m = filed_places(store, rules)
    where = direct if where is None else where
    detail, right = [], 0
    for r in rules:
        files = sorted({f for f, _ in where[r["id"]]})
        ok = bool(files) and all(top_of(f) == r["folder"] for f in files)
        right += ok
        detail.append({"id": r["id"], "expected": r["folder"], "filed": files, "ok": ok})
    links = {rel: m.links(rel) for rel in m.files}
    pairs = [{"pair": list(p), "status": pair_status(where[p[0]], where[p[1]], links)} for p in pairs_of(rules)]
    linked = sum(p["status"] in ("same file", "linked") for p in pairs)
    findings = lore_lint.lint(store)
    over = sorted(f["file"] for f in findings if f["gate"] == "oversized")
    topics = [rel for rel in m.files if rel != "core.md"]
    gates = {}
    for f in findings:
        gates[f["gate"]] = gates.get(f["gate"], 0) + 1
    bars = {
        "folder": bar(right, len(rules), f"at least {FOLDER_MIN.numerator * 100 // FOLDER_MIN.denominator}%",
                      met(right, len(rules), FOLDER_MIN)),
        "oversized": bar(len(over), len(topics), f"at most {OVERSIZED_MAX} files", len(over) <= OVERSIZED_MAX),
        "related": bar(linked, len(pairs), f"at least {RELATED_MIN.numerator * 100 // RELATED_MIN.denominator}%",
                       met(linked, len(pairs), RELATED_MIN)),
        "meaning": {"n": None, "d": MEANING_N, "need": f"{MEANING_N} of {MEANING_N}, judged by the owner",
                    "met": None, "status": "the owner fills in spot-check.md"},
    }
    ids = spot_ids(rules)
    by_id = {r["id"]: r for r in rules}
    rows = [{"id": i, "original": by_id[i]["text"], "filed": [{"file": f, "text": t} for f, t in where[i]]}
            for i in ids]
    info = {"oversized_files": over, "lint_after": gates, "rules_in_core": sum(
                1 for r in rules if any(f == "core.md" for f, _ in where[r["id"]])),
            "unfiled": [r["id"] for r in rules if not where[r["id"]]]}
    return bars, detail, pairs, rows, info



def run_loremaster(fixture, batch, workdir=None):
    """(report, spot-check sheet or None) of one Loremaster run."""
    report = {"role": "loremaster", "status": "failed", "error": None, "rejected": [], "batch_size": batch,
              "fixture": {"path": fixture, "sha256": fixture_hash(fixture)}}
    t0, meter, batches, sheet = time.monotonic(), Meter(), [], None
    try:
        rules = load_rules(fixture)
        report["fixture"].update(rules=len(rules), expected_pairs=len(pairs_of(rules)))
        with temp_store(workdir) as store:
            report["model"] = role_info(store, "loremaster")
            items = queue_items(store, rules)
            model = meter.wrap(lore_hub.run_model(store, "loremaster"))
            claims = lore_eval_attribution.Claims()
            for n in range(0, len(items), batch):
                chunk = items[n:n + batch]
                res = lore_master.file_items(store, chunk, claims.wrap(model, rules[n:n + batch], store, chunk), source="eval")
                batches.append({"batch": n // batch + 1, "items": len(chunk), "commit": res["commit"],
                                "files_changed": len(res["changed"]), "inbox": len(res["inbox"]),
                                "rejected": [lore.redact(str(x)) for x in res["rejected"][:5]]})
                if res["rejected"]:   # the real path refuses this reply: a failed run, and no more calls
                    report["rejected"] = batches[-1]["rejected"]
                    raise lore.LoreError(f"the validator rejected the reply to batch {n // batch + 1}: "
                                         + "; ".join(report["rejected"]))
            direct, identities = claims.direct(store, rules)
            bars, detail, pairs, rows, info = measure_loremaster(store, rules, direct)
            report.update(bars=bars, rules=detail, pairs=pairs, **info)
            where, candidates = claims.resolve(store, rules, direct, identities)
            adjusted, adjusted_rules, adjusted_pairs, rows, _ = measure_loremaster(store, rules, where)
            links = lore_master._Model(store)
            report.update(provisional={"bars": adjusted, "rules": adjusted_rules, "pairs": adjusted_pairs,
                                       "candidates": candidates, "links": {f: sorted(links.links(f)) for f in links.files}})
            report["spot_check"] = [r["id"] for r in rows]
            sheet = lore_eval_attribution.spot_sheet(rows, candidates)
            report["status"] = "ok"
    except Exception as err:   # a model error, an unparseable reply: reported, and the run is a failure
        report["error"] = failure(err)
    report.update(batches=batches, calls=meter.calls, tokens=meter.tokens(),
                  wall_seconds=round(time.monotonic() - t0, 1))
    return report, sheet


# ---- the Canon eval ---------------------------------------------------------------------------

def load_expect(fixture):
    try:
        with open(os.path.join(fixture, "canon", "expect.json")) as f:
            expect = json.load(f)
        gates = expect["gates"]
        if not isinstance(gates, dict) or not gates or any(g not in lore_lint.GATES for g in gates):
            raise ValueError("gates")
        for g in gates.values():
            if not isinstance(g.get("file"), str) or not isinstance(g.get("inbox"), bool):
                raise ValueError("gate entry")
    except (OSError, ValueError, KeyError, TypeError) as err:
        raise lore.LoreError(f"fixture canon/expect.json is unreadable or malformed: {err}")
    return expect


def copy_canon(store, fixture):
    """The Canon fixture's tree (not expect.json) into the temp store, committed, so Canon's checkout has it."""
    src = os.path.join(fixture, "canon")
    for d, _, names in os.walk(src):
        for fn in names:
            if d == src and fn == "expect.json":
                continue
            to = os.path.join(store.root, os.path.relpath(os.path.join(d, fn), src))
            os.makedirs(os.path.dirname(to), exist_ok=True)
            shutil.copyfile(os.path.join(d, fn), to)
    lore_store.tidy(store)
    lore_store.commit(store, "eval fixture")


RULE_GATES = ("contradiction", "duplicate")   # findings about particular rules; the others are about a file


def ident(f):
    """One finding's identity: its gate, its file and what singles it out inside the file: the rule
    ids for a finding about rules (two duplicate pairs in one file are two findings), the link
    target for a broken link. A file-level finding keeps no rule ids: lint derives them (the
    core rules dropped, the rules of a thin file), and they change as the file does."""
    ids = tuple(sorted(f["rule_ids"])) if f["gate"] in RULE_GATES else ()
    return (f["gate"], f["file"], ids, f["detail"] if f["gate"] == "broken-link" else "")


def idents_of(findings):
    return {ident(f) for f in findings}


def name_of(i):
    gate, file, ids, _ = i
    return " ".join([gate, file] + ([f"({', '.join(ids)})"] if ids else []))


def run_canon(fixture, workdir=None):
    """The report of one Canon run."""
    report = {"role": "canon", "status": "failed", "error": None, "rejected": [],
              "fixture": {"path": fixture, "sha256": fixture_hash(fixture)}}
    t0, meter = time.monotonic(), Meter()
    try:
        expect = load_expect(fixture)
        report["fixture"]["gates"] = len(expect["gates"])
        with temp_store(workdir) as store:
            report["model"] = role_info(store, "canon")
            copy_canon(store, fixture)
            base = lore_lint.lint(store)
            want = {(g, v["file"]) for g, v in expect["gates"].items()}
            if {i[:2] for i in idents_of(base)} != want or len(base) != len(want):
                raise lore.LoreError("the fixture does not seed every gate once and nothing else: lint finds "
                                     + ", ".join(f"{f['gate']} {f['file']}" for f in base))
            with store.locked():
                lore_store.begin(store)
                res = lore_canon.run(store, lore_canon.held(store, base)["kept"],
                                     meter.wrap(lore_hub.run_model(store, "canon")))
            report["rejected"] = [lore.redact(str(x)) for x in res["rejected"][:5]]
            if res["rejected"]:   # the real path refuses this reply: a failed run
                raise lore.LoreError("the validator rejected Canon's reply: " + "; ".join(report["rejected"]))
            # Judged on the whole store after the run, finding by finding, never on the seeded
            # (gate, file): a finding that moved to another file is still there, one that was not
            # seeded is introduced (a second pair in a seeded file included), and one waits in the
            # Inbox only when a pending retirement covers that finding's own rules.
            after = lore_lint.lint(store)
            remaining, waiting = idents_of(after), idents_of(lore_canon.held(store, after)["inbox"])
            introduced = sorted(name_of(i) for i in remaining - idents_of(base))
            gates = {}
            for g, v in expect["gates"].items():
                left = {i for i in remaining if i[0] == g}
                status = "fixed" if not left else (
                    "in Inbox" if v["inbox"] and left <= waiting else "not fixed")
                gates[g] = {"file": v["file"], "status": status, "fix": v["fix"]}
            done = sum(g["status"] != "not fixed" for g in gates.values())
            report.update(status="ok", gates=gates, bars={"canon": bar(done, len(gates), "every gate's fix present",
                                                                         done == len(gates) and not introduced)},
                          ops=res["ops"], commits=[subject for _, subject in res["commits"]], inbox=res["inbox"],
                          answer=res["answer"][:300], dropped=res["dropped"], new_findings=introduced)
    except Exception as err:
        report["error"] = failure(err)
    report.update(calls=meter.calls, tokens=meter.tokens(), wall_seconds=round(time.monotonic() - t0, 1))
    return report


# ---- the report -------------------------------------------------------------------------------

def exit_code(report):
    """2 when the run failed, 1 when a bar the tool computes is missed, else 0."""
    if report["status"] != "ok":
        return EXIT_FAILED
    return EXIT_MET if all(b["met"] for b in report["bars"].values() if b["met"] is not None) else EXIT_MISSED


def fraction(b):
    return f"{b['n']}/{b['d']}" if b["n"] is not None else f"?/{b['d']}"


def render(report, stamp):
    r = report
    out = [f"# lore eval {r['role']}", "", f"- Run: {stamp} (UTC)",
           f"- Result: {'FAILED: ' + r['error'] if r['status'] != 'ok' else 'ran'}",
           f"- Fixture: `{r['fixture']['path']}`, sha256 `{r['fixture']['sha256']}`"]
    fx = r["fixture"]
    if "rules" in fx:
        out[-1] += f" ({fx['rules']} rules, {fx['expected_pairs']} expected pairs)"
    elif "gates" in fx:
        out[-1] += f" ({fx['gates']} gates)"
    model = r.get("model")
    if model:
        out += [f"- Model: role `{r['role']}`, from `{model['name']}`; command `{model['command']}`"
                + (f", resolved `{model['resolved']}`" if model["resolved"] else "")]
    t = r["tokens"]
    out += [f"- Time: {r['wall_seconds']} s wall; {r['calls']} model call(s)",
            f"- Tokens ({t['basis']}): prompt {t['prompt']}, reply {t['reply']}, total {t['total']}", ""]
    if r["status"] == "ok":
        out += ["## Bars", "", "| Bar | Measured | Percent | Needs | Result |", "|---|---|---|---|---|"]
        for name, b in r["bars"].items():
            pct = f"{b['percent']}%" if b.get("percent") is not None else ""
            result = "owner judges" if b["met"] is None else ("PASS" if b["met"] else "FAIL")
            out.append(f"| {name} | {fraction(b)} | {pct} | {b['need']} | {result} |")
        out.append("")
    if r["role"] == "loremaster" and r["status"] == "ok":
        miss = [x for x in r["rules"] if not x["ok"]]
        out += [f"Folder misses ({len(miss)}): "
                + (", ".join(f"{x['id']} expected {x['expected']}, filed {'/'.join(x['filed']) or 'nowhere'}" for x in miss)
                   or "none"), "",
                f"Pairs: " + ", ".join(f"{s} {sum(p['status'] == s for p in r['pairs'])}"
                                        for s in ("same file", "linked", "not linked", "unfiled")), "",
                f"Oversized files: {', '.join(r['oversized_files']) or 'none'}. Rules filed to core.md: "
                f"{r['rules_in_core']} (a core filing counts as a folder miss). Lint findings after filing: "
                f"{json.dumps(r['lint_after'], sort_keys=True)}", "",
                "Meaning: 15 rules to judge yes or no in `spot-check.md`; the tool judges none.", ""]
    if r["role"] == "loremaster" and r["status"] == "ok":
        out += lore_eval_attribution.render(r["provisional"])
    if r["role"] == "loremaster" and r.get("batches"):
        out += ["## Batches", "", "| # | items | commit | files changed | rejected |", "|---|---|---|---|---|"]
        out += [f"| {b['batch']} | {b['items']} | {b['commit'] or '-'} | {b['files_changed']} | "
                f"{'; '.join(b['rejected']) or '-'} |" for b in r["batches"]]
        out.append("")
    if r["role"] == "canon" and r["status"] == "ok":
        out += ["## Gates", "", "| Gate | File | Result | A fix looks like |", "|---|---|---|---|"]
        out += [f"| {g} | {v['file']} | {v['status']} | {v['fix']} |" for g, v in r["gates"].items()]
        out += ["", f"Canon: {r['ops']} op(s), {len(r['commits'])} commit(s), inbox {', '.join(r['inbox']) or 'none'}; "
                    f"rejected: {'; '.join(r['rejected']) or 'no'}; introduced findings (any one fails the bar): "
                    f"{', '.join(r['new_findings']) or 'none'}", ""]
    return "\n".join(out)


def write_report(out, report, stamp, sheet):
    with open(os.path.join(out, "report.json"), "w") as f:
        json.dump(report, f, indent=1, sort_keys=True)
        f.write("\n")
    with open(os.path.join(out, "report.md"), "w") as f:
        f.write(render(report, stamp))
    if sheet:
        with open(os.path.join(out, "spot-check.md"), "w") as f:
            f.write(sheet)


# ---- the command ------------------------------------------------------------------------------

def cmd_eval(_, args):
    """lore eval loremaster|canon: build a temp store, run the role on the fixture, write the report."""
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    try:
        if args.store2:
            raise lore.LoreError("refused: eval builds its own store; --store2 is not accepted")
        fixture = os.path.abspath(args.fixture or FIXTURE)
        if not os.path.isdir(fixture):
            raise lore.LoreError(f"no fixture at {fixture}; run from a source clone or pass --fixture")
        batch = BATCH if args.batch is None else args.batch
        if batch < 1:
            raise lore.LoreError("--batch must be 1 or more")
        out = os.path.abspath(args.out or f"lore-eval-{args.role}-{stamp}")
        check_dir(out, "--out")
        if args.workdir:
            check_dir(args.workdir, "--workdir")
            if _inside(_real(args.workdir), _real(out)) or _inside(_real(out), _real(args.workdir)):
                raise lore.LoreError("refused: --workdir and --out must be separate directories")
        os.makedirs(out, exist_ok=True)   # check_dir allowed only a missing or empty directory
    except (lore.LoreError, OSError) as err:
        print(f"Error: {err}", file=sys.stderr)
        raise SystemExit(EXIT_FAILED)
    if args.role == "loremaster":
        report, sheet = run_loremaster(fixture, batch, args.workdir)
    else:
        report, sheet = run_canon(fixture, args.workdir), None
    write_report(out, report, stamp, sheet)
    print(f"report: {os.path.join(out, 'report.md')}")
    if report["status"] != "ok":
        print(f"eval {args.role} FAILED: {report['error']}")
    else:
        for name, b in report["bars"].items():
            print(f"{name}: {fraction(b)} {'owner judges' if b['met'] is None else ('PASS' if b['met'] else 'FAIL')}")
    code = exit_code(report)
    if code:
        raise SystemExit(code)
