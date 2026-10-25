"""lore 2.0 UI server: `lore ui` serves the built bundle and a small JSON API on 127.0.0.1 only.

A page in the same browser must not be able to read or write the memory, so: the server binds the
loopback address only; every response checks the Host header first (127.0.0.1:<port> or
localhost:<port>, nothing else, against DNS rebinding); the API needs the token, sent as the
X-Lore-Token header (never a cookie, so a cross-site request cannot carry it), compared in constant
time; no response carries a CORS header or sets a cookie, and OPTIONS is refused. The token is
made at start, printed once in the URL's fragment (which a browser never sends) and never written
or logged; it dies with the process.

The API reads the store without the lock and writes nothing, except the two write routes (Inbox
accept and reject), which take the run lock without waiting (busy is a 409) and call the same
functions as `lore inbox`, then push like it. Changes is read-only (revert follows in P4b).
Standard library only.
"""

import datetime as dt
import errno
import hmac
import http.server
import json
import os
import re
import secrets
import signal
import socket
import socketserver
import sys
import threading
import urllib.parse

import lore
import lore_hub
import lore_master
import lore_store

PORTS = range(3870, 3890)
HOST = "127.0.0.1"
DIST = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ui", "dist"))
BODY_MAX = 64 * 1024
DIFF_MAX = 200 * 1024
CHANGES_MAX = 200
CSP = "default-src 'self'; img-src 'self' data:; frame-ancestors 'none'"
NO_BUNDLE = "lore ui: the UI bundle is not built"
STATUS = {"bad_request": 400, "unauthorized": 401, "forbidden": 403, "not_found": 404, "method_not_allowed": 405,
          "busy": 409, "unsupported": 415, "refused": 422, "internal": 500}
TYPES = {".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".mjs": "text/javascript; charset=utf-8",
         ".css": "text/css; charset=utf-8", ".json": "application/json; charset=utf-8", ".svg": "image/svg+xml",
         ".png": "image/png", ".jpg": "image/jpeg", ".ico": "image/x-icon", ".woff": "font/woff",
         ".woff2": "font/woff2", ".txt": "text/plain; charset=utf-8", ".webp": "image/webp"}
SHA_RE = re.compile(r"^[0-9a-f]{4,64}$")
FILING_RE = re.compile(r"^loremaster( [0-9a-f]{12})?: ")
HUB_SUBJECTS = ("tidy after merging the hub", "tidy after landing Canon's commits")
MAX_HANDLERS = 16   # requests served at once; a connection beyond them is closed


def request_timeout():
    """Seconds a client has to send its request line, headers and body (LORE_UI_TIMEOUT, else 10)."""
    try:
        t = float(os.environ.get("LORE_UI_TIMEOUT") or 10)
    except ValueError:
        return 10.0
    return t if 0 < t <= 3600 else 10.0


REQUEST_TIMEOUT = request_timeout()


class ApiError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def commit_kind(subject, parents=1):
    """What made a commit, from its subject: canon, loremaster (a filing), inbox, revert, hub (an
    integrate or a merge), else owner."""
    if parents > 1 or subject in HUB_SUBJECTS:
        return "hub"
    if subject.startswith("canon: "):
        return "canon"
    if FILING_RE.match(subject):
        return "loremaster"
    for kind in ("inbox", "revert"):
        if subject.startswith(kind + ": "):
            return kind
    return "owner"


def one_line(text, n=300):
    """An error message fit for a response: secrets redacted, one line, short."""
    t = " ".join(lore.redact(str(text)).split())
    return t if len(t) <= n else t[:n - 3] + "..."


def skill_version():
    try:
        with open(os.path.join(lore.SKILL_DIR, "SKILL.md")) as f:
            m = re.search(r'^\s+version:\s*"?([^"\n]+?)"?\s*$', f.read(), re.M)
    except OSError:
        return ""
    return m.group(1) if m else ""


