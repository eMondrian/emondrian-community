#!/usr/bin/env bash
# Test environment for eMondrian's authentication: test identity sources in Docker, one
# identity profile per scenario, end-to-end tests. For development and tests only.
#
#   auth/testenv/testenv.sh up                start the test sources (AD, OpenLDAP, partner IdP, SSO proxy)
#   auth/testenv/testenv.sh profiles          list the profiles
#   auth/testenv/testenv.sh use PROFILE       apply a profile (auth/identity.yml is not touched)
#   auth/testenv/testenv.sh test PROFILE|all  apply and test one profile, or all of them
#   auth/testenv/testenv.sh reset             back to auth/identity.yml
#   auth/testenv/testenv.sh down              stop and remove the test sources
#
# Needs the stack with authentication (auth/scripts/init.sh, or your own .env and identity.yml).
# Settings: TESTENV_HOST (this machine's address, as browsers and containers reach it; default:
# its first IP), TESTENV_CA_FILE (CA of the gateway's certificate; default: its own certificate),
# TESTENV_IDP_PORT (8095), TESTENV_PROXY_PORT (9180), TESTENV_PROXY_JWT_PORT (9181).
set -Eeuo pipefail
cd "$(dirname "$0")/../.."
REPO=$PWD
TE=auth/testenv
STATE=$REPO/$TE/.state
SECRETS=$STATE/secrets
PROFILES=(local ldap-ad open ad-kerberos ldap-openldap broker-idp oidc-direct proxy-headers proxy-jwt)
USER_PASSWORD="Emondrian-Test-1"

fail() { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }
env_value() { { grep -E "^$1=" .env 2>/dev/null || true; } | tail -1 | cut -d= -f2-; }

PUBLIC_URL="$(env_value PUBLIC_URL)"
[ -n "$PUBLIC_URL" ] || fail ".env has no PUBLIC_URL: start with auth/scripts/init.sh first"
PUBLIC_HOSTPORT="${PUBLIC_URL#https://}"; PUBLIC_HOSTPORT="${PUBLIC_HOSTPORT#http://}"; PUBLIC_HOSTPORT="${PUBLIC_HOSTPORT%%/*}"
EMONDRIAN_HOST="${PUBLIC_HOSTPORT%%:*}"
export TESTENV_HOST="${TESTENV_HOST:-$(hostname -I | awk '{print $1}')}"
export TESTENV_IDP_PORT="${TESTENV_IDP_PORT:-8095}" TESTENV_PROXY_PORT="${TESTENV_PROXY_PORT:-9180}"
export TESTENV_PROXY_JWT_PORT="${TESTENV_PROXY_JWT_PORT:-9181}"
export TESTENV_EMONDRIAN_HOST="$EMONDRIAN_HOST" TESTENV_PUBLIC_HOST="$PUBLIC_HOSTPORT" TESTENV_UID="$(id -u)"
CA_FILE="${TESTENV_CA_FILE:-$REPO/auth/secrets/tls/tls.crt}"
# The compose network of this checkout (project name = directory name)
NETWORK="$(basename "$REPO" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')_app_network"

compose() {
    docker compose -f docker-compose.yml -f docker-compose.auth.yml -f $TE/docker-compose.testenv.yml \
        --profile keycloak --profile testenv "$@"
}

