-- A personal token (emk_…, pat.lua) in the address, for clients that keep the server address but
-- send no credentials of their own, and for links people open in a browser:
--
--   <PUBLIC_URL>/xmla?emondrian_token=emk_…              Power BI Desktop's live connection, which
--                                                        drops a saved password after the first 401
--   <PUBLIC_URL>/dashboard/d/<id>?emondrian_token=emk_…  a dashboard, without signing in
--
-- Nowhere else: the REST API and MCP take the token in the Authorization header only.
--
-- On /xmla the token in the address decides alone, whatever else the request carries: a broken
-- token must not quietly work under someone's saved password. On a dashboard page the gateway
-- checks it, puts it in a cookie (HttpOnly, Secure, SameSite Lax, never longer than the token or
-- 12 h) and redirects to the same address without the emondrian_token parameter, so the token
-- leaves the address bar; the page's own requests (its files, its API calls, its MDX on /xmla)
-- carry the cookie, which is taken on /dashboard and /xmla only. The cookie goes through the
-- token check on every request, so a revoked or expired token, a newer token of the same user, or
-- an owner disabled in Keycloak ends the browser session within the 30 s cache.
--
-- The token never goes further: it is removed from the query string before the request is
-- proxied, and the access log masks it ($request_masked, nginx.conf).
--
-- Until 2026-11 these addresses carried a separate XML/A link (eml_…); those no longer work.

local config   = require("emondrian.config")
local pat      = require("emondrian.pat")

-- Messages without the request line, which holds the token (log.lua)
local raw_log  = require("emondrian.log").out_of_request

local M = {}

M.raw_log = raw_log

M.COOKIE = "emondrian_link"
-- A browser keeps a link's session at most this long, and never past the token's expiry
local COOKIE_SECONDS = 12 * 3600
local PARAM = "emondrian_token"
-- Refused tokens in the address per client address and minute before the gateway stops checking
-- them (429)
local FAILURES_PER_MINUTE = 20

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

-- Whether this address has refused tokens enough for now; counts one more refusal when asked.
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

-- Whether a request may use the cookie: the Dashboard and XML/A, what a dashboard page uses.
function M.cookie_path(uri)
  return uri:find("^/dashboard/") ~= nil or uri == "/dashboard" or uri:find("^/xmla/?$") ~= nil
end

-- A dashboard page, where a token in the address is taken.
function M.dashboard_page(uri)
  return uri:find("^/dashboard/d/[A-Za-z0-9_-]+/?$") ~= nil
end

function M.cookie()
  local value = ngx.var["cookie_" .. M.COOKIE]
  if value and value ~= "" then
    return value
  end
end

local function secure()
  return config.public_url:find("^https://") and "; Secure" or ""
end

function M.set_cookie(token, expires_at)
  local age = COOKIE_SECONDS
  if expires_at then
    age = math.min(age, expires_at - ngx.now())
  end
  age = math.floor(age)
  ngx.header["Set-Cookie"] = M.COOKIE .. "=" .. token .. "; Path=/; Max-Age=" .. age .. "; HttpOnly; SameSite=Lax" .. secure()
end

function M.clear_cookie()
  ngx.header["Set-Cookie"] = M.COOKIE .. "=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax" .. secure()
end

-- The address without the token: the same path and every other parameter, for the redirect.
function M.address_without_token()
  M.strip()
  local args = ngx.var.args
  return ngx.var.uri .. ((args and args ~= "") and ("?" .. args) or "")
end

-- Returns claims and the token's expiry (epoch seconds); or nil and the reason, for the log only
-- (never sent to the client); or nil and "unavailable" (auth-tokens or Keycloak could not
-- answer: 503).
function M.verify(token)
  if not config.personal_tokens then
    return nil, "personal tokens are turned off (personal_tokens in identity.yml)"
  end
  if type(token) == "string" and token:find("^eml_") then
    return nil, "an XML/A link (eml_), which no longer works: the user needs a personal token"
  end
  if not pat.well_formed(token) then
    return nil, "malformed"
  end
  local claims, err, expires = pat.verify(token)
  if err == "unavailable" then
    return nil, "unavailable"
  end
  if not claims then
    return nil, "unknown, expired or revoked token, or its owner is disabled"
  end
  return claims, expires
end

return M
