#!/usr/bin/env bash
# Quick start with authentication: eMondrian behind the auth gateway with one local administrator,
# ready in one command. Later, replace the local source in auth/identity.yml by the customer's
# directory or identity provider (auth/docs/configuration-guide.md).
#
#   ./auth/scripts/init.sh [--url https://host[:port] | http://host[:port]] [--http-port N]
#                          [--admin-user NAME] [--admin-password PASSWORD] [--open] [--force]
#                          [--no-start]
#
# Defaults: https://localhost, HTTP port 80 (redirects), administrator "admin" with password "0",
# which must be changed at the first login. An http:// URL serves plain HTTP on its port, without
# a certificate (a trial; passwords travel unencrypted). --open starts with authentication off
# (open_access in identity.yml): everybody gets in as "guest" with all rights; switch it on with
# auth/scripts/authentication.sh on. Settings already in .env are kept; auth/identity.yml is
# written only when missing (or with --force). .env gets COMPOSE_FILE, so that a plain
# "docker compose ..." includes the authentication overlay. --no-start prepares .env, the
# certificate and identity.yml only (setup.sh starts the stack). Needs Docker.
set -Eeuo pipefail
cd "$(dirname "$0")/../.."

URL="https://localhost"
HTTP_PORT=""
ADMIN_USER="admin"
ADMIN_PASSWORD="0"
FORCE=false
OPEN=false
START=true

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
while [ $# -gt 0 ]; do
    case "$1" in
        --url) URL="${2:?--url needs a value}"; shift 2 ;;
        --http-port) HTTP_PORT="${2:?--http-port needs a value}"; shift 2 ;;
        --admin-user) ADMIN_USER="${2:?--admin-user needs a value}"; shift 2 ;;
        --admin-password) ADMIN_PASSWORD="${2:?--admin-password needs a value}"; shift 2 ;;
        --force) FORCE=true; shift ;;
        --open) OPEN=true; shift ;;
        --no-start) START=false; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

fail() { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }

URL="${URL%/}"
[[ "$URL" =~ ^(https?)://([A-Za-z0-9.-]+)(:([0-9]+))?$ ]] || fail "--url must look like https://host[:port] or http://host[:port]"
SCHEME="${BASH_REMATCH[1]}"
HOST="${BASH_REMATCH[2]}"
if [ "$SCHEME" = https ]; then
    TLS_PORT="${BASH_REMATCH[4]:-443}"
else
    # Plain HTTP: the URL's port is the HTTP port. The TLS port is published on a random free
    # port (0), where nothing listens without a certificate, so that 443 need not be free
    TLS_PORT=0
    [ -n "$HTTP_PORT" ] && [ "$HTTP_PORT" != "${BASH_REMATCH[4]:-80}" ] && fail "--http-port and the port of an http:// --url differ"
    HTTP_PORT="${BASH_REMATCH[4]:-80}"
fi
[[ "$ADMIN_USER" =~ ^[A-Za-z0-9._@-]+$ ]] || fail "--admin-user: letters, digits and . _ @ - only"
if $START; then
    command -v docker >/dev/null || fail "Docker is not installed: run ./setup.sh first (it installs Docker), then this script"
    docker compose version >/dev/null 2>&1 || fail "docker compose is not available to this user (docker group?)"
fi
command -v openssl >/dev/null || fail "openssl is needed to create the secrets and the certificate"

compose() { docker compose -f docker-compose.yml -f docker-compose.auth.yml "$@"; }

# --- .env -------------------------------------------------------------------------------------
step ".env"
[ -f .env ] || { cp .env.example .env; echo "created from .env.example"; }
chmod 600 .env
env_value() { { grep -E "^$1=" .env || true; } | tail -1 | cut -d= -f2-; }
set_default() {  # key value: adds the key only when .env has no value for it
    if [ -z "$(env_value "$1")" ]; then
        sed -i "/^$1=/d" .env
        printf '%s=%s\n' "$1" "$2" >> .env
        echo "  $1 set"
    else
        echo "  $1 kept"
    fi
}
grep -q '^# --- Authentication (auth/scripts/init.sh)' .env || printf '\n# --- Authentication (auth/scripts/init.sh) ---\n' >> .env
if [ "$SCHEME" = http ]; then
    if [ "$HTTP_PORT" = "80" ]; then PUBLIC_URL="http://$HOST"; else PUBLIC_URL="http://$HOST:$HTTP_PORT"; fi
elif [ "$TLS_PORT" = "443" ]; then PUBLIC_URL="https://$HOST"; else PUBLIC_URL="https://$HOST:$TLS_PORT"; fi
set_default PUBLIC_URL "$PUBLIC_URL"
set_default EMONDRIAN_TLS_PORT "$TLS_PORT"
[ -n "$HTTP_PORT" ] && { sed -i '/^EMONDRIAN_PORT=/d' .env; printf 'EMONDRIAN_PORT=%s\n' "$HTTP_PORT" >> .env; echo "  EMONDRIAN_PORT set"; }
set_default COMPOSE_PROFILES keycloak
# A plain "docker compose ..." in this directory then includes the authentication overlay
set_default COMPOSE_PATH_SEPARATOR ":"
set_default COMPOSE_FILE "docker-compose.yml:docker-compose.auth.yml"
for key in OIDC_CLIENT_SECRET SESSION_SECRET KEYCLOAK_DB_PASSWORD; do set_default "$key" "$(openssl rand -hex 32)"; done
set_default KEYCLOAK_ADMIN_PASSWORD "$(openssl rand -hex 16)"
# Keycloak's admin console: this machine and private networks; narrow it for production
set_default KEYCLOAK_ADMIN_ALLOW "127.0.0.1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"
PUBLIC_URL="$(env_value PUBLIC_URL)"
TLS_PORT="$(env_value EMONDRIAN_TLS_PORT)"
HTTP_PORT="$(env_value EMONDRIAN_PORT)"; HTTP_PORT="${HTTP_PORT:-80}"

# --- directories, certificate -----------------------------------------------------------------
step "Certificate"
# Created here so that Docker does not create them as root
mkdir -p logs auth/secrets/tls auth/secrets/truststore auth/secrets/kerberos
chmod 700 auth/secrets auth/secrets/tls auth/secrets/kerberos
if [[ "$PUBLIC_URL" == http://* ]]; then
    [ -f auth/secrets/tls/tls.crt ] && fail "PUBLIC_URL is $PUBLIC_URL but auth/secrets/tls/ holds a certificate: remove it, or use an https:// URL"
    echo "plain HTTP ($PUBLIC_URL): no certificate. Passwords travel unencrypted; use https:// beyond a trial"
elif [ -f auth/secrets/tls/tls.crt ] && [ -f auth/secrets/tls/tls.key ]; then
    echo "auth/secrets/tls/ already holds a certificate: kept"
else
    SAN="DNS:$HOST"
    [[ "$HOST" =~ ^[0-9.]+$ ]] && SAN="IP:$HOST"
    [ "$HOST" != "localhost" ] && SAN="$SAN,DNS:localhost"
    openssl req -x509 -newkey rsa:2048 -nodes -days 825 -subj "/CN=$HOST" \
        -addext "subjectAltName=$SAN" -addext "extendedKeyUsage=serverAuth" \
        -keyout auth/secrets/tls/tls.key -out auth/secrets/tls/tls.crt 2>/dev/null
    chmod 600 auth/secrets/tls/tls.key
    echo "self-signed certificate for $HOST created (browsers warn until it is replaced by one of your CA)"
fi

# --- identity.yml -----------------------------------------------------------------------------
step "auth/identity.yml"
if [ -f auth/identity.yml ] && ! $FORCE; then
    echo "already exists: kept (--force to replace it with the quick-start one)"
else
    # The initial password goes to a file in the secrets directory, not into identity.yml
    SECRETS_DIR="$(env_value AUTH_SECRETS_DIR)"; SECRETS_DIR="${SECRETS_DIR:-./auth/secrets}"
    install -m 600 /dev/null "$SECRETS_DIR/initial-admin-password"
    printf '%s' "$ADMIN_PASSWORD" > "$SECRETS_DIR/initial-admin-password"
    cat > auth/identity.yml <<EOF
# Quick start (auth/scripts/init.sh): users kept in Keycloak itself. Add users in Keycloak's admin
# console ($PUBLIC_URL/auth/admin/, realm "emondrian", user "admin" with KEYCLOAK_ADMIN_PASSWORD
# from .env) and put them into the groups below. For the customer's own directory or identity
# provider, see auth/identity.example.yml and auth/docs/configuration-guide.md.
sources:
  - name: local
    type: local
    groups: [emondrian-admins, emondrian-editors, emondrian-viewers]
    users:
      - username: $ADMIN_USER
        groups: [emondrian-admins]
        initial_password_file: initial-admin-password   # temporary: changed at the first login

roles:
  mapping:
    emondrian-admins:  [emondrian-admins]
    emondrian-editors: [emondrian-editors, emondrian-admins]
    emondrian-viewers: [emondrian-viewers, emondrian-editors, emondrian-admins]

# Authentication off: everybody who reaches the server gets in without logging in, as the user
# below with the roles below. Switch with auth/scripts/authentication.sh on|off (no restart).
open_access:
  enabled: $OPEN
  user: guest
  roles: [emondrian-admins]
EOF
    echo "written: source local, administrator $ADMIN_USER, authentication $($OPEN && echo "OFF (open_access)" || echo on)"
fi

if ! $START; then
    echo
    echo "Prepared (.env, auth/identity.yml); not started (--no-start)."
    exit 0
fi

# --- sample data, start -----------------------------------------------------------------------
step "Sample data"
if compgen -G "clickhouse/datasets/ontime/*.csv" >/dev/null; then
    echo "OnTime data present"
else
    ./clickhouse/scripts/setup-ontime.sh --sample
fi

step "Ports"
for port in "$HTTP_PORT" "$TLS_PORT"; do
    [ "$port" = 0 ] && continue
    # A port held by this project's own containers (the plain stack of setup.sh, or an earlier
    # run) is fine: compose recreates them. {{.Publishers}} prints "80/tcp -> 0.0.0.0:80", so
    # read the JSON field instead.
    if (echo >"/dev/tcp/127.0.0.1/$port") 2>/dev/null && \
       ! compose ps --format json 2>/dev/null | grep -Eq "\"PublishedPort\": ?$port([^0-9]|$)"; then
        fail "port $port is used by another program: pick others with --http-port N and --url https://$HOST:N"
    fi
done
if [[ "$PUBLIC_URL" == http://* ]]; then
    echo "HTTP $HTTP_PORT"
else
    echo "HTTP $HTTP_PORT (redirects to HTTPS), HTTPS $TLS_PORT"
fi

step "Starting (first run builds the auth images: a few minutes)"
compose up -d --build --wait --wait-timeout 600 || {
    compose logs --tail=30 auth-config keycloak auth_gateway || true
    fail "the stack did not start"
}
compose logs auth-config 2>/dev/null | sed -n 's/^[^|]*| //p' | grep -E 'user|group|policy|applied' || true

step "Check"
./auth/scripts/check-config.sh "$ADMIN_USER" | grep -vE '^ *(Container|Network)' || true

if [ "$(./auth/scripts/authentication.sh status)" = off ]; then
cat <<EOF

eMondrian is up with authentication OFF (open_access in auth/identity.yml): everybody who
reaches it gets in as "guest" with all rights, without logging in.

  Open:      $PUBLIC_URL/
  Excel:     server $PUBLIC_URL/xmla, Windows authentication (no user name or password needed)
  MCP:       $PUBLIC_URL/emondrian/mcp

Switch authentication on (no restart):  ./auth/scripts/authentication.sh on
Then log in as $ADMIN_USER (first password: as given to init.sh, "0" by default).
EOF
    exit 0
fi

cat <<EOF

eMondrian with authentication is up.

  Open:      $PUBLIC_URL/
  Log in:    $ADMIN_USER   (first password: as given to init.sh, "0" by default; you are asked
                           to choose a new one, at least 8 characters, right away)
  Excel:     server $PUBLIC_URL/xmla, the same user name and the new password
  Tokens:    $PUBLIC_URL/account/tokens  (for scripts, MCP agents, Power BI)
  Users:     $PUBLIC_URL/auth/admin/  realm "emondrian" (Keycloak administrator: admin,
             password KEYCLOAK_ADMIN_PASSWORD in .env)

EOF
if [[ "$PUBLIC_URL" == https://* ]]; then
cat <<EOF
The certificate is self-signed: replace auth/secrets/tls/tls.crt and tls.key with one of your
CA, then: docker compose -f docker-compose.yml -f docker-compose.auth.yml restart auth_gateway
EOF
fi
