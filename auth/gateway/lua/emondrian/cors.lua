-- Which other web sites' pages may call XML/A and the REST API from a browser (CORS).
--
-- None by default: eMondrian's own pages are on the same origin and need no CORS, and a page on
-- another site that holds a token or a link would carry it in its code. Sites that must call it
-- are listed in identity.yml (cors.allowed_origins); only those get Access-Control-Allow-Origin,
-- with their own origin, never "*", and never with credentials (cookies): such a page must send
-- a token in the Authorization header itself.
--
-- The upstream's own CORS headers (the entry container and the server send "*") are removed on
-- these paths, so that this list is the only answer. MCP keeps its own (mcp.lua).

local config = require("emondrian.config")

local M = {}

local ALLOW_METHODS = "GET, POST, OPTIONS"
local ALLOW_HEADERS = "Authorization, Content-Type, Accept, SOAPAction, X-Requested-With"

-- XML/A and the REST API (and the editors' /api): the paths this policy covers
function M.covers(uri)
  return uri:find("^/xmla/?$") ~= nil or uri:find("^/xmla/") ~= nil
      or uri:find("^/api/") ~= nil or uri == "/api"
end

local function allowed(origin)
  return origin ~= nil and origin ~= "" and config.cors_origins[origin:lower()] == true
end

-- An OPTIONS pre-flight: answered here, never forwarded. 204 with the headers for a listed
-- origin; 403 without them for any other, which the browser takes as "not allowed".
function M.preflight()
  local origin = ngx.var.http_origin
  ngx.header["Vary"] = "Origin"
  ngx.header["Cache-Control"] = "no-store"
  if not allowed(origin) then
    return ngx.exit(ngx.HTTP_FORBIDDEN)
  end
  ngx.header["Access-Control-Allow-Origin"] = origin
  ngx.header["Access-Control-Allow-Methods"] = ALLOW_METHODS
  ngx.header["Access-Control-Allow-Headers"] = ALLOW_HEADERS
  ngx.header["Access-Control-Max-Age"] = "600"
  -- the header filter below runs on this answer too and must leave these headers alone
  ngx.ctx.cors_preflight = true
  return ngx.exit(ngx.HTTP_NO_CONTENT)
end

-- Header filter of every answer on these paths, the gateway's own (401, 403) included
function M.filter()
  if ngx.ctx.cors_preflight or not M.covers(ngx.var.uri) then
    return
  end
  ngx.header["Access-Control-Allow-Origin"] = nil
  ngx.header["Access-Control-Allow-Credentials"] = nil
  ngx.header["Access-Control-Allow-Methods"] = nil
  ngx.header["Access-Control-Allow-Headers"] = nil
  ngx.header["Access-Control-Expose-Headers"] = nil
  ngx.header["Access-Control-Max-Age"] = nil
  local origin = ngx.var.http_origin
  if allowed(origin) then
    ngx.header["Access-Control-Allow-Origin"] = origin
    ngx.header["Vary"] = "Origin"
  end
end

return M
