-- Entry points of the auth gateway, called from emondrian-locations.conf.
--
-- web(): browser pages; redirect to the Keycloak login when there is no session.
-- api(): /xmla, /api, /emondrian/mcp; the credentials the request carries decide the method
--        (Bearer token, Basic, or else the browser session). No redirect: 401 with a challenge.
--
-- Both end with identity.set(), which fills the X-Forwarded-User / X-Forwarded-Groups headers.

local config   = require("emondrian.config")
local identity = require("emondrian.identity")
local oidc     = require("emondrian.oidc")
local basic    = require("emondrian.basic")
local pat      = require("emondrian.pat")
local mcp      = require("emondrian.mcp")
local kerberos = require("emondrian.kerberos")
local proxy    = require("emondrian.trusted_proxy")

local M = {}

function M.init()
  require("emondrian.hosts").init()
  config.load()
  oidc.init()
  proxy.init()
end

-- OpenResty keeps a single WWW-Authenticate header, so one challenge per path: Basic for XML/A
-- and the API, whose clients (Excel, Power BI) only answer Basic; Bearer for MCP clients.
-- bearer_error: why a Bearer token was refused. It goes to the client as error="invalid_token"
-- (RFC 6750), so an MCP client shows the reason instead of retrying with the same token.
local function challenge(bearer_error)
  if ngx.var.uri:find("^/emondrian/mcp") and config.mcp_oauth then
    -- MCP clients find the authorization server through this (MCP authorization)
    local error_params = ""
    if bearer_error then
      error_params = ', error="invalid_token", error_description="'
                     .. bearer_error:gsub('[%c"\\]', " ") .. '"'
    end
    ngx.header["WWW-Authenticate"] = 'Bearer realm="eMondrian", resource_metadata="'
                                     .. mcp.metadata_url(ngx.var.uri) .. '"' .. error_params
  elseif ngx.var.uri:find("^/emondrian/mcp") or not config.methods.basic then
    ngx.header["WWW-Authenticate"] = 'Bearer realm="eMondrian"'
  else
    local basic = 'Basic realm="eMondrian", charset="UTF-8"'
    if config.kerberos then
      -- Negotiate first: Excel (MSOLAP) with Windows authentication takes the first challenge
      -- and, finding Basic, sends nothing; curl, browsers and Power BI pick either way.
      -- OpenResty keeps one WWW-Authenticate from Lua (the last of a table), so nginx adds
      -- Basic after it (add_header $auth_second_challenge).
      ngx.header["WWW-Authenticate"] = "Negotiate"
      ngx.var.auth_second_challenge = basic
    else
      ngx.header["WWW-Authenticate"] = basic
    end
  end
  ngx.header["Content-Type"] = "text/plain; charset=utf-8"
  ngx.status = ngx.HTTP_UNAUTHORIZED
  ngx.say(bearer_error and ("Token refused: " .. bearer_error) or "Authentication required")
  return ngx.exit(ngx.HTTP_UNAUTHORIZED)
end

-- open_access: authentication is off. Every request is the guest of identity.yml with its roles,
-- whatever credentials it carries (Excel may still send a saved password); they are dropped, and
-- client-sent X-Forwarded-* headers are overwritten as always.
local function open_access()
  local guest = config.open_access
  ngx.var.auth_user   = identity.one_line(guest.user)
  ngx.var.auth_groups = table.concat(guest.roles, ",")
  ngx.var.auth_method = "open"
  ngx.req.clear_header("Authorization")
end

local function forbidden(message)
  ngx.header["Content-Type"] = "text/plain; charset=utf-8"
  ngx.status = ngx.HTTP_FORBIDDEN
  ngx.say(message)
  return ngx.exit(ngx.HTTP_FORBIDDEN)
end

