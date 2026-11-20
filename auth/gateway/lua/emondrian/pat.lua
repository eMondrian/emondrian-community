-- Personal access tokens (emk_…), kept by the auth-tokens service. One per user: issuing one
-- revokes the owner's other tokens.
--
-- verify(): a token sent as the Basic password (user name: the owner's), as a Bearer token, or in
--           the address of /xmla and of a dashboard page (link.lua).
-- api():    /account/api/tokens, the tokens API: the /account/tokens page (browser session),
--           scripts and automation (Basic with a password, Bearer). A personal token never manages
--           tokens, so a stolen one cannot renew itself.
--
-- Mode broker: at every use whose verification is not cached (at most 30 s) the owner is looked
-- up in Keycloak (owner.lua): a deleted or disabled owner's tokens are refused, and the token
-- carries the owner's current groups, not the ones it was issued with. If Keycloak cannot be
-- asked, the token is refused once its 30 s cache entry has run out (fail closed).
--
-- Other modes (no Keycloak to ask): the owner's groups stored with the token at issue are
-- forwarded, by full path. A token issued before groups were forwarded by path holds plain names,
-- which cannot be told from a same-named group elsewhere, so those are dropped: the token still
-- logs its owner in, with no groups, until the owner issues a new one.

local http     = require("resty.http")
local cjson    = require("cjson.safe")
local sha256   = require("resty.sha256")
local rstr     = require("resty.string")
local config   = require("emondrian.config")
local identity = require("emondrian.identity")
local owner    = require("emondrian.owner")
local oidc     = require("emondrian.oidc")

-- Messages without the request line: on /xmla and dashboard pages it holds the token (log.lua)
local raw_log  = require("emondrian.log").out_of_request

local M = {}

local SERVICE = "http://auth-tokens:8080"
local PREFIX = "emk_"
-- emk_ + 32 random bytes in base64url (auth/tokens/tokens.py)
local FORMAT = "^emk_[A-Za-z0-9_-]+$"
local LENGTH = 4 + 43
-- A revoked token keeps working for at most this long (the verification cache)
local CACHE_SECONDS = 30
local ADMIN_ROLE = "/emondrian-admins"
-- Refused Basic passwords on the tokens API per client address and minute before it answers 429
local FAILURES_PER_MINUTE = 10

local function hex_sha256(value)
  local hash = sha256:new()
  hash:update(value)
  return rstr.to_hex(hash:final())
end

local secret

local function service_secret()
  if not secret then
    -- Same derivation as auth/tokens/tokens.py
    secret = hex_sha256("emondrian-tokens\0" .. config.secret)
  end
  return secret
end
M.service_secret = service_secret

function M.is_token(value)
  return type(value) == "string" and value:sub(1, #PREFIX) == PREFIX
end

-- Whether a value has the shape of a token, as it must to be looked up at all.
function M.well_formed(value)
  return type(value) == "string" and #value == LENGTH and value:find(FORMAT) ~= nil
end

-- Whether an Authorization header carries a personal token (as Bearer or as the Basic password).
function M.in_header(authorization)
  local scheme, value = (authorization or ""):match("^(%a+)%s+(%S+)")
  if not scheme then
    return false
  end
  scheme = scheme:lower()
  if scheme == "bearer" then
    return M.is_token(value)
  end
  if scheme == "basic" then
    local decoded = ngx.decode_base64(value) or ""
    return M.is_token(decoded:match("^[^:]*:(.*)$"))
  end
  return false
end

-- Claims as the rest of the gateway knows them (identity.set), built from the token's owner.
local function claims_of(user, groups)
  return { [config.username_claim] = user, [config.groups_claims[1] or "groups"] = groups }
end

-- The stored groups that are full paths, and how many plain names were dropped.
local function path_groups(groups)
  local kept, dropped = {}, 0
  for _, group in ipairs(type(groups) == "table" and groups or {}) do
    if type(group) == "string" and group:sub(1, 1) == "/" then
      kept[#kept + 1] = group
    else
      dropped = dropped + 1
    end
  end
  return kept, dropped
end

-- Returns claims and the token's expiry (epoch seconds); or nil (unknown, expired, revoked,
-- another user's token, or an owner deleted or disabled in Keycloak); or nil and "unavailable"
-- (the service or Keycloak failed).
function M.verify(token, user)
  local key = "pat:" .. hex_sha256(config.secret .. "\0" .. token .. "\0" .. (user or ""):lower())
  local cache = ngx.shared.basic_auth
  local cached = cache:get(key)
  if cached == "" then
    return nil
  end
  if cached then
    local entry = cjson.decode(cached)
    if entry and (not entry.expires or ngx.now() < entry.expires) then
      return claims_of(entry.user, entry.groups), nil, entry.expires
    end
    cache:delete(key)
  end

  local httpc = http.new()
  httpc:set_timeout(5000)
  local res, err = httpc:request_uri(SERVICE .. "/verify", {
    method  = "POST",
    headers = { ["Content-Type"] = "application/json", ["X-Tokens-Secret"] = service_secret() },
    body    = cjson.encode({ token = token, user = user }),
  })
  if not res then
    raw_log(ngx.ERR, "auth-tokens unreachable: " .. tostring(err))
    return nil, "unavailable"
  end
  if res.status == 404 then
    raw_log(ngx.NOTICE, "personal token refused" .. (user and (" for user " .. identity.one_line(user)) or ""))
    cache:set(key, "", config.policy.basic_failure_cache)
    return nil
  end
  local entry = res.status == 200 and cjson.decode(res.body)
  if type(entry) ~= "table" or type(entry.user) ~= "string" then
    raw_log(ngx.ERR, "auth-tokens answered HTTP " .. res.status)
    return nil, "unavailable"
  end
  local groups
  if config.owner_check then
    local reason
    groups, reason = owner.current(entry.user)
    if not groups then
      if reason == "unavailable" then
        return nil, "unavailable"
      end
      raw_log(ngx.NOTICE, "personal token of " .. identity.one_line(entry.user) .. " refused: the owner no longer"
              .. " exists or is disabled in Keycloak")
      cache:set(key, "", config.policy.basic_failure_cache)
      return nil
    end
  else
    local dropped
    groups, dropped = path_groups(entry.groups)
    if dropped > 0 then
      raw_log(ngx.WARN, "personal token of " .. identity.one_line(entry.user) .. " was issued before groups were"
              .. " forwarded by path: its " .. dropped .. " group(s) are ignored until the owner issues a new token")
    end
  end
  local expires = tonumber(entry.expires_at)
  local ttl = CACHE_SECONDS
  if expires then
    ttl = math.min(ttl, expires - ngx.now())
  end
  if ttl > 0 then
    cache:set(key, cjson.encode({ user = entry.user, groups = groups, expires = expires }), ttl)
  end
  return claims_of(entry.user, groups), nil, expires
end

-- The tokens API ---------------------------------------------------------------------------------

-- Answers in the REST API's error format and ends the request.
local function fail(status, code, message)
  ngx.status = status
  ngx.header["Content-Type"] = "application/json; charset=utf-8"
  ngx.header["Cache-Control"] = "no-store"
  ngx.say(cjson.encode({ error = { code = code, message = message } }))
  return ngx.exit(status)
end

local function too_many_failures(count)
  local dict = ngx.shared.link_failures
  local key = "api:" .. (ngx.var.remote_addr or "-")
  if count then
    dict:incr(key, 1, 0, 60)
    return
  end
  return (dict:get(key) or 0) >= FAILURES_PER_MINUTE
end

-- Whether a provider access token was issued to the gateway's own client: the browser session
-- and Basic (the gateway's password grant) always are; an MCP client's or another program's
-- token is not. Entra's v1 tokens name the client appid instead of azp.
local function own_client(claims)
  local client = claims.azp or claims.appid
  return type(client) == "string" and client == config.provider.client_id
end

-- Who calls: claims and the method ("session", "basic", "bearer", "proxy"), or the request ends.
local function caller()
  local header = ngx.var.http_authorization
  if config.mode == "trusted-proxy" then
    if header and M.in_header(header) then
      return fail(401, "UNAUTHORIZED", "A personal token cannot issue or manage tokens; sign in instead.")
    end
    return require("emondrian.trusted_proxy").identity(), "proxy"
  end
  if not header then
    return oidc.session("deny"), "session"
  end
  if M.in_header(header) then
    return fail(401, "UNAUTHORIZED", "A personal token cannot issue or manage tokens. Use your password"
      .. " (Basic), a sign-in token (Bearer) or the page " .. config.public_url .. "/account/tokens.")
  end
  local scheme = (header:match("^(%a+)%s") or ""):lower()
  if scheme == "basic" then
    if too_many_failures(false) then
      ngx.header["Retry-After"] = "60"
      return fail(429, "TOO_MANY_REQUESTS", "Too many refused passwords from this address; try again in a minute.")
    end
    local basic = require("emondrian.basic")
    local user, password = basic.parse(header)
    if not user or not config.provider.password_grant then
      return fail(401, "UNAUTHORIZED", "Basic sign-in is not available here; use the page or a Bearer token.")
    end
    local claims, err = basic.authenticate(user, password)
    if err == "unavailable" then
      return fail(503, "UNAVAILABLE", "The identity provider cannot be reached; try again shortly.")
    end
    if not claims then
      too_many_failures(true)
      ngx.header["WWW-Authenticate"] = 'Basic realm="eMondrian", charset="UTF-8"'
      return fail(401, "UNAUTHORIZED", "Wrong user name or password.")
    end
    return claims, "basic"
  end
  if scheme == "bearer" then
    local claims, err = oidc.verify_access_token(header:match("^%a+%s+(%S+)"))
    if not claims then
      return fail(401, "UNAUTHORIZED", "Token refused: " .. tostring(err))
    end
    return claims, "bearer"
  end
  return fail(401, "UNAUTHORIZED", "Sign in with Basic (your password), Bearer, or the page "
    .. config.public_url .. "/account/tokens.")
end

-- The request body's "user" (POST): the user a token is issued for, or nil.
local function wanted_user()
  ngx.req.read_body()
  local data = cjson.decode(ngx.req.get_body_data() or "")
  if type(data) ~= "table" then
    return fail(400, "BAD_REQUEST", "The body must be a JSON object: {\"user\"?, \"name\"?, \"days\"?}.")
  end
  local user = data.user
  if user == nil or user == cjson.null or user == "" then
    return nil
  end
  if type(user) ~= "string" then
    return fail(400, "BAD_REQUEST", "user must be a user name.")
  end
  return user
end

-- Access phase of /account/api/tokens[/<id>].
function M.api()
  ngx.req.clear_header("X-Token-Target")
  ngx.req.clear_header("X-Token-Target-Groups")
  ngx.req.clear_header("X-Token-Via")
  ngx.req.clear_header("X-Token-Admin")
  if config.open_access_on() then
    -- Tokens belong to logged-in users; with authentication off there are none
    return fail(403, "FORBIDDEN", "Authentication is off (open_access in identity.yml): no personal tokens.")
  end
  if not config.personal_tokens then
    return fail(403, "FORBIDDEN", "Personal tokens are turned off (personal_tokens in identity.yml).")
  end
  local method = ngx.req.get_method()
  local claims, how = caller()
  local user, groups = identity.from_claims(claims)
  if not user then
    return fail(401, "UNAUTHORIZED", "Not signed in.")
  end
  identity.set(claims, how)
  -- A page of this site only: a browser sends the cookie with other sites' requests too
  -- (SameSite=Lax keeps their POSTs out; the Origin check covers the rest). A script with Basic or
  -- Bearer sends no Origin; one that does must be this site.
  local origin = ngx.var.http_origin
  if (how == "session" and method ~= "GET" and origin ~= config.public_url)
      or (origin and origin ~= config.public_url) then
    return fail(403, "FORBIDDEN", "Cross-origin request refused.")
  end
  local admin = false
  for _, group in ipairs(groups) do
    if group == ADMIN_ROLE then
      admin = true
    end
  end

  if method == "POST" then
    -- issue_via_agents: off, a token is issued only to the gateway's own sign-ins (the page,
    -- Basic), never to an MCP client's or another program's OAuth token
    if how == "bearer" and not config.issue_via_agents and not own_client(claims) then
      ngx.log(ngx.NOTICE, "token not issued to ", identity.one_line(user), ": Bearer token of client ",
              identity.one_line(tostring(claims.azp or claims.appid)))
      return fail(403, "FORBIDDEN", "issuing tokens via AI agents is disabled (personal_tokens.issue_via_agents"
        .. " in identity.yml): an OAuth token of this client cannot issue tokens. Open "
        .. config.public_url .. "/account/tokens in a browser.")
    end
    local target = wanted_user()
    if target and target:lower() == user:lower() then
      target = nil
    end
    if target and not admin then
      return fail(403, "FORBIDDEN", "Only administrators (" .. ADMIN_ROLE .. ") issue tokens for other users.")
    end
    if target and not config.owner_check then
      return fail(400, "BAD_REQUEST", "Tokens for other users need Keycloak to look the user up (mode broker).")
    end
    -- A token is checked against its owner in Keycloak at every use (verify): refuse to issue one
    -- that could never pass, with the reason, rather than one that fails later
    if config.owner_check then
      local owner_groups, reason = owner.current(target or user)
      if reason == "unavailable" then
        return fail(503, "UNAVAILABLE", "Keycloak cannot be reached to check the account; try again shortly.")
      elseif not owner_groups then
        ngx.log(ngx.NOTICE, "personal token not issued for ", identity.one_line(target or user),
                ": no such account in Keycloak, or disabled")
        if target then
          return fail(404, "NOT_FOUND", "No user " .. target .. " in Keycloak, or the user is disabled.")
        end
        return fail(403, "FORBIDDEN", "No personal tokens for this account: it does not exist in Keycloak, or"
          .. " is disabled there, so a token could not be checked against it. Ask the administrator.")
      end
      if target then
        ngx.req.set_header("X-Token-Target", target)
        ngx.req.set_header("X-Token-Target-Groups", table.concat(owner_groups, ","))
      end
    end
  end

  ngx.req.clear_header("Authorization")
  ngx.req.clear_header("Cookie")
  ngx.req.set_header("X-Tokens-Secret", service_secret())
  ngx.req.set_header("X-Token-User", user)
  ngx.req.set_header("X-Token-Groups", table.concat(groups, ","))
  ngx.req.set_header("X-Token-Admin", admin and "true" or "false")
end

return M