# ---- the read routes --------------------------------------------------------------------------

def _int_sum(values):
    return sum(v for v in (values or {}).values() if isinstance(v, int) and not isinstance(v, bool))


def _newest(values):
    days = [v for v in (values or {}).values() if isinstance(v, str)]
    return max(days) if days else None


def _read_when(meta):
    rw = meta.get("read_when")
    return rw if isinstance(rw, str) and rw.strip() else None


def _links(meta):
    links = meta.get("links")
    return [x for x in links if isinstance(x, str)] if isinstance(links, list) else []


def _title(store, rel):
    return lore_store.parse_rules(store.read(rel))[0] or lore_master._title(rel)


def _machine(store):
    try:
        with open(store.local("machine")) as f:
            return f.read().strip()
    except OSError:
        return ""


def _lint(store):
    sys.modules.setdefault("lore", lore)
    try:
        import lore_lint
    except ImportError:
        return []
    return lore_lint.lint(store)


def summary(store, _):
    files = store.rule_files()
    st = lore_hub.load_state(store)
    url = lore_hub.hub_url(store)
    return {"store": store.root, "machine": _machine(store), "version": skill_version(),
            "head": store.git("rev-parse", "--short", "HEAD")[1].strip(),
            "hub": {"url": lore_hub.safe_url(url) if url else None, "last_push": st.get("last_push") or None,
                    "push_fails": int(st.get("push_fails") or 0)},
            "counts": {"files": len(files), "rules": sum(len(lore_store.parse_rules(store.read(r))[1]) for r in files),
                       "inbox": len(lore_master.inbox_list(store))}}


def memory(store, _):
    findings = _lint(store)
    out = []
    for rel in store.rule_files():
        text = store.read(rel) or ""
        meta = lore_store.load_meta(store, rel)
        gates = {f["gate"] for f in findings if f.get("file") == rel}
        out.append({"path": rel, "title": _title(store, rel), "read_when": _read_when(meta),
                    "rules": len(lore_store.parse_rules(text)[1]), "chars": len(text),
                    "reads": _int_sum(meta.get("reads")), "last_read": _newest(meta.get("last_read")),
                    "links": _links(meta), "core": rel == "core.md",
                    "lint": [g for g in _gates() if g in gates]})
    return {"top": store.layout(), "files": out, "outside_layout": store.outside_layout()}


def _gates():
    sys.modules.setdefault("lore", lore)
    try:
        import lore_lint
    except ImportError:
        return ()
    return lore_lint.GATES


def file_view(store, q):
    rel = _param(q, "path")
    if rel not in store.rule_files():
        raise ApiError("not_found", f"no rule file {lore_master._safe(rel)}")
    m = lore_master._Model(store)
    meta = m.files[rel]["meta"]
    entries = m.entries(rel)
    rules = []
    for eid in m.ordered(rel):
        e = entries[eid]
        rules.append({"id": eid, "text": e.get("text"), "count": e.get("count"), "explicit": e.get("explicit"),
                      "created": e.get("created"), "dates": e.get("dates") or [], "confidence": e.get("confidence"),
                      "updated": e.get("updated"), "quote": e["quote"] if isinstance(e.get("quote"), str) else None,
                      "hand_edit": e.get("hand_edit") or None, "contradictions": e.get("contradictions") or []})
    reads = meta.get("reads") if isinstance(meta.get("reads"), dict) else {}
    last = meta.get("last_read") if isinstance(meta.get("last_read"), dict) else {}
    return {"path": rel, "title": _title(store, rel), "read_when": _read_when(meta), "links": _links(meta),
            "reads": {k: v for k, v in sorted(reads.items()) if isinstance(v, int)},
            "last_read": {k: v for k, v in sorted(last.items()) if isinstance(v, str)}, "rules": rules}


def _folder(rel):
    return rel.split("/", 1)[0] + "/" if "/" in rel else rel


