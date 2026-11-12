-- Kerberos ("Authorization: Negotiate …"): Excel and Power BI on domain computers send a ticket
-- for HTTP/<host> instead of a password. The auth-kerberos service checks it against the keytab
-- and looks the user and their groups up in the LDAP source of identity.yml (kerberos.source).
--
-- Every request is authenticated on its own: no identity is kept per connection, since one
-- connection may carry several users' requests behind a proxy.

local http     = require("resty.http")
local cjson    = require("cjson.safe")
local sha256   = require("resty.sha256")
local rstr     = require("resty.string")
local config   = require("emondrian.config")

local M = {}

local SERVICE = "http://auth-kerberos:8080/accept"
local secret

local function service_secret()
  if not secret then
    -- Same derivation as auth/kerberos/kerberos.py
    local hash = sha256:new()
    hash:update("emondrian-kerberos\0" .. config.secret)
    secret = rstr.to_hex(hash:final())
  end
  return secret
end

-- Returns claims, or nil (ticket or user refused), or nil and "unavailable".
function M.verify(header)
  local token = header:match("^%a+%s+(%S+)")
  if not token then
    return nil
  end
  local httpc = http.new()
  httpc:set_timeout(10000)
  local res, err = httpc:request_uri(SERVICE, {
    method  = "POST",
    headers = { ["Content-Type"] = "application/json", ["X-Kerberos-Secret"] = service_secret() },
    body    = cjson.encode({ token = token }),
  })
  if not res then
    ngx.log(ngx.ERR, "auth-kerberos unreachable: ", err)
    return nil, "unavailable"
  end
  local body = cjson.decode(res.body) or {}
  if res.status == 503 then
    return nil, "unavailable"
  end
  if res.status ~= 200 or type(body.user) ~= "string" then
    ngx.log(ngx.NOTICE, "Kerberos login refused: ", tostring(body.error))
    return nil
  end
  if type(body.output_token) == "string" then
    -- Mutual authentication: the client may check that it talked to the real service
    ngx.header["WWW-Authenticate"] = "Negotiate " .. body.output_token
  end
  return { [config.username_claim] = body.user, [config.groups_claims[1] or "groups"] = body.groups }
end

return M
