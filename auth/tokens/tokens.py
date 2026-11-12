"""Personal access tokens of eMondrian users: for clients that cannot log in through a browser
(Excel and Power BI with Basic, scripts, MCP agents), whatever identity source the user has.

Only the auth gateway talks to this service, inside the compose network; every request carries
X-Tokens-Secret (derived from SESSION_SECRET). The gateway tells who is asking with X-Token-User,
X-Token-Groups (the user's own groups, comma-separated) and X-Token-Admin. A token is stored as its
SHA-256 only and shown once, when it is created.

    POST   /tokens           {"name", "days"}     create a token for the caller
    GET    /tokens[?all=1]                        the caller's tokens (all users' for admins)
    DELETE /tokens/<id>                           revoke (own, or any for admins)
    POST   /verify           {"token", "user"?}   owner and groups of a valid token
    GET    /health
"""
import datetime
import hashlib
import hmac
import json
import os
import re
import secrets
import sqlite3
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DB = os.environ.get("TOKENS_DB", "/data/tokens.db")
SECRET = hashlib.sha256(b"emondrian-tokens\0" + os.environ["SESSION_SECRET"].encode()).hexdigest()
# personal_tokens in identity.yml, written by auth-config
SETTINGS_FILE = os.environ.get("TOKENS_SETTINGS", "/generated/tokens.json")
DEFAULTS = {"enabled": True, "default_days": 90, "max_days": 365, "max_per_user": 10}
PREFIX = "emk_"


def settings():
    try:
        with open(SETTINGS_FILE) as f:
            return dict(DEFAULTS, **json.load(f))
    except (OSError, ValueError):
        return dict(DEFAULTS)

LOCK = threading.Lock()


def connect():
    db = sqlite3.connect(DB, check_same_thread=False)
    db.row_factory = sqlite3.Row
    db.execute("""CREATE TABLE IF NOT EXISTS tokens (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        hash TEXT NOT NULL UNIQUE,
        hint TEXT NOT NULL,
        owner TEXT NOT NULL COLLATE NOCASE,
        groups TEXT NOT NULL,
        name TEXT NOT NULL,
        created TEXT NOT NULL,
        expires TEXT NOT NULL,
        last_used TEXT,
        revoked TEXT)""")
    db.execute("CREATE INDEX IF NOT EXISTS tokens_owner ON tokens(owner)")
    db.commit()
    return db


DBH = None


def now():
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)


def iso(dt):
    return dt.isoformat().replace("+00:00", "Z")


def digest(token):
    return hashlib.sha256(token.encode()).hexdigest()


def public(row):
    return {"id": row["id"], "name": row["name"], "owner": row["owner"], "hint": row["hint"],
            "created": row["created"], "expires": row["expires"], "last_used": row["last_used"]}


