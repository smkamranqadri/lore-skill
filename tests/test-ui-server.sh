#!/usr/bin/env bash
# lore 2.0 P4a UI server tests: `lore ui` on a free port, started here and killed in a trap. The
# Host check (missing, foreign, another port, twice) and the token (missing, wrong) refuse with
# the contract's status and code; no response carries a CORS header or a cookie; the security
# headers are on every response; it listens on 127.0.0.1 only; traversal under /assets/ (plain,
# encoded, a symlink) is 404 and a missing bundle 503; every read route's exact body on a fixture
# store; Inbox accept and reject through the API make the same commits as `lore inbox` on a twin
# store; POST /api/revert is no route (revert follows in P4b); a held lock is 409, a non-JSON POST
# 415; slow clients are cut off; pages across a merge; the token never reaches the server's stderr;
# SIGTERM and SIGINT end it with exit 0. Safe beside another copy of this suite: lore ui picks its own
# port from its range, and the fixture's twin is copied in a way a moving repository cannot break.
# Fictional fixtures; never a real model (a fake Canon), never the network (each hub is a local bare repo).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
pids=()
cleanup() {
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; done
  [[ -n "${KEEP:-}" ]] || rm -rf "$tmp"
}
trap cleanup EXIT
export HOME="$tmp/home"; mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset LORE_STORE LORE_STORE2 LORE_GH_CMD LORE_GIT_TIMEOUT LORE_SYNC_CMD LORE_EXTRACT_CMD LORE_REVIEW_CMD \
  LORE_LOREMASTER_CMD LORE_CANON_CMD LORE_MODEL_TIMEOUT MISE_DATA_DIR XDG_DATA_HOME 2>/dev/null || true
cat > "$tmp/canon-none.sh" <<'FAKE'
#!/bin/sh
echo '{"ops": [], "answer": "nothing to fix"}'
FAKE
chmod +x "$tmp/canon-none.sh"; export LORE_CANON_CMD="$tmp/canon-none.sh"

cp -r "$repo_root/skills/lore" "$tmp/skill"
rm -rf "$tmp/skill/ui/dist"   # the fixture bundle below, whatever the source tree holds
export LORE_SCRIPTS="$tmp/skill/scripts" TMP_ROOT="$tmp" PYTHONDONTWRITEBYTECODE=1
export PYTHONPATH="$repo_root/tests/fixtures/canon:$repo_root/tests/fixtures/ui"
lore="$tmp/skill/scripts/lore.py"
section() { echo "-- $1"; python3 -; }
fail() { echo "FAIL: $*" >&2; exit 1; }
stop_server() {   # $1 pid, $2 signal: it must exit 0 within 20 s (a hang fails, never blocks the suite)
  kill "-$2" "$1"
  for _ in $(seq 200); do kill -0 "$1" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$1" 2>/dev/null; then kill -KILL "$1"; fail "lore ui did not stop on SIG$2"; fi
  local rc=0; wait "$1" || rc=$?
  [[ "$rc" == 0 ]] || fail "lore ui exited $rc on SIG$2"
}
free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }

# A fictional bundle, and a file outside it that a symlink inside points at.
dist="$tmp/skill/ui/dist"
mkdir -p "$dist/assets"
printf '<!doctype html><title>lore fixture</title><script src="/assets/app.js"></script>\n' > "$dist/index.html"
printf 'console.log("fixture");\n' > "$dist/assets/app.js"
printf 'body { color: black; }\n' > "$dist/assets/app.css"
printf 'outside the bundle\n' > "$tmp/outside.txt"
ln -s "$tmp/outside.txt" "$dist/assets/link.js"

# 1. The fixture store, its twin (a copy, its own hub) and the facts the checks need.
section "fixture" <<'PY'
from uifix import *
import shutil, subprocess, time
S = new_store("served")
for repo in (S.root, hub_dir(S)):   # nothing of git's own repacks these while the twin is copied
    for key, value in (("gc.auto", "0"), ("maintenance.auto", "false"), ("receive.autogc", "false")):
        git(repo, "config", key, value)
AMB, GIT, ODIN = "stack/amber.md", "gotchas/git.md", "stack/odin.md"
seed(S, [add("core.md", "Run the tests before saying done.", core=True),
         add(AMB, "Pin Amber builds.", quote="always pin amber"), add(AMB, "Cache Amber builds."), add(AMB, "Lint Amber configs."),
         describe(AMB, "building Amber"), add(GIT, "Pull before you push."), describe(GIT, "a git command misbehaves"),
         {"op": "link", "file": AMB, "to": GIT}, add(ODIN, "Pin Odin builds.")])
a1 = rule_id(S, AMB, "Pin Amber builds.")
seed(S, [{"op": "flag-contradiction", "rule_id": a1, "with_text": "Never pin Amber builds."}])
m = meta(S, AMB)
m.update(links=sorted(m["links"] + ["stack/gone.md"]), reads={"m-aaaaaaaa": 3, "m-bbbbbbbb": 5},
         last_read={"m-aaaaaaaa": "2026-09-20", "m-bbbbbbbb": "2026-09-28"})
lore_store.save_meta(S, AMB, m); commit_hand(S, "reads and a stale link")
S.write(ODIN, S.read(ODIN) + "- Cache Odin builds by hand.\n"); commit_hand(S, "a hand edit")
S.write("notes.md", "- A note outside the layout.\n"); commit_hand(S, "a note")
S.write("retired/stack/big.md", "# Big\n\n" + "".join(f"- Fictional archived rule {i:05} for the diff cap: " + "\u754c" * 50 + ".\n"
                                                    for i in range(1500)))   # fewer than 200K characters, more than 200 KB of UTF-8