# --- up ---------------------------------------------------------------------------------------
cmd_up() {
    step "Secrets of the test environment ($STATE)"
    mkdir -p "$SECRETS"; chmod 700 "$STATE" "$SECRETS"
    put() { [ -f "$SECRETS/$1" ] || { install -m 600 /dev/null "$SECRETS/$1"; printf '%s' "$2" > "$SECRETS/$1"; }; }
    put user-password "$USER_PASSWORD"
    put openldap-admin-password "Ldap-Admin-Test-1"
    put partner-oidc-secret "partner-oidc-test-secret"
    put partner-direct-secret "partner-direct-test-secret"
    put local-initial-password "0"
    put local-new-password "Local-New-Test-1"
    put proxy-secret "$(openssl rand -hex 24)"

    step "Test sources (first run builds the images)"
    rm -f "$STATE/ad-ready"
    compose up -d --build testenv-ad testenv-openldap testenv-idp testenv-proxy
    echo -n "waiting for the test Active Directory"
    for _ in $(seq 1 60); do [ -f "$STATE/ad-ready" ] && break; echo -n .; sleep 3; done; echo
    [ -f "$STATE/ad-ready" ] || { compose logs --tail=30 testenv-ad; fail "the test AD did not come up"; }

    step "CA and keytab of the test AD for Keycloak and auth-kerberos"
    cp "$STATE/testenv-ad-ca.pem" auth/secrets/truststore/testenv-ad-ca.pem
    install -m 600 "$STATE/testenv-http.keytab" auth/secrets/kerberos/testenv-http.keytab
    # Keycloak reads its truststore at start; the test AD has a new CA at every start
    compose up -d --wait --force-recreate --no-deps keycloak >/dev/null

    step "OpenLDAP test data"
    for _ in $(seq 1 30); do docker exec emondrian_testenv_openldap ldapsearch -x -H ldap://localhost -b dc=emtest,dc=local \
        -D cn=admin,dc=emtest,dc=local -w Ldap-Admin-Test-1 -s base >/dev/null 2>&1 && break; sleep 2; done
    docker exec -i emondrian_testenv_openldap ldapadd -c -x -H ldap://localhost -D cn=admin,dc=emtest,dc=local \
        -w Ldap-Admin-Test-1 >/dev/null 2>&1 <<EOF || true
dn: ou=people,dc=emtest,dc=local
objectClass: organizationalUnit
ou: people

dn: ou=groups,dc=emtest,dc=local
objectClass: organizationalUnit
ou: groups

dn: uid=oliver,ou=people,dc=emtest,dc=local
objectClass: inetOrgPerson
uid: oliver
cn: Oliver OpenLDAP
givenName: Oliver
sn: OpenLDAP
mail: oliver@emtest.local
userPassword: $USER_PASSWORD

dn: uid=olga,ou=people,dc=emtest,dc=local
objectClass: inetOrgPerson
uid: olga
cn: Olga Outsider
sn: Outsider
userPassword: $USER_PASSWORD

dn: cn=bi-users,ou=groups,dc=emtest,dc=local
objectClass: groupOfUniqueNames
cn: bi-users
uniqueMember: uid=oliver,ou=people,dc=emtest,dc=local
EOF
    echo "oliver (bi-users), olga (no group)"

    step "Partner identity provider"
    for _ in $(seq 1 60); do curl -sf -o /dev/null "http://$TESTENV_HOST:$TESTENV_IDP_PORT/realms/partner" && break; sleep 3; done
    curl -sf -o /dev/null "http://$TESTENV_HOST:$TESTENV_IDP_PORT/realms/partner" \
        || fail "the partner IdP is not reachable at http://$TESTENV_HOST:$TESTENV_IDP_PORT (TESTENV_HOST?)"
    echo "http://$TESTENV_HOST:$TESTENV_IDP_PORT/realms/partner: pat (partner-analysts), quinn (no group)"
    cat <<EOF

Test environment up. Profiles: ${PROFILES[*]}
  $0 use <profile>     $0 test <profile>|all     $0 reset
EOF
}

# --- use --------------------------------------------------------------------------------------
render() {  # profile -> $STATE/identity.yml with {PLACEHOLDERS} filled in
    local file=$TE/profiles/$1.yml proxy_ip=""
    [ -f "$file" ] || fail "no profile $1 (profiles: ${PROFILES[*]})"
    if grep -q '{PROXY_IP}' "$file"; then
        proxy_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' emondrian_testenv_proxy 2>/dev/null) \
            || fail "the test SSO proxy is not running: $0 up"
    fi
    PROXY_IP=$proxy_ip EMONDRIAN_HOST=$EMONDRIAN_HOST python3 -I - "$file" "$STATE/identity.yml" <<'PY'
import os, re, sys
text = open(sys.argv[1]).read()
open(sys.argv[2], "w").write(re.sub(r"\{([A-Z_]+)\}", lambda m: os.environ[m.group(1)], text))
PY
}

