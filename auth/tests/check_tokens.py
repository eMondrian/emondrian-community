#!/usr/bin/env python3
"""End-to-end checks of personal tokens (one per user): log in through the browser, issue a token
on the tokens API, use it the way Excel (Basic), scripts (Bearer), Power BI's live connection
(/xmla?emondrian_token=…) and a dashboard link do, issue a second one (which revokes the first),
then revoke it.

    TEST_USER=jdoe TEST_PASSWORD_FILE=~/jdoe.pw python3 auth/tests/check_tokens.py [SOURCE]

Same settings as browser_login.py (BASE_URL, CA_FILE, RESOLVE, ENV_FILE). It replaces the test
user's own token and revokes it at the end: run it as a test user, not as someone whose clients
use a token. TOKEN_USER (default: TEST_USER) is the name the token is used under, for sources whose
user names differ from the login name. With ADMIN_USER and ADMIN_PASSWORD_FILE (a member of
/emondrian-admins) it also issues a token for TEST_USER as that administrator with Basic. The probe
of auth-tokens runs inside this stack's entry container: the compose service emondrian_entry of
project COMPOSE_PROJECT_NAME (from ENV_FILE, else the checkout's directory name, as docker compose
does), or ENTRY_CONTAINER. Exit status 0 when every check passes.
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


def entry_container():
    """(name, None) of this stack's entry container, or (None, why): never another stack's."""
    if os.environ.get("ENTRY_CONTAINER"):
        return os.environ["ENTRY_CONTAINER"], None
    project = (b.env_file_value("COMPOSE_PROJECT_NAME") or
               re.sub(r"[^a-z0-9_-]", "", os.path.basename(b.ROOT).lower()))
    found = subprocess.run(["docker", "ps", "--format", "{{.Names}}",
                            "--filter", f"label=com.docker.compose.project={project}",
                            "--filter", "label=com.docker.compose.service=emondrian_entry"],
                           capture_output=True, text=True)
    names = found.stdout.split()
    if found.returncode != 0:
        return None, f"docker ps failed: {found.stderr.strip()[:80]}"
    if len(names) != 1:
        return None, (f"{len(names)} entry containers of compose project '{project}'"
                      f"{': ' + ', '.join(names) if names else ''}; set ENTRY_CONTAINER")
    return names[0], None
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


def plain(method, url, body=None, authorization=None, data=None, content_type="application/json"):
    """A request without the session cookie and without following redirects: status, headers, body."""
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs):
            return None
    opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=b.CONTEXT), NoRedirect)
    headers = {"Content-Type": content_type} if (body is not None or data is not None) else {}
    if authorization:
        headers["Authorization"] = authorization
    payload = data if data is not None else (json.dumps(body).encode() if body is not None else None)
    req = urllib.request.Request(url, payload, headers=headers, method=method)
    try:
        with opener.open(req, timeout=30) as r:
            return r.status, r.headers, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.headers, e.read()


def cubes(answer):
    return answer.decode(errors="replace").count("<CUBE_NAME>")


def main():
    source = sys.argv[1] if len(sys.argv) > 1 else None
    if b.login(source) is None:
        return 1
    token_user = os.environ.get("TOKEN_USER", b.USER)
    api = "/account/api/tokens"

    status, data = session_call("GET", api)
    check("token list for the session's user", status == 200 and data.get("user"),
          f"HTTP {status}, user {data.get('user')}, admin {data.get('admin')}, {len(data.get('tokens', []))} token(s)")
    status, data = session_call("POST", api, {"name": "check_tokens", "days": 1}, origin=False)
    check("issue without Origin header (CSRF) is refused", status == 403, f"HTTP {status}")
    status, data = session_call("POST", api, {"name": "check_tokens", "days": 1})
    token, token_id = data.get("token"), data.get("id")
    check("issue a token", status == 201 and str(token).startswith("emk_"),
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

    # In the address: Power BI's live connection, a dashboard link; never the REST API
    st, _, body = plain("POST", f"{b.BASE}/xmla?emondrian_token={token}", data=CUBES, content_type="text/xml")
    check("XML/A with the token in the address and no credentials (Power BI live)", st == 200 and cubes(body) > 0,
          f"HTTP {st}, {cubes(body)} cubes")
    st, _, body = plain("POST", f"{b.BASE}/xmla?emondrian_token={token}", data=CUBES, content_type="text/xml",
                        authorization=basic("someone-else", "wrong"))
    check("the token in the address wins over other credentials", st == 200, f"HTTP {st}")
    st, _, _ = plain("POST", f"{b.BASE}/xmla?emondrian_token={token[:-3]}abc", data=CUBES, content_type="text/xml")
    check("an altered token in the address is refused", st == 401, f"HTTP {st}")
    st, _, _ = plain("POST", f"{b.BASE}/xmla?emondrian_token=eml_{'A' * 43}", data=CUBES, content_type="text/xml")
    check("an XML/A link (eml_) of earlier versions is refused", st == 401, f"HTTP {st}")
    st, _, body = plain("GET", f"{b.BASE}/api/v1/catalogs?emondrian_token={token}")
    refused = st == 401 and b"Authorization" in body
    check("the REST API refuses a token in the address", refused, f"HTTP {st}")
    st, _, body = plain("GET", f"{b.BASE}/api/v1/catalogs", authorization="Bearer " + token)
    check("the REST API takes it in the header", st == 200, f"HTTP {st}")
    st, headers, _ = plain("GET", f"{b.BASE}/dashboard/d/check0tokens?page=2&emondrian_token={token}")
    where = headers.get("Location") or ""
    cookie = headers.get("Set-Cookie") or ""
    check("a dashboard link: redirect without the token, other parameters kept, cookie set",
          st == 302 and "emondrian_token" not in where and "page=2" in where and "HttpOnly" in cookie,
          f"HTTP {st}, Location {where}")

    # The tokens API takes no token: a stolen one cannot renew itself
    st, _, _ = plain("POST", b.BASE + api, {"name": "x"}, authorization=basic(token_user, token))
    check("the tokens API refuses a token as the Basic password", st == 401, f"HTTP {st}")
    st, _, _ = plain("POST", b.BASE + api, {"name": "x"}, authorization="Bearer " + token)
    check("the tokens API refuses a token as Bearer", st == 401, f"HTTP {st}")
    st, _, body = plain("GET", b.BASE + api, authorization=basic(b.USER, b.PASSWORD))
    check("the tokens API takes Basic with the password", st == 200, f"HTTP {st}")
    st, _, body = plain("POST", b.BASE + api, {"user": "someone-else-entirely"}, authorization=basic(b.USER, b.PASSWORD))
    mine = session_call("GET", api)[1]
    check("a token for another user is refused for a non-administrator, or 404 for an unknown user",
          st == (404 if mine.get("admin") else 403), f"HTTP {st}")

    status, data = session_call("GET", api)
    listed = next((t for t in data.get("tokens", []) if t["id"] == token_id), {})
    check("the token is listed, with last use, without its value", bool(listed.get("last_used")) and "token" not in listed,
          f"hint {listed.get('hint')}, last used {listed.get('last_used')}")

    # The service itself answers only the gateway: asked from another container of this stack
    entry, why = entry_container()
    if not entry:
        check("auth-tokens refuses other containers (no secret)", False, why)
    else:
        probe = subprocess.run(["docker", "exec", entry, "wget", "-q", "-S", "-O", "-",
                                "--post-data", json.dumps({"token": token}), "http://auth-tokens:8080/verify"],
                               capture_output=True, text=True)
        status_line = next((l.strip() for l in probe.stderr.splitlines() if l.strip().startswith("HTTP/")), "")
        refused = " 403" in status_line and token_user not in probe.stdout
        check("auth-tokens refuses other containers (no secret)", refused,
              f"{entry}: {status_line or (probe.stderr.strip().splitlines() or ['no answer'])[0].strip()}")

    # One token per user: a second revokes the first
    if os.environ.get("ADMIN_USER") and os.environ.get("ADMIN_PASSWORD_FILE"):
        with open(os.path.expanduser(os.environ["ADMIN_PASSWORD_FILE"]), "rb") as f:
            admin_password = f.read().decode().rstrip("\r\n")
        st, _, body = plain("POST", b.BASE + api, {"user": token_user, "name": "check_tokens (admin)", "days": 1},
                            authorization=basic(os.environ["ADMIN_USER"], admin_password))
        second = json.loads(body or b"{}")
        check("an administrator issues a token for the user (Basic)",
              st == 201 and second.get("created_by") and token_id in second.get("replaced", []),
              f"HTTP {st}, created_by {second.get('created_by')}, replaced {second.get('replaced')}")
    else:
        status, second = session_call("POST", api, {"name": "check_tokens 2", "days": 1})
        check("a second token revokes the first", status == 201 and token_id in second.get("replaced", []),
              f"HTTP {status}, replaced {second.get('replaced')}")
    new_token, new_id = second.get("token"), second.get("id")

    status, data = session_call("DELETE", f"{api}/{new_id}")
    check("revoke the new token", status == 200, f"HTTP {status}")
    time.sleep(31)  # the gateway caches a verified token for 30 s
    st, n = xmla(basic(token_user, token))
    check("the replaced token is refused (after the 30 s cache)", st == 401, f"HTTP {st}")
    st, n = xmla(basic(token_user, new_token or "emk_none"))
    check("the revoked token is refused (after the 30 s cache)", st == 401, f"HTTP {st}")

    print(f"\n{'all checks passed' if not failures else f'{failures} check(s) failed'}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