commit_hand(S, "a big archive")
M.apply(S, [{"op": "reword", "rule_id": rule_id(S, GIT, "Pull before you push."), "text": "Always pull before you push."}], source="canon")
M.apply(S, [add(GIT, "Fetch before you rebase.")], source="loremaster 0123456789ab")
S.write(GIT, S.read(GIT) + "- Tag releases by hand.\n"); commit_hand(S, "a git hand edit")
M.inbox_accept(S, [i["id"] for i in M.inbox_list(S) if i["kind"] == "hand-edit" and i["payload"]["file"] == GIT][0])
seed(S, [add(GIT, "Squash before you merge.")])
S.write(GIT, S.read(GIT).replace("- Squash before you merge.\n", "")); lore_store.tidy(S); lore_store.commit(S, "revert: seed: edit gotchas/git.md")
lore_store.record_reads(S, {GIT: 1}, "m-aaaaaaaa"); lore_store.tidy(S); lore_store.commit(S, "tidy after merging the hub")
retire = M.apply(S, [{"op": "retire", "rule_id": rule_id(S, AMB, "Lint Amber configs."), "reason": "fixture"}], source="canon")["inbox"][0]
lore_store.save_proposal(S.root, json.dumps({"top": S.layout() + ["tools/"]}))
seed(S, [add(GIT, "Rebase before you push.")])
eq(git(S.root, "status", "--porcelain"), "", "the fixture is committed")
eq(pushed(S), True, "and pushed")
kinds = {i["kind"]: i["id"] for i in M.inbox_list(S)}
eq(sorted(kinds), ["hand-edit", "layout", "retire"], "the inbox holds one item of each kind")
A = os.path.join(TMP, "twin")
for attempt in range(5):   # a file copy of a live repository: a file that moves mid-copy is copied again
    try:
        shutil.copytree(S.root, A, symlinks=True)
        break
    except (shutil.Error, OSError):
        shutil.rmtree(A, ignore_errors=True)
        time.sleep(0.5)
else:
    fail("the twin store could not be copied")
git(A, "fsck", "--no-progress", "--no-dangling")
subprocess.run(["git", "clone", "-q", "--mirror", "--no-local", hub_dir(S), os.path.join(TMP, "twin-hub.git")], check=True)
git(A, "remote", "set-url", "hub", os.path.join(TMP, "twin-hub.git"))
with open(os.path.join(TMP, "facts.json"), "w") as f:
    json.dump({"served": S.root, "twin": A, "hub": hub_dir(S), "twin_hub": os.path.join(TMP, "twin-hub.git"),
               "rebase": full(S), "root": git(S.root, "rev-list", "--max-parents=0", "HEAD"), "kinds": kinds,
               "big": git(S.root, "log", "--format=%H", "--grep=^a big archive$", "-n1")}, f)
PY

S="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["served"])' "$tmp/facts.json")"

# 2. The bind helper: the first free port of a range; none free is an error.
section "ports" <<'PY'
import os, socket, sys
sys.path.insert(0, os.environ["LORE_SCRIPTS"])
from harness import eq, raises
import lore, lore_ui
taken = []
for _ in range(2):
    s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(1); taken.append(s)
a, b = (s.getsockname()[1] for s in taken)
free = socket.socket(); free.bind(("127.0.0.1", 0)); c = free.getsockname()[1]; free.close()
srv = lore_ui.bind([a, c])
eq((srv.server_address, lore_ui.HOST), (("127.0.0.1", c), "127.0.0.1"), "the first free port, on 127.0.0.1")
srv.server_close()
raises(lambda: lore_ui.bind([a, b]), lore.LoreError, f"no free port from {a} to {b}; pass --port N", "none free")
raises(lambda: lore_ui.bind([a]), lore.LoreError, f"port {a} is in use", "a named port in use")
eq((lore_ui.PORTS.start, lore_ui.PORTS.stop), (3870, 3890), "the default range is 3870 to 3889")
# F7: every handler's socket has a read timeout (10 s unless LORE_UI_TIMEOUT says otherwise)
import threading
seen = []
class Observed(lore_ui.Handler):
    def setup(self):
        super().setup()
        seen.append(self.connection.gettimeout())
srv = lore_ui.Server(("127.0.0.1", 0), Observed)
srv.root, srv.today, srv.token = os.environ["TMP_ROOT"], None, "fixture"
th = threading.Thread(target=srv.handle_request); th.start()
c = socket.create_connection(srv.server_address, timeout=10); c.sendall(b"GET / HTTP/1.0\r\n\r\n"); c.recv(100); c.close()
th.join(10); srv.server_close()
eq(seen, [10.0], "a handler's socket has the read timeout")
eq(lore_ui.REQUEST_TIMEOUT, 10.0, "10 s unless LORE_UI_TIMEOUT says otherwise")
PY

# 3. The server: one line on stdout, the token only there. It binds the first free port of its range
# itself, so a second copy of this suite running beside this one takes the next.
LORE_UI_TIMEOUT=3 python3 "$lore" --today 2026-10-01 --store2 "$S" ui > "$tmp/ui.out" 2> "$tmp/ui.err" &
ui_pid=$!; pids+=("$ui_pid")
for _ in $(seq 100); do [[ -s "$tmp/ui.out" ]] && break; sleep 0.1; done
[[ "$(wc -l < "$tmp/ui.out" | tr -d ' ')" == 1 ]] || fail "lore ui did not print exactly one line"
grep -qxE "lore ui: http://127\.0\.0\.1:38(7[0-9]|8[0-9])/#t=[A-Za-z0-9_-]{43}" "$tmp/ui.out" || fail "the URL line is wrong: $(cat "$tmp/ui.out")"
port="$(sed -n 's#^lore ui: http://127\.0\.0\.1:\([0-9]*\)/.*#\1#p' "$tmp/ui.out")"
token="$(sed -n 's/.*#t=//p' "$tmp/ui.out")"
grep -qF -- "$token" "/proc/$ui_pid/cmdline" && fail "the token is in the server's argv"
export UI_PORT="$port" UI_OUT="$tmp/ui.out"

