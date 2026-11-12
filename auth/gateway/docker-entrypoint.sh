#!/bin/sh
# Writes the server blocks of the auth gateway from the environment, then starts OpenResty.
#
# TLS is on when /etc/nginx/tls/tls.crt and tls.key exist (auth/secrets/tls/ on the host):
# HTTPS on 443, and port 80 only redirects to PUBLIC_URL. Without them the gateway serves plain
# HTTP on 80, which is acceptable on a test network only (Basic passwords travel in clear text).
#
# KEYCLOAK_ADMIN_ALLOW: space-separated addresses/CIDRs allowed to reach Keycloak's admin console
# and master realm through the gateway; empty means nobody.
set -eu

GENERATED=/etc/nginx/generated
mkdir -p "$GENERATED"

PUBLIC_URL="${PUBLIC_URL%/}"
case "$PUBLIC_URL" in
    *[\'\"\ \;\$]*) echo "PUBLIC_URL contains a quote, space, ; or \$" >&2; exit 1 ;;
esac

: > "$GENERATED/admin-access.conf"
for source in ${KEYCLOAK_ADMIN_ALLOW:-}; do
    case "$source" in
        *[!0-9a-fA-F.:/]*) echo "KEYCLOAK_ADMIN_ALLOW: '$source' is not an address or CIDR" >&2; exit 1 ;;
    esac
    echo "allow $source;" >> "$GENERATED/admin-access.conf"
done
echo "deny all;" >> "$GENERATED/admin-access.conf"

# GATEWAY_REAL_IP_FROM: addresses/CIDRs of reverse proxies in front of the gateway. From them the
# client address is taken from X-Forwarded-For (the last entry, the one the proxy added), so
# KEYCLOAK_ADMIN_ALLOW and the logs see the real client instead of the proxy.
: > "$GENERATED/real-ip.conf"
for source in ${GATEWAY_REAL_IP_FROM:-}; do
    case "$source" in
        *[!0-9a-fA-F.:/]*) echo "GATEWAY_REAL_IP_FROM: '$source' is not an address or CIDR" >&2; exit 1 ;;
    esac
    echo "set_real_ip_from $source;" >> "$GENERATED/real-ip.conf"
done
if [ -s "$GENERATED/real-ip.conf" ]; then
    echo "real_ip_header X-Forwarded-For;" >> "$GENERATED/real-ip.conf"
fi

# CAs for the gateway's own TLS connections to an identity provider (mode oidc-direct): the
# system's plus the PEM files of auth/secrets/truststore/
cat /etc/ssl/certs/ca-certificates.crt > "$GENERATED/ca-bundle.pem"
for pem in /etc/nginx/truststore/*.pem /etc/nginx/truststore/*.crt; do
    [ -f "$pem" ] && { cat "$pem"; echo; } >> "$GENERATED/ca-bundle.pem"
done

if [ -f /etc/nginx/tls/tls.crt ] && [ -f /etc/nginx/tls/tls.key ]; then
    echo "TLS: on (certificate /etc/nginx/tls/tls.crt)"
    case "$PUBLIC_URL" in
        https://*) ;;
        *) echo "TLS is on but PUBLIC_URL is not https://" >&2; exit 1 ;;
    esac
    cat > "$GENERATED/servers.conf" <<EOF
server {
    listen 80;
    location / {
        return 301 $PUBLIC_URL\$request_uri;
    }
}

server {
    listen 443 ssl;
    http2 on;
    ssl_certificate     /etc/nginx/tls/tls.crt;
    ssl_certificate_key /etc/nginx/tls/tls.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:TLS:10m;
    add_header Strict-Transport-Security "max-age=31536000" always;
    include /etc/nginx/emondrian-locations.conf;
}
EOF
else
    echo "TLS: off (no certificate in /etc/nginx/tls) - plain HTTP"
    case "$PUBLIC_URL" in
        https://*) echo "WARNING: PUBLIC_URL is https:// but this gateway serves plain HTTP; TLS must end in front of it" >&2 ;;
    esac
    cat > "$GENERATED/servers.conf" <<EOF
server {
    listen 80;
    include /etc/nginx/emondrian-locations.conf;
}
EOF
fi

exec /usr/local/openresty/bin/openresty -g 'daemon off;'