def graph(store, _):
    files = store.rule_files()
    known = set(files)
    orphans = {f["file"] for f in _lint(store) if f.get("gate") == "orphan"}
    nodes, edges, broken = [], [], []
    for rel in files:
        meta = lore_store.load_meta(store, rel)
        nodes.append({"id": rel, "folder": _folder(rel), "rules": len(lore_store.parse_rules(store.read(rel))[1]),
                      "heat": _int_sum(meta.get("reads")), "orphan": rel in orphans, "core": rel == "core.md"})
        for target in sorted(set(_links(meta))):
            (edges if target in known else broken).append({"source": rel, "target": target})
    return {"nodes": nodes, "edges": edges, "broken": broken}


def inbox(store, _):
    return {"items": [{"id": i["id"], "kind": i["kind"], "created": i["created"], "summary": lore_hub.inbox_summary(i),
                       "payload": i.get("payload"), "source": i.get("source")} for i in lore_master.inbox_list(store)]}


def _commit_sha(store, sha, what="commit"):
    """The full sha of a commit object, or ApiError (400 for a malformed id, 404 for an unknown one)."""
    if not isinstance(sha, str) or not SHA_RE.match(sha):
        raise ApiError("bad_request", f"{what} must be a commit id (hex)")
    rc, out, _ = store.git("rev-parse", "--verify", "-q", sha + "^{commit}", check=False)
    if rc:
        raise ApiError("not_found", f"unknown commit {sha}")
    return out.strip()


def changes(store, q):
    raw = q.get("limit", ["50"])[-1]
    if not re.fullmatch(r"[0-9]{1,3}", raw) or not 1 <= int(raw) <= CHANGES_MAX:
        raise ApiError("bad_request", f"limit must be 1 to {CHANGES_MAX}")
    limit = int(raw)
    order = store.git("rev-list", "HEAD")[1].split()   # one traversal from HEAD; every page is a slice of it
    at = 0
    if "before" in q:
        start = _commit_sha(store, q["before"][-1], "before")
        if start not in order:
            short = store.git("rev-parse", "--short", start)[1].strip()   # a full sha would be redacted as secret-looking
            raise ApiError("not_found", f"commit {short} is not in this store's history")
        at = order.index(start) + 1
    page = order[at:at + limit]
    out = store.git("-c", "core.quotePath=false", "log", "--no-walk=unsorted", "--no-renames", "--name-only",
                    "--diff-merges=first-parent", "--format=%x1e%H%x1f%h%x1f%cI%x1f%P%x1f%s", *page)[1] if page else ""
    commits = []
    for rec in out.split("\x1e")[1:]:
        head, _, rest = rec.partition("\n")
        sha, short, date, parents, subject = head.split("\x1f", 4)
        commits.append({"sha": sha, "short": short, "date": date, "subject": subject,
                        "kind": commit_kind(subject, len(parents.split())),
                        "files": [l for l in rest.splitlines() if l]})
    return {"commits": commits, "next": commits[-1]["sha"] if len(order) > at + limit else None}


def _empty_tree(store):
    return store.git("hash-object", "-t", "tree", "--stdin", stdin="")[1].strip()