class Handler(BaseHTTPRequestHandler):
    server_version = "emondrian-tokens"

    def log_message(self, fmt, *args):
        # No query strings or bodies in the log: they may carry tokens
        print(f"{self.address_string()} {self.command} {self.path.split('?')[0]} {args[1] if len(args) > 1 else ''}",
              flush=True)

    def reply(self, status, body=None):
        data = json.dumps(body if body is not None else {}).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length > 4096:
            return None
        try:
            return json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            return None

    def trusted(self):
        return hmac.compare_digest(self.headers.get("X-Tokens-Secret", ""), SECRET)

    def caller(self):
        user = (self.headers.get("X-Token-User") or "").strip()
        groups = [g for g in (self.headers.get("X-Token-Groups") or "").split(",") if g]
        return user, groups, self.headers.get("X-Token-Admin") == "true"

    def do_GET(self):
        if self.path == "/health":
            return self.reply(200, {"status": "UP"})
        if not self.trusted():
            return self.reply(403, {"error": "forbidden"})
        user, _, admin = self.caller()
        if not user or not self.path.startswith("/tokens"):
            return self.reply(404, {"error": "not found"})
        everyone = admin and self.path.endswith("?all=1")
        limits = settings()
        with LOCK:
            rows = DBH.execute(
                "SELECT * FROM tokens WHERE revoked IS NULL AND expires > ?"
                + ("" if everyone else " AND owner = ?") + " ORDER BY owner, created DESC",
                (iso(now()),) if everyone else (iso(now()), user)).fetchall()
        self.reply(200, {"tokens": [public(r) for r in rows], "all": everyone, "user": user, "admin": admin,
                         "default_days": limits["default_days"], "max_days": limits["max_days"],
                         "enabled": limits["enabled"]})

    def do_POST(self):
        if not self.trusted():
            return self.reply(403, {"error": "forbidden"})
        data = self.body()
        if data is None:
            return self.reply(400, {"error": "invalid request"})
        if self.path == "/verify":
            return self.verify(data)
        if self.path != "/tokens":
            return self.reply(404, {"error": "not found"})
        user, groups, _ = self.caller()
        if not user:
            return self.reply(400, {"error": "no user"})
        limits = settings()
        if not limits["enabled"]:
            return self.reply(403, {"error": "personal tokens are turned off"})
        name = str(data.get("name") or "").strip()[:80]
        if not name:
            return self.reply(400, {"error": "a name is required"})
        try:
            days = int(data.get("days") or limits["default_days"])
        except (TypeError, ValueError):
            return self.reply(400, {"error": "days must be a number"})
        if not 1 <= days <= limits["max_days"]:
            return self.reply(400, {"error": f"days must be between 1 and {limits['max_days']}"})
        token = PREFIX + secrets.token_urlsafe(32)
        created = now()
        with LOCK:
            count = DBH.execute("SELECT COUNT(*) FROM tokens WHERE owner = ? AND revoked IS NULL AND expires > ?",
                                (user, iso(created))).fetchone()[0]
            if count >= limits["max_per_user"]:
                return self.reply(409, {"error": f"at most {limits['max_per_user']} tokens per user; revoke one first"})
            cur = DBH.execute(
                "INSERT INTO tokens (hash, hint, owner, groups, name, created, expires) VALUES (?, ?, ?, ?, ?, ?, ?)",
                (digest(token), token[:len(PREFIX) + 4] + "…", user, json.dumps(groups), name, iso(created),
                 iso(created + datetime.timedelta(days=days))))
            DBH.commit()
            row = DBH.execute("SELECT * FROM tokens WHERE id = ?", (cur.lastrowid,)).fetchone()
        print(f"token {row['id']} created for {user}, expires {row['expires']}", flush=True)
        self.reply(201, dict(public(row), token=token))

    def verify(self, data):
        token = str(data.get("token") or "")
        if not token.startswith(PREFIX) or not settings()["enabled"]:
            return self.reply(404, {"error": "unknown token"})
        stamp = iso(now())
        with LOCK:
            row = DBH.execute("SELECT * FROM tokens WHERE hash = ? AND revoked IS NULL AND expires > ?",
                              (digest(token), stamp)).fetchone()
            if row is None:
                return self.reply(404, {"error": "unknown, expired or revoked token"})
            user = data.get("user")
            if user and user.lower() != row["owner"].lower():
                return self.reply(404, {"error": "token belongs to another user"})
            DBH.execute("UPDATE tokens SET last_used = ? WHERE id = ?", (stamp, row["id"]))
            DBH.commit()
        self.reply(200, {"user": row["owner"], "groups": json.loads(row["groups"]), "expires": row["expires"],
                         "id": row["id"]})

    def do_DELETE(self):
        if not self.trusted():
            return self.reply(403, {"error": "forbidden"})
        user, _, admin = self.caller()
        match = re.fullmatch(r"/tokens/(\d+)", self.path)
        if not user or not match:
            return self.reply(404, {"error": "not found"})
        with LOCK:
            row = DBH.execute("SELECT * FROM tokens WHERE id = ? AND revoked IS NULL", (int(match.group(1)),)).fetchone()
            if row is None or (not admin and row["owner"].lower() != user.lower()):
                return self.reply(404, {"error": "not found"})
            DBH.execute("UPDATE tokens SET revoked = ? WHERE id = ?", (iso(now()), row["id"]))
            DBH.commit()
        print(f"token {row['id']} of {row['owner']} revoked by {user}", flush=True)
        self.reply(200, {"revoked": row["id"]})


if __name__ == "__main__":
    os.makedirs(os.path.dirname(DB), exist_ok=True)
    DBH = connect()
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
