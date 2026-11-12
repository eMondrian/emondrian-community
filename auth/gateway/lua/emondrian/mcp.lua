-- OAuth for MCP clients (MCP authorization, revision 2025-06-18): the MCP endpoint is an OAuth
-- protected resource whose authorization server is Keycloak's realm.
--
-- A request without credentials gets 401 with WWW-Authenticate: Bearer resource_metadata=…;
-- the client reads the Protected Resource Metadata (RFC 9728) served here, then Keycloak's
-- authorization server metadata (RFC 8414), registers itself (dynamic client registration),
-- logs the user in with PKCE and sends the access token as Bearer.

local cjson  = require("cjson.safe").new()
cjson.encode_escape_forward_slash(false)
local config = require("emondrian.config")

local M = {}

local METADATA_PATH = "/.well-known/oauth-protected-resource"

-- The metadata URL for the resource a request went to (/emondrian/mcp, /emondrian/mcp/sse, …).
function M.metadata_url(uri)
  local resource = uri:match("^/emondrian/mcp/sse") and "/emondrian/mcp/sse" or "/emondrian/mcp"
  return config.public_url .. METADATA_PATH .. resource
end

-- content_by_lua of /.well-known/oauth-protected-resource[/<resource path>]
function M.protected_resource_metadata()
  if not config.mcp_oauth then
    return ngx.exit(ngx.HTTP_NOT_FOUND)
  end
  local resource = ngx.var.uri:sub(#METADATA_PATH + 1)
  if resource == "" then
    resource = "/emondrian/mcp"
  end
  ngx.header["Content-Type"] = "application/json"
  ngx.header["Access-Control-Allow-Origin"] = "*"
  ngx.header["Cache-Control"] = "max-age=300"
  ngx.say(cjson.encode({
    resource = config.public_url .. resource,
    authorization_servers = { config.issuer },
    bearer_methods_supported = { "header" },
    scopes_supported = { "openid", "profile", "email", "emondrian" },
    resource_name = "eMondrian MCP",
  }))
end

return M
