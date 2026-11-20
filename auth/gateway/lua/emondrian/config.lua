-- Settings of the auth gateway, read once per worker from the environment (nginx.conf lists
-- every variable with an `env` directive, otherwise os.getenv does not see it) and from the
-- gateway config the configurator writes from auth/identity.yml (claims).

local cjson = require("cjson.safe")

local M = {}

local GATEWAY_CONFIG = "/etc/emondrian-auth/gateway.json"

local function read_gateway_config()
  local file, err = io.open(GATEWAY_CONFIG, "r")
  if not file then
    error("cannot read " .. GATEWAY_CONFIG .. " (written by the auth-config service): " .. err)
  end
  local content = file:read("*a")
  file:close()
  local decoded = cjson.decode(content)
  if type(decoded) ~= "table" then
    error(GATEWAY_CONFIG .. " is not valid JSON")
  end
  return decoded
end

local function env(name, default)
  local value = os.getenv(name)
  if value == nil or value == "" then
    if default == nil then
      error("environment variable " .. name .. " is not set")
    end
    return default
  end
  return value
end

local function flag(name, default)
  return env(name, default and "true" or "false") == "true"
end

-- The OpenID provider the gateway is a client of. mode broker: our Keycloak, reached inside the
-- compose network. mode oidc-direct: the customer's provider, from gateway.json.
local function provider(gateway)
  if gateway.mode == "trusted-proxy" then
    -- No OpenID provider: the SSO proxy has authenticated the user
    return { password_grant = false, password_grant_params = {}, audiences = {}, scope = "openid" }
  end
  if gateway.mode == "oidc-direct" then
    local oidc = gateway.oidc
    if type(oidc) ~= "table" then
      error("gateway.json: mode oidc-direct without its oidc settings; run auth/scripts/apply-config.sh")
    end
    return {
      discovery_url         = oidc.discovery_url,
      client_id             = oidc.client_id,
      client_secret         = oidc.client_secret,
      scope                 = oidc.scopes,
      token_endpoint        = nil,  -- from the discovery document
      token_issuers         = oidc.token_issuers,
      audiences             = oidc.token_audiences,
      password_grant        = oidc.password_grant == true,
      password_grant_params = oidc.password_grant_params or {},
    }
  end
  local keycloak = env("KEYCLOAK_INTERNAL_URL", "http://keycloak:8080/auth"):gsub("/+$", "")
  local realm_url = keycloak .. "/realms/" .. env("KEYCLOAK_REALM", "emondrian")
  return {
    discovery_url         = realm_url .. "/.well-known/openid-configuration",
    client_id             = env("OIDC_CLIENT_ID", "emondrian-gateway"),
    client_secret         = env("OIDC_CLIENT_SECRET"),
    scope                 = "openid profile email",
    token_endpoint        = realm_url .. "/protocol/openid-connect/token",
    token_issuers         = nil,  -- the discovery document's issuer
    audiences             = { env("OIDC_AUDIENCE", "emondrian") },
    -- Keycloak checks Basic credentials against its LDAP sources
    password_grant        = true,
    password_grant_params = {},
  }
end

