#!/bin/sh
# Applies auth/identity.yml: identity sources to Keycloak, claims and role mapping to the auth
# gateway (which reloads without dropping connections or sessions). Run after every change to
# identity.yml or to the files in the secrets directory it names.
set -eu
cd "$(dirname "$0")/../.."
compose() {
    docker compose -f docker-compose.yml -f docker-compose.auth.yml "$@"
}

compose build -q auth-config
compose run --rm --no-deps auth-config apply
# nginx re-reads the gateway config on reload (init_by_lua runs again in new workers). Old
# workers finish their requests with the old config, so wait until they are gone: after this
# script, every request sees the new config.
if [ -n "$(compose ps -q auth_gateway)" ]; then
    compose kill -s HUP auth_gateway >/dev/null
    sleep 1
    for _ in $(seq 1 30); do
        compose exec -T auth_gateway sh -c 'ps' | grep -q 'shutting down' || break
        sleep 1
    done
    echo "auth gateway reloaded"
fi