def commit_view(store, q):
    full = _commit_sha(store, _param(q, "sha"))
    out = store.git("show", "-s", "--format=%H%x1f%h%x1f%cI%x1f%P%x1f%s%x1f%b", full)[1]
    sha, short, date, parents, subject, body = out.split("\x1f", 5)
    parents = parents.split()
    base = parents[0] if parents else _empty_tree(store)
    raw = store.git("diff-tree", "-r", "-M", "--name-status", "-z", base, full)[1].split("\0")
    files, i = [], 0
    while i < len(raw) - 1:
        status = raw[i][:1]
        if status in ("R", "C"):
            files.append({"path": raw[i + 2], "status": "R" if status == "R" else "A"})
            i += 3
        else:
            files.append({"path": raw[i + 1], "status": status if status in ("A", "M", "D") else "M"})
            i += 2
    data = store.git("diff", "--no-color", "--no-ext-diff", "--no-textconv", base, full, "--", "*.md",
                     raw=True)[1].decode("utf-8", errors="replace").encode("utf-8")
    truncated = len(data) > DIFF_MAX   # the cap is in UTF-8 bytes, as the response carries them
    if truncated:   # whole lines only: a newline byte is never inside a multi-byte character
        data = data[:DIFF_MAX]
        data = data[:data.rfind(b"\n") + 1]
    diff = data.decode("utf-8")
    return {"sha": sha, "short": short, "date": date, "subject": subject, "body": body.rstrip("\n"),
            "kind": commit_kind(subject, len(parents)), "files": files, "diff": diff,
            "truncated": truncated, "meta_changed": [f["path"] for f in files if f["path"].startswith(".lore/meta/")]}


def _param(q, name):
    vals = q.get(name)
    if not vals or not vals[-1]:
        raise ApiError("bad_request", f"missing {name}")
    return vals[-1]


# ---- the write routes -------------------------------------------------------------------------

def _field(body, name):
    if set(body) != {name} or not isinstance(body[name], str) or not body[name].strip():
        raise ApiError("bad_request", f"the body must be {{\"{name}\": \"...\"}}")
    return body[name].strip()


def _known_item(store, item_id):
    if item_id not in {i["id"] for i in lore_master.inbox_list(store)}:
        raise ApiError("not_found", f"no inbox item {lore_master._safe(item_id)}")


def accept(store, body):
    item_id = _field(body, "id")
    _known_item(store, item_id)
    try:
        res = lore_hub.inbox_accept(store, item_id)
    except lore.LoreError as err:
        raise ApiError("refused", str(err))
    return {"ok": True, "kind": res["kind"], "commit": res["commit"], "push": res["push"], "pushed": res["pushed"]}


def reject(store, body):
    item_id = _field(body, "id")
    _known_item(store, item_id)
    try:
        res = lore_hub.inbox_reject(store, item_id)
    except lore.LoreError as err:
        raise ApiError("refused", str(err))
    return {"ok": True, "commit": res["commit"], "push": res["push"], "pushed": res["pushed"]}


READS = {"/api/summary": summary, "/api/memory": memory, "/api/file": file_view, "/api/graph": graph,
         "/api/inbox": inbox, "/api/changes": changes, "/api/commit": commit_view}
WRITES = {"/api/inbox/accept": accept, "/api/inbox/reject": reject}


# ---- the server -------------------------------------------------------------------------------

class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, *args, **kw):
        self.slots = threading.BoundedSemaphore(MAX_HANDLERS)
        super().__init__(*args, **kw)

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):   # slow clients cannot take every thread
            sys.stderr.write("lore ui: too many open requests; a connection was closed\n")
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()

    def server_bind(self):
        socketserver.TCPServer.server_bind(self)   # no reverse lookup of the address, unlike HTTPServer
        self.server_name, self.server_port = self.server_address[:2]

    def handle_error(self, request, client_address):
        sys.stderr.write("lore ui: a request failed (the connection broke)\n")   # never a traceback


