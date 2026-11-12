#!/bin/sh
# Applies auth/keycloak/realm-emondrian.json to a running stack. Keycloak imports the realm only
# when it does not exist yet, so later changes to the file - or to PUBLIC_URL, which the realm's
# redirect URIs are built from - need this.
#
# A changed PUBLIC_URL does not need it: apply-config.sh (run by `up -d`) keeps the gateway
# client's redirect URIs in line with it.
#
# The realm is overwritten: clients and settings added through the admin console since are lost,
# and everybody is logged out. Users of directories and identity providers are not stored, but
# USERS KEPT IN KEYCLOAK (source type local) ARE DELETED; the users listed in identity.yml are
# created again with their initial password. The identity sources are applied again.
set -eu
cd "$(dirname "$0")/../.."
compose() {
    docker compose -f docker-compose.yml -f docker-compose.auth.yml "$@"
}

compose stop keycloak
compose run --rm --no-deps keycloak import \
    --file /opt/keycloak/data/import/realm-emondrian.json --override true
compose up -d --wait keycloak
./auth/scripts/apply-config.sh
