-- Basic credentials, for clients such as Excel and Power BI that speak nothing else.
--
-- The user name and password are exchanged for a token at the OpenID provider (Resource Owner
-- Password grant): Keycloak, which checks them against its LDAP sources (mode broker), or the
-- customer's provider when it supports the grant (mode oidc-direct, basic_password_grant). A
-- successful exchange is reused for policy.basic_cache (at most until shortly before the token
-- expires), a failed one is refused again for policy.basic_failure_cache, so that clients sending
-- the credentials with every request neither hammer the provider nor lock accounts.

local http     = require("resty.http")
local cjson    = require("cjson.safe")
local sha256   = require("resty.sha256")
local rstr     = require("resty.string")
local config   = require("emondrian.config")
local oidc     = require("emondrian.oidc")
local identity = require("emondrian.identity")

local M = {}

-- Splits an "Authorization: Basic ..." value into user and password.
function M.parse(header)
  local decoded = ngx.decode_base64((header:gsub("^%a+%s+", "")))
  if not decoded then
    return nil
  end
  local user, password = decoded:match("^([^:]*):(.*)$")
  if not user or user == "" or password == "" then
    return nil
  end
  return user, password
end

local function cache_key(user, password)
  local hash = sha256:new()
  hash:update(config.secret .. "\0" .. user .. "\0" .. password)
  return rstr.to_hex(hash:final())
end

-- Returns claims, or nil (wrong credentials), or nil and "unavailable" (the provider failed).
function M.authenticate(user, password)
  local key = cache_key(user, password)
  local cache = ngx.shared.basic_auth
  local cached = cache:get(key)
  if cached == "" then
    return nil
  end
  if cached then
    return cjson.decode(cached)
  end

  local provider = config.provider
  local token_endpoint = provider.token_endpoint
  if not token_endpoint then
    local discovery, err = oidc.discovery()
    if err or type(discovery) ~= "table" then
      ngx.log(ngx.ERR, "discovery of the OpenID provider failed: ", err)
      return nil, "unavailable"
    end
    token_endpoint = discovery.token_endpoint
  end
  local args = {
    grant_type    = "password",
    client_id     = provider.client_id,
    client_secret = provider.client_secret,
    username      = user,
    password      = password,
    scope         = "openid",
  }
  for name, value in pairs(provider.password_grant_params) do
    args[name] = value
  end

  local httpc = http.new()
  httpc:set_timeout(10000)
  local res, err = httpc:request_uri(token_endpoint, {
    method     = "POST",
    headers    = { ["Content-Type"] = "application/x-www-form-urlencoded" },
    body       = ngx.encode_args(args),
    ssl_verify = true,
  })
  if not res then
    ngx.log(ngx.ERR, "token endpoint unreachable: ", err)
    return nil, "unavailable"
  end
  if res.status == 400 or res.status == 401 then
    ngx.log(ngx.NOTICE, "Basic login refused for user ", identity.one_line(user))
    cache:set(key, "", config.policy.basic_failure_cache)
    return nil
  end
  if res.status ~= 200 then
    ngx.log(ngx.ERR, "token endpoint answered HTTP ", res.status)
    return nil, "unavailable"
  end

  local body = cjson.decode(res.body)
  local claims
  claims, err = oidc.verify_access_token(body and body.access_token)
  if not claims then
    ngx.log(ngx.ERR, "token issued by the provider rejected: ", err)
    return nil, "unavailable"
  end
  local ttl = math.min(config.policy.basic_cache, (claims.exp or 0) - ngx.time() - 30)
  if ttl > 0 then
    local cached_claims = { [config.username_claim] = claims[config.username_claim] }
    for _, claim in ipairs(config.groups_claims) do
      cached_claims[claim] = claims[claim]
    end
    cache:set(key, cjson.encode(cached_claims), ttl)
  end
  return claims
end

return M
