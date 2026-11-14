-- Turns verified claims into the identity eMondrian receives: $auth_user and $auth_groups, sent
-- as X-Forwarded-User / X-Forwarded-Groups by emondrian-proxy.conf.
--
-- The groups go to eMondrian as the identity source reports them. Every authenticated user gets
-- in; what a user may see and do is eMondrian's decision: server rights in
-- auth/emondrian/mondrian.properties, data roles (<RoleMember>) in the schemas.

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
-- Returns true, or false and "no_user" (the claims name nobody).
function M.set(claims, method)
  local user, groups = M.from_claims(claims)
  if not user then
    return false, "no_user"
  end
  ngx.var.auth_user   = user
  ngx.var.auth_groups = table.concat(groups, ",")
  ngx.var.auth_method = method
  return true
end

return M
