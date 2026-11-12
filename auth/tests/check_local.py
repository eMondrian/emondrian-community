#!/usr/bin/env python3
"""First login of a local user (source type local): the initial password opens nothing but the
page that asks for a new one; a weak new password is refused; the new one works everywhere.

    TEST_USER=admin TEST_PASSWORD_FILE=<initial password> NEW_PASSWORD_FILE=<new password> \\
        python3 auth/tests/check_local.py

The user must not have logged in yet (a fresh initial password). Same settings as
browser_login.py (BASE_URL, CA_FILE, RESOLVE). Exit status 0 when every check passes.
"""
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import browser_login as b  # noqa: E402
import check_tokens as c  # noqa: E402

NEW = open(os.path.expanduser(os.environ["NEW_PASSWORD_FILE"])).read().strip()


def update_form(page):
    parser = b.Forms()
    parser.feed(page)
    return next((f for f in parser.forms if any(n == "password-new" for n, _, _ in f["inputs"])), None)


def set_new(url, form, value):
    fields = [(n, value if n in ("password-new", "password-confirm") else v)
              for n, k, v in form["inputs"] if k not in ("submit", "button")]
    return b.fetch(urllib.parse.urljoin(url, form["action"]), urllib.parse.urlencode(fields).encode())


def main():
    st, n = c.xmla(c.basic(b.USER, b.PASSWORD))
    c.check("Excel with the initial password, before the first login", st == 401, f"HTTP {st}")
    status, url, page = b.fetch(b.BASE + "/")
    parser = b.Forms()
    parser.feed(page)
    login = next((f for f in parser.forms if any(k == "password" for _, k, _ in f["inputs"])), None)
    if not login:
        c.check("login page", False, parser.title)
        return 1
    status, url, page = b.submit(url, login, fill_login=True)
    form = update_form(page)
    c.check("Keycloak asks for a new password", form is not None, f"HTTP {status}")
    if not form:
        return 1
    status, url, page = set_new(url, form, "short1")
    c.check("a weak new password is refused (password policy)", update_form(page) is not None, f"HTTP {status}")
    status, url, page = set_new(url, update_form(page), NEW)
    c.check("the new password is accepted, logged in", status == 200 and "/auth/" not in urllib.parse.urlsplit(url).path,
            f"HTTP {status}")
    try:
        with b.OPENER.open(urllib.request.Request(b.BASE + "/logs/"), timeout=20) as r:
            logs = r.status
    except urllib.error.HTTPError as e:
        logs = e.code
    c.check("server logs for an emondrian-admins member", logs == 200, f"HTTP {logs}")
    st, n = c.xmla(c.basic(b.USER, NEW))
    c.check("Excel with the new password", st == 200 and n > 0, f"HTTP {st}, {n} cubes")
    st, n = c.xmla(c.basic(b.USER, b.PASSWORD))
    c.check("the initial password no longer works", st == 401, f"HTTP {st}")
    return 1 if c.failures else 0


if __name__ == "__main__":
    sys.exit(main())
