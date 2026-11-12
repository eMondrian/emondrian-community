#!/usr/bin/env python3
"""End-to-end checks of OAuth for MCP clients (MCP authorization, revision 2025-06-18), done the
way an MCP client does it, plus the device code login for command-line tools.

    TEST_USER=jdoe TEST_PASSWORD_FILE=~/jdoe.pw python3 auth/tests/check_mcp_oauth.py

Same settings as browser_login.py (BASE_URL, CA_FILE, RESOLVE). The client registered on the
way is deleted at the end. Exit status 0 when every check passes.
"""
import base64
import hashlib
import http.server
import json
import os
import secrets
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import browser_login as b  # noqa: E402

failures = 0


def check(name, ok, detail):
    global failures
    failures += not ok
    print(f"{'OK  ' if ok else 'FAIL'} | {name} | {detail}")


def call(url, data=None, headers=None, method=None, form=False):
    headers = dict(headers or {})
    body = None
    if data is not None:
        if form:
            body = urllib.parse.urlencode(data).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        else:
            body = json.dumps(data).encode()
            headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, body, headers=headers, method=method)
    opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=b.CONTEXT))
    try:
        with opener.open(req, timeout=30) as r:
            raw = r.read()
            return r.status, r.headers, json.loads(raw) if raw.strip().startswith(b"{") else raw.decode()
    except urllib.error.HTTPError as e:
        raw = e.read()
        return e.code, e.headers, json.loads(raw) if raw.strip().startswith(b"{") else raw.decode()


class Callback(http.server.BaseHTTPRequestHandler):
    """The MCP client's local redirect target."""
    received = None

    def do_GET(self):
        Callback.received = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(self.path).query))
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"done")

    def log_message(self, *args):
        pass


def browse(url, done):
    """Follows a browser flow from url (login, consent) until done() is true."""
    status, url, page = b.fetch(url)
    for _ in range(15):
        if done():
            return True
        parser = b.Forms()
        parser.feed(page)
        form = next((f for f in parser.forms if any(k == "password" for _, k, _ in f["inputs"])), None)
        if form:
            status, url, page = b.submit(url, form, fill_login=True)
            continue
        form = next((f for f in parser.forms if f["method"] == "post"), None)
        if form:  # consent ("Do you grant…") or device confirmation
            status, url, page = b.submit(url, form, fill_login=False)
            continue
        # e.g. the device flow's "login successful" page: nothing left to submit
        break
    return done()


def mcp_initialize(token):
    init = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "check_mcp_oauth", "version": "1"}}}
    status, _, body = call(b.BASE + "/emondrian/mcp", init, {"Authorization": "Bearer " + token,
                                                             "Accept": "application/json, text/event-stream"})
    return status, body


def claims(token):
    return json.loads(base64.urlsafe_b64decode(token.split(".")[1] + "=="))