kc_admin() {  # kcadm.sh as the master admin, inside the Keycloak container
    local user; user=$(env_value KEYCLOAK_ADMIN_USER)
    docker exec emondrian_keycloak /opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080/auth \
        --realm master --user "${user:-admin}" --password "$(env_value KEYCLOAK_ADMIN_PASSWORD)" >/dev/null
    docker exec emondrian_keycloak /opt/keycloak/bin/kcadm.sh "$@"
}

cmd_use() {
    local profile=${1:?profile name}
    [ -f "$STATE/ad-ready" ] || fail "the test environment is not up: $0 up"
    render "$profile"
    if [ "$profile" = local ]; then
        # The first-login test needs a user that has never logged in
        local id; id=$(kc_admin get users -r emondrian -q username=testenv-admin -q exact=true --fields id --format csv --noquotes 2>/dev/null || true)
        [ -n "$id" ] && kc_admin delete "users/$id" -r emondrian >/dev/null
    fi
    AUTH_IDENTITY_FILE=$STATE/identity.yml AUTH_SECRETS_DIR=$SECRETS ./auth/scripts/apply-config.sh 2>&1 \
        | grep -E '^source|mode|kerberos|trusted|ERROR|applied|reloaded' || true
    echo "$profile" > "$STATE/current-profile"
}

cmd_reset() {
    ./auth/scripts/apply-config.sh 2>&1 | grep -E 'mode|ERROR|applied|reloaded' || true
    rm -f "$STATE/current-profile"
}

# --- test -------------------------------------------------------------------------------------
RESULTS=$STATE/results.txt
record() {  # profile command...: runs a test, keeps its OK / FAIL lines
    local profile=$1; shift
    local out status=0
    out=$("$@" 2>&1) || status=$?
    echo "$out" | grep -E '^(OK  |FAIL)' | sed "s/^/$profile | /" | tee -a "$RESULTS" || true
    if [ $status -ne 0 ] && ! echo "$out" | grep -q '^FAIL'; then
        echo "$profile | FAIL | $(basename "${@: -1}") stopped | $(echo "$out" | tail -1)" | tee -a "$RESULTS"
    fi
}
expect_check() {  # profile user expectation(allowed:<roles>|refused)
    local out; out=$(AUTH_IDENTITY_FILE=$STATE/identity.yml AUTH_SECRETS_DIR=$SECRETS ./auth/scripts/check-config.sh "$2" 2>&1 || true)
    if [ "$3" = refused ]; then
        echo "$out" | grep -q "FAIL | user $2 |" && line="OK   | check-config: $2 may not log in |" || line="FAIL | check-config: $2 should be refused |"
    else
        echo "$out" | grep -q "X-Forwarded-Groups: $3" && line="OK   | check-config: $2 gets $3 |" \
            || line="FAIL | check-config: $2 should get $3 | $(echo "$out" | grep -E 'forwarded|user' | tail -1)"
    fi
    echo "$1 | $line" | tee -a "$RESULTS"
}
logs_check() {  # profile user expected-status: the user's browser session on /logs/ (server permissions)
    local status
    status=$(TEST_USER=$2 TEST_PASSWORD_FILE=$SECRETS/user-password python3 -I - <<'PY' 2>/dev/null || echo "?"
import os, sys, urllib.request, urllib.error
sys.path.insert(0, "auth/tests")
import browser_login as b
sys.stdout = open(os.devnull, "w"); ok = b.login(); sys.stdout = sys.__stdout__
try:
    with b.OPENER.open(urllib.request.Request(b.BASE + "/logs/"), timeout=20) as r: print(r.status)
except urllib.error.HTTPError as e: print(e.code)
PY
)
    [ "$status" = "$3" ] && line="OK   | server logs for $2: HTTP $status |" || line="FAIL | server logs for $2: HTTP $status, expected $3 |"
    echo "$1 | $line" | tee -a "$RESULTS"
}
kerberos_check() {  # profile user [refused]
    printf '[libdefaults]\n    default_realm = EMTEST.LOCAL\n    dns_lookup_kdc = false\n    rdns = false\n    dns_canonicalize_hostname = false\n[realms]\n    EMTEST.LOCAL = {\n        kdc = dc.emtest.local\n    }\n[domain_realm]\n    .emtest.local = EMTEST.LOCAL\n    %s = EMTEST.LOCAL\n' "$EMONDRIAN_HOST" > "$STATE/krb5.conf"
    record "$1" docker run --rm --network "$NETWORK" --add-host "$EMONDRIAN_HOST:$TESTENV_HOST" \
        -v "$STATE/krb5.conf:/etc/krb5.conf:ro" -v "$CA_FILE:/ca.pem:ro" -v "$REPO/auth/tests:/tests:ro" \
        -v "$SECRETS/user-password:/pw:ro" -e BASE_URL="$PUBLIC_URL" -e CA_FILE=/ca.pem -e EXPECT="${3:-}" \
        --user "$(id -u):$(id -g)" --entrypoint sh emondrian-auth-kerberos:local \
        -c "kinit $2@EMTEST.LOCAL < /pw >/dev/null && echo 'OK   | kinit $2@EMTEST.LOCAL |' && python3 -B /tests/check_kerberos.py"
}

