-- Turns verified claims into the identity eMondrian receives: $auth_user and $auth_groups, sent
-- as X-Forwarded-User / X-Forwarded-Groups by emondrian-proxy.conf.
--
-- The groups go to eMondrian as the identity source reports them. Every authenticated user gets
-- in; what a user may see and do is eMondrian's decision: server rights in
-- auth/security/security.properties, data roles (<RoleMember>) in the schemas.

local config = require("emondrian.config")

local M = {}

-- Header values must stay on one line; group names are additionally comma-separated, so a comma
-- inside one would split it.
local function one_line(s)
  return (s:gsub("%c", ""))
end

M.one_line = one_line

local function clean(s)
  return (one_line(s):gsub(",", ""))
end

-- Group names from a claim: a list of names or paths, or a single string. Every group is
-- forwarded as its full path, top-level groups included ("/emondrian-admins",
-- "/Sales/WebAppUsers"), never by its own name: two groups of the same name under different
-- parents must not be taken for each other. A plain name (a directory group of an external
-- provider, a guest group of identity.yml) is a top-level group: "Admins" goes as "/Admins".
-- Membership is not inherited: a member of /Sales/WebAppUsers is not sent "/Sales".
local function group_names(value)
  if type(value) == "string" then
    value = { value }
  end
  local groups = {}
  if type(value) == "table" then
    for _, group in ipairs(value) do
      if type(group) == "string" then
        local parts = {}
        for part in group:gmatch("[^/]+") do
          part = clean(part)
          if part ~= "" then
            parts[#parts + 1] = part
          end
        end
        if #parts > 0 then
          groups[#groups + 1] = "/" .. table.concat(parts, "/")
        end
      end
    end
  end
  return groups
end

M.group_names = group_names

-- Groups of an external identity provider (the claim external_groups, set by Keycloak's provider
-- mappers) are forwarded under the provider's own name, /<source>/<group>, so that a provider can
-- never name a Keycloak group or a server group (a provider group "emondrian-admins" is
-- /entra/emondrian-admins, not /emondrian-admins). A provider's group name is one path segment:
-- "/", "," and "%" in it are written %2F, %2C and %25.
local EXTERNAL = "external_groups"
local EXTERNAL_SOURCE = "external_groups_source"

local function segment(s)
  return (one_line(s):gsub("%%", "%%25"):gsub("/", "%%2F"):gsub(",", "%%2C"))
end

function M.external_groups(source, names)
  local groups = {}
  if type(source) == "table" then
    source = source[1]
  end
  if type(source) ~= "string" or source == "" then
    return groups  -- no source recorded (a login before this release): none until the next login
  end
  if type(names) == "string" then
    names = { names }
  end
  for _, name in ipairs(type(names) == "table" and names or {}) do
    if type(name) == "string" and name ~= "" then
      groups[#groups + 1] = "/" .. segment(source) .. "/" .. segment(name)
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
    local names = claim == EXTERNAL and M.external_groups(claims[EXTERNAL_SOURCE], claims[claim])
      or group_names(claims[claim])
    for _, group in ipairs(names) do
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