function M.load()
  M.public_url     = env("PUBLIC_URL"):gsub("/+$", "")
  -- Signs the session cookie and salts cache keys; the same in every worker
  M.secret         = env("SESSION_SECRET")
  -- Sent to eMondrian as X-Forwarded-Secret on every request forwarded there: eMondrian believes
  -- X-Forwarded-User/-Groups only with it, so a caller that reaches eMondrian around this gateway
  -- (the host, another container) cannot name itself a user. The same value as eMondrian's.
  M.forwarded_secret = env("EMONDRIAN_FORWARDED_SECRET")
  if #M.forwarded_secret < 32 then
    error("EMONDRIAN_FORWARDED_SECRET must be at least 32 characters (auth/scripts/init.sh writes one)")
  end
  M.https          = M.public_url:find("^https://") ~= nil

  local gateway = read_gateway_config()
  M.mode     = gateway.mode or "broker"
  -- mode broker: the service account that checks a personal token's owner at use (owner.lua)
  local owner_check = gateway.owner_check
  if M.mode == "broker" and type(owner_check) == "table" and owner_check.client_id and owner_check.client_secret then
    local keycloak = env("KEYCLOAK_INTERNAL_URL", "http://keycloak:8080/auth"):gsub("/+$", "")
    local realm = env("KEYCLOAK_REALM", "emondrian")
    M.owner_check = {
      client_id      = owner_check.client_id,
      client_secret  = owner_check.client_secret,
      token_endpoint = keycloak .. "/realms/" .. realm .. "/protocol/openid-connect/token",
      users          = keycloak .. "/admin/realms/" .. realm .. "/users",
    }
  else
    M.owner_check = nil
  end
  M.provider = provider(gateway)
  -- mode trusted-proxy: how to recognise the SSO proxy and read the user from it
  M.trusted_proxy = type(gateway.trusted_proxy) == "table" and gateway.trusted_proxy or nil
  -- policy in identity.yml (seconds)
  local policy = type(gateway.policy) == "table" and gateway.policy or {}
  M.policy = {
    session_idle        = tonumber(policy.session_idle) or 1800,
    session_max         = tonumber(policy.session_max) or 36000,
    basic_cache         = tonumber(policy.basic_cache) or 300,
    basic_failure_cache = tonumber(policy.basic_failure_cache) or 10,
  }

  -- Personal access tokens (emk_…), as the Basic password or a Bearer token
  M.personal_tokens = gateway.personal_tokens ~= false
  -- XML/A links, /xmla?emondrian_token=eml_… (Power BI Desktop's live connection)
  M.xmla_links = gateway.xmla_links ~= false
  -- Web sites whose pages may call XML/A and the REST API from a browser (cors.lua); none by default
  M.cors_origins = {}
  local cors = type(gateway.cors) == "table" and gateway.cors or {}
  for _, origin in ipairs(type(cors.allowed_origins) == "table" and cors.allowed_origins or {}) do
    M.cors_origins[origin] = true
  end
  -- OAuth for MCP clients (Protected Resource Metadata, Keycloak as authorization server)
  M.mcp_oauth = gateway.mcp_oauth == true
  -- Kerberos (Negotiate) on XML/A and the API
  M.kerberos = gateway.kerberos == true
  M.issuer = M.public_url .. "/auth/realms/" .. env("KEYCLOAK_REALM", "emondrian")
  -- Authentication methods for the API paths; the browser session is always accepted there
  M.methods = {
    bearer = flag("AUTH_BEARER", true),
    -- Basic: a password checked by the provider's password grant, or a personal token
    basic  = flag("AUTH_BASIC", true) and (M.provider.password_grant or M.personal_tokens),
    -- Kerberos tickets (Excel, Power BI on domain computers)
    negotiate = M.kerberos,
  }

  M.username_claim = gateway.username_claim or "preferred_username"
  -- Directory groups and groups of external identity providers (external_groups)
  M.groups_claims  = type(gateway.groups_claims) == "table" and gateway.groups_claims or { "groups" }
  M.default_idp    = type(gateway.default_idp) == "string" and gateway.default_idp or nil
  -- Seconds an access token is still accepted after its exp (and before its nbf/iat), for clocks
  -- that differ a little; lua-resty-openidc's own default is 120. AUTH_TOKEN_LEEWAY in .env, 30-60.
  local leeway = tonumber(env("AUTH_TOKEN_LEEWAY", "60"))
  if not leeway or leeway < 0 or leeway > 300 then
    error("AUTH_TOKEN_LEEWAY must be a number of seconds, 30 to 60 recommended")
  end
  M.token_leeway = math.floor(leeway)
  -- open_access in identity.yml: the guest every request is while authentication is off
  -- ({enabled, user, groups}); whether it is off is decided per request, see M.open_access_on
  local open = gateway.open_access
  M.open_access = type(open) == "table" and type(open.user) == "string" and type(open.groups) == "table"
                  and open or nil
  M.idp_aliases    = {}
  for _, alias in ipairs(type(gateway.idp_aliases) == "table" and gateway.idp_aliases or {}) do
    M.idp_aliases[alias] = true
  end
  return M
end

-- auth/state/open_access.json, written by the MCP tool set_open_access and by
-- auth/scripts/authentication.sh: {"enabled": true|false}. Read on each request (cached here for
-- two seconds per worker), so a switch applies without a reload. Without the file, identity.yml's
-- open_access.enabled applies; a file that cannot be read leaves authentication on.
local STATE_FILE = "/etc/emondrian-auth-state/open_access.json"
local state_cache = { at = -1, value = nil }

function M.open_access_on()
  if not M.open_access then
    return false
  end
  local now = ngx.now()
  if now - state_cache.at >= 2 then
    local value = M.open_access.enabled == true
    local file = io.open(STATE_FILE, "r")
    if file then
      local decoded = cjson.decode(file:read("*a"))
      file:close()
      if type(decoded) == "table" and type(decoded.enabled) == "boolean" then
        value = decoded.enabled
      else
        require("emondrian.log").out_of_request(ngx.ERR, STATE_FILE .. " holds no \"enabled\": true|false; authentication stays on")
        value = false
      end
    end
    if value ~= state_cache.value and state_cache.at >= 0 then
      -- Out of the request: its request line may hold an XML/A link's token (link.lua)
      require("emondrian.log").out_of_request(ngx.WARN, "open access switched " .. (value and "ON (authentication off)" or "OFF (authentication on)"))
    end
    state_cache.at, state_cache.value = now, value
  end
  return state_cache.value
end

return M
