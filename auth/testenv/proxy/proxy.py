"""Test SSO proxy for mode trusted-proxy (test environment only).

Asks the browser for a user name and password (Basic, checked against USERS below), then passes
the request on to the auth gateway the way real SSO proxies do:

    :8080  headers: X-Forwarded-User, X-Forwarded-Groups, X-Proxy-Secret   (like oauth2-proxy)
    :8081  a signed assertion in Cf-Access-Jwt-Assertion                    (like Cloudflare Access)
    :8082  /certs.json: the public key of the assertions (JWKS), for the gateway

Whatever identity headers the client sends itself are dropped.
"""
import base64
import http.client
import json
import os
import ssl
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM_HOST = os.environ.get("UPSTREAM_HOST", "emondrian_auth_gateway")
UPSTREAM_PORT = int(os.environ.get("UPSTREAM_PORT", "443"))
PUBLIC_HOST = os.environ["PUBLIC_HOST"]          # Host header and TLS name the gateway expects
SECRET = open(os.environ.get("PROXY_SECRET_FILE", "/secrets/proxy-secret")).read().strip()
ISSUER = "https://proxy.emtest.local"
AUDIENCE = "emondrian-testenv"
# The proxy's own users: name -> (password, groups)
USERS = {"sam": ("Emondrian-Test-1", ["BI-Users"]), "tom": ("Emondrian-Test-1", [])}
DROP = {"x-forwarded-user", "x-forwarded-groups", "x-proxy-secret", "cf-access-jwt-assertion",
        "authorization", "host", "connection", "keep-alive", "transfer-encoding"}

KEY = os.path.join(tempfile.mkdtemp(), "proxy.key")
subprocess.run(["openssl", "genrsa", "-out", KEY, "2048"], check=True, capture_output=True)


def b64u(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def jwks():
    modulus = subprocess.run(["openssl", "rsa", "-in", KEY, "-noout", "-modulus"],
                             capture_output=True, text=True, check=True).stdout.strip().split("=", 1)[1]
    return {"keys": [{"kty": "RSA", "kid": "testenv", "use": "sig", "alg": "RS256",
                      "n": b64u(bytes.fromhex(modulus)), "e": "AQAB"}]}


def assertion(user, groups):
    now = int(time.time())
    head = b64u(json.dumps({"alg": "RS256", "kid": "testenv", "typ": "JWT"}).encode()) + "." + b64u(json.dumps({
        "iss": ISSUER, "aud": [AUDIENCE], "email": f"{user}@proxy.emtest.local", "groups": groups,
        "iat": now, "exp": now + 300}).encode())
    signature = subprocess.run(["openssl", "dgst", "-sha256", "-sign", KEY], input=head.encode(),
                               capture_output=True, check=True).stdout
    return head + "." + b64u(signature)


def handler(mode):
    class Proxy(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):
            print(f"[{mode}] {self.command} {self.path.split('?')[0]} {args[1] if len(args) > 1 else ''}", flush=True)

        def user(self):
            try:
                name, _, password = base64.b64decode(self.headers.get("Authorization", "")[6:]).decode().partition(":")
            except ValueError:
                return None
            entry = USERS.get(name)
            return (name, entry[1]) if entry and entry[0] == password else None

        def forward(self):
            if mode == "jwks":
                body = json.dumps(jwks()).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                return self.wfile.write(body)
            who = self.user()
            if not who:
                self.send_response(401)
                self.send_header("WWW-Authenticate", 'Basic realm="Test SSO proxy"')
                self.send_header("Content-Length", "0")
                return self.end_headers()
            headers = {k: v for k, v in self.headers.items() if k.lower() not in DROP}
            headers["Host"] = PUBLIC_HOST
            # As nginx's $proxy_add_x_forwarded_for: the client's address appended
            forwarded = self.headers.get("X-Forwarded-For")
            headers["X-Forwarded-For"] = (forwarded + ", " if forwarded else "") + self.client_address[0]
            if mode == "headers":
                headers.update({"X-Forwarded-User": who[0], "X-Forwarded-Groups": ",".join(who[1]),
                                "X-Proxy-Secret": SECRET})
            else:
                headers["Cf-Access-Jwt-Assertion"] = assertion(*who)
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length) if length else None
            # Inside the compose network; the test proxy does not check the gateway's certificate
            context = ssl.create_default_context()
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
            upstream = http.client.HTTPSConnection(UPSTREAM_HOST, UPSTREAM_PORT, context=context, timeout=60)
            upstream.request(self.command, self.path, body=body, headers=headers)
            response = upstream.getresponse()
            data = response.read()
            self.send_response(response.status)
            for key, value in response.getheaders():
                if key.lower() not in ("transfer-encoding", "connection", "content-length"):
                    self.send_header(key, value)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        do_GET = do_POST = do_PUT = do_DELETE = do_HEAD = do_OPTIONS = forward
    return Proxy


if __name__ == "__main__":
    servers = [ThreadingHTTPServer(("0.0.0.0", port), handler(mode))
               for port, mode in ((8080, "headers"), (8081, "jwt"), (8082, "jwks"))]
    for server in servers[1:]:
        threading.Thread(target=server.serve_forever, daemon=True).start()
    print("test SSO proxy: headers on 8080, signed assertions on 8081, JWKS on 8082", flush=True)
    servers[0].serve_forever()