-- Authorization header methods: scheme (lower case) -> function(header) returning claims or
-- nil, err; err "unavailable" means the method could not decide (503, not 401). A third value
-- names the method for the audit log when it differs from the scheme (a personal token).
local header_methods = {
  bearer = function(header)
    local token = header:match("^%a+%s+(%S+)")
    if config.mode == "trusted-proxy" and not pat.is_token(token) then
      return nil  -- no OpenID provider to check other tokens against
    end
    if pat.is_token(token) then
      if not config.personal_tokens then
        return nil
      end
      local claims, err = pat.verify(token)
      return claims, err, "pat"
    end
    local claims, err = oidc.verify_access_token(token)
    if not claims then
      ngx.log(ngx.NOTICE, "Bearer token rejected: ", err)
    end
    return claims, err
  end,
  negotiate = function(header)
    return kerberos.verify(header)
  end,
  basic = function(header)
    local user, password = basic.parse(header)
    if not user then
      return nil
    end
    -- A personal token as the password, under the owner's user name (Excel, Power BI)
    if pat.is_token(password) and config.personal_tokens then
      local claims, err = pat.verify(password, user)
      return claims, err, "pat"
    end
    if not config.provider.password_grant then
      return nil
    end
    return basic.authenticate(user, password)
  end,
}

function M.api()
  -- CORS pre-flights carry no credentials; the entry container answers them without data
  if ngx.req.get_method() == "OPTIONS" then
    return
  end

  if config.open_access then
    return open_access()
  end

  local header = ngx.var.http_authorization
  local claims, err, method
  if config.mode == "trusted-proxy" and not pat.in_header(header) then
    -- The SSO proxy says who the user is; a personal token (Excel) may come without it
    local reason
    claims, reason = proxy.identity()
    method = "proxy"
    if claims then
      proxy.clear_headers()
    elseif reason ~= "untrusted" and reason ~= "no_user" then
      return forbidden("The request did not come through the SSO proxy correctly.")
    end
  elseif header then
    method = (header:match("^(%a+)%s") or ""):lower()
    if config.methods[method] and header_methods[method] then
      local used
      claims, err, used = header_methods[method](header)
      method = used or method
      if err == "unavailable" then
        return ngx.exit(ngx.HTTP_SERVICE_UNAVAILABLE)
      end
    end
  else
    -- The browser OLAP client calls /xmla with the session cookie of the page it runs on
    method = "session"
    claims = oidc.session("deny")
  end

  local ok, reason = identity.set(claims, method)
  if not ok then
    if reason == "no_role" then
      return forbidden("You are logged in as " .. ngx.var.auth_user .. " but hold no eMondrian role.")
    end
    if method == "bearer" and claims then
      err = "the token has no user name (" .. config.username_claim .. ")"
    end
    return challenge(method == "bearer" and err or nil)
  end
  -- Credentials end here; eMondrian gets the identity headers only
  ngx.req.clear_header("Authorization")
end

local function web_through_proxy()
  if ngx.var.uri == "/logout" then
    return ngx.redirect(proxy.logout_url() or "/")
  end
  local claims, reason = proxy.identity()
  if not claims then
    ngx.log(ngx.NOTICE, "trusted proxy: browser request from ", ngx.var.remote_addr, " refused: ", reason)
    return forbidden(reason == "untrusted"
      and "eMondrian is reached through the organisation's sign-in proxy only."
      or "The sign-in proxy did not say who you are.")
  end
  proxy.clear_headers()
  local ok, why = identity.set(claims, "proxy")
  if not ok then
    return forbidden(why == "no_role"
      and ("You are logged in as " .. ngx.var.auth_user .. " but hold no eMondrian role.")
      or "The sign-in proxy did not say who you are.")
  end
end

function M.web()
  if config.open_access then
    -- No login, so nothing to log out of or to come back to
    if ngx.var.uri == "/logout" or ngx.var.uri == "/redirect_uri" then
      return ngx.redirect("/")
    end
    return open_access()
  end
  if config.mode == "trusted-proxy" then
    return web_through_proxy()
  end
  local claims, err = oidc.session()
  if err then
    -- e.g. /redirect_uri opened from a bookmark or after the session expired
    if err:find("no session state", 1, true) then
      return ngx.redirect("/")
    end
    ngx.log(ngx.ERR, "login failed: ", err)
    ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
    ngx.say("Login failed, see the auth gateway log")
    return ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
  end
  local ok, reason = identity.set(claims, "session")
  if not ok then
    if reason == "no_role" then
      return forbidden("You are logged in as " .. ngx.var.auth_user ..
                       " but hold no eMondrian role. Ask your administrator for access, or log out: /logout")
    end
    return forbidden("The identity provider sent no user name.")
  end
end

return M
