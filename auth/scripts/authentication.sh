#!/usr/bin/env bash
# Switches authentication on or off without restarting anything (open_access in identity.yml).
#
#   ./auth/scripts/authentication.sh off      everybody gets in without logging in, as the
#                                             open_access user (default "guest") in its groups
#                                             (default emondrian-admins): a demo or a trial
#   ./auth/scripts/authentication.sh on       logins are required again (the sources of
#                                             identity.yml, unchanged meanwhile)
#   ./auth/scripts/authentication.sh status   prints on or off
#
# Edits only the "enabled:" line of the open_access section (adding the section when missing),
# then applies identity.yml with apply-config.sh. The switch itself is auth/state/open_access.json,
# which the gateway reads on each request and the MCP tool set_open_access also writes; this
# script writes it too, so both ways agree, and status reads it first.
set -Eeuo pipefail
cd "$(dirname "$0")/../.."

fail() { echo "ERROR: $*" >&2; exit 1; }

# Same file apply-config.sh applies: AUTH_IDENTITY_FILE from the environment or .env
FILE="${AUTH_IDENTITY_FILE:-$( { grep -E '^AUTH_IDENTITY_FILE=' .env 2>/dev/null || true; } | tail -1 | cut -d= -f2-)}"
FILE="${FILE:-./auth/identity.yml}"
[ -f "$FILE" ] || fail "$FILE not found (auth/scripts/init.sh writes one)"

# Prints "true" when open_access is enabled: a section with enabled: true (or without an enabled
# line), or "open_access: true"
open_access_enabled() {
    awk '
        /^open_access:[ \t]*true[ \t]*(#.*)?$/ { found = 1; on = 1; next }
        /^open_access:[ \t]*(#.*)?$/           { found = 1; inside = 1; on = 1; next }
        inside && /^[^ \t#]/                   { inside = 0 }
        inside && /^[ \t]+enabled:/ {
            value = $0; sub(/^[ \t]+enabled:[ \t]*/, "", value); sub(/[ \t]*(#.*)?$/, "", value)
            on = (value == "true")
        }
        END { print (found && on) ? "true" : "false" }
    ' "$FILE"
}

set_enabled() {  # true | false
    if grep -Eq '^open_access:[ \t]*(true|false)[ \t]*(#.*)?$' "$FILE"; then
        sed -i -E "s/^open_access:[ \\t]*(true|false)/open_access: $1/" "$FILE"
    elif grep -Eq '^open_access:[ \t]*(#.*)?$' "$FILE"; then
        if awk '/^open_access:/{inside=1;next} inside&&/^[^ \t#]/{inside=0} inside&&/^[ \t]+enabled:/{f=1} END{exit !f}' "$FILE"; then
            awk -v value="$1" '
                /^open_access:/ { inside = 1; print; next }
                inside && /^[^ \t#]/ { inside = 0 }
                inside && /^[ \t]+enabled:/ { match($0, /^[ \t]+/); print substr($0, 1, RLENGTH) "enabled: " value; next }
                { print }
            ' "$FILE" > "$FILE.tmp"
        else
            awk -v value="$1" '{ print } /^open_access:/ { print "  enabled: " value }' "$FILE" > "$FILE.tmp"
        fi
        cat "$FILE.tmp" > "$FILE" && rm -f "$FILE.tmp"
    else
        [ "$1" = false ] && return 0
        cat >> "$FILE" <<'EOF'

# Authentication off: everybody who reaches the server gets in without logging in, as the user
# below in the groups below. Switch with auth/scripts/authentication.sh on|off (no restart).
open_access:
  enabled: true
  user: guest
  groups: [emondrian-admins]
EOF
    fi
    [ "$(open_access_enabled)" = "$1" ] || fail "could not change open_access in $FILE; edit it by hand"
}

STATE=./auth/state/open_access.json

# Prints "true" or "false" from the state file, or nothing when it is missing or unreadable
state_enabled() {
    [ -f "$STATE" ] || return 0
    grep -Eo '"enabled"[[:space:]]*:[[:space:]]*(true|false)' "$STATE" | grep -Eo '(true|false)$' | head -1
}

# Written beside it and renamed over it, so the gateway never reads half a file (the directory is
# ours even when the MCP tool, running as root in its container, wrote the file last)
write_state() {  # true | false
    mkdir -p ./auth/state
    local tmp
    tmp="$(mktemp ./auth/state/.open_access.XXXXXX)"
    printf '{\n  "enabled": %s,\n  "changed_by": "%s",\n  "changed_at": "%s",\n  "changed_with": "authentication.sh"\n}\n' \
        "$1" "${USER:-$(id -un)}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmp"
    chmod 644 "$tmp"
    mv -f "$tmp" "$STATE"
}

case "${1:-}" in
    status)
        state="$(state_enabled)"
        [ "${state:-$(open_access_enabled)}" = true ] && echo off || echo on
        exit 0 ;;
    on)  enabled=false ;;
    off) enabled=true ;;
    *)   sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac

set_enabled "$enabled"
write_state "$enabled"
./auth/scripts/apply-config.sh
echo
if [ "$enabled" = true ]; then
    echo "Authentication is OFF: everybody who reaches the server gets in without logging in."
else
    echo "Authentication is ON: logins are required (browser sessions of the guest are not kept)."
    case "$({ grep -E '^PUBLIC_URL=' .env || true; } | tail -1 | cut -d= -f2-)" in
        http://localhost*|http://127.0.0.1*|https://*|"") ;;
        *) echo "  MCP agents that log in with OAuth from other machines need HTTPS: auth/README.md, HTTPS." ;;
    esac
fi
