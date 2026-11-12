-- Makes the gateway's own HTTP requests (to an identity provider) honour /etc/hosts, where
-- docker compose puts extra_hosts (IDP_EXTRA_HOST): nginx's resolver asks DNS only.
--
-- The name is replaced by its address for the TCP connection only; the TLS handshake still sends
-- and verifies the name (ssl_server_name), and the Host header still carries it.

local http = require("resty.http")

local M = {}

local function read_hosts()
  local map = {}
  local file = io.open("/etc/hosts", "r")
  if not file then
    return map
  end
  for line in file:lines() do
    line = line:gsub("#.*", "")
    local address, names = line:match("^%s*(%S+)%s+(.+)$")
    if address then
      for name in names:gmatch("%S+") do
        name = name:lower()
        if map[name] == nil and name ~= "localhost" then
          map[name] = address
        end
      end
    end
  end
  file:close()
  return map
end

function M.init()
  local hosts = read_hosts()
  local connect = http.connect
  http.connect = function(self, options, ...)
    if type(options) ~= "table" or type(options.host) ~= "string" then
      return connect(self, options, ...)
    end
    local name = options.host
    local address = hosts[name:lower()]
    if not address then
      return connect(self, options, ...)
    end
    local patched = {}
    for key, value in pairs(options) do
      patched[key] = value
    end
    patched.host = address
    patched.ssl_server_name = options.ssl_server_name or name
    local ok, err = connect(self, patched, ...)
    if ok then
      self.host = name
    end
    return ok, err
  end
end

return M
