#!/usr/bin/env python3
"""Authentication off (open_access in identity.yml): everything opens without logging in, as the
guest with its roles, whatever credentials or forged headers a request carries.

    python3 auth/tests/check_open.py

Same settings as check_auth.py (BASE_URL, CA_FILE, RESOLVE, ENV_FILE); no user needed. The guest
must hold emondrian-admins (the default), which the /logs/ check relies on. Exit status 0 when
every check passes.
"""
import json
import os
import re
import socket
import ssl
import sys
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

overrides = dict(i.split("=", 1) for i in os.environ.get("RESOLVE", "").split(",") if "=" in i)
if overrides:
    _getaddrinfo = socket.getaddrinfo
    socket.getaddrinfo = lambda host, *a, **k: _getaddrinfo(overrides.get(host, host), *a, **k)


def env_file_value(name):
    with open(os.environ.get("ENV_FILE", os.path.join(ROOT, ".env"))) as f:
        for line in f:
            if line.startswith(name + "="):
                return line.split("=", 1)[1].strip().strip("'\"")
    raise KeyError(name)


BASE = (os.environ.get("BASE_URL") or env_file_value("PUBLIC_URL")).rstrip("/")
CONTEXT = ssl.create_default_context(cafile=os.environ.get("CA_FILE") or None)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


OPENER = urllib.request.build_opener(NoRedirect, urllib.request.HTTPSHandler(context=CONTEXT))
CUBES = (
    '<Envelope xmlns="http://schemas.xmlsoap.org/soap/envelope/"><Body>'
    '<Discover xmlns="urn:schemas-microsoft-com:xml-analysis"><RequestType>MDSCHEMA_CUBES</RequestType>'
    '<Restrictions><RestrictionList><CATALOG_NAME>FoodMart</CATALOG_NAME></RestrictionList></Restrictions>'
    '<Properties><PropertyList><Catalog>FoodMart</Catalog></PropertyList></Properties>'
    '</Discover></Body></Envelope>').encode()
failures = 0


def check(name, ok, detail):
    global failures
    failures += not ok
    print(f"{'OK  ' if ok else 'FAIL'} | {name} | {detail}")


def request(path, data=None, headers=None):
    req = urllib.request.Request(BASE + path, data=data, headers=headers or {})
    try:
        with OPENER.open(req, timeout=30) as r:
            return r.status, r.read().decode("utf-8", "replace"), r.headers
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace"), e.headers


def cubes(headers=None):
    h = {"Content-Type": "text/xml"}
    h.update(headers or {})
    status, body, _ = request("/xmla", CUBES, h)
    return status, re.findall(r"<CUBE_NAME>([^<]*)</CUBE_NAME>", body)


status, _, headers = request("/")
check("browser page opens without a login", status == 200, f"HTTP {status} {headers.get('Location') or ''}")
status, _, _ = request("/logs/")
check("server logs open (guest holds emondrian-admins)", status == 200, f"HTTP {status}")

status, names = cubes()
check("XML/A without credentials (Excel, Windows authentication)", status == 200 and bool(names),
      f"HTTP {status}, {len(names)} cubes")
status, names = cubes({"Authorization": "Basic bm9ib2R5Ondyb25n"})  # nobody:wrong
check("XML/A with a stale saved password still opens", status == 200 and bool(names), f"HTTP {status}")
status, names = cubes({"Authorization": "Negotiate YIIBnotaticket"})
check("XML/A with a Negotiate token still opens", status == 200 and bool(names), f"HTTP {status}")
status, _, _ = request("/logs/", headers={"X-Forwarded-User": "nobody", "X-Forwarded-Groups": "nothing"})
check("forged X-Forwarded-* are overwritten (still the guest)", status == 200, f"HTTP {status}")

init = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
    "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "check_open", "version": "1"}}}).encode()
status, body, _ = request("/emondrian/mcp", init, {"Content-Type": "application/json",
                                                   "Accept": "application/json, text/event-stream"})
check("MCP without credentials", status == 200 and "serverInfo" in body, f"HTTP {status}")

status, _, _ = request("/account/api/tokens")
check("no personal tokens with authentication off", status == 403, f"HTTP {status}")
status, _, headers = request("/logout")
check("/logout leads back to the start page", status == 302 and headers.get("Location") == "/",
      f"HTTP {status} {headers.get('Location')}")

print(f"\n{'all checks passed' if not failures else f'{failures} check(s) failed'}")
sys.exit(1 if failures else 0)
