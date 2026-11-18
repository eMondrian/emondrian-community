-- XML/A links: <PUBLIC_URL>/xmla?emondrian_token=eml_…, for clients that keep the server address
-- but send no credentials of their own. Power BI Desktop's live connection is the one that needs
-- it: it drops a saved Basic password after the first 401 (auth/README.md, "XML/A links").
--
-- A user creates the link on /account/tokens (POST /account/api/link, browser session); the
-- auth-tokens service keeps one per user, as its SHA-256, and a new one replaces the old.
--
-- verify(): on /xmla, before any other method. A link that fails is a 401 straight away, whatever
-- else the request carries: a broken link must not quietly work under someone's saved password.
-- Expiry is checked on every request, also from the cache; the owner is looked up in Keycloak as
-- for personal tokens (mode broker, owner.lua, fail closed). The token never goes further: it is
-- removed from the query string before the request is proxied, and the access log masks it
-- ($request_masked, nginx.conf).

local http     = require("resty.http")
local cjson    = require("cjson.safe")
local sha256   = require("resty.sha256")
local rstr     = require("resty.string")
local config   = require("emondrian.config")
local identity = require("emondrian.identity")
local owner    = require("emondrian.owner")

-- Messages without the request line, which holds the token (log.lua)
local raw_log  = require("emondrian.log").out_of_request

local M = {}

M.raw_log = raw_log

local SERVICE = "http://auth-tokens:8080"
local PARAM = "emondrian_token"
-- eml_ + 32 random bytes in base64url (auth/tokens/tokens.py)
local FORMAT = "^eml_[A-Za-z0-9_-]+$"
local LENGTH = 4 + 43
-- A revoked or replaced link keeps working for at most this long (the verification cache)
local CACHE_SECONDS = 30
-- Refused links per client address and minute before the gateway stops checking them (429)
local FAILURES_PER_MINUTE = 20

local function hex_sha256(value)
  local hash = sha256:new()
  hash:update(value)
  return rstr.to_hex(hash:final())
end

local secret

local function service_secret()
  if not secret then
    secret = hex_sha256("emondrian-tokens\0" .. config.secret)
  end
  return secret
end

-- What the log may show of a token: its first characters, as the token list shows them
function M.hint(token)
  if type(token) ~= "string" then
    return "-"
  end
  return token:sub(1, 8) .. "…"
end

-- The token of the request, or nil when there is none. A parameter given twice is a list: the
-- first value counts, and verify() refuses it unless it is well-formed.
function M.from_request()
  local args = ngx.req.get_uri_args(100)
  local value = args[PARAM]
  if value == nil then
    return nil
  end
  if type(value) == "table" then
    value = value[1]
  end
  if type(value) ~= "string" then
    value = ""  -- ?emondrian_token without a value
  end
  return value
end

-- Removes the token from the query string, so that it never reaches eMondrian or its logs.
function M.strip()
  local args = ngx.req.get_uri_args(100)
  if args[PARAM] ~= nil then
    args[PARAM] = nil
    ngx.req.set_uri_args(args)
  end
end

-- Whether this address has refused links enough for now; counts one more refusal when asked.
local function failures(count)
  local dict = ngx.shared.link_failures
  local key = ngx.var.remote_addr or "-"
  if count then
    dict:incr(key, 1, 0, 60)
    return
  end
  return (dict:get(key) or 0) >= FAILURES_PER_MINUTE
end

M.too_many_failures = function() return failures(false) end
M.count_failure = function() return failures(true) end

local function claims_of(user, groups)
  return { [config.username_claim] = user, [config.groups_claims[1] or "groups"] = groups }
end

-- Returns claims; or nil and the reason, for the log only (never sent to the client); or nil and
-- "unavailable" (auth-tokens or Keycloak could not answer: 503).
function M.verify(token)
  if not config.xmla_links then
    return nil, "XML/A links are turned off (xmla_links in identity.yml)"
  end
  if #token ~= LENGTH or not token:find(FORMAT) then
    return nil, "malformed"
  end

  local key = "link:" .. hex_sha256(config.secret .. "\0" .. token)
  local cache = ngx.shared.basic_auth
  local cached = cache:get(key)
  if cached then
    local entry = cjson.decode(cached)
    if entry and entry.expires and ngx.now() < entry.expires then
      return claims_of(entry.user, entry.groups)
    end
    cache:delete(key)
  end

  local httpc = http.new()
  httpc:set_timeout(5000)
  local res, err = httpc:request_uri(SERVICE .. "/verify-link", {
    method  = "POST",
    headers = { ["Content-Type"] = "application/json", ["X-Tokens-Secret"] = service_secret() },
    body    = cjson.encode({ token = token }),
  })
  if not res then
    raw_log(ngx.ERR, "auth-tokens unreachable: " .. tostring(err))
    return nil, "unavailable"
  end
  local body = cjson.decode(res.body or "") or {}
  if res.status == 404 then
    local reason = type(body.reason) == "string" and body.reason or "unknown"
    if type(body.user) == "string" then
      reason = reason .. " (link of " .. identity.one_line(body.user) .. ")"
    end
    return nil, reason
  end
  if res.status ~= 200 or type(body.user) ~= "string" then
    raw_log(ngx.ERR, "auth-tokens answered HTTP " .. res.status .. " to a link check")
    return nil, "unavailable"
  end

  local groups
  if config.owner_check then
    local reason
    groups, reason = owner.current(body.user)
    if not groups then
      if reason == "unavailable" then
        return nil, "unavailable"
      end
      return nil, "the owner " .. identity.one_line(body.user) .. " no longer exists or is disabled in Keycloak"
    end
  else
    groups = {}
    for _, group in ipairs(type(body.groups) == "table" and body.groups or {}) do
      if type(group) == "string" and group:sub(1, 1) == "/" then
        groups[#groups + 1] = group
      end
    end
  end

  -- The expiry, as epoch seconds; the cache never outlives it
  local expires = tonumber(body.expires_at)
  if not expires then
    raw_log(ngx.ERR, "auth-tokens sent no expiry for a link")
    return nil, "unavailable"
  end
  local ttl = math.min(CACHE_SECONDS, expires - ngx.now())
  if ttl > 0 then
    cache:set(key, cjson.encode({ user = body.user, groups = groups, expires = expires }), ttl)
  end
  return claims_of(body.user, groups)
end

return M