test_profile() {
    local p=$1
    export RESOLVE="$EMONDRIAN_HOST=$TESTENV_HOST" CA_FILE BASE_URL="$PUBLIC_URL"
    local pw=$SECRETS/user-password
    step "Profile $p"
    cmd_use "$p" >/dev/null
    case $p in
        local)
            record "$p" env TEST_USER=testenv-admin TEST_PASSWORD_FILE="$SECRETS/local-initial-password" \
                NEW_PASSWORD_FILE="$SECRETS/local-new-password" python3 -I auth/tests/check_local.py ;;
        ldap-ad)
            record "$p" env TEST_USER=alice TEST_PASSWORD_FILE="$pw" python3 -I auth/tests/check_auth.py
            record "$p" env TEST_USER=alice TEST_PASSWORD_FILE="$pw" python3 -I auth/tests/browser_login.py
            expect_check "$p" nina emondrian-viewers      # nested group
            expect_check "$p" bob emondrian-admins
            expect_check "$p" erin emondrian-editors
            expect_check "$p" carol refused               # in no allowed group
            expect_check "$p" dave refused                # disabled
            logs_check "$p" bob 200
            logs_check "$p" alice 403 ;;
        open)
            record "$p" python3 -I auth/tests/check_open.py
            # Switched on again, without a restart: logins are required, the source works
            AUTH_IDENTITY_FILE=$STATE/identity.yml AUTH_SECRETS_DIR=$SECRETS ./auth/scripts/authentication.sh on >/dev/null 2>&1
            record "$p" env TEST_USER=alice TEST_PASSWORD_FILE="$pw" python3 -I auth/tests/check_auth.py ;;
        ad-kerberos)
            kerberos_check "$p" alice
            kerberos_check "$p" carol refused ;;
        ldap-openldap)
            record "$p" env TEST_USER=oliver TEST_PASSWORD_FILE="$pw" python3 -I auth/tests/check_auth.py
            expect_check "$p" olga refused ;;
        broker-idp)
            record "$p" env TEST_USER=alice TEST_PASSWORD_FILE="$pw" python3 -I auth/tests/browser_login.py
            record "$p" env TEST_USER=pat TEST_PASSWORD_FILE="$pw" python3 -I auth/tests/browser_login.py partner-oidc
            record "$p" env TEST_USER=pat TEST_PASSWORD_FILE="$pw" python3 -I auth/tests/browser_login.py partner-saml
            record "$p" env TEST_USER=quinn TEST_PASSWORD_FILE="$pw" EXPECT_DENIED=1 python3 -I auth/tests/browser_login.py partner-oidc
            record "$p" env TEST_USER=pat TEST_PASSWORD_FILE="$pw" python3 -I auth/tests/check_tokens.py partner-oidc
            record "$p" env TEST_USER=alice TEST_PASSWORD_FILE="$pw" python3 -I auth/tests/check_mcp_oauth.py ;;
        oidc-direct)
            record "$p" env TEST_USER=pat TEST_PASSWORD_FILE="$pw" python3 -I auth/tests/browser_login.py
            record "$p" env TEST_USER=quinn TEST_PASSWORD_FILE="$pw" EXPECT_DENIED=1 python3 -I auth/tests/browser_login.py
            record "$p" env TEST_USER=pat TEST_PASSWORD_FILE="$pw" CLIENT_ID=emondrian-direct \
                CLIENT_SECRET_FILE="$SECRETS/partner-direct-secret" \
                TOKEN_URL="http://$TESTENV_HOST:$TESTENV_IDP_PORT/realms/partner/protocol/openid-connect/token" \
                python3 -I auth/tests/check_provider_token.py
            record "$p" env TEST_USER=pat TEST_PASSWORD_FILE="$pw" python3 -I auth/tests/check_tokens.py ;;
        proxy-headers|proxy-jwt)
            local port=$TESTENV_PROXY_PORT; [ $p = proxy-jwt ] && port=$TESTENV_PROXY_JWT_PORT
            record "$p" env PROXY_URL="http://localhost:$port" PROXY_USER=sam NOROLE_USER=tom PROXY_PASSWORD_FILE="$pw" \
                python3 -I auth/tests/check_trusted_proxy.py ;;
    esac
}

