#!/usr/bin/env python3
"""Kerberos (Negotiate) end-to-end checks, as Excel on a domain computer would log in.

Runs where python3-gssapi and a Kerberos ticket are available, e.g. in the auth-kerberos image:

    docker run --rm -it --add-host emondrian.example.com:10.0.0.5 \\
        -v /path/krb5.conf:/etc/krb5.conf:ro -v /path/ca.pem:/ca.pem:ro -v $PWD/auth/tests:/tests:ro \\
        --entrypoint sh emondrian-auth-kerberos:local \\
        -c 'kinit jdoe@EXAMPLE.COM && BASE_URL=https://emondrian.example.com CA_FILE=/ca.pem python3 /tests/check_kerberos.py'

EXPECT=refused checks that the ticket holder is refused (not allowed by the LDAP source).
"""
import base64
import os
import re
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

import gssapi

BASE = os.environ["BASE_URL"].rstrip("/")
CONTEXT = ssl.create_default_context(cafile=os.environ.get("CA_FILE") or None)
EXPECT_REFUSED = os.environ.get("EXPECT") == "refused"
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


def xmla(authorization=None):
    headers = {"Content-Type": "text/xml"}
    if authorization:
        headers["Authorization"] = authorization
    req = urllib.request.Request(BASE + "/xmla", CUBES, headers=headers)
    opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=CONTEXT))
    try:
        with opener.open(req, timeout=30) as r:
            return r.status, r.headers, len(re.findall("<CUBE_NAME>", r.read().decode()))
    except urllib.error.HTTPError as e:
        return e.code, e.headers, 0


def ticket():
    host = urllib.parse.urlsplit(BASE).hostname
    service = gssapi.Name(f"HTTP@{host}", gssapi.NameType.hostbased_service)
    context = gssapi.SecurityContext(name=service, usage="initiate", mech=gssapi.MechType.kerberos)
    return base64.b64encode(context.step()).decode()


status, headers, _ = xmla()
schemes = [v.split()[0] for v in headers.get_all("WWW-Authenticate") or []]
# Negotiate first: Excel (MSOLAP) with Windows authentication takes the first challenge only
check("401 offers Negotiate first, then Basic", status == 401 and schemes[:2] == ["Negotiate", "Basic"],
      f"HTTP {status}, WWW-Authenticate: {schemes}")

status, headers, cubes = xmla("Negotiate " + ticket())
if EXPECT_REFUSED:
    check("ticket of a user the source does not let in is refused", status in (401, 403), f"HTTP {status}")
else:
    mutual = [v for v in headers.get_all("WWW-Authenticate") or [] if v.startswith("Negotiate ")]
    check("XML/A with a Kerberos ticket (Negotiate)", status == 200 and cubes > 0,
          f"HTTP {status}, {cubes} cubes, mutual authentication token {'returned' if mutual else 'not returned'}")
    status, _, _ = xmla("Negotiate " + base64.b64encode(b"\x60\x10not-a-real-gss-token").decode())
    check("a forged Negotiate token is refused", status == 401, f"HTTP {status}")

    # Browser: Keycloak's login page asks for Negotiate; the ticket replaces the form
    import http.cookiejar

    class Raw(urllib.request.HTTPErrorProcessor):
        def http_response(self, request, response):
            return response
        https_response = http_response

    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs):
            return None

    browser = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
                                          urllib.request.HTTPSHandler(context=CONTEXT), NoRedirect, Raw)
    url, asked = BASE + "/", False
    for _ in range(10):
        response = browser.open(urllib.request.Request(url), timeout=30)
        if response.status == 401 and "Negotiate" in (response.headers.get("WWW-Authenticate") or "") and not asked:
            asked = True
            response = browser.open(urllib.request.Request(url, headers={"Authorization": "Negotiate " + ticket()}),
                                    timeout=30)
        if response.status in (301, 302, 303):
            url = urllib.parse.urljoin(url, response.headers["Location"])
            continue
        break
    page_status = response.status
    session = browser.open(urllib.request.Request(BASE + "/account/api/tokens"), timeout=30).status
    check("browser login with the ticket, without the form", asked and page_status == 200 and session == 200,
          f"Keycloak asked for Negotiate: {asked}, page HTTP {page_status}, session HTTP {session}")

print(f"\n{'all checks passed' if not failures else f'{failures} check(s) failed'}")
sys.exit(1 if failures else 0)