# 4. The Host check, the token, OPTIONS, the headers, 127.0.0.1 only.
section "auth" <<'PY'
from uifix import *
from client import *
port = PORT
unauth = {"error": "unauthorized", "code": "unauthorized"}
forbidden = {"error": "forbidden host", "code": "forbidden"}
eq(api("GET", "/api/summary", token=None), (401, unauth), "no token")
eq(api("GET", "/api/summary", token="x" * 43), (401, unauth), "a wrong token")
eq(api("GET", "/api/summary", token=TOKEN[:-1]), (401, unauth), "a token one character short")
eq(api("GET", "/api/summary", token=TOKEN + "x"), (401, unauth), "a token one character long")
eq(api("GET", "/api/nope", token=None), (401, unauth), "an unknown route needs the token first")
for host, what in ((None, "a missing Host"), (f"evil.example:{port}", "a foreign Host"), (f"127.0.0.1:{port + 1}", "another port"),
                   ("127.0.0.1", "no port"), (f"LOCALHOST:{port}", "another spelling"), (f"127.0.0.1:{port}.evil.example", "a suffix"),
                   ([f"127.0.0.1:{port}", f"evil.example:{port}"], "two Host headers")):
    eq(api("GET", "/api/summary", host=host), (403, forbidden), what)
    eq(api("GET", "/", host=host), (403, forbidden), f"{what} (the page)")
    eq(api("GET", "/api/summary", host=host, token=None), (403, forbidden), f"{what} comes before the token")
eq(api("GET", "/api/summary", host=f"localhost:{port}")[0], 200, "localhost:<port> is accepted")
eq(api("GET", "/api/summary")[0], 200, "127.0.0.1:<port> is accepted")
not_allowed = {"error": "method not allowed", "code": "method_not_allowed"}
eq(api("OPTIONS", "/api/summary", headers=[("Origin", "http://evil.example"), ("Access-Control-Request-Method", "POST")]),
   (405, not_allowed), "a preflight is 405")
eq(api("OPTIONS", "/api/inbox/accept", token=None), (405, not_allowed), "OPTIONS needs no token to be refused")
eq(api("OPTIONS", "/"), (405, not_allowed), "OPTIONS on the page")
for method in ("PUT", "DELETE", "PATCH", "BREW"):
    eq(api(method, "/api/summary"), (405, not_allowed), f"{method} is 405")
eq(api("POST", "/api/summary", body={}), (405, not_allowed), "POST on a read route")
eq(api("GET", "/api/inbox/accept"), (405, not_allowed), "GET on a write route")
eq(api("GET", "/api/nope"), (404, {"error": "no such route", "code": "not_found"}), "an unknown route")
eq(api("GET", "/api/summary", headers=[("Origin", "http://evil.example"), ("Cookie", "a=b")])[0], 200, "an Origin is ignored, not echoed")
eq(req("GET", "/api/summary")[1]["content-type"], "application/json; charset=utf-8", "JSON responses say so")

# listening on 127.0.0.1 only: the kernel's table of listening sockets for this port
def listening(table):
    try:
        rows = open(table).read().splitlines()[1:]
    except FileNotFoundError:
        return []
    return [r.split()[1].split(":")[0] for r in rows if r.split()[3] == "0A" and int(r.split()[1].split(":")[1], 16) == port]
eq((listening("/proc/net/tcp"), listening("/proc/net/tcp6")), (["0100007F"], []), "one listener, on 127.0.0.1 only")
eq(headers_ok(fail) > 30, True, "headers checked on every response")
PY

# 5. The page and its assets: traversal, encoded or through a symlink, is 404; no bundle is 503.
section "static" <<'PY'
from uifix import *
from client import *
nf = (404, b'{"error": "not found", "code": "not_found"}')
status, h, body = req("GET", "/", token=None)
eq((status, h["content-type"], body), (200, "text/html; charset=utf-8",
   b'<!doctype html><title>lore fixture</title><script src="/assets/app.js"></script>\n'), "the page needs no token")
status, h, body = req("GET", "/assets/app.js", token=None)
eq((status, h["content-type"], body, "cache-control" in h), (200, "text/javascript; charset=utf-8", b'console.log("fixture");\n', False), "an asset")
eq(req("GET", "/assets/app.css")[1]["content-type"], "text/css; charset=utf-8", "a stylesheet")
for path in ("/assets/../index.html", "/assets/%2e%2e/index.html", "/assets/%2E%2E/%2E%2E/scripts/lore.py",
             "/assets/..%2f..%2fscripts%2flore.py", "/assets/%2e%2e%2f%2e%2e%2fSKILL.md", "/assets/link.js",
             "/assets/%2e%2e/assets/../../../outside.txt", "/assets/./app.js", "/assets//app.js", "/assets/",
             "/assets/%00", "/assets/%ff", "/assets/..\\index.html", "/index.html", "/favicon.ico", "/scripts/lore.py",
             "/assets/missing.js", "/assets/app.js/x"):
    eq((req("GET", path, token=None)[0], req("GET", path, token=None)[2]), nf, f"{path} is not found")
