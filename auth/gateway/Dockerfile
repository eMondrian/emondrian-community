FROM openresty/openresty:1.27.1.2-alpine-fat

# OIDC relying party for OpenResty; pulls lua-resty-http, lua-resty-session and lua-resty-jwt.
RUN luarocks install lua-resty-openidc 1.8.0-1

COPY nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY emondrian-locations.conf keycloak-proxy.conf emondrian-proxy.conf /etc/nginx/
COPY lua/ /etc/nginx/lua/
COPY html/ /etc/nginx/html/
COPY --chmod=755 docker-entrypoint.sh /docker-entrypoint.sh

ENTRYPOINT ["/docker-entrypoint.sh"]