cmd_test() {
    local which=${1:?profile name or all}
    [ -f "$STATE/ad-ready" ] || fail "the test environment is not up: $0 up"
    : > "$RESULTS"
    if [ "$which" = all ]; then for p in "${PROFILES[@]}"; do test_profile "$p"; done; else test_profile "$which"; fi
    step "Back to auth/identity.yml"
    cmd_reset
    find auth/tests -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null || true
    step "Summary"
    awk -F' \\| ' '{n[$1]++; if ($2 ~ /^OK/) ok[$1]++} END {for (p in n) printf "%-15s %3d checks, %3d OK, %d FAIL\n", p, n[p], ok[p], n[p]-ok[p]}' "$RESULTS" | sort
    local total failed; total=$(wc -l < "$RESULTS"); failed=$(grep -c ' | FAIL' "$RESULTS" || true)
    printf '%-15s %3d checks, %3d OK, %d FAIL\n' TOTAL "$total" "$((total - failed))" "$failed"
    [ "$failed" = 0 ]
}

cmd_down() {
    compose rm -sf testenv-ad testenv-openldap testenv-idp testenv-proxy
    rm -f auth/secrets/truststore/testenv-ad-ca.pem auth/secrets/kerberos/testenv-http.keytab "$STATE/ad-ready"
    [ -f "$STATE/current-profile" ] && cmd_reset
    compose up -d --wait --force-recreate --no-deps keycloak >/dev/null
    echo "test sources removed (secrets of the test environment kept in $STATE)"
}

case "${1:-}" in
    up) cmd_up ;;
    use) cmd_use "${2:-}" ;;
    test) cmd_test "${2:-}" ;;
    reset) cmd_reset ;;
    down) cmd_down ;;
    profiles) printf '%s\n' "${PROFILES[@]}" ;;
    *) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
