-- Entry points of the auth gateway, called from emondrian-locations.conf.
--
-- web(): browser pages; redirect to the Keycloak login when there is no session.
-- api(): /xmla, /api, /emondrian/mcp; the credentials the request carries decide the method
--        (an XML/A link's ?emondrian_token=, Bearer token, Basic, or else the browser session).
--        No redirect: 401 with a challenge.
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
local link     = require("emondrian.link")

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
-- A request a page's own script made (fetch/XHR from the entry page, the OLAP client): browsers
-- mark it with Sec-Fetch-Mode other than "navigate" (or a library with X-Requested-With). Excel,
-- Power BI and scripts send neither.
local function from_page_script()
  local mode = ngx.var.http_sec_fetch_mode
  if mode and mode ~= "" and mode ~= "navigate" then
    return true
  end
  return ngx.var.http_x_requested_with ~= nil
end

-- 401 without a challenge, for a page's script: a Basic challenge there makes the browser open its
-- own password dialog over a page whose session has ended. The page goes to the login instead
-- (login: "/" redirects there); a page that shows the answer's text shows the message.
local function login_required(bearer_error)
  local message = bearer_error and ("Token refused: " .. bearer_error)
                  or "Your session has ended. Reload the page to sign in again."
  ngx.status = ngx.HTTP_UNAUTHORIZED
  ngx.header["Cache-Control"] = "no-store"
  if (ngx.var.http_accept or ""):find("json", 1, true) then
    ngx.header["Content-Type"] = "application/json"
    ngx.say(require("cjson.safe").encode({ error = "login_required", message = message, login = "/" }))
  else
    ngx.header["Content-Type"] = "text/plain; charset=utf-8"
    ngx.say(message)
  end
  return ngx.exit(ngx.HTTP_UNAUTHORIZED)
end

local function challenge(bearer_error)
  if not ngx.var.uri:find("^/emondrian/mcp") and from_page_script() then
    return login_required(bearer_error)
  end
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

-- open_access: authentication is off. Every request is the guest of identity.yml with its groups,
-- whatever credentials it carries (Excel may still send a saved password); they are dropped, and
-- client-sent X-Forwarded-* headers are overwritten as always.
local function open_access()
  local guest = config.open_access
  ngx.var.auth_user   = identity.one_line(guest.user)
  ngx.var.auth_groups = table.concat(identity.group_names(guest.groups), ",")
  ngx.var.auth_method = "open"
  ngx.req.clear_header("Authorization")
  link.strip()
end

-- X-Forwarded-Access-Token on every endpoint (XML/A, the API, MCP, the web tools): the user's
-- access token of the identity provider (Keycloak, or the provider of oidc-direct), so that a
-- service behind the gateway can call that provider's APIs as the user, also when one service
-- calls another (XML/A to MCP). There is none for personal tokens, Kerberos, the SSO proxy and
-- open_access.
local function forward_access_token()
  if ngx.ctx.access_token then
    ngx.var.auth_access_token = ngx.ctx.access_token
  end
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
    else
      ngx.ctx.access_token = token
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

-- 401 for an XML/A link that failed: no challenge, since no other credentials will be taken
-- with it. The reason goes to the log only; the client is told what to do.
local function link_refused(token, reason)
  link.raw_log(ngx.NOTICE, "XML/A link " .. link.hint(token) .. " from " .. ngx.var.remote_addr .. " refused: " .. reason)
  link.count_failure()
  ngx.status = ngx.HTTP_UNAUTHORIZED
  ngx.header["Content-Type"] = "text/plain; charset=utf-8"
  ngx.header["Cache-Control"] = "no-store"
  ngx.say("This eMondrian link has expired or is no longer valid. Sign in to eMondrian and get a new"
          .. " link on " .. config.public_url .. "/account/tokens")
  return ngx.exit(ngx.HTTP_UNAUTHORIZED)
end

-- /xmla?emondrian_token=…: the link decides alone, whatever else the request carries.
local function api_with_link(token)
  link.strip()
  if link.too_many_failures() then
    link.raw_log(ngx.NOTICE, "XML/A link from " .. ngx.var.remote_addr .. " not checked: too many refused links")
    ngx.header["Retry-After"] = "60"
    return ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
  end
  local claims, reason = link.verify(token)
  if reason == "unavailable" then
    return ngx.exit(ngx.HTTP_SERVICE_UNAVAILABLE)
  end
  if not claims or not identity.set(claims, "link") then
    return link_refused(token, reason or "no user")
  end
  ngx.req.clear_header("Authorization")
end

function M.api()
  -- CORS pre-flights carry no credentials; the entry container answers them without data
  if ngx.req.get_method() == "OPTIONS" then
    link.strip()
    return
  end

  if config.open_access_on() then
    return open_access()
  end

  -- XML/A links are for /xmla only; anywhere else the parameter is dropped unread
  local token = link.from_request()
  if token then
    if ngx.var.uri:find("^/xmla/?$") then
      return api_with_link(token)
    end
    link.strip()
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

  if not identity.set(claims, method) then
    if method == "bearer" and claims then
      err = "the token has no user name (" .. config.username_claim .. ")"
    end
    return challenge(method == "bearer" and err or nil)
  end
  -- Credentials end here; eMondrian gets the identity headers only, and the access token
  forward_access_token()
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
  if not identity.set(claims, "proxy") then
    return forbidden("The sign-in proxy did not say who you are.")
  end
end

function M.web()
  if config.open_access_on() then
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
  if not identity.set(claims, "session") then
    return forbidden("The identity provider sent no user name.")
  end
  forward_access_token()
end

return M
