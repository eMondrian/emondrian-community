"""Kerberos (SPNEGO, "Negotiate") for the auth gateway: Excel and Power BI on domain computers
log in with the Windows session, without a password.

The gateway hands each "Authorization: Negotiate <token>" here. This service accepts the token
with the service's keytab (no round trip to the KDC), then looks the user up in Keycloak, in the
LDAP source named in identity.yml (kerberos.source), for their groups. A user that source does
not let in (allowed_groups, user_filter, disabled account) is refused like at the login page.

Only the gateway talks to it, inside the compose network; requests carry X-Kerberos-Secret
(derived from SESSION_SECRET).

    POST /accept  {"token": "<base64>"}  ->  {"user", "groups", "principal", "output_token"}
    GET  /health
"""
import base64
import hashlib
import hmac
import json
import os
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import gssapi

SECRET = hashlib.sha256(b"emondrian-kerberos\0" + os.environ["SESSION_SECRET"].encode()).hexdigest()
SETTINGS_FILE = os.environ.get("KERBEROS_SETTINGS", "/generated/kerberos.json")
KEYTAB = os.environ.get("KRB5_KTNAME", "/etc/kerberos/http.keytab")
# Groups of a user are looked up again after this long
LOOKUP_CACHE_SECONDS = int(os.environ.get("KERBEROS_LOOKUP_CACHE", "300"))

_cache = {}
_cache_lock = threading.Lock()
_token = {"value": None, "expires": 0}


def settings():
    try:
        with open(SETTINGS_FILE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {"enabled": False}


def keycloak_token(s):
    """Access token of the service account that may look users up (view-users)."""
    if _token["value"] and time.time() < _token["expires"]:
        return _token["value"]
    body = urllib.parse.urlencode({"grant_type": "client_credentials", "client_id": s["client_id"],
                                   "client_secret": s["client_secret"]}).encode()
    with urllib.request.urlopen(f"{s['keycloak_url']}/realms/{s['realm']}/protocol/openid-connect/token",
                                body, timeout=10) as r:
        data = json.load(r)
    _token.update(value=data["access_token"], expires=time.time() + data.get("expires_in", 60) - 15)
    return _token["value"]


def keycloak_get(s, path, query=None):
    url = f"{s['keycloak_url']}/admin/realms/{s['realm']}{path}"
    if query:
        url += "?" + urllib.parse.urlencode(query)
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + keycloak_token(s)})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.load(r)


def lookup(s, username):
    """(groups, None) for a user of the configured source, or (None, reason)."""
    now = time.time()
    with _cache_lock:
        hit = _cache.get(username.lower())
        if hit and hit[0] > now:
            return hit[1], hit[2]
    users = keycloak_get(s, "/users", {"username": username, "exact": "true"})
    if not users:
        result = (None, "not found or not allowed to log in")
    elif users[0].get("federationLink") != s["source_id"]:
        result = (None, "belongs to another source")
    elif not users[0].get("enabled", False):
        result = (None, "disabled")
    else:
        result = ([g["name"] for g in keycloak_get(s, f"/users/{users[0]['id']}/groups")], None)
    with _cache_lock:
        _cache[username.lower()] = (now + LOOKUP_CACHE_SECONDS, *result)
    return result


class Handler(BaseHTTPRequestHandler):
    server_version = "emondrian-kerberos"

    def log_message(self, fmt, *args):
        print(f"{self.address_string()} {self.command} {self.path} {args[1] if len(args) > 1 else ''}", flush=True)

    def reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            s = settings()
            return self.reply(200, {"status": "UP", "enabled": bool(s.get("enabled")),
                                    "keytab": os.path.exists(s.get("keytab", KEYTAB))})
        self.reply(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/accept" or not hmac.compare_digest(self.headers.get("X-Kerberos-Secret", ""), SECRET):
            return self.reply(403, {"error": "forbidden"})
        s = settings()
        if not s.get("enabled"):
            return self.reply(404, {"error": "Kerberos is turned off"})
        try:
            length = int(self.headers.get("Content-Length") or 0)
            token = base64.b64decode(json.loads(self.rfile.read(min(length, 65536)))["token"])
        except (ValueError, KeyError, TypeError):
            return self.reply(400, {"error": "invalid request"})
        try:
            server = gssapi.Name(s["service_principal"], gssapi.NameType.kerberos_principal)
            # The keytab named in identity.yml (kerberos.keytab_file)
            creds = gssapi.Credentials(name=server, usage="accept", store={"keytab": s.get("keytab", KEYTAB)})
            context = gssapi.SecurityContext(creds=creds, usage="accept")
            output = context.step(token)
        except gssapi.exceptions.GSSError as e:
            print(f"ticket refused: {e}", flush=True)
            return self.reply(401, {"error": "ticket refused"})
        if not context.complete:
            # Kerberos completes in one step; anything else (NTLM) is not supported
            return self.reply(401, {"error": "only Kerberos is supported"})
        principal = str(context.initiator_name)
        name, _, realm = principal.partition("@")
        if realm.upper() != s["kerberos_realm"].upper():
            print(f"ticket of {principal} refused: realm is not {s['kerberos_realm']}", flush=True)
            return self.reply(401, {"error": "foreign realm"})
        try:
            groups, reason = lookup(s, name)
        except (urllib.error.URLError, OSError, KeyError, ValueError) as e:
            print(f"user lookup failed: {e}", flush=True)
            return self.reply(503, {"error": "user lookup failed"})
        if groups is None:
            print(f"{principal} refused: {reason}", flush=True)
            return self.reply(403, {"error": reason})
        self.reply(200, {"user": name, "groups": groups, "principal": principal,
                         "output_token": base64.b64encode(output).decode() if output else None})


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
