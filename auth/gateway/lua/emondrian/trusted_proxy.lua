-- Mode trusted-proxy: the customer's SSO proxy (oauth2-proxy, Authelia, Cloudflare Access, …) in
-- front of the gateway has authenticated the user and says who it is.
--
-- Header-based proxies are believed only for requests from trusted_proxy.addresses (and with the
-- shared secret header, when one is set). JWT-based proxies sign an assertion, checked here
-- against the proxy's keys (jwks_url), issuer and audience. Either way the result is
-- {user = …, groups = {…}}, which identity.lua maps to eMondrian roles.

local openidc = require("resty.openidc")
local config  = require("emondrian.config")

local M = {}
local settings
local networks = {}
local jwt_opts

local function ipv4(text)
  local a, b, c, d = text:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then
    return nil
  end
  return ((tonumber(a) * 256 + tonumber(b)) * 256 + tonumber(c)) * 256 + tonumber(d)
end

function M.init()
  if not config.trusted_proxy then
    return
  end
  -- JSON null arrives as cjson.null, which is true in a condition: turn it into nil
  settings = {}
  for key, value in pairs(config.trusted_proxy) do
    if value ~= require("cjson.safe").null then
      settings[key] = value
    end
  end
  networks = {}
  for _, address in ipairs(settings.addresses or {}) do
    local ip, bits = address:match("^([^/]+)/?(%d*)$")
    local value = ipv4(ip)
    if value then
      local size = 2 ^ (32 - (tonumber(bits) or 32))
      networks[#networks + 1] = { first = value - value % size, size = size }
    else
      networks[#networks + 1] = { exact = ip:lower() }
    end
  end
  if settings.jwt_header then
    jwt_opts = {
      discovery = { jwks_uri = settings.jwks_url, issuer = settings.issuer },
      token_signing_alg_values_expected = settings.algorithms,
      ssl_verify = "yes",
      jwk_expires_in = 3600,
    }
  end
end

local function trusted_source(address)
  if #networks == 0 then
    return true  -- a JWT-signing proxy without an address list
  end
  local value = ipv4(address)
  for _, network in ipairs(networks) do
    if network.exact then
      if network.exact == address:lower() then
        return true
      end
    elseif value and value >= network.first and value < network.first + network.size then
      return true
    end
  end
  return false
end

-- One header value; nil when absent, false when sent more than once (ambiguous: refused).
local function header(name)
  local value = ngx.req.get_headers()[name:lower()]
  if type(value) == "table" then
    return false
  end
  return value
end

local function audience_ok(aud)
  if type(aud) == "string" then
    return aud == settings.audience
  end
  if type(aud) == "table" then
    for _, a in ipairs(aud) do
      if a == settings.audience then
        return true
      end
    end
  end
  return false
end

local function split(value, separator)
  local groups = {}
  for part in (value .. separator):gmatch("(.-)" .. separator:gsub("%p", "%%%0")) do
    part = part:match("^%s*(.-)%s*$")
    if part ~= "" then
      groups[#groups + 1] = part
    end
  end
  return groups
end

-- Returns {user, groups}, or nil and a reason ("untrusted", "secret", "no_user", "invalid").
function M.identity()
  -- The connection's own address: with GATEWAY_REAL_IP_FROM, remote_addr is the end user's
  -- (from X-Forwarded-For) while the proxy to trust is the one connected
  local source = ngx.var.realip_remote_addr or ngx.var.remote_addr
  if not trusted_source(source) then
    return nil, "untrusted"
  end
  if settings.secret and header(settings.secret_header) ~= settings.secret then
    ngx.log(ngx.WARN, "trusted proxy: request from ", source, " without the shared secret")
    return nil, "secret"
  end

  if settings.jwt_header then
    local token = header(settings.jwt_header)
    if not token then
      return nil, token == false and "invalid" or "no_user"
    end
    local claims, err = openidc.jwt_verify(token, jwt_opts)
    if err or not claims then
      ngx.log(ngx.WARN, "trusted proxy: assertion refused: ", err)
      return nil, "invalid"
    end
    if settings.issuer and claims.iss ~= settings.issuer then
      ngx.log(ngx.WARN, "trusted proxy: assertion from issuer ", tostring(claims.iss))
      return nil, "invalid"
    end
    if not audience_ok(claims.aud) then
      local aud = type(claims.aud) == "table" and table.concat(claims.aud, " ") or tostring(claims.aud)
      ngx.log(ngx.WARN, "trusted proxy: assertion for audience ", aud)
      return nil, "invalid"
    end
    local user = claims[settings.username_claim]
    if type(user) ~= "string" or user == "" then
      return nil, "no_user"
    end
    local groups = settings.groups_claim and claims[settings.groups_claim] or {}
    return { user = user, groups = type(groups) == "string" and { groups } or groups }
  end

  local user = header(settings.user_header)
  if user == false then
    ngx.log(ngx.WARN, "trusted proxy: ", settings.user_header, " sent more than once")
    return nil, "invalid"
  end
  if not user or user == "" then
    return nil, "no_user"
  end
  local groups = settings.groups_header and header(settings.groups_header)
  if groups == false then
    return nil, "invalid"
  end
  return { user = user, groups = groups and split(groups, settings.groups_separator) or {} }
end

-- The proxy's own headers stop here; eMondrian gets X-Forwarded-User / -Groups from the gateway.
function M.clear_headers()
  for _, name in ipairs({ settings.secret_header, settings.user_header, settings.groups_header,
                          settings.jwt_header }) do
    if name then
      ngx.req.clear_header(name)
    end
  end
end

function M.logout_url()
  return settings.logout_url
end

return M