eq(api("GET", "http://127.0.0.1/api/summary")[0], 404, "an absolute-form target is not served")
dist = os.path.join(os.environ["LORE_SCRIPTS"], "..", "ui", "dist")
os.rename(dist, dist + ".away")
try:
    eq(req("GET", "/")[0::2], (503, b"lore ui: the UI bundle is not built"), "no bundle: 503")
    eq(req("GET", "/")[1]["content-type"], "text/plain; charset=utf-8", "as text")
    eq(req("GET", "/assets/app.js")[0], 404, "no bundle: an asset is not found")
finally:
    os.rename(dist + ".away", dist)
eq(req("GET", "/")[0], 200, "the bundle is back")
headers_ok(fail)
PY

# 6. Every read route, its exact body, rederived from the files and git.
section "reads" <<'PY'
from uifix import *
from client import *
import subprocess
facts = json.load(open(os.path.join(TMP, "facts.json")))
S = lore_store.Store2(facts["served"], DAY)
AMB, GIT, ODIN, CORE, PROF = "stack/amber.md", "gotchas/git.md", "stack/odin.md", "core.md", "profile.md"
FILES = [CORE, PROF, AMB, ODIN, GIT]
raw = lambda rel: open(os.path.join(S.root, rel)).read()
side = lambda rel: json.load(open(os.path.join(S.root, ".lore/meta", rel[:-3] + ".json")))
lines = lambda rel: [l[2:] for l in raw(rel).splitlines() if l.startswith("- ")]
state = json.load(open(os.path.join(S.root, ".git/lore/state.json")))

eq(S.rule_files(), FILES, "the fixture's rule files")
eq(api("GET", "/api/summary"), (200, {"store": S.root, "machine": open(os.path.join(S.root, ".git/lore/machine")).read().strip(),
   "version": "2.0.0-p5a", "head": git(S.root, "rev-parse", "--short", "HEAD"),
   "hub": {"url": facts["hub"], "last_push": state["last_push"], "push_fails": 0},
   "counts": {"files": 5, "rules": 10, "inbox": 3}}), "summary")

def mem(rel, title, rw, reads, last, links, lint):
    return {"path": rel, "title": title, "read_when": rw, "rules": len(lines(rel)), "chars": len(raw(rel)), "reads": reads,
            "last_read": last, "links": links, "core": rel == CORE, "lint": lint}
eq(api("GET", "/api/memory"), (200, {"top": ["profile.md", "how-i-work/", "preferences/", "safety/", "stack/", "gotchas/"], "files": [
    mem(CORE, "Core", None, 0, None, [], []),
    mem(PROF, "Profile", "you need to know who the user is", 0, None, [], []),
    mem(AMB, "Amber", "building Amber", 8, "2026-09-28", [GIT, "stack/gone.md"], ["contradiction", "broken-link"]),
    mem(ODIN, "Odin", None, 0, None, [], ["orphan"]),
    mem(GIT, "Git", "a git command misbehaves", 1, "2026-10-01", [], [])], "outside_layout": ["notes.md"]}), "memory")
eq([len(lines(r)) for r in FILES], [1, 0, 3, 2, 4], "the rule counts")

def rule(rel, text):
    eid, e = next((k, v) for k, v in side(rel)["rules"].items() if v["text"] == text)
    return {"id": eid, "text": text, "count": e["count"], "explicit": e["explicit"], "created": e["created"], "dates": e["dates"],
            "confidence": e["confidence"], "updated": e["updated"], "quote": e.get("quote"), "hand_edit": e.get("hand_edit"),
            "contradictions": e.get("contradictions", [])}
status, body = api("GET", "/api/file?path=" + AMB)
eq((status, body), (200, {"path": AMB, "title": "Amber", "read_when": "building Amber", "links": [GIT, "stack/gone.md"],
   "reads": {"m-aaaaaaaa": 3, "m-bbbbbbbb": 5}, "last_read": {"m-aaaaaaaa": "2026-09-20", "m-bbbbbbbb": "2026-09-28"},
   "rules": [rule(AMB, t) for t in lines(AMB)]}), "file: amber")
eq([(r["text"], r["quote"], r["contradictions"], r["explicit"], r["count"], r["created"], r["hand_edit"]) for r in body["rules"]],
   [("Pin Amber builds.", "always pin amber", [{"with": "Never pin Amber builds.", "flagged": "2026-10-01"}], True, 1, "2026-10-01", None),
    ("Cache Amber builds.", "Cache Amber builds.", [], True, 1, "2026-10-01", None),
    ("Lint Amber configs.", "Lint Amber configs.", [], True, 1, "2026-10-01", None)], "file: amber's rules, literally")
status, body = api("GET", "/api/file?path=" + ODIN)
eq((status, [(r["text"], r["hand_edit"]) for r in body["rules"]], body["read_when"], body["reads"]),
   (200, [("Pin Odin builds.", None), ("Cache Odin builds by hand.", "2026-10-01")], None, {}), "file: odin, with its hand edit")
eq(body["rules"], [rule(ODIN, t) for t in lines(ODIN)], "file: odin's entries")
for path, want in (("notes.md", (404, {"error": "no rule file notes.md", "code": "not_found"})),
                   ("../outside.txt", (404, {"error": "no rule file ../outside.txt", "code": "not_found"})),
                   ("", (400, {"error": "missing path", "code": "bad_request"}))):
    eq(api("GET", "/api/file?path=" + path), want, f"file: {path or 'no path'}")
eq(api("GET", "/api/file"), (400, {"error": "missing path", "code": "bad_request"}), "file: no parameter")

