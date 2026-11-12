#!/bin/bash
# Test Active Directory for eMondrian's auth test environment. A fresh domain at every start,
# so the test data is always the same. NEVER use these passwords anywhere else.
set -euo pipefail

REALM="EMTEST.LOCAL"
DOMAIN="EMTEST"
BASE="DC=emtest,DC=local"
OU="OU=eMondrian,$BASE"
USER_PASSWORD="Emondrian-Test-1"      # all test users
BIND_PASSWORD="Bind-Test-1"           # svc_ldap
ADMIN_PASSWORD="Admin-Test-1!"        # domain Administrator
HTTP_HOST="${EMONDRIAN_HOST:?EMONDRIAN_HOST: the host name of PUBLIC_URL, for the HTTP SPN}"
STATE=/state                          # shared with the host: CA certificate, keytab, ready flag

rm -f "$STATE/ad-ready"
samba-tool domain provision --use-rfc2307 --realm="$REALM" --domain="$DOMAIN" --server-role=dc \
    --dns-backend=SAMBA_INTERNAL --adminpass="$ADMIN_PASSWORD" --host-name=dc \
    --option="dns forwarder = 127.0.0.11" >/tmp/provision.log 2>&1 \
    || { cat /tmp/provision.log; exit 1; }
cp /var/lib/samba/private/krb5.conf /etc/krb5.conf

samba --foreground --no-process-group &
SAMBA=$!
for _ in $(seq 1 60); do (echo >/dev/tcp/127.0.0.1/636) 2>/dev/null && break; sleep 1; done

st() { samba-tool "$@" >/dev/null; }
st ou create "$OU"
for ou in Users Groups Service; do st ou create "OU=$ou,$OU"; done
user() {  # name given surname groups...
    local name=$1 given=$2 surname=$3; shift 3
    st user create "$name" "$USER_PASSWORD" --userou="OU=Users,OU=eMondrian" \
        --given-name="$given" --surname="$surname" --mail-address="$name@emtest.local"
    st user setexpiry "$name" --noexpiry
}
for group in BI-Users BI-Admins BI-Modelers BI-Analysts; do st group add "$group" --groupou="OU=Groups,OU=eMondrian"; done
user alice Alice Viewer;     st group addmembers BI-Users alice
user bob   Bob Admin;        st group addmembers BI-Admins bob
user erin  Erin Modeler;     st group addmembers BI-Modelers erin
user nina  Nina Nested;      st group addmembers BI-Analysts nina
st group addmembers BI-Users BI-Analysts                      # nested: nina gets in through BI-Analysts
user carol Carol Outsider                                       # in no BI group: not allowed
user dave  Dave Disabled;    st group addmembers BI-Users dave; st user disable dave

st user create svc_ldap "$BIND_PASSWORD" --userou="OU=Service,OU=eMondrian"
st user setexpiry svc_ldap --noexpiry
st user create svc_http "$(head -c 24 /dev/urandom | base64)" --userou="OU=Service,OU=eMondrian"
st spn add "HTTP/$HTTP_HOST" svc_http
# AES only (as for a real service account): without it the keytab gets just the RC4 key, and
# tickets encrypted with AES find no key
ldbmodify -H /var/lib/samba/private/sam.ldb >/dev/null <<LDIF
dn: CN=svc_http,OU=Service,$OU
changetype: modify
replace: msDS-SupportedEncryptionTypes
msDS-SupportedEncryptionTypes: 24
LDIF
rm -f "$STATE/testenv-http.keytab"
samba-tool domain exportkeytab "$STATE/testenv-http.keytab" --principal="HTTP/$HTTP_HOST@$REALM" >/dev/null

cp /var/lib/samba/private/tls/ca.pem "$STATE/testenv-ad-ca.pem"
printf '%s' "$BIND_PASSWORD" > "$STATE/secrets/ad-bind-password"
chown "${STATE_UID:-1000}:${STATE_UID:-1000}" "$STATE/testenv-http.keytab" "$STATE/testenv-ad-ca.pem" "$STATE/secrets/ad-bind-password"
chmod 600 "$STATE/testenv-http.keytab" "$STATE/secrets/ad-bind-password"
touch "$STATE/ad-ready"
echo "Test AD ready: realm $REALM, users alice bob erin nina carol dave, SPN HTTP/$HTTP_HOST"
wait $SAMBA
