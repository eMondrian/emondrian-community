#!/bin/sh
# Tests the identity sources of auth/identity.yml as applied to Keycloak: connection and bind of
# every source; with a user name, whether that user may log in, their groups, and the eMondrian
# roles the gateway forwards for them. No password of the user is needed.
#
#   auth/scripts/check-config.sh [USER]
set -eu
cd "$(dirname "$0")/../.."
docker compose -f docker-compose.yml -f docker-compose.auth.yml \
    run --rm --no-deps auth-config check "$@"
