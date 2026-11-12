#!/usr/bin/env python3
"""Mode oidc-direct: tokens and passwords checked by the customer's provider itself.

    TOKEN_URL=https://sso.example.com/realms/corp/protocol/openid-connect/token CLIENT_ID=emondrian \\
    CLIENT_SECRET_FILE=<file> TEST_USER=jdoe TEST_PASSWORD_FILE=<file> python3 auth/tests/check_provider_token.py

Gets an access token from the provider (password grant) and uses it as Bearer; uses the
password as Basic (needs basic_password_grant: true). EXTRA_PARAMS (optional, URL-encoded) are
added to the token request, e.g. resource=<client id> for AD FS. Same settings as
browser_login.py otherwise. Exit status 0 when every check passes.
"""
import json
import os
import secrets
import sys
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import browser_login as b  # noqa: E402
import check_tokens as c  # noqa: E402


def main():
    form = {"grant_type": "password", "client_id": os.environ["CLIENT_ID"],
            "client_secret": open(os.path.expanduser(os.environ["CLIENT_SECRET_FILE"])).read().strip(),
            "username": b.USER, "password": b.PASSWORD, "scope": "openid"}
    form.update(dict(urllib.parse.parse_qsl(os.environ.get("EXTRA_PARAMS", ""))))
    try:
        with urllib.request.urlopen(urllib.request.Request(os.environ["TOKEN_URL"], urllib.parse.urlencode(form).encode()),
                                    timeout=30, context=b.CONTEXT) as r:
            token = json.load(r)["access_token"]
    except (urllib.error.URLError, KeyError, ValueError) as e:
        c.check("access token from the provider", False, str(e))
        return 1
    st, n = c.xmla("Bearer " + token)
    c.check("XML/A with the provider's access token", st == 200 and n > 0, f"HTTP {st}, {n} cubes")
    st, n = c.xmla("Bearer " + token[:-4] + "AAAA")
    c.check("the provider's token with a broken signature", st == 401, f"HTTP {st}")
    st, n = c.xmla(c.basic(b.USER, b.PASSWORD))
    c.check("Basic with the password (provider's password grant)", st == 200 and n > 0, f"HTTP {st}, {n} cubes")
    st, n = c.xmla(c.basic(b.USER, secrets.token_hex(8)))
    c.check("Basic with a wrong password", st == 401, f"HTTP {st}")
    print(f"\n{'all checks passed' if not c.failures else f'{c.failures} check(s) failed'}")
    return 1 if c.failures else 0


if __name__ == "__main__":
    sys.exit(main())