node = lambda rel, folder, rules, heat, orphan: {"id": rel, "folder": folder, "rules": rules, "heat": heat, "orphan": orphan, "core": rel == CORE}
eq(api("GET", "/api/graph"), (200, {"nodes": [node(CORE, "core.md", 1, 0, False), node(PROF, "profile.md", 0, 0, False),
   node(AMB, "stack/", 3, 8, False), node(ODIN, "stack/", 2, 0, True), node(GIT, "gotchas/", 4, 1, False)],
   "edges": [{"source": AMB, "target": GIT}], "broken": [{"source": AMB, "target": "stack/gone.md"}]}), "graph")

items = M.inbox_list(S)
eq(api("GET", "/api/inbox"), (200, {"items": [{"id": i["id"], "kind": i["kind"], "created": i["created"], "summary": lore_hub.inbox_summary(i),
   "payload": i["payload"], "source": i["source"]} for i in items]}), "inbox")
retire = next(i for i in items if i["kind"] == "retire")
eq((retire["payload"]["file"], lore_hub.inbox_summary(retire)), (AMB, f"{AMB} {retire['payload']['rule_id']}: Lint Amber configs."), "inbox: the retirement")

# changes: from git, newest first, with the files each changed against its first parent
log = [l.split("\x1f") for l in git(S.root, "log", "--format=%H%x1f%h%x1f%cI%x1f%P%x1f%s").splitlines()]
def changed(sha, parents):
    base = parents.split()[0] if parents else "--root"
    args = ["diff-tree", "-r", "--no-renames", "--name-only", base, sha] if parents else ["diff-tree", "-r", "--no-renames", "--name-only", "--root", sha]
    out = git(S.root, *args).splitlines()
    return out[1:] if not parents else out   # --root prints the commit id first
want = [{"sha": c[0], "short": c[1], "date": c[2], "subject": c[4], "kind": None, "files": changed(c[0], c[3])} for c in log]
kinds = ["owner", "hub", "revert", "owner", "inbox", "owner", "loremaster", "canon", "owner", "owner", "owner", "owner", "owner", "owner", "owner"]
eq([c["subject"] for c in want], ["seed: edit gotchas/git.md", "tidy after merging the hub", "revert: seed: edit gotchas/git.md",
   "seed: edit gotchas/git.md", want[4]["subject"], "a git hand edit", "loremaster 0123456789ab: edit gotchas/git.md",
   "canon: edit gotchas/git.md", "a big archive", "a note", "a hand edit", "reads and a stale link", want[12]["subject"], want[13]["subject"],
   "new lore store"], "the fixture's history")
eq(want[4]["subject"].startswith("inbox: keep hand edit "), True, "an inbox commit")
for c, k in zip(want, kinds):
    c["kind"] = k
eq(api("GET", "/api/changes"), (200, {"commits": want, "next": None}), "changes: all")
eq(api("GET", "/api/changes?limit=3"), (200, {"commits": want[:3], "next": want[2]["sha"]}), "changes: a page")
eq(api("GET", f"/api/changes?limit=3&before={want[2]['sha']}"), (200, {"commits": want[3:6], "next": want[5]["sha"]}), "changes: the next page")
eq(api("GET", f"/api/changes?limit=200&before={want[13]['short']}"), (200, {"commits": want[14:], "next": None}), "changes: the last page")
eq(api("GET", f"/api/changes?before={want[14]['sha']}"), (200, {"commits": [], "next": None}), "changes: before the root")
eq(api("GET", "/api/changes?limit=15")[1]["next"], None, "changes: exactly all")
eq(api("GET", "/api/changes?limit=14")[1]["next"], want[13]["sha"], "changes: one short")
bad_limit = (400, {"error": "limit must be 1 to 200", "code": "bad_request"})
for q in ("limit=0", "limit=201", "limit=abc", "limit=-1", "limit=", "limit=1e2"):
    eq(api("GET", "/api/changes?" + q), bad_limit, f"changes: {q}")
eq(api("GET", "/api/changes?before=zz"), (400, {"error": "before must be a commit id (hex)", "code": "bad_request"}), "changes: a bad before")
eq(api("GET", "/api/changes?before=deadbeef"), (404, {"error": "unknown commit deadbeef", "code": "not_found"}), "changes: an unknown before")
dangling = git(S.root, "commit-tree", "HEAD^{tree}", "-m", "dangling")
eq(api("GET", f"/api/changes?before={dangling}"), (404, {"error": f"commit {dangling[:7]} is not in this store's history", "code": "not_found"}),
   "changes: a commit outside the history")

# commit: files with their status, the .md diff, the sidecars (no revert field: revert follows in P4b)
def commit(sha):
    c = next(x for x in log if x[0] == sha)
    parent = c[3].split()[0] if c[3] else git(S.root, "hash-object", "-t", "tree", "/dev/null")
    st = [l.split("\t") for l in git(S.root, "diff-tree", "-r", "-M", "--name-status", parent, sha).splitlines()]
    files = [{"path": p[-1], "status": p[0][0]} for p in st]
    diff = subprocess.run(["git", "-C", S.root, "diff", "--no-color", parent, sha, "--", "*.md"], capture_output=True, text=True).stdout
    return {"sha": sha, "short": c[1], "date": c[2], "subject": c[4], "body": git(S.root, "log", "-1", "--format=%b", sha),
            "kind": kinds[log.index(c)], "files": files, "diff": diff, "truncated": False,
            "meta_changed": [f["path"] for f in files if f["path"].startswith(".lore/meta/")]}
rebase = facts["rebase"]
eq(api("GET", f"/api/commit?sha={rebase}"), (200, commit(rebase)), "commit: the newest")
status, body = api("GET", f"/api/commit?sha={rebase[:7]}")
eq((status, body["sha"], body["files"], body["meta_changed"]), (200, rebase, [{"path": ".lore/meta/gotchas/git.json", "status": "M"},
   {"path": GIT, "status": "M"}], [".lore/meta/gotchas/git.json"]), "commit: by its short id, literally")
