#!/usr/bin/env python3
"""End-to-end checks of XML/A links (/xmla?emondrian_token=…, for Power BI Desktop's live
connection): log in through the browser, get a link on /account/api/link, use it without any
other credentials, replace it, revoke it.

    TEST_USER=jdoe TEST_PASSWORD_FILE=~/jdoe.pw python3 auth/tests/check_xmla_link.py [SOURCE]

Same settings as browser_login.py (BASE_URL, CA_FILE, RESOLVE, ENV_FILE). It replaces the test
user's own link and revokes it at the end: run it as a test user, not as someone whose reports
use a link. Exit status 0 when every check passes.
"""
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import browser_login as b  # noqa: E402
from check_tokens import CUBES, check, session_call  # noqa: E402
import check_tokens  # noqa: E402


def xmla_url(url, authorization=None):
    """POST a Discover to a full URL without the session cookie, as Power BI does."""
    opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=b.CONTEXT))
    headers = {"Content-Type": "text/xml"}
    if authorization:
        headers["Authorization"] = authorization
    req = urllib.request.Request(url, CUBES, headers=headers)
    try:
        with opener.open(req, timeout=30) as r:
            return r.status, r.read().decode().count("<CUBE_NAME>")
    except urllib.error.HTTPError as e:
        return e.code, 0


def main():
    source = sys.argv[1] if len(sys.argv) > 1 else None
    if b.login(source) is None:
        return 1

    status, data = session_call("GET", "/account/api/link")
    check("link state for the session's user", status == 200 and data.get("user"),
          f"HTTP {status}, enabled {data.get('enabled')}, valid for {data.get('days')} days")
    status, data = session_call("POST", "/account/api/link", {}, origin=False)
    check("create without Origin header (CSRF) is refused", status == 403, f"HTTP {status}")
    status, data = session_call("POST", "/account/api/link", {})
    url = data.get("url") or ""
    check("create a link", status == 201 and url.startswith(b.BASE + "/xmla?emondrian_token=eml_"),
          f"HTTP {status}, expires {data.get('expires')}")
    if status != 201:
        return 1
    token = urllib.parse.parse_qs(urllib.parse.urlsplit(url).query)["emondrian_token"][0]
    check("the token needs no escaping in a URL", urllib.parse.quote(token, safe="") == token, "base64url")

    st, n = xmla_url(url)
    check("XML/A with the link and no credentials (Power BI live)", st == 200 and n > 0, f"HTTP {st}, {n} cubes")
    st, n = xmla_url(url, check_tokens.basic("someone-else", "wrong"))
    check("the link wins over other credentials", st == 200 and n > 0, f"HTTP {st}")
    st, n = xmla_url(url[:-3] + "abc")
    check("an altered link is refused", st == 401, f"HTTP {st}")
    st, n = xmla_url(b.BASE + "/xmla?emondrian_token=")
    check("an empty token is refused", st == 401, f"HTTP {st}")
    st, n = xmla_url(b.BASE + "/xmla")
    check("no link and no credentials: 401 as before", st == 401, f"HTTP {st}")

    status, data = session_call("POST", "/account/api/link", {})
    new_url = data.get("url") or ""
    check("a new link replaces the old one", status == 201 and data.get("replaced") is True, f"HTTP {status}")
    time.sleep(31)  # the gateway caches a verified link for 30 s
    st, n = xmla_url(url)
    check("the replaced link is refused (after the 30 s cache)", st == 401, f"HTTP {st}")
    st, n = xmla_url(new_url)
    check("the new link works", st == 200 and n > 0, f"HTTP {st}, {n} cubes")

    status, data = session_call("GET", "/account/api/link")
    link = data.get("link") or {}
    check("the link is shown with its last use, without its value", bool(link.get("last_used"))
          and "token" not in link and "url" not in link, f"expires {link.get('expires')}")

    status, data = session_call("DELETE", "/account/api/link")
    check("revoke the link", status == 200 and data.get("revoked") is True, f"HTTP {status}")
    time.sleep(31)
    st, n = xmla_url(new_url)
    check("the revoked link is refused (after the 30 s cache)", st == 401, f"HTTP {st}")

    print(f"\n{'all checks passed' if not check_tokens.failures else f'{check_tokens.failures} check(s) failed'}")
    return 1 if check_tokens.failures else 0


if __name__ == "__main__":
    sys.exit(main())
