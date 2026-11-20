"""Personal access tokens of eMondrian users (emk_…): one per user, for everything that cannot log
in through a browser: Excel and Power BI (as the Basic password, or in the server address for
Power BI's live connection), scripts and backends (Bearer), MCP agents, and a dashboard opened
from a link (<PUBLIC_URL>/dashboard/d/<id>?emondrian_token=…).

Only the auth gateway and eMondrian's MCP server talk to this service, inside the compose network;
every request carries X-Tokens-Secret (derived from SESSION_SECRET). The caller says who is asking:

    X-Token-User, X-Token-Groups (full paths, comma-separated), X-Token-Admin ("true" for an
    administrator); X-Token-Target and X-Token-Target-Groups when a token is issued for another
    user (the caller has checked that the user exists and has these groups); X-Token-Via: mcp when
    the request comes from an MCP tool.

The gateway strips client copies of all of them. A token is stored as its SHA-256 only and shown
once, when it is issued. Issuing a token revokes every other token of its owner.

    POST   /tokens            {"name"?, "days"?}   issue (for X-Token-Target, else the caller)
    GET    /tokens[?user=u|?all=1]                 active tokens, never their values
    DELETE /tokens/<id>                            revoke (own, or any for administrators)
    POST   /verify            {"token", "user"?}   owner, groups and expiry of a valid token
    GET    /health

Errors are {"error": {"code", "message"}}, as eMondrian's REST API answers.
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
from urllib.parse import parse_qs

DB = os.environ.get("TOKENS_DB", "/data/tokens.db")
SECRET = hashlib.sha256(b"emondrian-tokens\0" + os.environ["SESSION_SECRET"].encode()).hexdigest()
# personal_tokens in identity.yml, written by auth-config
SETTINGS_FILE = os.environ.get("TOKENS_SETTINGS", "/generated/tokens.json")
DEFAULTS = {"enabled": True, "default_days": 90, "max_days": 365,
            "issue_via_agents": False, "issue_for_admins": False}
PREFIX = "emk_"
ADMINS = "/emondrian-admins"
AGENTS_OFF = ("issuing tokens via AI agents is disabled (personal_tokens.issue_via_agents in"
              " identity.yml)")


def settings():
    try:
        with open(SETTINGS_FILE) as f:
            return dict(DEFAULTS, **json.load(f))
    except (OSError, ValueError):
        return dict(DEFAULTS)


LOCK = threading.Lock()


def now():
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)


def iso(dt):
    return dt.isoformat().replace("+00:00", "Z")


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
    # Who issued a token for another user (an administrator); null: the owner themselves
    try:
        db.execute("ALTER TABLE tokens ADD COLUMN created_by TEXT")
    except sqlite3.OperationalError:
        pass  # already there
    db.commit()
    return db


def one_per_user(db):
    """One token per user (2026-11). A user who still has several active ones keeps the newest;
    the others are revoked when this version starts (again harmlessly at later starts: there is
    nothing left to revoke). The links table of the XML/A links (eml_) of earlier versions is
    dropped: those links no longer work, and their hashes are of no use."""
    if db.execute("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'links'").fetchone():
        count = db.execute("SELECT COUNT(*) FROM links").fetchone()[0]
        db.execute("DROP TABLE links")
        print(f"XML/A links removed: table links dropped ({count} link(s), no longer valid)", flush=True)
    stamp = iso(now())
    rows = db.execute("SELECT id, owner FROM tokens WHERE revoked IS NULL AND expires > ?"
                      " ORDER BY owner, created DESC, id DESC", (stamp,)).fetchall()
    kept = set()
    for row in rows:
        owner = row["owner"].lower()
        if owner not in kept:
            kept.add(owner)
            continue
        db.execute("UPDATE tokens SET revoked = ? WHERE id = ?", (stamp, row["id"]))
        print(f"token {row['id']} of {row['owner']} revoked: one token per user, the newest is kept", flush=True)
    db.commit()


DBH = None


def digest(token):
    return hashlib.sha256(token.encode()).hexdigest()


def public(row):
    return {"id": row["id"], "name": row["name"], "owner": row["owner"], "hint": row["hint"],
            "created": row["created"], "expires": row["expires"], "last_used": row["last_used"],
            "created_by": row["created_by"]}


def failure(status, code, message):
    return status, {"error": {"code": code, "message": message}}


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

    def fail(self, status, code, message):
        return self.reply(*failure(status, code, message))

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length > 4096:
            return None
        try:
            data = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            return None
        return data if isinstance(data, dict) else None

    def trusted(self):
        return hmac.compare_digest(self.headers.get("X-Tokens-Secret", ""), SECRET)

    def caller(self):
        user = (self.headers.get("X-Token-User") or "").strip()
        groups = [g for g in (self.headers.get("X-Token-Groups") or "").split(",") if g]
        return user, groups, self.headers.get("X-Token-Admin") == "true"

    def target(self):
        """The user a token is issued for, when it is not the caller, and their groups."""
        target = (self.headers.get("X-Token-Target") or "").strip()
        groups = [g for g in (self.headers.get("X-Token-Target-Groups") or "").split(",") if g]
        return (target, groups) if target else (None, [])

    def via_agent(self):
        return (self.headers.get("X-Token-Via") or "").strip().lower() == "mcp"

    def gone(self):
        return self.fail(410, "GONE", "XML/A links (eml_) were removed: every user has one personal token,"
                                      " which also works in the address. Issue one on /account/tokens.")

    def do_GET(self):
        if self.path == "/health":
            return self.reply(200, {"status": "UP"})
        if not self.trusted():
            return self.fail(403, "FORBIDDEN", "forbidden")
        user, _, admin = self.caller()
        path, _, query = self.path.partition("?")
        args = {k: v[0] for k, v in parse_qs(query).items()}
        if path == "/link":
            return self.gone()
        if not user or path != "/tokens":
            return self.fail(404, "NOT_FOUND", "not found")
        everyone = args.get("all") == "1"
        whose = (args.get("user") or "").strip() or user
        if (everyone or whose.lower() != user.lower()) and not admin:
            return self.fail(403, "FORBIDDEN", "only administrators see other users' tokens")
        limits = settings()
        with LOCK:
            rows = DBH.execute(
                "SELECT * FROM tokens WHERE revoked IS NULL AND expires > ?"
                + ("" if everyone else " AND owner = ?") + " ORDER BY owner, created DESC",
                (iso(now()),) if everyone else (iso(now()), whose)).fetchall()
        self.reply(200, {"tokens": [public(r) for r in rows], "all": everyone,
                         "for": None if everyone else whose, "user": user, "admin": admin,
                         "default_days": limits["default_days"], "max_days": limits["max_days"],
                         "enabled": limits["enabled"], "issue_for_admins": limits["issue_for_admins"],
                         "issue_via_agents": limits["issue_via_agents"]})

    def do_POST(self):
        if not self.trusted():
            return self.fail(403, "FORBIDDEN", "forbidden")
        data = self.body()
        if data is None:
            return self.fail(400, "BAD_REQUEST", "the body must be a JSON object")
        if self.path == "/verify":
            return self.verify(data)
        if self.path in ("/link", "/verify-link"):
            return self.gone()
        if self.path != "/tokens":
            return self.fail(404, "NOT_FOUND", "not found")
        self.reply(*self.issue(data))

    def issue(self, data):
        caller, groups, admin = self.caller()
        if not caller:
            return failure(400, "BAD_REQUEST", "no user")
        limits = settings()
        if not limits["enabled"]:
            return failure(403, "FORBIDDEN", "personal tokens are turned off (personal_tokens in identity.yml)")
        if self.via_agent() and not limits["issue_via_agents"]:
            return failure(403, "FORBIDDEN", AGENTS_OFF)
        target, target_groups = self.target()
        owner, owner_groups = (target, target_groups) if target else (caller, groups)
        created_by = None
        if owner.lower() != caller.lower():
            if not admin:
                return failure(403, "FORBIDDEN", "only administrators (/emondrian-admins) issue tokens for other users")
            if ADMINS in owner_groups and not limits["issue_for_admins"]:
                return failure(403, "FORBIDDEN", f"{owner} is an administrator: no token is issued for another"
                                                 " administrator (personal_tokens.issue_for_admins in identity.yml);"
                                                 " they issue their own")
            created_by = caller
        name = str(data.get("name") or "").strip()[:80] or ("issued by " + caller if created_by else "token")
        try:
            days = int(data.get("days") or limits["default_days"])
        except (TypeError, ValueError):
            return failure(400, "BAD_REQUEST", "days must be a whole number")
        if not 1 <= days <= limits["max_days"]:
            return failure(400, "BAD_REQUEST", f"days must be between 1 and {limits['max_days']}"
                                               " (personal_tokens.max_lifetime)")
        token = PREFIX + secrets.token_urlsafe(32)
        created = now()
        with LOCK:
            replaced = [r["id"] for r in DBH.execute(
                "SELECT id FROM tokens WHERE owner = ? AND revoked IS NULL AND expires > ?",
                (owner, iso(created))).fetchall()]
            DBH.execute("UPDATE tokens SET revoked = ? WHERE owner = ? AND revoked IS NULL", (iso(created), owner))
            cur = DBH.execute(
                "INSERT INTO tokens (hash, hint, owner, groups, name, created, expires, created_by)"
                " VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (digest(token), token[:len(PREFIX) + 4] + "…", owner, json.dumps(owner_groups), name, iso(created),
                 iso(created + datetime.timedelta(days=days)), created_by))
            DBH.commit()
            row = DBH.execute("SELECT * FROM tokens WHERE id = ?", (cur.lastrowid,)).fetchone()
        print(f"token {row['id']} issued for {owner}" + (f" by {created_by}" if created_by else "")
              + (" through MCP" if self.via_agent() else "") + f", expires {row['expires']}"
              + (f"; revoked: {', '.join(map(str, replaced))}" if replaced else ""), flush=True)
        return 201, dict(public(row), token=token, replaced=replaced)

    def verify(self, data):
        token = str(data.get("token") or "")
        if not token.startswith(PREFIX) or not settings()["enabled"]:
            return self.fail(404, "NOT_FOUND", "unknown token")
        stamp = iso(now())
        with LOCK:
            row = DBH.execute("SELECT * FROM tokens WHERE hash = ? AND revoked IS NULL AND expires > ?",
                              (digest(token), stamp)).fetchone()
            if row is None:
                return self.fail(404, "NOT_FOUND", "unknown, expired or revoked token")
            user = data.get("user")
            if user and str(user).lower() != row["owner"].lower():
                return self.fail(404, "NOT_FOUND", "token belongs to another user")
            DBH.execute("UPDATE tokens SET last_used = ? WHERE id = ?", (stamp, row["id"]))
            DBH.commit()
        expires_at = int(datetime.datetime.fromisoformat(row["expires"].replace("Z", "+00:00")).timestamp())
        self.reply(200, {"user": row["owner"], "groups": json.loads(row["groups"]), "expires": row["expires"],
                         "expires_at": expires_at, "id": row["id"]})

    def do_DELETE(self):
        if not self.trusted():
            return self.fail(403, "FORBIDDEN", "forbidden")
        user, _, admin = self.caller()
        if self.path == "/link":
            return self.gone()
        match = re.fullmatch(r"/tokens/(\d+)", self.path)
        if not user or not match:
            return self.fail(404, "NOT_FOUND", "not found")
        with LOCK:
            row = DBH.execute("SELECT * FROM tokens WHERE id = ? AND revoked IS NULL", (int(match.group(1)),)).fetchone()
            if row is None or (not admin and row["owner"].lower() != user.lower()):
                return self.fail(404, "NOT_FOUND", "no such active token")
            DBH.execute("UPDATE tokens SET revoked = ? WHERE id = ?", (iso(now()), row["id"]))
            DBH.commit()
        print(f"token {row['id']} of {row['owner']} revoked by {user}"
              + (" through MCP" if self.via_agent() else ""), flush=True)
        self.reply(200, {"revoked": row["id"], "owner": row["owner"]})


if __name__ == "__main__":
    os.makedirs(os.path.dirname(DB), exist_ok=True)
    DBH = connect()
    one_per_user(DBH)
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
