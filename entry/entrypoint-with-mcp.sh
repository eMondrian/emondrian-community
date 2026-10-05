#!/bin/sh
# Front-door entrypoint that adds the MCP route the entry image does not generate.
#
# emondrian/entry:0.0.4 has ENTRYPOINT=/docker-entrypoint.d/99-custom-config.sh, a script that
# writes /etc/nginx/conf.d/default.conf (routes for /xmla, /api/, /logs/, /client/,
# /schema-editor/ -- no /mcp) and then ends with `exec nginx`. Because it execs, nothing after it
# runs: dropping another script into /docker-entrypoint.d/ has no effect, the standard nginx
# entrypoint loop never executes. So this wrapper runs that generator with its exec line removed,
# appends the MCP location to what it produced, and starts nginx itself.
#
# The route is /emondrian/mcp/, not /mcp/, on purpose: the SSE handshake advertises its message
# endpoint as /emondrian/mcp/message?sessionId=... -- webapp context path included -- and a
# client resolves that against this origin. A bare /mcp/ would serve the stream, then 404 the POST.
set -e

IMAGE_ENTRYPOINT=/docker-entrypoint.d/99-custom-config.sh
CONF=/etc/nginx/conf.d/default.conf

if [ ! -f "$IMAGE_ENTRYPOINT" ]; then
    echo "entrypoint-with-mcp: $IMAGE_ENTRYPOINT is gone -- the entry image changed shape." >&2
    echo "entrypoint-with-mcp: starting nginx without the MCP route." >&2
    exec nginx -g 'daemon off;'
fi

# Generate the config, minus the final `exec nginx` so we get control back.
sed '/^exec nginx/d' "$IMAGE_ENTRYPOINT" > /tmp/generate-config.sh
sh /tmp/generate-config.sh

if [ "$ENABLE_SERVICE_EMONDRIAN" = "true" ] && ! grep -q "location /emondrian/mcp/" "$CONF"; then
    BLOCK=$(cat <<'EOF'
    # MCP endpoint for AI agents. proxy_buffering must stay off: with it on, nginx holds the SSE
    # stream and the client never sees the endpoint event telling it where to POST.
    location /emondrian/mcp/ {
        proxy_pass http://emondrian_service:8080/emondrian/mcp/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header Connection "";
        proxy_buffering off;
        proxy_cache off;

        proxy_connect_timeout 300s;
        proxy_send_timeout    3600s;
        proxy_read_timeout    3600s;
        send_timeout          3600s;
    }
EOF
)
    # Insert inside the server block, i.e. before its closing brace (the last one in the file).
    awk -v block="$BLOCK" '
      { lines[NR] = $0 }
      END {
        last = 0
        for (i = 1; i <= NR; i++) if (lines[i] ~ /^}[[:space:]]*$/) last = i
        for (i = 1; i <= NR; i++) {
          if (i == last) print block
          print lines[i]
        }
      }' "$CONF" > "$CONF.mcp" && mv "$CONF.mcp" "$CONF"
    echo "entrypoint-with-mcp: added the /emondrian/mcp/ route"
fi

nginx -t
exec nginx -g 'daemon off;'