if "\n+- Rebase before you push.\n" not in body["diff"] or ".json" in body["diff"]:
    fail(f"commit: the diff is not the .md change only: {body['diff']!r}")
status, body = api("GET", f"/api/commit?sha={want[2]['sha']}")
eq((status, body["kind"], body), (200, "revert", commit(want[2]["sha"])), "commit: a `revert:` subject is kind revert")
root = facts["root"]
eq(api("GET", f"/api/commit?sha={root}"), (200, commit(root)), "commit: the root")
status, body = api("GET", f"/api/commit?sha={facts['big']}")
full_diff = subprocess.run(["git", "-C", S.root, "diff", "--no-color", f"{facts['big']}^", facts["big"], "--", "*.md"], capture_output=True).stdout
got = body["diff"].encode("utf-8")
eq((len(full_diff.decode("utf-8")) < 200 * 1024, len(full_diff) > 200 * 1024), (True, True), "the fixture: under 200K characters, over 200 KB")
eq((status, body["truncated"], len(got) <= 200 * 1024, len(got) > 200 * 1024 - 300, full_diff.startswith(got), got.endswith(b"\n"),
    full_diff[len(got) - 1:len(got)]), (200, True, True, True, True, True, b"\n"), "commit: the diff is capped at 200 KB of UTF-8, at a line end")
eq(api("GET", "/api/commit?sha=deadbeef"), (404, {"error": "unknown commit deadbeef", "code": "not_found"}), "commit: unknown")
eq(api("GET", "/api/commit?sha=HEAD"), (400, {"error": "commit must be a commit id (hex)", "code": "bad_request"}), "commit: not an id")
eq(api("GET", "/api/commit"), (400, {"error": "missing sha", "code": "bad_request"}), "commit: no sha")
eq(git(S.root, "status", "--porcelain"), "", "the read routes wrote nothing")
headers_ok(fail)
dump = os.environ.get("UI_BODIES")
if dump:   # one real body per route, for the handoff
    for name, path in (("summary", "/api/summary"), ("memory", "/api/memory"), ("file", "/api/file?path=" + AMB),
                       ("graph", "/api/graph"), ("inbox", "/api/inbox"), ("changes", "/api/changes?limit=2"),
                       ("commit", f"/api/commit?sha={rebase}")):
        with open(os.path.join(dump, name + ".json"), "w") as f:
            json.dump(api("GET", path)[1], f, indent=1)
PY

# 7. The write routes: bad bodies, the busy lock, the same commits as `lore inbox` on the twin, no
# revert route, a failed push kept, pushed true, false and null.
section "writes" <<'PY'
from uifix import *
from client import *
import fcntl
facts = json.load(open(os.path.join(TMP, "facts.json")))
S = lore_store.Store2(facts["served"], DAY)
A = lore_store.Store2(facts["twin"], DAY)
kinds = facts["kinds"]
head = full(S)
eq(api("POST", "/api/inbox/accept", body=b"id=x", ctype="text/plain"), (415, {"error": "the body must be application/json", "code": "unsupported"}), "text/plain")
eq(api("POST", "/api/inbox/accept", body=b'{"id": "x"}', ctype=None), (415, {"error": "the body must be application/json", "code": "unsupported"}), "no Content-Type")
eq(api("POST", "/api/inbox/accept", body=b'{"id": "x"}', ctype="application/x-www-form-urlencoded"),
   (415, {"error": "the body must be application/json", "code": "unsupported"}), "a form post")
eq(api("POST", "/api/inbox/accept", body=json.dumps({"id": "x" * (64 * 1024)}).encode()),
   (400, {"error": "the body is over 64 KiB", "code": "bad_request"}), "over 64 KiB")
eq(api("POST", "/api/inbox/accept", body=json.dumps({"id": "x" * (64 * 1024 - 20)}).encode())[1]["code"], "not_found", "just under 64 KiB is read")
eq(api("POST", "/api/inbox/accept", body=b"{not json"), (400, {"error": "the body is not JSON", "code": "bad_request"}), "not JSON")
eq(api("POST", "/api/inbox/accept", body=[1]), (400, {"error": "the body must be a JSON object", "code": "bad_request"}), "not an object")
for body in ({}, {"id": 3}, {"id": ""}, {"id": "x", "more": 1}):
    eq(api("POST", "/api/inbox/accept", body=body), (400, {"error": 'the body must be {"id": "..."}', "code": "bad_request"}), f"body {body}")
eq(api("POST", "/api/inbox/reject", body={"id": "nope"}), (404, {"error": "no inbox item nope", "code": "not_found"}), "an unknown item")
eq(api("POST", "/api/inbox/reject", body={"sha": "x"}), (400, {"error": 'the body must be {"id": "..."}', "code": "bad_request"}), "reject: a bad body")
eq(api("POST", "/api/inbox/accept", body={"id": kinds["retire"]}, token=None), (401, {"error": "unauthorized", "code": "unauthorized"}), "a write needs the token")
eq(full(S), head, "nothing written so far")

# a held lock: 409, nothing written
holder = open(S.local("run.lock"), "w")   # this process holds the run lock, as a session-end run would
fcntl.flock(holder, fcntl.LOCK_EX)
try:
    busy = (409, {"error": "busy: another lore run holds the store; retry", "code": "busy"})
    for path, body in (("/api/inbox/accept", {"id": kinds["retire"]}), ("/api/inbox/reject", {"id": kinds["layout"]})):
        eq(api("POST", path, body=body), busy, f"{path} while the lock is held")
    eq(api("GET", "/api/summary")[0], 200, "reads need no lock")
