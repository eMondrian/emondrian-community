-- Settings of the auth gateway, read once per worker from the environment (nginx.conf lists
-- every variable with an `env` directive, otherwise os.getenv does not see it) and from the
-- gateway config the configurator writes from auth/identity.yml (claims, role mapping).

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
  M.https          = M.public_url:find("^https://") ~= nil

  local gateway = read_gateway_config()
  M.mode     = gateway.mode or "broker"
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
  -- eMondrian role -> list of group names or "user:<name>"; nil (JSON null) forwards groups as they are
  M.role_mapping   = gateway.role_mapping ~= cjson.null and gateway.role_mapping or nil
  M.forward_groups = gateway.forward_groups == true
  M.require_role   = gateway.require_role == true
  M.default_idp    = type(gateway.default_idp) == "string" and gateway.default_idp or nil
  -- open_access in identity.yml: authentication is off, every request is this user ({user, roles})
  local open = gateway.open_access
  M.open_access = type(open) == "table" and type(open.user) == "string" and type(open.roles) == "table"
                  and open or nil
  M.idp_aliases    = {}
  for _, alias in ipairs(type(gateway.idp_aliases) == "table" and gateway.idp_aliases or {}) do
    M.idp_aliases[alias] = true
  end
  return M
end

return M
