#!/usr/bin/env python3
"""End-to-end checks of the authentication overlay against a running stack.

    TEST_USER=jdoe TEST_PASSWORD_FILE=~/jdoe.pw python3 auth/tests/check_auth.py

TEST_USER must be allowed to log in (LDAP_USER_FILTER). Its password is read from
TEST_PASSWORD_FILE inside this process and never printed. Optional settings:

    BASE_URL      default: PUBLIC_URL from .env
    RESOLVE       host=ip[,host=ip...], like curl --resolve, for names this machine cannot resolve
    CA_FILE       CA bundle for an HTTPS BASE_URL signed by a private CA
    ENV_FILE      default: .env next to docker-compose.yml (for PUBLIC_URL, OIDC_CLIENT_SECRET)
    EXPECT_CUBES  comma-separated FoodMart cubes TEST_USER must see, exactly; also enables the
                  check that forged X-Forwarded-* headers change nothing

Exit status 0 when every check passes.
"""
import base64
import json
import os
import re
import secrets
import socket
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _apply_resolve():
    """RESOLVE=host=ip[,host=ip...]: like curl --resolve, for hosts this machine cannot resolve."""
    overrides = dict(item.split("=", 1) for item in os.environ.get("RESOLVE", "").split(",") if "=" in item)
    if not overrides:
        return
    original = socket.getaddrinfo

    def getaddrinfo(host, *args, **kwargs):
        return original(overrides.get(host, host), *args, **kwargs)
    socket.getaddrinfo = getaddrinfo


_apply_resolve()


def env_file_value(name):
    path = os.environ.get("ENV_FILE", os.path.join(ROOT, ".env"))
    with open(path) as f:
        for line in f:
            if line.startswith(name + "="):
                return line.split("=", 1)[1].strip().strip("'\"")
    raise KeyError(f"{name} is not set in {path}")


BASE = os.environ.get("BASE_URL") or env_file_value("PUBLIC_URL")
BASE = BASE.rstrip("/")
USER = os.environ["TEST_USER"]
with open(os.path.expanduser(os.environ["TEST_PASSWORD_FILE"]), "rb") as f:
    PASSWORD = f.read().decode().rstrip("\r\n")
EXPECT = [c for c in os.environ.get("EXPECT_CUBES", "").split(",") if c]

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
    '</Discover></Body></Envelope>'
).encode()

failures = 0


def request(path, data=None, headers=None, method=None):
    req = urllib.request.Request(BASE + path, data=data, headers=headers or {},
                                 method=method or ("POST" if data is not None else "GET"))
    try:
        with OPENER.open(req, timeout=30) as r:
            return r.status, r.read().decode("utf-8", "replace"), r.headers
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace"), e.headers


def basic(user, password):
    return "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()


def xmla_cubes(headers):
    h = {"Content-Type": "text/xml", "SOAPAction": '"urn:schemas-microsoft-com:xml-analysis:Discover"'}
    h.update(headers)
    status, body, _ = request("/xmla", CUBES, h)
    return status, re.findall(r"<CUBE_NAME>([^<]*)</CUBE_NAME>", body)


def check(name, ok, detail):
    global failures
    failures += not ok
    print(f"{'OK  ' if ok else 'FAIL'} | {name} | {detail}")


def cubes_ok(status, cubes):
    return status == 200 and (cubes == EXPECT if EXPECT else bool(cubes))


good = basic(USER, PASSWORD)

# Without credentials
status, _, headers = request("/")
location = headers.get("Location") or ""
check("browser page redirects to the login", status == 302 and "/protocol/openid-connect/auth" in location,
      f"HTTP {status}")
status, _, headers = request("/xmla", CUBES, {"Content-Type": "text/xml"})
# Basic among the challenges; with Kerberos on, Negotiate comes first (Excel takes the first one)
challenges = headers.get_all("WWW-Authenticate") or []
check("XML/A asks for Basic", status == 401 and any(c.startswith("Basic") for c in challenges),
      f"HTTP {status}, {challenges}")
status, _, headers = request("/emondrian/mcp", b"{}", {"Content-Type": "application/json"})
check("MCP asks for Bearer", status == 401 and (headers.get("WWW-Authenticate") or "").startswith("Bearer"),
      f"HTTP {status}, {headers.get('WWW-Authenticate')}")
status, _ = xmla_cubes({"X-Forwarded-User": "admin", "X-Forwarded-Groups": "emondrian-admins"})
check("forged X-Forwarded-* alone is refused", status == 401, f"HTTP {status}")

# Basic
status, cubes = xmla_cubes({"Authorization": good})
check("XML/A with Basic", cubes_ok(status, cubes), f"HTTP {status}, cubes {cubes}")
status, cubes = xmla_cubes({"Authorization": good})
check("XML/A with Basic again (cached)", cubes_ok(status, cubes), f"HTTP {status}")
if EXPECT:
    status, cubes = xmla_cubes({"Authorization": good, "X-Forwarded-User": "admin",
                                "X-Forwarded-Groups": "emondrian-admins"})
    check("forged X-Forwarded-* with a valid login changes nothing", cubes_ok(status, cubes),
          f"HTTP {status}, cubes {cubes}")
status, _ = xmla_cubes({"Authorization": basic(USER, secrets.token_urlsafe(18))})
check("XML/A with a wrong password", status == 401, f"HTTP {status}")
status, _ = xmla_cubes({"Authorization": basic("nosuchuser-" + secrets.token_hex(4), secrets.token_urlsafe(18))})
check("XML/A with an unknown user", status == 401, f"HTTP {status}")

# Bearer: a token of the gateway client, through the public token endpoint
form = urllib.parse.urlencode({
    "grant_type": "password", "client_id": "emondrian-gateway",
    "client_secret": env_file_value("OIDC_CLIENT_SECRET"),
    "username": USER, "password": PASSWORD, "scope": "openid",
}).encode()
status, body, _ = request("/auth/realms/emondrian/protocol/openid-connect/token", form,
                          {"Content-Type": "application/x-www-form-urlencoded"})
token = json.loads(body).get("access_token") if status == 200 else None
if token:
    payload = token.split(".")[1]
    claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    aud = claims.get("aud") if isinstance(claims.get("aud"), list) else [claims.get("aud")]
    check("token carries user, groups and audience",
          claims.get("preferred_username") == USER and "emondrian" in aud and isinstance(claims.get("groups"), list),
          f"user={claims.get('preferred_username')}, groups={claims.get('groups')}, aud={aud}")
    status, cubes = xmla_cubes({"Authorization": "Bearer " + token})
    check("XML/A with Bearer", cubes_ok(status, cubes), f"HTTP {status}, cubes {cubes}")
    status, _ = xmla_cubes({"Authorization": "Bearer " + token[:-4] + "AAAA"})
    check("XML/A with a tampered Bearer token", status == 401, f"HTTP {status}")
else:
    check("token from Keycloak", False, f"HTTP {status}")

# MCP
init = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
    "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "check_auth", "version": "1"}}}).encode()
status, body, _ = request("/emondrian/mcp", init, {"Content-Type": "application/json",
                                                   "Accept": "application/json, text/event-stream",
                                                   "Authorization": good})
check("MCP initialize with Basic", status == 200 and "serverInfo" in body, f"HTTP {status}")

print(f"\n{'all checks passed' if not failures else f'{failures} check(s) failed'}")
sys.exit(1 if failures else 0)
