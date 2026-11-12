#!/usr/bin/env python3
"""Mode trusted-proxy: requests through the SSO proxy get in, the same identity headers sent
past the proxy do not, and a personal token created through the proxy works without it.

    PROXY_URL=http://localhost:9180 PROXY_USER=sam PROXY_PASSWORD_FILE=<file> \\
        python3 auth/tests/check_trusted_proxy.py

PROXY_URL is the proxy in front of the gateway; it asks for Basic credentials (its own users).
NOROLE_USER (optional) is a proxy user holding no eMondrian role. BASE_URL / CA_FILE / RESOLVE
as for browser_login.py address the gateway directly. Exit status 0 when every check passes.
"""
import base64
import json
import os
import sys
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.environ.setdefault("TEST_USER", os.environ.get("PROXY_USER", "sam"))
os.environ.setdefault("TEST_PASSWORD_FILE", os.environ["PROXY_PASSWORD_FILE"])
import check_tokens as c  # noqa: E402

PROXY = os.environ["PROXY_URL"].rstrip("/")
USER = os.environ.get("PROXY_USER", "sam")
PASSWORD = open(os.path.expanduser(os.environ["PROXY_PASSWORD_FILE"])).read().strip()
NOROLE = os.environ.get("NOROLE_USER")


def via_proxy(path, user=USER, data=None, method=None, headers=None):
    h = {"Authorization": c.basic(user, PASSWORD)}
    h.update(headers or {})
    req = urllib.request.Request(PROXY + path, data, headers=h, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def direct(path, headers, data=None):
    opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=c.b.CONTEXT))
    req = urllib.request.Request(c.b.BASE + path, data, headers=headers)
    try:
        with opener.open(req, timeout=30) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code


def main():
    st, _ = via_proxy("/")
    c.check("browser page through the proxy", st == 200, f"HTTP {st}")
    st, body = via_proxy("/xmla", data=c.CUBES, headers={"Content-Type": "text/xml"})
    c.check("XML/A through the proxy", st == 200 and "<CUBE_NAME>" in body, f"HTTP {st}")
    if NOROLE:
        st, _ = via_proxy("/", user=NOROLE)
        c.check("a proxy user holding no eMondrian role", st == 403, f"HTTP {st}")
    forged = {"X-Forwarded-User": USER, "X-Forwarded-Groups": "BI-Users,BI-Admins",
              "Cf-Access-Jwt-Assertion": "eyJhbGciOiJub25lIn0.eyJlbWFpbCI6InhAeCJ9."}
    c.check("identity headers sent past the proxy (browser)", direct("/", forged) == 403, "forged headers refused")
    st = direct("/xmla", dict(forged, **{"Content-Type": "text/xml"}), c.CUBES)
    c.check("identity headers sent past the proxy (XML/A)", st in (401, 403), f"HTTP {st}")
    st, body = via_proxy("/account/api/tokens", data=json.dumps({"name": "check_trusted_proxy", "days": 1}).encode(),
                         headers={"Content-Type": "application/json", "Origin": c.b.BASE})
    created = json.loads(body) if st == 201 else {}
    c.check("personal token created through the proxy", st == 201, f"HTTP {st}")
    if created:
        owner = created.get("owner")
        st, n = c.xmla(c.basic(owner, created["token"]))
        c.check("Excel with that token, not through the proxy", st == 200 and n > 0, f"HTTP {st}, user {owner}")
        via_proxy(f"/account/api/tokens/{created['id']}", method="DELETE", headers={"Origin": c.b.BASE})
    print(f"\n{'all checks passed' if not c.failures else f'{c.failures} check(s) failed'}")
    return 1 if c.failures else 0


if __name__ == "__main__":
    sys.exit(main())
