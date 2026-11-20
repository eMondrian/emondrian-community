-- The owner of a personal access token as Keycloak knows it now (mode broker): whether the user
-- still exists and is enabled, and its current groups. pat.lua asks at every use whose
-- verification is not cached (at most 30 s), so disabling a user, removing it from a group or
-- adding one reaches its personal tokens as fast as it reaches its logins.
--
-- Asked with the gateway's own service account (emondrian-gateway-lookup, realm-management's
-- view-users only), whose credentials auth-config writes into gateway.json (root only).

local http   = require("resty.http")
local cjson  = require("cjson.safe")
local config   = require("emondrian.config")
local identity = require("emondrian.identity")

-- Also called for a token in the address, whose request line holds it; ngx.log would add it
local raw_log = require("emondrian.log").out_of_request

local M = {}

local TOKEN_KEY = "owner-check:service-token"

local function request(url, options)
  local httpc = http.new()
  httpc:set_timeout(5000)
  return httpc:request_uri(url, options)
end

-- The service account's access token, cached until 30 s before it expires.
local function service_token()
  local cache = ngx.shared.basic_auth
  local token = cache:get(TOKEN_KEY)
  if token then
    return token
  end
  local check = config.owner_check
  local res, err = request(check.token_endpoint, {
    method  = "POST",
    headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
    body    = ngx.encode_args({ grant_type = "client_credentials", client_id = check.client_id,
                                client_secret = check.client_secret }),
  })
  local body = res and res.status == 200 and cjson.decode(res.body)
  if type(body) ~= "table" or type(body.access_token) ~= "string" then
    raw_log(ngx.ERR, "owner check: no service token from Keycloak (" .. tostring(err or (res and ("HTTP " .. res.status)) or "?") .. ")")
    return nil
  end
  local ttl = (tonumber(body.expires_in) or 60) - 30
  if ttl > 0 then
    cache:set(TOKEN_KEY, body.access_token, ttl)
  end
  return body.access_token
end

local function get(url, token)
  local res, err = request(url, { method = "GET", headers = { Authorization = "Bearer " .. token } })
  if not res then
    return nil, err
  end
  if res.status ~= 200 then
    return nil, "HTTP " .. res.status
  end
  return cjson.decode(res.body)
end

-- Returns the user's current groups (Keycloak group paths, then the provider's external_groups);
-- or nil and "gone" (no such user, or disabled); or nil and "unavailable" (Keycloak could not be
-- asked), which the caller refuses too.
function M.current(user)
  local check = config.owner_check
  local token = service_token()
  if not token then
    return nil, "unavailable"
  end
  local users, err = get(check.users .. "?" .. ngx.encode_args({ username = user, exact = "true",
                                                                   briefRepresentation = "false" }), token)
  if type(users) ~= "table" then
    raw_log(ngx.ERR, "owner check: user lookup failed (" .. tostring(err or "?") .. ")")
    return nil, "unavailable"
  end
  local found
  for _, u in ipairs(users) do
    if type(u.username) == "string" and u.username:lower() == user:lower() then
      found = u
    end
  end
  if not found then
    return nil, "gone"
  end
  if found.enabled == false then
    return nil, "gone"
  end
  local groups
  groups, err = get(check.users .. "/" .. found.id .. "/groups?" .. ngx.encode_args({ briefRepresentation = "true",
                                                                                      max = "1000" }), token)
  if type(groups) ~= "table" then
    raw_log(ngx.ERR, "owner check: group lookup failed (" .. tostring(err or "?") .. ")")
    return nil, "unavailable"
  end
  local paths = {}
  for _, g in ipairs(groups) do
    if type(g.path) == "string" then
      paths[#paths + 1] = g.path
    end
  end
  -- Groups of an external identity provider, which its mappers keep in the attribute
  -- external_groups (forwarded as top-level paths, like at login). Keycloak updates the attribute
  -- only when the user logs in through the provider again.
  local attributes = type(found.attributes) == "table" and found.attributes or {}
  for _, group in ipairs(identity.external_groups(attributes.external_groups_source, attributes.external_groups)) do
    paths[#paths + 1] = group
  end
  return paths
end

return M
