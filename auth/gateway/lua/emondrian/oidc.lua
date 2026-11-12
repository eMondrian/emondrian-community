-- The OpenID provider: the browser login (Authorization Code with PKCE, tokens kept in a
-- server-side session) and the verification of access tokens. The provider is our Keycloak (mode
-- broker) or the customer's own (mode oidc-direct); see config.provider.

local openidc = require("resty.openidc")
local session = require("resty.session")
local config  = require("emondrian.config")

local M = {}
local opts

function M.init()
  local provider = config.provider
  -- mode broker: discovery goes to Keycloak inside the compose network. Keycloak answers with the
  -- public authorization/logout endpoints (KC_HOSTNAME) and internal token/JWKS endpoints
  -- (KC_HOSTNAME_BACKCHANNEL_DYNAMIC), so the gateway never needs the public URL itself.
  opts = {
    discovery                         = provider.discovery_url,
    client_id                         = provider.client_id,
    client_secret                     = provider.client_secret,
    token_endpoint_auth_method        = "client_secret_post",
    redirect_uri                      = config.public_url .. "/redirect_uri",
    logout_path                       = "/logout",
    post_logout_redirect_uri          = config.public_url .. "/",
    scope                             = provider.scope,
    use_pkce                          = true,
    renew_access_token_on_expiry      = true,
    access_token_expires_leeway       = 30,
    token_signing_alg_values_expected = { "RS256" },
    session_contents                  = { id_token = true, access_token = true },
    -- HTTPS to the provider (oidc-direct) is checked against lua_ssl_trusted_certificate
    ssl_verify                        = "yes",
  }

  session.init({
    secret           = config.secret,
    cookie_name      = "emondrian_session",
    cookie_secure    = config.https,
    cookie_same_site = "Lax",
    storage          = "shm",
    shm              = { zone = "sessions" },
    idling_timeout   = config.policy.session_idle,
    rolling_timeout  = math.min(3600, config.policy.session_max),
    absolute_timeout = config.policy.session_max,
  })
end

-- The provider's discovery document (cached by lua-resty-openidc).
function M.discovery()
  return openidc.get_discovery_doc(opts)
end

-- mode broker: login straight at one identity provider of identity.yml (kc_idp_hint) instead of
-- Keycloak's login page: ?idp=<source> on any page, else login.default_source.
local function login_opts()
  local idp = ngx.var.arg_idp
  if not (idp and config.idp_aliases[idp]) then
    idp = config.default_idp
  end
  if not idp then
    return opts
  end
  return setmetatable({ authorization_params = { kc_idp_hint = idp } }, { __index = opts })
end

-- Browser login. unauth_action "deny" returns nil instead of redirecting (API paths).
-- Returns the ID token claims, or nil and an error.
function M.session(unauth_action)
  local res, err = openidc.authenticate(unauth_action and opts or login_opts(), nil, unauth_action)
  if err then
    return nil, err
  end
  return res and res.id_token
end

local function contains(list, value)
  for _, item in ipairs(list or {}) do
    if item == value then
      return true
    end
  end
  return false
end

local function has_audience(claims)
  local aud = type(claims.aud) == "table" and claims.aud or { claims.aud }
  for _, a in ipairs(aud) do
    if contains(config.provider.audiences, a) then
      return true
    end
  end
  return false
end

-- Signature, expiry, issuer and audience of an access token of the provider.
function M.verify_access_token(token)
  if type(token) ~= "string" or token == "" then
    return nil, "no token"
  end
  local discovery, err = openidc.get_discovery_doc(opts)
  if err then
    return nil, "discovery failed: " .. err
  end
  local claims
  claims, err = openidc.jwt_verify(token, opts)
  if err or not claims then
    return nil, err or "invalid token"
  end
  local issuers = config.provider.token_issuers or { discovery.issuer }
  if not contains(issuers, claims.iss) then
    return nil, "unexpected issuer " .. tostring(claims.iss)
  end
  if not has_audience(claims) then
    return nil, "token is not issued for " .. table.concat(config.provider.audiences, " or ")
  end
  if claims.typ ~= nil and claims.typ ~= "Bearer" then
    return nil, "not an access token"
  end
  return claims
end

return M