finally:
    holder.close()
eq((full(S), sorted(i["id"] for i in M.inbox_list(S))), (head, sorted(kinds.values())), "nothing written while busy")

# the twin: each Inbox action from the shell on A, through the API on S, the same commit
def twin(action, iid, kind):
    rc, out = cli(A, "inbox", action, iid)
    eq(rc, 0, f"lore inbox {action} {iid} on the twin")
    status, body = api("POST", f"/api/inbox/{action}", body={"id": iid})
    push = f"hub: pushed to {facts['hub']}"
    want = {"ok": True, "kind": kind, "commit": short(S), "push": push, "pushed": True} if action == "accept" else \
        {"ok": True, "commit": short(S), "push": push, "pushed": True}
    eq((status, body), (200, want), f"{action} {kind} through the API")
    eq((git(S.root, "log", "-1", "--format=%s"), full(S, "HEAD^{tree}"), count(S)),
       (git(A.root, "log", "-1", "--format=%s"), full(A, "HEAD^{tree}"), count(A)), f"{action} {kind}: the same commit as the shell's")
    eq((pushed(S), git(A.root, "rev-parse", "HEAD") == git(facts["twin_hub"], "rev-parse", "main")), (True, True), f"{action} {kind}: both pushed")
twin("accept", kinds["retire"], "retire")
twin("reject", kinds["hand-edit"], "hand-edit")
twin("accept", kinds["layout"], "layout")
eq(git(S.root, "log", "-3", "--format=%s").splitlines()[2].startswith("inbox: retire "), True, "the retirement's subject")
eq((M.inbox_list(S), M.inbox_list(A)), ([], []), "both inboxes are empty")
# a reject that makes no commit
lore_store.save_proposal(S.root, json.dumps({"top": ["profile.md", "stack/"]}))
iid = M.inbox_list(S)[0]["id"]
n = count(S)
eq(api("POST", "/api/inbox/reject", body={"id": iid}), (200, {"ok": True, "commit": None, "push": None, "pushed": None}), "a reject without a commit: pushed is null")
eq((count(S), M.inbox_list(S)), (n, []), "nothing committed, the item gone")
# an accept the store refuses is 422 with lore's reason
lore_store.save_proposal(S.root, json.dumps({"top": ["profile.md", "gotchas/"]}))
iid = M.inbox_list(S)[0]["id"]
eq(api("POST", "/api/inbox/accept", body={"id": iid}), (422, {"error": f"inbox item {iid}: the new layout drops content still in "
   "stack/amber.md, stack/odin.md; move it first", "code": "refused"}), "a refused accept")
eq(count(S), n, "nothing committed")
M._drop(S, M.inbox_list(S)[0])

# no revert route in P4a: POST /api/revert is 404 like any unknown route, and writes nothing
eq(api("POST", "/api/revert", body={"sha": facts["rebase"]}), (404, {"error": "no such route", "code": "not_found"}), "no revert route")
eq(count(S), n, "nothing written")
# a failed push keeps the commit: 200, pushed false, the FAILED line
def hand_edit(text, subject):
    S.write("stack/odin.md", S.read("stack/odin.md") + f"- {text}\n"); commit_hand(S, subject)
    return [i["id"] for i in M.inbox_list(S) if i["kind"] == "hand-edit"][0]
hand = hand_edit("Prefer Odin debug builds.", "an odin debug hand edit")
n = count(S)
os.rename(facts["hub"], facts["hub"] + ".gone")
try:
    status, body = api("POST", "/api/inbox/accept", body={"id": hand})
finally:
    os.rename(facts["hub"] + ".gone", facts["hub"])
eq((status, sorted(body), body["ok"], body["kind"], body["commit"], body["pushed"], body["push"].startswith("hub: push FAILED (")),
   (200, ["commit", "kind", "ok", "push", "pushed"], True, "hand-edit", short(S), False, True), "a failed push keeps the accept")
eq(count(S), n + 1, "the commit is kept")
# no hub set: pushed is null and push says so (the commit is local, which is not a failure)
git(S.root, "remote", "remove", "hub")
try:
    lore_store.save_proposal(S.root, json.dumps({"top": ["profile.md", "stack/"]}))
    eq(api("POST", "/api/inbox/accept", body={"id": M.inbox_list(S)[0]["id"]})[1]["code"], "refused", "a refused accept, no hub")
    M._drop(S, M.inbox_list(S)[0])
    hand = hand_edit("Prefer Odin nightly builds.", "an odin hand edit")
    eq(api("POST", "/api/inbox/accept", body={"id": hand}), (200, {"ok": True, "kind": "hand-edit", "commit": short(S),
       "push": "hub: none (local git only)", "pushed": None}), "no hub: an accept's pushed is null")
finally:
    git(S.root, "remote", "add", "hub", facts["hub"])
hand = hand_edit("Prefer Odin release builds.", "an odin release hand edit")
eq(api("POST", "/api/inbox/accept", body={"id": hand}), (200, {"ok": True, "kind": "hand-edit", "commit": short(S),
   "push": f"hub: pushed to {facts['hub']}", "pushed": True}), "the hub back: pushed is true")
headers_ok(fail)
PY

# 7b. F7: slow clients. The server runs with LORE_UI_TIMEOUT=3: a request whose line, headers or body
# does not arrive in 3 s is closed (however slowly it trickles), and at most 16 requests are served at
# once, a connection beyond them closed at once; the server answers normally afterwards.
section "slow clients" <<'PY'
from uifix import *
from client import *
import socket, time
good = f"127.0.0.1:{PORT}"

