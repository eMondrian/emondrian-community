-- Personal access tokens (emk_…), kept by the auth-tokens service.
--
-- verify(): a token sent as the Basic password (user name: the owner's) or as a Bearer token.
-- api():    /account/api/tokens and /account/api/link (XML/A links, link.lua), the API of the
--           /account/tokens page; the caller is the browser session's user, whose groups go with
--           a new token.
--
-- Mode broker: at every use whose verification is not cached (at most 30 s) the owner is looked
-- up in Keycloak (owner.lua): a deleted or disabled owner's tokens are refused, and the token
-- carries the owner's current groups, not the ones it was issued with. If Keycloak cannot be
-- asked, the token is refused once its 30 s cache entry has run out (fail closed).
--
-- Other modes (no Keycloak to ask): the owner's groups stored with the token at issue are
-- forwarded, by full path. A token issued before groups were forwarded by path holds plain names,
-- which cannot be told from a same-named group elsewhere, so those are dropped: the token still
-- logs its owner in, with no groups, until the owner issues a new one.

local http     = require("resty.http")
local cjson    = require("cjson.safe")
local sha256   = require("resty.sha256")
local rstr     = require("resty.string")
local config   = require("emondrian.config")
local identity = require("emondrian.identity")
local owner    = require("emondrian.owner")
local oidc     = require("emondrian.oidc")

local M = {}

local SERVICE = "http://auth-tokens:8080"
local PREFIX = "emk_"
-- A revoked token keeps working for at most this long (the verification cache)
local CACHE_SECONDS = 30
local ADMIN_ROLE = "/emondrian-admins"

local function hex_sha256(value)
  local hash = sha256:new()
  hash:update(value)
  return rstr.to_hex(hash:final())
end

local secret

local function service_secret()
  if not secret then
    -- Same derivation as auth/tokens/tokens.py
    secret = hex_sha256("emondrian-tokens\0" .. config.secret)
  end
  return secret
end

function M.is_token(value)
  return type(value) == "string" and value:sub(1, #PREFIX) == PREFIX
end

-- Whether an Authorization header carries a personal token (as Bearer or as the Basic password).
function M.in_header(authorization)
  local scheme, value = (authorization or ""):match("^(%a+)%s+(%S+)")
  if not scheme then
    return false
  end
  scheme = scheme:lower()
  if scheme == "bearer" then
    return M.is_token(value)
  end
  if scheme == "basic" then
    local decoded = ngx.decode_base64(value) or ""
    return M.is_token(decoded:match("^[^:]*:(.*)$"))
  end
  return false
end

-- Claims as the rest of the gateway knows them (identity.set), built from the token's owner.
local function claims_of(owner, groups)
  return { [config.username_claim] = owner, [config.groups_claims[1] or "groups"] = groups }
end

-- The stored groups that are full paths, and how many plain names were dropped.
local function path_groups(groups)
  local kept, dropped = {}, 0
  for _, group in ipairs(type(groups) == "table" and groups or {}) do
    if type(group) == "string" and group:sub(1, 1) == "/" then
      kept[#kept + 1] = group
    else
      dropped = dropped + 1
    end
  end
  return kept, dropped
end

-- Returns claims, or nil (unknown, expired, revoked, or another user's token), or nil and
-- "unavailable" (the service failed).
function M.verify(token, user)
  local key = "pat:" .. hex_sha256(config.secret .. "\0" .. token .. "\0" .. (user or ""):lower())
  local cache = ngx.shared.basic_auth
  local cached = cache:get(key)
  if cached == "" then
    return nil
  end
  if cached then
    local entry = cjson.decode(cached)
    return claims_of(entry.user, entry.groups)
  end

  local httpc = http.new()
  httpc:set_timeout(5000)
  local res, err = httpc:request_uri(SERVICE .. "/verify", {
    method  = "POST",
    headers = { ["Content-Type"] = "application/json", ["X-Tokens-Secret"] = service_secret() },
    body    = cjson.encode({ token = token, user = user }),
  })
  if not res then
    ngx.log(ngx.ERR, "auth-tokens unreachable: ", err)
    return nil, "unavailable"
  end
  if res.status == 404 then
    ngx.log(ngx.NOTICE, "personal token refused", user and (" for user " .. identity.one_line(user)) or "")
    cache:set(key, "", config.policy.basic_failure_cache)
    return nil
  end
  local entry = res.status == 200 and cjson.decode(res.body)
  if type(entry) ~= "table" or type(entry.user) ~= "string" then
    ngx.log(ngx.ERR, "auth-tokens answered HTTP ", res.status)
    return nil, "unavailable"
  end
  local groups
  if config.owner_check then
    local reason
    groups, reason = owner.current(entry.user)
    if not groups then
      if reason == "unavailable" then
        return nil, "unavailable"
      end
      ngx.log(ngx.NOTICE, "personal token of ", identity.one_line(entry.user), " refused: the owner no longer",
              " exists or is disabled in Keycloak")
      cache:set(key, "", config.policy.basic_failure_cache)
      return nil
    end
  else
    local dropped
    groups, dropped = path_groups(entry.groups)
    if dropped > 0 then
      ngx.log(ngx.WARN, "personal token of ", identity.one_line(entry.user), " was issued before groups were",
              " forwarded by path: its ", dropped, " group(s) are ignored until the owner issues a new token")
    end
  end
  cache:set(key, cjson.encode({ user = entry.user, groups = groups }), CACHE_SECONDS)
  return claims_of(entry.user, groups)
end

-- Access phase of /account/api/tokens: the browser session decides who the caller is.
function M.api()
  if config.open_access_on() then
    -- Tokens belong to logged-in users; with authentication off there are none
    ngx.status = ngx.HTTP_FORBIDDEN
    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"error":"authentication is off (open_access in identity.yml): no personal tokens"}')
    return ngx.exit(ngx.HTTP_FORBIDDEN)
  end
  local claims
  if config.mode == "trusted-proxy" then
    claims = require("emondrian.trusted_proxy").identity()
  else
    claims = oidc.session("deny")
  end
  local user, groups = identity.from_claims(claims)
  if not user then
    ngx.status = ngx.HTTP_UNAUTHORIZED
    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"error":"not logged in"}')
    return ngx.exit(ngx.HTTP_UNAUTHORIZED)
  end
  identity.set(claims, "session")
  -- Changes only from this site's own page (SameSite=Lax already keeps other sites' POSTs out)
  local method = ngx.req.get_method()
  if method ~= "GET" then
    local origin = ngx.var.http_origin
    if origin ~= config.public_url then
      ngx.status = ngx.HTTP_FORBIDDEN
      ngx.say('{"error":"cross-origin request refused"}')
      return ngx.exit(ngx.HTTP_FORBIDDEN)
    end
  end
  -- A token is checked against its owner in Keycloak at every use (verify): refuse to issue one
  -- that could never pass, with the reason, rather than one that fails later
  if method == "POST" and config.owner_check then
    local _, reason = owner.current(user)
    if reason == "unavailable" then
      ngx.status = ngx.HTTP_SERVICE_UNAVAILABLE
      ngx.header["Content-Type"] = "application/json"
      ngx.say('{"error":"Keycloak cannot be reached to check your account; try again shortly"}')
      return ngx.exit(ngx.HTTP_SERVICE_UNAVAILABLE)
    elseif reason == "gone" then
      ngx.log(ngx.NOTICE, "personal token not issued to ", identity.one_line(user), ": no such account in",
              " Keycloak, or disabled")
      ngx.status = ngx.HTTP_FORBIDDEN
      ngx.header["Content-Type"] = "application/json"
      ngx.say(cjson.encode({ error = "No personal tokens for this account: it does not exist in Keycloak, or"
        .. " is disabled there, so a token could not be checked against it. Ask the administrator." }))
      return ngx.exit(ngx.HTTP_FORBIDDEN)
    end
  end
  local admin = false
  for role in (ngx.var.auth_groups or ""):gmatch("[^,]+") do
    if role == ADMIN_ROLE then
      admin = true
    end
  end
  ngx.req.clear_header("Authorization")
  ngx.req.clear_header("Cookie")
  -- A link for another user is issued only by eMondrian's MCP tool for an administrator, straight
  -- to auth-tokens; a browser's copy of these headers must never reach it
  ngx.req.clear_header("X-Token-Target")
  ngx.req.clear_header("X-Token-Target-Groups")
  ngx.req.set_header("X-Tokens-Secret", service_secret())
  ngx.req.set_header("X-Token-User", user)
  ngx.req.set_header("X-Token-Groups", table.concat(groups, ","))
  ngx.req.set_header("X-Token-Admin", admin and "true" or "false")
  -- An XML/A link is this address plus /xmla, never the Host the browser sent
  ngx.req.set_header("X-Public-Url", config.public_url)
end

return M