class Gone(Exception):
    """The client did not send its whole request in time (or went away)."""


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "lore-ui"
    sys_version = ""
    timeout = REQUEST_TIMEOUT   # each read and write of the socket

    def setup(self):
        super().setup()
        # the whole request (line, headers, body) must arrive in time, however slowly it trickles
        self.deadline = threading.Timer(REQUEST_TIMEOUT, self._expire)
        self.deadline.daemon = True
        self.deadline.start()

    def _expire(self):
        self.expired = True   # what the request sent so far is not answered
        try:
            self.connection.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass

    def finish(self):
        self.deadline.cancel()
        super().finish()

    def log_error(self, *args):   # BaseHTTPRequestHandler's timeout path; never the request's text
        sys.stderr.write("lore ui: a request timed out\n")

    def version_string(self):
        return self.server_version

    # every request goes through _handle; anything else BaseHTTPRequestHandler answers (a malformed
    # request, an unknown method) comes through send_error, with the same headers
    def do_GET(self):
        self._handle()

    do_POST = do_PUT = do_DELETE = do_PATCH = do_HEAD = do_OPTIONS = do_GET

    def log_message(self, *args):
        pass   # never BaseHTTPRequestHandler's lines: they carry the request line as sent

    def log_request(self, code="-", size="-"):
        path = urllib.parse.urlsplit(getattr(self, "path", "") or "").path
        method = getattr(self, "command", None) or "-"
        sys.stderr.write(f"lore ui: {method} {one_line(path, 200) or '-'} {code}\n")
        sys.stderr.flush()

    def send_error(self, code, message=None, explain=None):
        self.close_connection = True
        if getattr(self, "expired", False):
            sys.stderr.write("lore ui: a request timed out\n")
            return
        if getattr(self, "headers", None) is not None and not self._host_ok():
            self._error("forbidden", "forbidden host")
        elif code == 501:   # a method no do_ handles
            self._error("method_not_allowed", "method not allowed")
        else:
            name = {404: "not_found"}.get(code, "bad_request" if code < 500 else "internal")
            self._send(code, json.dumps({"error": one_line(message or "bad request"), "code": name}).encode(),
                       "application/json; charset=utf-8", True)

    def _send(self, status, body, ctype, no_store, extra=()):
        if getattr(self, "expired", False):
            return
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", CSP)
        if no_store:
            self.send_header("Cache-Control", "no-store")
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, status, data, extra=()):
        self._send(status, json.dumps(data, ensure_ascii=False).encode("utf-8"), "application/json; charset=utf-8",
                   True, extra)

    def _error(self, code, message):
        extra = [("Allow", "GET, POST")] if code == "method_not_allowed" else []
        self._json(STATUS[code], {"error": one_line(message), "code": code}, extra)

    def _host_ok(self):
        port = self.server.server_port
        hosts = self.headers.get_all("Host") or []
        return len(hosts) == 1 and hosts[0] in (f"{HOST}:{port}", f"localhost:{port}")

    def _token_ok(self):
        given = self.headers.get_all("X-Lore-Token") or []
        return len(given) == 1 and hmac.compare_digest(given[0].encode("utf-8", "surrogateescape"),
                                                       self.server.token.encode())

    def _handle(self):
        if self.command != "POST":
            self.deadline.cancel()   # the request is all here
        try:
            if not self._host_ok():
                raise ApiError("forbidden", "forbidden host")
            if not self.path.startswith("/"):
                raise ApiError("not_found", "not found")
            url = urllib.parse.urlsplit(self.path)
            if url.path == "/api" or url.path.startswith("/api/"):
                self._api(url)
            else:
                self._static(url.path)
        except Gone:
            self.close_connection = True
            sys.stderr.write("lore ui: a request timed out\n")
        except ApiError as err:
            self._error(err.code, str(err))
        except lore.LoreError as err:
            self._error("internal", str(err))
        except Exception as err:   # never a traceback to the client or the log
            self._error("internal", f"internal error ({type(err).__name__})")

    def _api(self, url):
        if self.command not in ("GET", "POST"):
            raise ApiError("method_not_allowed", "method not allowed")
        if not self._token_ok():
            raise ApiError("unauthorized", "unauthorized")
        routes = READS if self.command == "GET" else WRITES
        if url.path not in routes:
            if url.path in READS or url.path in WRITES:
                raise ApiError("method_not_allowed", "method not allowed")
            raise ApiError("not_found", "no such route")
        store = lore_store.Store2(self.server.root, self.server.today())
        store.require()
        if self.command == "GET":
            self._json(200, routes[url.path](store, urllib.parse.parse_qs(url.query, keep_blank_values=True)))
            return
        body = self._body()
        self.deadline.cancel()
        with store.locked(wait=False) as lk:
            if lk is None:
                raise ApiError("busy", "busy: another lore run holds the store; retry")
            self._json(200, routes[url.path](store, body))

    def _body(self):
        ctype = (self.headers.get("Content-Type") or "").split(";", 1)[0].strip().lower()
        if ctype != "application/json":
            raise ApiError("unsupported", "the body must be application/json")
        if self.headers.get("Transfer-Encoding"):
            raise ApiError("bad_request", "send the body with a Content-Length")
        length = self.headers.get("Content-Length") or ""
        if not re.fullmatch(r"[0-9]{1,9}", length):
            raise ApiError("bad_request", "a Content-Length is needed")
        if int(length) > BODY_MAX:
            raise ApiError("bad_request", f"the body is over {BODY_MAX // 1024} KiB")
        try:
            raw = self.rfile.read(int(length))
        except OSError:   # a read timeout, or the deadline closed the socket
            raise Gone()
        if len(raw) < int(length):
            raise Gone()
        try:
            data = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            raise ApiError("bad_request", "the body is not JSON")
        if not isinstance(data, dict):
            raise ApiError("bad_request", "the body must be a JSON object")
        return data

    def _static(self, path):
        if self.command != "GET":
            raise ApiError("method_not_allowed", "method not allowed")
        if path == "/":
            index = os.path.join(DIST, "index.html")
            if not os.path.isfile(index):
                self._send(503, NO_BUNDLE.encode(), "text/plain; charset=utf-8", True)
                return
            self._file(index, True)
            return
        if not path.startswith("/assets/"):
            raise ApiError("not_found", "not found")
        try:
            name = urllib.parse.unquote(path[len("/assets/"):], errors="strict")
        except UnicodeDecodeError:
            raise ApiError("not_found", "not found")
        parts = name.split("/")
        if any(p in ("", ".", "..") for p in parts) or "\\" in name or "\0" in name:
            raise ApiError("not_found", "not found")
        self._file(os.path.join(DIST, "assets", *parts), False)

    def _file(self, path, no_store):
        """Serve a file of the bundle; one that resolves outside it (a symlink) is not found."""
        base = os.path.realpath(DIST)
        real = os.path.realpath(path)
        if os.path.commonpath([real, base]) != base or not os.path.isfile(real):
            raise ApiError("not_found", "not found")
        with open(real, "rb") as f:
            data = f.read()
        self._send(200, data, TYPES.get(os.path.splitext(real)[1].lower(), "application/octet-stream"), no_store)


def bind(ports):
    """A server on 127.0.0.1 at the first port of `ports` that is free; LoreError when none is."""
    ports = list(ports)
    for port in ports:
        try:
            return Server((HOST, port), Handler)
        except OSError as err:
            if err.errno != errno.EADDRINUSE:
                raise
    if len(ports) == 1:
        raise lore.LoreError(f"port {ports[0]} is in use")
    raise lore.LoreError(f"no free port from {ports[0]} to {ports[-1]}; pass --port N")


def serve(root, port=None, today=None):
    """Serve until SIGINT or SIGTERM. Prints exactly one line, the URL with the token."""
    if port is not None and not 1 <= port <= 65535:
        raise lore.LoreError("--port must be 1 to 65535")
    srv = bind([port] if port is not None else PORTS)
    srv.root = root
    srv.token = secrets.token_urlsafe(32)
    srv.today = (lambda: lore.parse_date(today)) if today else dt.date.today

    def stop(*_):
        raise KeyboardInterrupt
    for sig in (signal.SIGINT, signal.SIGTERM):   # SIGINT too: a background job starts with it ignored
        signal.signal(sig, stop)
    print(f"lore ui: http://{HOST}:{srv.server_port}/#t={srv.token}", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.server_close()