def closed_after(sock, trickle=b""):
    """Seconds until the server closes `sock` (it answers nothing), sending `trickle` a byte every 0.5 s."""
    t0, got = time.monotonic(), b""
    sock.settimeout(0.5)
    while time.monotonic() - t0 < 15:
        try:
            data = sock.recv(4096)
            if not data:
                break
            got += data
        except socket.timeout:
            if trickle:
                try:
                    sock.sendall(trickle[:1]); trickle = trickle[1:] or b"X"
                except OSError:
                    break
        except OSError:
            break
    sock.close()
    return time.monotonic() - t0, got

def opened(payload):
    s = socket.create_connection(("127.0.0.1", PORT), timeout=5)
    s.sendall(payload)
    return s

for what, payload, trickle in (
        ("half a header", b"GET / HTTP/1.1\r\nHost:", b""),
        ("a trickled request line", b"G", b"ET /api/summary HTTP/1.1\r\nX-Pad: " + b"a" * 100),
        ("half an authenticated body", f"POST /api/inbox/accept HTTP/1.1\r\nHost: {good}\r\nX-Lore-Token: {TOKEN}\r\n"
         "Content-Type: application/json\r\nContent-Length: 50\r\n\r\n{".encode(), b"")):
    took, got = closed_after(opened(payload), trickle)
    eq((2.5 < took < 8, got), (True, b""), f"{what}: closed after the 3 s deadline with no answer ({took:.1f} s)")

held = [opened(b"GET / HTTP/1.1\r\nHost:") for _ in range(16)]
time.sleep(0.5)
took, got = closed_after(opened(b"GET /api/summary HTTP/1.1\r\n"))
eq((took < 2, got), (True, b""), f"a 17th request while 16 are open is closed at once ({took:.1f} s)")
for s in held:
    s.close()
time.sleep(0.5)
eq(api("GET", "/api/summary")[0], 200, "the server answers again once they are gone")
headers_ok(fail)
PY

# 7c. F8: Changes pages are slices of one traversal from HEAD, so a merged history is covered once.
section "pagination" <<'PY'
from uifix import *
import lore_ui
st = new_store("merged", hub=False)
F, G = "stack/amber.md", "stack/basil.md"
seed(st, [add(F, "Pin fictional Amber builds."), describe(F, "building fictional Amber")])
git(st.root, "checkout", "-q", "-b", "side")
seed(st, [add(G, "Pin fictional Basil builds.")]); seed(st, [describe(G, "building fictional Basil")])
git(st.root, "checkout", "-q", "main")
seed(st, [add(F, "Cache fictional Amber builds.")]); seed(st, [add(F, "Lint fictional Amber configs.")])
git(st.root, "merge", "-q", "--no-ff", "-m", "merge side", "side")
want = git(st.root, "rev-list", "HEAD").split()
for limit in (1, 2, 3, 200):
    seen, before = [], None
    for _ in range(len(want) + 1):
        q = {"limit": [str(limit)], **({"before": [before]} if before else {})}
        page = lore_ui.changes(st, q)
        seen += [c["sha"] for c in page["commits"]]
        before = page["next"]
        if before is None:
            break
    eq(seen, want, f"pages of {limit}: every commit once, in rev-list order")
merge = lore_ui.changes(st, {"limit": ["1"]})["commits"][0]
eq((merge["subject"], merge["kind"], sorted(merge["files"])), ("merge side", "hub", [".lore/meta/stack/basil.json", G]),
   "the merge, with the files it brought in")
PY

# 8. SIGTERM ends it with exit 0; its stderr has one line per request and never the token.
stop_server "$ui_pid" TERM
grep -qF -- "$token" "$tmp/ui.err" && fail "the token is in the server's stderr"
line_re='lore ui: ([A-Z]+ [^ ]+ [0-9]{3}|a request timed out|too many open requests; a connection was closed|a request failed \(the connection broke\))'
grep -qvxE "$line_re" "$tmp/ui.err" && fail "a stderr line is not a request line: $(grep -vxE "$line_re" "$tmp/ui.err" | head -3)"
grep -qxF "lore ui: too many open requests; a connection was closed" "$tmp/ui.err" || fail "the closed 17th connection was not logged"
grep -qxF "lore ui: GET /api/changes 200" "$tmp/ui.err" || fail "a request's query reached the log, or it was not logged"
grep -qF "limit=" "$tmp/ui.err" && fail "a query string is in the log"
[[ "$(grep -c '' "$tmp/ui.err")" -gt 100 ]] || fail "too few request lines logged"

# 9. SIGINT ends it with exit 0 too.
python3 "$lore" --store2 "$S" ui > "$tmp/ui2.out" 2> "$tmp/ui2.err" &
ui2=$!; pids+=("$ui2")
for _ in $(seq 100); do [[ -s "$tmp/ui2.out" ]] && break; sleep 0.1; done
[[ -s "$tmp/ui2.out" ]] || fail "the second server did not start"
stop_server "$ui2" INT
[[ ! -s "$tmp/ui2.err" ]] || fail "lore ui wrote to stderr on SIGINT: $(cat "$tmp/ui2.err")"
# a port in use is an error, exit 1
held="$(free_port)"
out="$(python3 - "$held" "$lore" "$S" <<'PY'
import socket, subprocess, sys
s = socket.socket(); s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(1)
r = subprocess.run(["python3", sys.argv[2], "--store2", sys.argv[3], "ui", "--port", sys.argv[1]], capture_output=True, text=True, timeout=60)
print(r.returncode, r.stdout.strip(), r.stderr.strip())
PY
)"
[[ "$out" == "1  Error: port $held is in use" ]] || fail "a port in use: $out"

echo "test-ui-server: all checks passed"