def main():
    resource = b.BASE + "/emondrian/mcp"

    # 1. Discovery from the 401
    status, headers, _ = call(resource, {"jsonrpc": "2.0", "id": 1, "method": "initialize"})
    challenge = headers.get("WWW-Authenticate", "")
    metadata_url = challenge.split('resource_metadata="')[-1].rstrip('"') if "resource_metadata" in challenge else None
    check("401 names the protected resource metadata", status == 401 and bool(metadata_url), challenge)
    if not metadata_url:
        return 1
    status, _, prm = call(metadata_url)
    issuer = (prm.get("authorization_servers") or [None])[0] if isinstance(prm, dict) else None
    check("protected resource metadata (RFC 9728)", status == 200 and prm.get("resource") == resource and issuer,
          f"resource {prm.get('resource')}, authorization server {issuer}")
    parts = urllib.parse.urlsplit(issuer)
    as_url = f"{parts.scheme}://{parts.netloc}/.well-known/oauth-authorization-server{parts.path}"
    status, _, asm = call(as_url)
    check("authorization server metadata (RFC 8414 path)", status == 200 and asm.get("issuer") == issuer
          and "S256" in asm.get("code_challenge_methods_supported", []) and asm.get("registration_endpoint"),
          as_url)

    # 2. Dynamic client registration
    server = http.server.HTTPServer(("127.0.0.1", 0), Callback)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    redirect = f"http://127.0.0.1:{server.server_port}/callback"
    # As Claude Code does: the scopes of the protected resource metadata, plus offline_access for
    # a refresh token. Keycloak makes requested scopes optional and only `basic` default.
    scope = " ".join(prm.get("scopes_supported") or ["openid"])
    status, _, client = call(asm["registration_endpoint"], {
        "client_name": "check_mcp_oauth", "redirect_uris": [redirect], "token_endpoint_auth_method": "none",
        "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"],
        "scope": scope + " offline_access"})
    client_id = client.get("client_id") if isinstance(client, dict) else None
    check("dynamic client registration (localhost redirect)", status == 201 and client_id, f"HTTP {status}, client {client_id}")
    status, _, refused = call(asm["registration_endpoint"], {
        "client_name": "evil", "redirect_uris": ["https://evil.example.com/callback"], "token_endpoint_auth_method": "none"})
    check("registration with a foreign redirect is refused", status in (400, 403), f"HTTP {status}")
    if not client_id:
        return 1

    # 3. Authorization code with PKCE and the resource indicator, through the user's login
    verifier = secrets.token_urlsafe(48)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    state = secrets.token_urlsafe(16)
    authorize = asm["authorization_endpoint"] + "?" + urllib.parse.urlencode({
        "response_type": "code", "client_id": client_id, "redirect_uri": redirect, "scope": scope + " offline_access",
        "state": state, "code_challenge": challenge, "code_challenge_method": "S256", "resource": resource})
    got = browse(authorize, lambda: Callback.received is not None)
    code = (Callback.received or {}).get("code")
    check("user login and consent return a code to the client", got and code and Callback.received.get("state") == state,
          f"callback {sorted((Callback.received or {}).keys())}")
    token = None
    if code:
        status, _, tokens = call(asm["token_endpoint"], {
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirect, "client_id": client_id,
            "code_verifier": verifier, "resource": resource}, form=True)
        token = tokens.get("access_token") if isinstance(tokens, dict) else None
        c = claims(token) if token else {}
        check("token exchange with the PKCE verifier", status == 200 and token,
              f"HTTP {status}, user {c.get('preferred_username')}, aud {c.get('aud')}, groups {c.get('groups')}"
              + ("" if token else f", {tokens}"))
        check("the token carries audience and groups without asking for them", "emondrian" in str(c.get("aud"))
              and c.get("groups") is not None, f"aud {c.get('aud')}, groups {c.get('groups')}")
        check("an offline refresh token for the client", isinstance(tokens, dict) and tokens.get("refresh_token")
              and claims(tokens["refresh_token"]).get("typ") == "Offline", f"scope {(tokens or {}).get('scope')}")
    if token:
        status, body = mcp_initialize(token)
        check("MCP initialize with the client's token", status == 200 and "serverInfo" in str(body), f"HTTP {status}")
    status, headers, _ = call(resource, {"jsonrpc": "2.0", "id": 1, "method": "initialize"},
                              headers={"Authorization": "Bearer eyJhbGciOiJSUzI1NiJ9.e30.c2ln"})
    challenge = headers.get("WWW-Authenticate", "")
    check("a refused token is named in the challenge (invalid_token)", status == 401
          and 'error="invalid_token"' in challenge and "resource_metadata" in challenge, challenge)
    server.shutdown()

    # 4. Clean up the registered client (its registration access token)
    status, _, _ = call(client["registration_client_uri"], method="DELETE",
                        headers={"Authorization": "Bearer " + client["registration_access_token"]})
    check("the registered client deletes itself", status == 204, f"HTTP {status}")

    # 5. Device code (command-line tools)
    device_endpoint = asm.get("device_authorization_endpoint")
    status, _, device = call(device_endpoint, {"client_id": "emondrian-cli", "scope": "openid"}, form=True)
    check("device authorization (emondrian-cli)", status == 200 and device.get("user_code"),
          f"HTTP {status}, user code {device.get('user_code') if isinstance(device, dict) else '?'}")
    if status == 200:
        approved = {"done": False}

        def confirmed():
            st, _, poll = call(asm["token_endpoint"], {"grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                                                       "device_code": device["device_code"], "client_id": "emondrian-cli"},
                               form=True)
            if st == 200:
                approved.update(done=True, token=poll["access_token"])
            return approved["done"]
        browse(device["verification_uri_complete"], confirmed)
        deadline = time.time() + 15
        while not approved["done"] and time.time() < deadline:
            time.sleep(device.get("interval", 5))
            confirmed()
        check("device code approved in the browser, token polled", approved["done"],
              f"user {claims(approved['token']).get('preferred_username') if approved['done'] else '-'}")
        if approved["done"]:
            status, body = mcp_initialize(approved["token"])
            check("MCP initialize with the device-code token", status == 200, f"HTTP {status}")

    print(f"\n{'all checks passed' if not failures else f'{failures} check(s) failed'}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
