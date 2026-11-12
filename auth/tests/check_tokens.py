#!/usr/bin/env python3
"""End-to-end checks of personal access tokens: log in through the browser, create a token on
the /account/tokens API, use it the way Excel (Basic) and scripts (Bearer) do, revoke it.

    TEST_USER=jdoe TEST_PASSWORD_FILE=~/jdoe.pw python3 auth/tests/check_tokens.py [SOURCE]

Same settings as browser_login.py (BASE_URL, CA_FILE, RESOLVE, ENV_FILE). The token created is
revoked at the end. TOKEN_USER (default: TEST_USER) is the name the token is used under, for
sources whose user names differ from the login name. Exit status 0 when every check passes.
"""
import base64
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import browser_login as b  # noqa: E402  (reads the settings from the environment)

failures = 0
CUBES = (
    '<Envelope xmlns="http://schemas.xmlsoap.org/soap/envelope/"><Body>'
    '<Discover xmlns="urn:schemas-microsoft-com:xml-analysis"><RequestType>MDSCHEMA_CUBES</RequestType>'
    '<Restrictions><RestrictionList><CATALOG_NAME>FoodMart</CATALOG_NAME></RestrictionList></Restrictions>'
    '<Properties><PropertyList><Catalog>FoodMart</Catalog></PropertyList></Properties>'
    '</Discover></Body></Envelope>').encode()


def check(name, ok, detail):
    global failures
    failures += not ok
    print(f"{'OK  ' if ok else 'FAIL'} | {name} | {detail}")


def session_call(method, path, body=None, origin=True):
    headers = {"Content-Type": "application/json"} if body is not None else {}
    if origin:
        headers["Origin"] = b.BASE
    req = urllib.request.Request(b.BASE + path, json.dumps(body).encode() if body is not None else None,
                                 headers=headers, method=method)
    try:
        with b.OPENER.open(req, timeout=30) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def xmla(authorization):
    # No session cookie: a fresh opener, like Excel
    opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=b.CONTEXT))
    req = urllib.request.Request(b.BASE + "/xmla", CUBES, headers={"Content-Type": "text/xml",
                                                                   "Authorization": authorization})
    try:
        with opener.open(req, timeout=30) as r:
            return r.status, len(re.findall("<CUBE_NAME>", r.read().decode()))
    except urllib.error.HTTPError as e:
        return e.code, 0


def basic(user, password):
    return "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()


def main():
    source = sys.argv[1] if len(sys.argv) > 1 else None
    if b.login(source) is None:
        return 1
    token_user = os.environ.get("TOKEN_USER", b.USER)

    status, data = session_call("GET", "/account/api/tokens")
    check("token list for the session's user", status == 200 and data.get("user"),
          f"HTTP {status}, user {data.get('user')}, admin {data.get('admin')}, {len(data.get('tokens', []))} token(s)")
    status, data = session_call("POST", "/account/api/tokens", {"name": "check_tokens", "days": 1}, origin=False)
    check("create without Origin header (CSRF) is refused", status == 403, f"HTTP {status}")
    status, data = session_call("POST", "/account/api/tokens", {"name": "check_tokens", "days": 1})
    token, token_id = data.get("token"), data.get("id")
    check("create a token", status == 201 and str(token).startswith("emk_"),
          f"HTTP {status}, hint {data.get('hint')}, expires {data.get('expires')}")
    if not token:
        return 1

    st, n = xmla(basic(token_user, token))
    check("XML/A with Basic: user name + token (Excel)", st == 200 and n > 0, f"HTTP {st}, {n} cubes")
    st, n = xmla("Bearer " + token)
    check("XML/A with Bearer token (scripts, MCP)", st == 200 and n > 0, f"HTTP {st}, {n} cubes")
    st, n = xmla(basic("someone-else", token))
    check("the token under another user name is refused", st == 401, f"HTTP {st}")
    st, n = xmla(basic(token_user, token[:-3] + "abc"))
    check("an altered token is refused", st == 401, f"HTTP {st}")

    status, data = session_call("GET", "/account/api/tokens")
    mine = next((t for t in data.get("tokens", []) if t["id"] == token_id), {})
    check("the token is listed, with last use, without its value", bool(mine.get("last_used")) and "token" not in mine,
          f"hint {mine.get('hint')}, last used {mine.get('last_used')}")

    # The service itself answers only the gateway
    probe = subprocess.run(["docker", "exec", "emondrian_entry", "wget", "-q", "-S", "-O", "-",
                            "--post-data", json.dumps({"token": token}), "http://auth-tokens:8080/verify"],
                           capture_output=True, text=True)
    refused = "403" in probe.stderr and token_user not in probe.stdout
    check("auth-tokens refuses other containers (no secret)", refused, (probe.stderr.strip().splitlines() or ["?"])[0].strip())

    status, data = session_call("DELETE", f"/account/api/tokens/{token_id}")
    check("revoke the token", status == 200, f"HTTP {status}")
    time.sleep(31)  # the gateway caches a verified token for 30 s
    st, n = xmla(basic(token_user, token))
    check("the revoked token is refused (after the 30 s cache)", st == 401, f"HTTP {st}")

    print(f"\n{'all checks passed' if not failures else f'{failures} check(s) failed'}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
