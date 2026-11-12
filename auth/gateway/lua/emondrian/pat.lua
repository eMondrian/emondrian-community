-- Personal access tokens (emk_…), kept by the auth-tokens service.
--
-- verify(): a token sent as the Basic password (user name: the owner's) or as a Bearer token.
-- api():    /account/api/tokens, the API of the /account/tokens page; the caller is the browser
--           session's user, whose groups go with a new token.
--
-- The owner's groups are stored with the token; roles.mapping turns them into eMondrian roles at
-- every use, so mapping changes apply to existing tokens.

local http     = require("resty.http")
local cjson    = require("cjson.safe")
local sha256   = require("resty.sha256")
local rstr     = require("resty.string")
local config   = require("emondrian.config")
local identity = require("emondrian.identity")
local oidc     = require("emondrian.oidc")

local M = {}

local SERVICE = "http://auth-tokens:8080"
local PREFIX = "emk_"
-- A revoked token keeps working for at most this long (the verification cache)
local CACHE_SECONDS = 30
local ADMIN_ROLE = "emondrian-admins"

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
  cache:set(key, cjson.encode({ user = entry.user, groups = entry.groups }), CACHE_SECONDS)
  return claims_of(entry.user, entry.groups)
end

-- Access phase of /account/api/tokens: the browser session decides who the caller is.
function M.api()
  if config.open_access then
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
  local ok, reason = identity.set(claims, "session")
  if not ok then
    ngx.status = ngx.HTTP_FORBIDDEN
    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode({ error = reason == "no_role" and "you hold no eMondrian role" or "no user name" }))
    return ngx.exit(ngx.HTTP_FORBIDDEN)
  end
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
  local admin = false
  for role in (ngx.var.auth_groups or ""):gmatch("[^,]+") do
    if role == ADMIN_ROLE then
      admin = true
    end
  end
  ngx.req.clear_header("Authorization")
  ngx.req.clear_header("Cookie")
  ngx.req.set_header("X-Tokens-Secret", service_secret())
  ngx.req.set_header("X-Token-User", user)
  ngx.req.set_header("X-Token-Groups", table.concat(groups, ","))
  ngx.req.set_header("X-Token-Admin", admin and "true" or "false")
end

return M
