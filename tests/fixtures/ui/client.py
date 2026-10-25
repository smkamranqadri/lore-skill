"""A raw HTTP client for tests/test-ui-server.sh: any Host header (or none), any path as sent,
and a record of every response's headers so the suite can check them all at the end."""

import http.client
import json
import os

PORT = int(os.environ["UI_PORT"])
with open(os.environ["UI_OUT"]) as f:
    LINE = f.read()
TOKEN = LINE.rsplit("#t=", 1)[-1].strip()
HOST = f"127.0.0.1:{PORT}"
SEEN = []   # (method, path, status, [(header, value)])


def req(method, path, token=TOKEN, host=HOST, body=None, ctype="application/json", headers=()):
    """One request; `host` may be None (no Host header) or a list (several). Returns
    (status, {lowercased header: value}, body bytes)."""
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=60)
    c.putrequest(method, path, skip_host=True, skip_accept_encoding=True)
    for h in ([host] if isinstance(host, str) else host or []):
        c.putheader("Host", h)
    if token is not None:
        c.putheader("X-Lore-Token", token)
    data = None
    if body is not None:
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        if ctype is not None:
            c.putheader("Content-Type", ctype)
        c.putheader("Content-Length", str(len(data)))
    for k, v in headers:
        c.putheader(k, v)
    c.endheaders()
    if data:
        c.send(data)
    r = c.getresponse()
    out = r.read()
    hdrs = r.getheaders()
    c.close()
    SEEN.append((method, path, r.status, hdrs))
    return r.status, {k.lower(): v for k, v in hdrs}, out


def api(method, path, body=None, **kw):
    """An API call: (status, the JSON body)."""
    status, _, out = req(method, path, body=body, **kw)
    return status, json.loads(out)


SECURITY = {"x-content-type-options": "nosniff", "referrer-policy": "no-referrer",
            "content-security-policy": "default-src 'self'; img-src 'self' data:; frame-ancestors 'none'"}


def headers_ok(fail):
    """Every response seen: no CORS header, no cookie, the security headers exactly once each, and
    no-store on every API response and on the page itself."""
    if not SEEN:
        fail("no responses were checked")
    for method, path, status, hdrs in SEEN:
        names = [k.lower() for k, _ in hdrs]
        what = f"{method} {path} ({status})"
        if any(n.startswith("access-control-") for n in names) or "set-cookie" in names:
            fail(f"{what}: a CORS or cookie header: {hdrs}")
        for k, v in SECURITY.items():
            if [x for n, x in hdrs if n.lower() == k] != [v]:
                fail(f"{what}: {k} is not exactly {v!r}: {hdrs}")
        if (path == "/" or path.startswith("/api")) and [x for n, x in hdrs if n.lower() == "cache-control"] != ["no-store"]:
            fail(f"{what}: no Cache-Control: no-store")
    return len(SEEN)
