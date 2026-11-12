-- Turns verified claims into the identity eMondrian receives: $auth_user and $auth_groups, sent
-- as X-Forwarded-User / X-Forwarded-Groups by emondrian-proxy.conf.
--
-- The groups the identity source reports are translated into eMondrian roles with
-- roles.mapping from auth/identity.yml, so the schemas and the server permissions name the
-- product's roles, not the customer's groups.

local config = require("emondrian.config")

local M = {}

-- Header values must stay on one line; group names are additionally comma-separated, so a comma
-- inside one would split it.
local function one_line(s)
  return (s:gsub("%c", ""))
end

M.one_line = one_line

-- Group names from a claim: a list of names or paths ("/Parent/WebAppUsers" when Keycloak sends
-- full paths), or a single string.
local function group_names(value)
  if type(value) == "string" then
    value = { value }
  end
  local groups = {}
  if type(value) == "table" then
    for _, group in ipairs(value) do
      if type(group) == "string" then
        group = one_line(group:match("([^/]*)$")):gsub(",", "")
        if group ~= "" then
          groups[#groups + 1] = group
        end
      end
    end
  end
  return groups
end

-- eMondrian roles held by the user, plus their own groups when forward_groups is set.
local function roles(user, groups)
  local mapping = config.role_mapping
  if not mapping then
    return groups
  end
  local held = { ["user:" .. user:lower()] = true }
  for _, group in ipairs(groups) do
    held[group:lower()] = true
  end
  local result = {}
  for role, members in pairs(mapping) do
    for _, member in ipairs(members) do
      if held[member:lower()] then
        result[#result + 1] = one_line(role):gsub(",", "")
        break
      end
    end
  end
  table.sort(result)
  if config.forward_groups then
    for _, group in ipairs(groups) do
      result[#result + 1] = group
    end
  end
  return result
end

-- Picks the user name and groups out of verified claims (claims.username / claims.groups in
-- identity.yml, plus external_groups). Returns them, or nil when the claims carry no user name.
function M.from_claims(claims)
  local user = claims and claims[config.username_claim]
  if type(user) ~= "string" or user == "" then
    return nil
  end
  local groups, seen = {}, {}
  for _, claim in ipairs(config.groups_claims) do
    for _, group in ipairs(group_names(claims[claim])) do
      if not seen[group] then
        seen[group] = true
        groups[#groups + 1] = group
      end
    end
  end
  return one_line(user), groups
end

-- claims: verified token claims. method: how the caller authenticated, for the audit log.
-- Returns true, or false and "no_user" (the claims name nobody) or "no_role" (require_role is set
-- and the user holds no eMondrian role).
function M.set(claims, method)
  local user, groups = M.from_claims(claims)
  if not user then
    return false, "no_user"
  end
  local held = roles(user, groups)
  ngx.var.auth_user   = user
  ngx.var.auth_groups = table.concat(held, ",")
  ngx.var.auth_method = method
  if config.require_role and config.role_mapping and #held == 0 then
    return false, "no_role"
  end
  return true
end

return M
