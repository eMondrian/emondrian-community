#!/usr/bin/env python3
"""Logs in through the browser flow, as a person would, and checks the session it ends with.

    TEST_USER=jdoe TEST_PASSWORD_FILE=~/jdoe.pw python3 auth/tests/browser_login.py [SOURCE]

SOURCE is an oidc or saml source of identity.yml (opens /?idp=SOURCE); without it, the user logs
in on Keycloak's own login page (directory sources). The script fills the first form with a
password field (Keycloak, AD FS and most providers' login pages), submits the automatic SAML
forms, and fails on any other page. TEST_PASSWORD_FILE is read inside this process and never
printed. Optional: RESOLVE (host=ip,... like curl --resolve), BASE_URL (default PUBLIC_URL from .env), CA_FILE, ENV_FILE,
EXPECT_DENIED=1 (the user must be refused with 403: no eMondrian role).
"""
import html.parser
import http.cookiejar
import os
import re
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


BASE = (os.environ.get("BASE_URL") or env_file_value("PUBLIC_URL")).rstrip("/")
USER = os.environ["TEST_USER"]
with open(os.path.expanduser(os.environ["TEST_PASSWORD_FILE"]), "rb") as f:
    PASSWORD = f.read().decode().rstrip("\r\n")
SOURCE = sys.argv[1] if len(sys.argv) > 1 else None
EXPECT_DENIED = os.environ.get("EXPECT_DENIED") == "1"

CONTEXT = ssl.create_default_context(cafile=os.environ.get("CA_FILE") or None)
JAR = http.cookiejar.CookieJar()
OPENER = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(JAR),
                                     urllib.request.HTTPSHandler(context=CONTEXT))


class Forms(html.parser.HTMLParser):
    """Collects the forms of a page: action, method and inputs (name, type, value)."""

    def __init__(self):
        super().__init__()
        self.forms, self.title, self._in_title = [], "", False

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "form":
            self.forms.append({"action": a.get("action") or "", "method": (a.get("method") or "get").lower(),
                               "inputs": []})
        elif tag == "input" and self.forms and a.get("name"):
            self.forms[-1]["inputs"].append((a["name"], (a.get("type") or "text").lower(), a.get("value") or ""))
        elif tag == "title":
            self._in_title = True

    def handle_endtag(self, tag):
        if tag == "title":
            self._in_title = False

    def handle_data(self, data):
        if self._in_title:
            self.title += data.strip()


def fetch(url, data=None):
    req = urllib.request.Request(url, data=data)
    try:
        with OPENER.open(req, timeout=30) as r:
            return r.status, r.geturl(), r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.geturl(), e.read().decode("utf-8", "replace")


def host(url):
    return urllib.parse.urlsplit(url).netloc


def step_name(url):
    parts = urllib.parse.urlsplit(url)
    return f"{parts.netloc}{parts.path}"


def submit(url, form, fill_login):
    fields = []
    for name, kind, value in form["inputs"]:
        if fill_login and kind == "password":
            value = PASSWORD
        elif fill_login and kind in ("text", "email") and re.search(r"user|login|email|name", name, re.I):
            value = USER
        if kind in ("submit", "button", "checkbox") and not value:
            continue
        # Consent and confirmation pages: press the button that agrees, never "cancel"
        if kind in ("submit", "button") and name.lower().startswith("cancel"):
            continue
        fields.append((name, value))
    target = urllib.parse.urljoin(url, form["action"] or url)
    body = urllib.parse.urlencode(fields).encode()
    if form["method"] == "post":
        return fetch(target, body)
    return fetch(target + ("&" if "?" in target else "?") + body.decode())


def login(source=None):
    """Runs the browser login; OPENER then holds the session. Returns (status, page) of the
    eMondrian page it ends on, or None when the login failed."""
    status, url, page = fetch(BASE + "/" + (f"?idp={urllib.parse.quote(source)}" if source else ""))
    for _ in range(15):
        print(f"  {status} {step_name(url)}")
        on_gateway = host(url) == host(BASE) and not urllib.parse.urlsplit(url).path.startswith("/auth/")
        if on_gateway and status in (200, 403):
            return status, page
        parser = Forms()
        parser.feed(page)
        form = next((f for f in parser.forms if any(k == "password" for _, k, _ in f["inputs"])), None)
        saml = next((f for f in parser.forms if any(n in ("SAMLRequest", "SAMLResponse") for n, _, _ in f["inputs"])), None)
        if form:
            status, url, page = submit(url, form, fill_login=True)
        elif saml:
            status, url, page = submit(url, saml, fill_login=False)
        elif parser.forms and re.search(r"forms\[0\]\.submit\(\)", page):
            # A page a browser submits by itself on load, e.g. Keycloak's "Kerberos Unsupported"
            # when Kerberos is on and the client has no ticket
            status, url, page = submit(url, parser.forms[0], fill_login=False)
        else:
            error = re.search(r'class="[^"]*(?:alert-error|kc-feedback-text|error)[^"]*"[^>]*>(.*?)<', page, re.S)
            print(f"FAIL | unexpected page '{parser.title}'" + (f": {error.group(1).strip()}" if error else ""))
            return None
    print("FAIL | login did not come back to eMondrian")
    return None


def main():
    result = login(SOURCE)
    if result is None:
        return 1
    status, page = result

    if EXPECT_DENIED:
        ok = status == 403
        print(f"{'OK  ' if ok else 'FAIL'} | refused without an eMondrian role | HTTP {status}: {page.strip()[:120]}")
        return 0 if ok else 1
    print(f"{'OK  ' if status == 200 else 'FAIL'} | logged in, entry page | HTTP {status}")

    cubes = (
        '<Envelope xmlns="http://schemas.xmlsoap.org/soap/envelope/"><Body>'
        '<Discover xmlns="urn:schemas-microsoft-com:xml-analysis"><RequestType>MDSCHEMA_CUBES</RequestType>'
        '<Restrictions><RestrictionList><CATALOG_NAME>FoodMart</CATALOG_NAME></RestrictionList></Restrictions>'
        '<Properties><PropertyList><Catalog>FoodMart</Catalog></PropertyList></Properties>'
        '</Discover></Body></Envelope>').encode()
    req = urllib.request.Request(BASE + "/xmla", cubes, headers={"Content-Type": "text/xml"})
    try:
        with OPENER.open(req, timeout=30) as r:
            xmla_status, body = r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        xmla_status, body = e.code, ""
    names = re.findall(r"<CUBE_NAME>([^<]*)</CUBE_NAME>", body)
    print(f"{'OK  ' if xmla_status == 200 and names else 'FAIL'} | XML/A with the browser session | "
          f"HTTP {xmla_status}, cubes {names}")
    return 0 if status == 200 and xmla_status == 200 and names else 1


if __name__ == "__main__":
    sys.exit(main())
