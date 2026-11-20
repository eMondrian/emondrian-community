# Changelog

One release is one state of `docker-compose.yml`: the server image, the modules in `modules/`, the web tools and the entry page. Releases are tagged by date (`2026.10.18`; a second release on the same day is `2026.10.18.1`), and each tag has a GitHub Release with the section below.

To upgrade to any release:

```bash
git pull
docker compose pull
docker compose up -d --build --remove-orphans
```

`--build` rebuilds the services built from this repository (the authentication gateway, its
configuration step and the personal-token service); without it they keep running the previous
release's code next to the new server. `./setup.sh` (Windows: `windows-setup.ps1`) does the same.

## Unreleased

Server `10.0.95` · modules `0.0.0.114` · OLAP Client `1.2.3` · Dashboard `0.2.0` · entry `1.3.2`

Modules `0.0.0.114` (was `0.0.0.113`), the authentication gateway, its configuration step and the personal-token service (run `docker compose up -d --build`). **Incompatible changes: read the first four points before you upgrade.**

- **XML/A links (`eml_…`) stop working on the day you upgrade.** Every user now has one personal token, which does their work too: issue one on `/account/tokens` (or *Power BI live connection* on the main page), then change the server address of Power BI reports to `PUBLIC_URL/xmla?emondrian_token=<token>` and send new dashboard links, `PUBLIC_URL/dashboard/d/<id>?emondrian_token=<token>`. `xmla_links` in `auth/identity.yml` is ignored with a warning, and the token service drops its table of links at the first start.
- **One personal token per user.** Issuing one revokes the user's current one, wherever it is used. A user who has several when you upgrade keeps the newest; the others are revoked at the first start. `personal_tokens.max_per_user` is ignored with a warning. Give each consumer (a portal's backend, a client's links) a user of its own, so that revoking one stops nothing else.
- **The REST API takes a token in the `Authorization` header only.** `?emondrian_token=` on `/api/v1` now gets 401.
- **MCP:** `create_link`, `get_link` and `revoke_link` are removed; `create_token`, `list_tokens` and `revoke_token` replace them. `create_user` no longer takes `password` or `temporary_password`: the user chooses a password from an e-mail (`send_password_email`), or an administrator issues a token on `/account/tokens?user=<name>`.
- **Administrators issue tokens for users**: on `/account/tokens` (*For user*, or `?user=<name>&dashboard=<id>`, which shows the dashboard's link ready to copy) and with the tokens API, `POST /account/api/tokens` `{"user", "name", "days"}`, signed in with a password (Basic) or a sign-in's Bearer token; a personal token cannot issue or manage tokens. `GET` lists tokens (never their values) with who issued them; `DELETE` revokes. Not for another administrator unless `personal_tokens.issue_for_admins: true`.
- **No token passes through an AI agent** unless you allow it (`personal_tokens.issue_via_agents`, off by default): `create_token` then answers with the page an administrator opens in a browser, and an MCP client's OAuth token cannot issue tokens on the API. What this does not cover (an agent with a password and a shell, an agent driving an administrator's browser) is in `auth/README.md`, *Personal tokens*.
- **A dashboard link keeps the address's other parameters**: the gateway now removes only `emondrian_token` when it redirects.

## 2026.11.20.1

Server `10.0.95` · modules `0.0.0.113` · OLAP Client `1.2.3` · Dashboard `0.2.0` · entry `1.3.2`

Modules `0.0.0.113` (was `0.0.0.112`), and the Dashboard's address in `docker-compose.auth.yml` (run `docker compose up -d`). The server and the web tools are unchanged.

- **Dashboard links include the port.** The links `create_dashboard`, `list_dashboards` and `get_dashboard` give, and the Dashboard's own, now start with `PUBLIC_URL`. On a server with a port other than 80 or 443 they lost the port before, so a link an agent gave didn't open as given.
- **MCP tools for roles.** An agent reads and changes one role at a time instead of rewriting the whole schema, whose file can be more than an MCP client takes back from one call: `list_roles` (each role's members and grants, and the schema's `defaultRole`), `get_role`, `save_role` (create or replace one role; the rest of the file stays as it is), `delete_role`, `set_default_role`, and `get_schema` with `part` (`outline`, `roles`, `cube:<name>`, `dimension:<name>`). `save_role` writes nothing unless the schema with the role is well-formed and loads in the engine; an unknown member is refused by name. The same rights as `save_schema`.
- **Check what a user sees before sharing.** With authentication on, a Keycloak administrator's agent can run `execute_query` and `describe_cube` with `as_user`: the user's groups and schema roles, so the agent sees exactly what that user will see. Logged in `logs/mcp-audit.log`.
- **The cube authoring guide has a section on roles** (`get_cube_authoring_guide`, section 19): rows with `rollupPolicy="partial"`, hiding measures, the `defaultRole` and the other catalogs, and the order for sharing a dashboard with a client.

## 2026.11.20

Server `10.0.95` · modules `0.0.0.112` · OLAP Client `1.2.3` · Dashboard `0.2.0` · entry `1.3.2`

Modules `0.0.0.112` (was `0.0.0.111`), with the new REST module, and the authentication gateway and its configuration step (run `docker compose up -d --build`). The server and the web tools are unchanged.

- **REST API with JSON** at `/api/v1`, next to XML/A, for systems that are not BI clients (backends, scripts, ETL and low-code tools, services behind the gateway): `GET /api/v1/catalogs`, `GET /api/v1/catalogs/{catalog}/cubes/{cube}` (the model as the caller sees it) and `POST /api/v1/query` (MDX or DAX; the result as a flat table, plain values by default or captions, unique names and formatted values with `"format": "detailed"`). The same sign-in as XML/A (password, personal token, OAuth, an XML/A link, a trusted service with the gateway's secret), the caller's roles and row-level security on every query, a line per request in the gateway's access log. Read-only and free; limits on rows, cells, time and request size. OpenAPI at `/api/v1/openapi.json`; see *REST API (JSON)* in `auth/README.md`. New module `modules/emondrian-rest-0.0.0.112.jar`.
- **XML/A links also work on the REST API**, with the same expiry and revocation.
- **No CORS for other sites by default.** The gateway no longer passes on the `Access-Control-Allow-Origin: *` the entry page and the server sent on `/xmla` and `/api`, and refuses CORS pre-flights there: a web page on another site can no longer call them from a visitor's browser. If you have such a page, list its origin under `cors.allowed_origins` in `auth/identity.yml` and run `auth/scripts/apply-config.sh`. `CORS_ALLOW_ORIGIN` in `.env` no longer has an effect on these paths. MCP is unchanged. Run `docker compose up -d --build`.

## 2026.11.19

Server `10.0.95` · modules `0.0.0.111` · OLAP Client `1.2.3` · Dashboard `0.2.0` · entry `1.3.2`

Modules `0.0.0.111` (was `0.0.0.110`), and the authentication gateway, its configuration step and the personal-token service (run `docker compose up -d --build`). The server and the web tools are unchanged.

- **Power BI live connection with authentication on: XML/A links.** Power BI Desktop's *Connect live* does not send a saved user name and password, so it could not connect to a server with authentication on (import mode and Excel could). A signed-in user now gets a personal address, `https://<server>/xmla?emondrian_token=…`, with **Get link** on the main page or on `/account/tokens`, and uses it as the server name. One link per user: a new one replaces the old. It expires after 30 days (`xmla_links` in `auth/identity.yml`), and an expired, replaced, revoked or altered link answers 401. The gateway removes the token before the request reaches eMondrian and masks it in its access log. See *XML/A links* in `auth/README.md`. Run `docker compose up -d --build` to rebuild the gateway and the token service.
- **The same link opens dashboards.** `https://<server>/dashboard/d/<id>?emondrian_token=…` opens a dashboard without signing in, as the link's user and with the Dashboard's own rights. The browser keeps the link in a cookie (at most 12 hours, never past the link's expiry), checked on every request: a replaced or revoked link, or a disabled user, ends it.
- **An administrator's agent can issue a link for a user** (MCP `create_link`, `get_link`, `revoke_link`, realm administrators only; modules `0.0.0.111`), so a user who has no password can open a dashboard or connect a client tool.
- **E-mail from Keycloak.** An `smtp:` section in `auth/identity.yml` (host, port, sender, `starttls`/`ssl`/`none`, user and password file) lets Keycloak send e-mails such as the set-password e-mail.

## 2026.11.18

Server `10.0.95` · modules `0.0.0.110` · OLAP Client `1.2.3` · Dashboard `0.2.0` · entry `1.3.2`

Server `10.0.95` (was `10.0.94`). Everything else is unchanged.

- **A filter under row-level security gives the right answer.** For a user whose role sees only part of a hierarchy with `rollupPolicy="partial"` (for example only the state CA), a filter on a value the role hides or on a value that does not exist (`'Store'[Store.Store State] = "WA"` in DAX, a Power BI slicer or filter, or an MDX subselect) was ignored, and the user got their own total instead of an empty result. Nothing hidden was shown, but the number did not match the filter. Such a filter now gives an empty result; filters on values the role sees, and everything without a role, are unchanged.

## 2026.11.16.1

Server `10.0.94` · modules `0.0.0.110` · OLAP Client `1.2.3` · Dashboard `0.2.0` · entry `1.3.2`

Server `10.0.94` (was `10.0.92`), modules `0.0.0.110` (was `0.0.0.109`), Dashboard `0.2.0` (was `0.1.4`). The web tools are unchanged.

- **The levels Power Query names in a parent-child hierarchy work in MDX.** Power Query (Power BI import, Excel's "From Analysis Services") names the levels of a parent-child hierarchy `Level 01`, `Level 02`, … (for example FoodMart HR's `Employees`); the server now answers `[Employees].[Level 01].MEMBERS`, `.ALLMEMBERS` and `DESCENDANTS(…, [Employees].[Level 07], LEAVES)`, the queries Power Query sends to import such a table.
- **Dashboards have rights** (with authentication on). A new dashboard belongs to the person who created it: they and the dashboard administrators (`mondrian.security.dashboard.manage` in `auth/security/security.properties`, `/emondrian-admins` by default) may see, change and delete it and give other users, groups or everyone signed in the right to view or to edit it (**Share…** on the dashboard, or the MCP tool `set_dashboard_access`). The creator's and the administrators' own rights cannot be taken away. For someone without a right the dashboard does not exist: its link answers *not found*. Someone who may only view it cannot change it. Every change of rights made through MCP is written to `logs/mcp-audit.log`, whatever `emondrian.mcp.audit` says. Dashboards created before have no creator: the administrators own them and everyone signed in may view them. Without authentication nothing changes: everyone may use every dashboard.

  **Upgrading:** `./setup.sh` (Windows: `windows-setup.ps1`) adds `mondrian.security.dashboard.manage=/emondrian-admins` to your `auth/security/security.properties` once, when it has no such line, and prints it.
- **A Cancel from Excel or Power BI gets a normal answer.** It used to answer with the error "The query was canceled by user."; client cancels are now one line in `logs/mondrian.log` instead of an error with a stack trace.
- **Server rights are in one file, `auth/security/security.properties`**, the only place the server reads them from (`-Demondrian.security.file`). It is mounted read-only, so nothing reachable over the network can change it, the MCP tool `set_security` included, and an edit applies at the next request without a restart. Setup creates it from `auth/security/security.properties.example` and never overwrites it; git ignores it. `mondrian.security.*` lines in `auth/emondrian/mondrian.properties` and `-Dmondrian.security.*` options in `.env` are ignored from now on (the server log names any it finds).

  **Upgrading:** the first `./setup.sh` (Windows: `windows-setup.ps1`) after `git pull` moves your current rights from `auth/emondrian/mondrian.properties` into the new file and prints them. If you edited that file, `git pull` stops with *"Your local changes to the following files would be overwritten by merge: auth/emondrian/mondrian.properties"*. Then run:

  ```bash
  cp auth/emondrian/mondrian.properties auth/emondrian/mondrian.properties.mine
  git checkout auth/emondrian/mondrian.properties
  git pull
  ./setup.sh
  ```

  On Windows the same with `Copy-Item` for `cp` and `.\windows-setup.ps1`. Setup takes your rights from `mondrian.properties.mine`. Any other setting you changed in that file has to be copied back by hand.
- README, NOTICE and a new SECURITY.md: what each edition includes, which modules need a key, and how to report a vulnerability.

## 2026.11.16

Server `10.0.92` · modules `0.0.0.109` · OLAP Client `1.2.3` · Dashboard `0.1.4` · entry `1.3.2`

Modules `0.0.0.109` (were `0.0.0.108`). The server image, the web tools and the Dashboard are unchanged.

- **MCP tools no longer need a licence key.** A DAX query, `get_csdl` and the Power BI report tools still need a key including `DAX`, synthetic catalogs `SYNTHETIC`, dashboards `DASHBOARD`.

## 2026.11.15

Server `10.0.92` · modules `0.0.0.108` · OLAP Client `1.2.3` · Dashboard `0.1.4` · entry `1.3.2`

Groups by full path, a shorter token expiry tolerance, larger request headers and a secret between the gateway and eMondrian; server `10.0.92` (was `10.0.89`), modules `0.0.0.108` (were `0.0.0.106`) and Dashboard `0.1.4` (was `0.1.3`). The web tools are unchanged.

### Authentication

- **Groups are forwarded by their full path only,** top-level groups included: a member of `emondrian-admins` arrives as `/emondrian-admins`, a member of `WebAppUsers` inside `Sales` as `/Sales/WebAppUsers`. A group is never forwarded by its own name, so two groups of the same name under different parents are never taken for each other. Membership is not inherited: a right for `/Sales` does not reach the members of `/Sales/WebAppUsers`, and a member of a group inside `/emondrian-admins` is not an administrator. Groups of an external identity provider arrive under the source's name (`/entra/BI-Users`), so a provider can never grant a Keycloak or server group; plain names from Kerberos or a trusted proxy arrive as top-level paths (`Admins` as `/Admins`).
- **Server rights and schema roles name groups by path.** `auth/emondrian/mondrian.properties` now names `/emondrian-admins`, `/emondrian-editors` and `/emondrian-viewers`; write your own groups the same way, also in a schema's `<RoleMember name="/Sales/WebAppUsers"/>`.
- **Bearer tokens are refused at most 60 seconds after they expire** (was 120): `AUTH_TOKEN_LEEWAY` in `.env`, 0 to 300 seconds. A refusal now says why: `token expired` or `token not valid yet`.
- **Request headers up to 32 KB** (were 8 KB) at the gateway, the entry page and eMondrian, since every request carries the user's groups and access token.
- **Members of `emondrian-admins` are administrators of the realm in Keycloak.** Setup gives the group Keycloak's `realm-admin` role (it had no Keycloak role before, so the MCP tools for users, groups, the security file and switching authentication off refused everyone). It is Keycloak's full administration of the realm. Keycloak would pass it on to members of the group's subgroups, so while `emondrian-admins` has subgroups the role is not given (and taken back), apply logs an ERROR naming them, and the MCP tool `create_group` refuses to create one under it. See `auth/README.md`, *Users kept in Keycloak*.
- **Personal access tokens follow their owner.** At each use (checked at most every 30 seconds) the gateway asks Keycloak whether the owner still exists and is enabled, and forwards the owner's current groups, with a new service account `emondrian-gateway-lookup` that may only read users. Before, a token kept the groups it was issued with for its whole life (90 days by default), and disabling its owner did not stop it. While Keycloak cannot be reached, tokens not checked in the last 30 seconds are refused. The groups of an external identity provider come along, as of the user's last login through it.
- **A Basic login (Excel, Power BI) is reused at most until 30 seconds before its token expires** (5 minutes by default), however long `policy.basic_cache` is: disabling a user, changing a password or removing a group reaches Basic within one token lifetime (measured: 269 seconds).
- **eMondrian believes the forwarded user and groups only from the gateway.** The gateway sends a secret, `EMONDRIAN_FORWARDED_SECRET` in `.env`, with every request it forwards to eMondrian; a request that names a user without it is refused. Before, anything that reached eMondrian around the gateway (this machine, another container of the stack) could name itself an administrator. The Dashboard (`0.1.4`, `GATEWAY_ONLY`) answers only requests carrying the same secret; before, anything inside the stack could list, change and delete dashboards without logging in.
- **Pages behind the login are no longer kept by the browser.** The entry page, its scripts and data, the web tools, the logs and the Dashboard's answers are sent with `Cache-Control: no-store` (fonts, images and content-hashed scripts keep their own caching). Before, a browser could show the entry page from its cache after the session had ended, and the page's first request then opened the browser's own password dialog.
- **A page's own request never opens the browser's password dialog.** When a page's script (the entry page, the OLAP client) calls `/api` or `/xmla` after its session has ended, the answer is 401 without a Basic challenge: `{"error": "login_required", "login": "/"}` for a request that accepts JSON, a line of text otherwise. Excel, Power BI, scripts and `curl -u` still get the Basic challenge as before; the gateway tells the two apart by the browser's own `Sec-Fetch-Mode` header (or `X-Requested-With`).
- **Logging out ends the Keycloak session too.** `/logout` did not tell Keycloak which session to close, Keycloak refused the logout, and the next page logged the person straight back in. Sessions started before the upgrade log out properly after their next login.

### Server

- **`10.0.92`** (engine `9.3.0-emondrian.90`, was `.88`): Tomcat accepts 32 KB of request headers. With `-Demondrian.security.trustForwardedUser=true` the forwarded user and groups count only with the gateway's secret (`EMONDRIAN_FORWARDED_SECRET`); without the secret set, none are believed and the server logs an error at start. The engine reads server rights from a security file named with `-Dmondrian.security.file` and rereads it when it changes, and a long list filter such as Power BI's `TREATAS` over thousands of keys reaches the database as one `IN` list.

### Modules

- **MCP acts as the person calling.** Behind the gateway every MCP tool call uses the caller's user name and groups: the schema roles decide which data and which cubes they see, the server rights decide what they may change, and the traffic log names them. An MCP session over SSE belongs to the user who opened it. Before, every MCP call ran as the same anonymous identity.
- **`describe_cube`, `get_csdl` and `list_catalogs` need no server right**, like Excel's view of the model: the caller's roles limit what they show, the same as XML/A. `get_schema` (the schema file itself) still takes `schema.read`, and so do the formulas of calculated measures in `describe_cube`: without it they show as "(calculated)", as in Excel, which gets no formulas either.
- **DAX:** a filter on thousands of keys (`TREATAS`, `IN { … }`) no longer overflows; it reaches the database as one `IN` list.
- **DAX: numbers work on a numeric key's column.** `'Customer'[Customer.Customer Id] = 3`, `IN {1, 2, 3}`, `TREATAS({1, 2, 3}, …)` and `<`, `>=` failed with "No function matches signature '<String> = <Numeric Expression>'"; they now compare with the key, and the database gets a numeric condition on the key column. A column that shows names instead of the key refuses a number with a message naming its `.Key` column. Power BI was not affected: it sends numbers to the `.Key` column.

- **Once authentication is on, MCP agents that log in with OAuth from another machine need HTTPS.** Claude Code refuses an OAuth login whose token endpoint is plain `http://`, unless it is `localhost`; set up HTTPS as in `auth/README.md` (*HTTPS*) before connecting agents from other machines. `authentication.sh on` (Windows: `authentication.ps1 on`), the MCP tool `set_open_access` and setup say so when `PUBLIC_URL` is `http://` and not `localhost`. A user name and password (Basic) still work over HTTP; with authentication off nobody logs in.
- **The authentication gateway and Keycloak are part of every installation;** `docker-compose.yml` alone is not supported.

### Upgrading

- **Rebuild while upgrading: `docker compose up -d --build --remove-orphans`.** The new server accepts the forwarded user only with the gateway's secret, which only the new gateway sends; upgraded without `--build`, the old gateway stays, and every request, also with authentication off, is refused with "Forwarded identity headers are accepted only from this server's authentication gateway". Running the command again with `--build` repairs it.

- **Images built on your machine are named after the compose project:** `<project>-auth-gateway:local`, `-auth-config`, `-auth-tokens` and `-auth-kerberos` (`<project>` is `COMPOSE_PROJECT_NAME`, by default the installation's directory name, e.g. `emondrian-community-auth-gateway:local`); they were `emondrian-auth-gateway:local` and so on, the same names for every installation on the machine, so building one could change what another ran. This upgrade builds them under the new names even without `--build`. The images under the old names are no longer used; once no other installation on the machine uses them, remove them with `docker image rm emondrian-auth-gateway:local emondrian-auth-config:local emondrian-auth-tokens:local emondrian-auth-kerberos:local`.

- **Run `./auth/scripts/init.sh --no-start` once** (Windows: `windows-setup.ps1`) before `docker compose up -d --build --remove-orphans`: it adds `EMONDRIAN_FORWARDED_SECRET` to `.env` and keeps everything else. Without it `docker compose up` stops with a message saying so, rather than starting a server that trusts nobody.

- **A right or a `<RoleMember>` that names a group by its plain name now grants nothing.** Write the path instead: `emondrian-admins` becomes `/emondrian-admins`. `./auth/scripts/apply-config.sh` lists every such entry it finds in `auth/emondrian/mondrian.properties` and in `schema/`, with the path to write; it changes no file. Your own `mondrian.properties`: rewrite the group names the same way.
- **Every user must have an account in Keycloak, users of external identity providers (Entra ID, Google, ...) included.** Signing in through a provider never creates an account any more (before, Keycloak kept such users only for their session); somebody without one is refused with a page saying to ask the administrator. Create the accounts (admin console, or the MCP tool `create_user` with the person's e-mail) and set `link_by_email: true` on a provider you trust to verify e-mail addresses, so that a sign-in links to the account with the same address; without it, only accounts linked by hand in the admin console get in. Users of Active Directory or LDAP are found in the directory as before. `store_users` is no longer read (apply-config.sh warns). **Before upgrading, create the accounts of everybody who signs in through a provider**, or they are locked out.
- **Kerberos logins forward groups by full path** like every other login (they forwarded a nested Keycloak group by its own name).
- **Personal access tokens issued before this release keep working** with their owner's current groups, by full path (read from Keycloak at use, not the names stored with the token). Without Keycloak (modes `oidc-direct`, `trusted-proxy`) a token still carries the groups stored at issue, and one issued before this release has no groups until it is issued again.
- Keycloak is switched to full group paths by `apply-config.sh` (also run by `setup.sh`); the realm is not re-imported.

## 2026.11.14.1

Server `10.0.89` · modules `0.0.0.106` · OLAP Client `1.2.3` · Dashboard `0.1.3` · entry `1.3.2` · authentication gateway and Keycloak (new)

Authentication, and modules `0.0.0.106` (were `0.0.0.105`) with the MCP tools for it. The server image, the web tools and the Dashboard are unchanged.

### Authentication

- **An authentication gateway with Keycloak** now sits in front of eMondrian and is the only published port. Browsers log in on a login page; Excel, Power BI, scripts and MCP agents send a user name and password (or a token). Users come from Keycloak itself, from Active Directory or another LDAP directory, or both. See `auth/README.md`.
- **It starts with authentication off** (`open_access` in `auth/identity.yml`): everybody who reaches the server gets in without logging in, as `guest` with all rights. Switch it on, without a restart, before others get access: `./auth/scripts/authentication.sh on` (Windows: `.\auth\scripts\authentication.ps1 on`); `off` and `status` likewise.
- **The switch is `auth/state/open_access.json`,** read by the gateway on each request, so it applies at once. `authentication.sh` writes it, and so do the MCP tools `get_open_access` and `set_open_access`. Anybody may switch authentication on; only a Keycloak administrator of the realm may switch it off.
- **No self-signed certificate is created.** For HTTPS, put your certificate and key into `auth/secrets/tls/` (`tls.crt`, `tls.key`); until then the gateway serves plain HTTP.
- **First login, once it is on:** `admin` with the password `0`, which must be changed at once. Add users and groups in Keycloak's admin console (`/auth/admin/`, realm `emondrian`).
- **Rights per group.** eMondrian receives the user name and the groups unchanged. Server rights are set per group in `auth/emondrian/mondrian.properties` (`emondrian-admins`, `emondrian-editors`, `emondrian-viewers` out of the box); roles in the schemas decide which data each user sees.
- **Setup** (`setup.sh`, `windows-setup.ps1`) now also needs `openssl`, and builds the gateway's images on the first run (a few minutes).

### Modules

- **MCP tools behind the authentication gateway,** acting as the person calling, with Keycloak deciding what they may do (the streamable endpoint `/emondrian/mcp`, logged in with a user name and password or a token):
  - users and groups: `list_users`, `get_user`, `list_groups`, `get_group_members`, `create_user`, `update_user`, `set_user_groups`, `create_group`;
  - the authentication switch: `get_open_access`, `set_open_access`.
- A Keycloak user needs Keycloak's own rights for these: `view-users`/`manage-users` for users and groups, and `realm-admin` to switch authentication off. Grant them in Keycloak's admin console (realm `emondrian`); switching authentication on needs none.

### Upgrading

- After `git pull`, run `./setup.sh` (Windows: `windows-setup.ps1`) once: it adds the new settings to `.env` and writes `auth/identity.yml` with authentication off, keeping what is already there. Behaviour stays open until you switch authentication on.

## 2026.11.14

Server `10.0.89` · modules `0.0.0.105` · OLAP Client `1.2.3` · Dashboard `0.1.3` · entry `1.3.2`

Server `10.0.89` (engine `9.3.0-emondrian.88`). The modules, the web tools, the Dashboard and the entry page are unchanged. These changes concern schemas with data roles (`<Role>` with a `<HierarchyGrant>`); without roles nothing changes.

### Server

- **DAX and Power BI work under a role that restricts a hierarchy.** The attribute hierarchies a restricted hierarchy's levels are built from now show the members of that level the role sees. Before, they had no access at all, so every DAX query on that dimension failed with "Illegal access to members of hierarchy" and Power BI's field list lost the columns. A grant written for the attribute hierarchy itself takes precedence. An attribute hierarchy that cannot be derived (a hidden key attribute) gets a message saying to grant it in the role.
- **ClickHouse: a role with more than `mondrian.rolap.maxConstraints` (1,000) members keeps its filter in the SQL**, when the connect string raises both `max_query_size` and `max_ast_elements` (the shipped connect strings do). Before, the filter was dropped and the whole level was read and filtered in memory; the values were right, but slow.
- **Faster totals under `rollupPolicy="partial"` with many granted members.** A role granting 2,000 members of one level took 169 s for an Airline × Year pivot; it now takes about 15 s (1,000 members: 35 s → 6 s).

## 2026.11.13

Server `10.0.88` · modules `0.0.0.105` · OLAP Client `1.2.3` · Dashboard `0.1.3` · entry `1.3.2`

Server `10.0.88` (engine unchanged, `9.3.0-emondrian.87`). The modules, the web tools, the Dashboard and the entry page are unchanged. Nothing changes in how the server behaves: every right stays open.

### Server

- **Administrative rights are set in `.env`, not in `mondrian.properties`.** The image's `mondrian.properties` no longer has a security section. The rights are `-Dmondrian.security.<right>=<roles>` options on `JAVA_TOOL_OPTIONS` in `.env`; `.env.example` explains them and carries a commented example. If you mount your own `mondrian.properties` with `mondrian.security.*` lines, they still work.

## 2026.11.12.2

Server `10.0.87` · modules `0.0.0.105` · OLAP Client `1.2.3` · Dashboard `0.1.3` · entry `1.3.2`

Server `10.0.87` (engine `9.3.0-emondrian.87`, was `10.0.86`). The modules, the web tools, the Dashboard and the entry page are unchanged; `docker-compose.yml` changes only the server image tag. Out of the box nothing changes: every right stays open.

### Engine

- **A new format for server rights in `mondrian.properties`.** A right is now one line naming the roles that hold it, `mondrian.security.<right>.<value>=<role>,<role>`, with the rights `schema.read`, `schema.write`, `database.read`, `database.manage`, `logs.read`, `license.manage` and `impersonate.allow`. A role is a user name or a group name. A right with no line stays open to everyone; a right with a line goes only to the roles on it (`write` and `manage` include `read`); an empty line gives it to nobody. `mondrian.security.defaultRole` names the role of a caller who is not named on any line. The image's own file sets `mondrian.security.defaultRole=admin` and keeps every right commented out, so nothing is enforced until you uncomment one.
- **The old `mondrian.security.role.<role>.*` keys are no longer read.** If your own `mondrian.properties` still has them, or has a key the server does not know, the server logs an error for each such key and refuses every server right until the file is corrected. Rewrite them in the new format before upgrading.

## 2026.11.12.1

Server `10.0.86` · modules `0.0.0.105` · OLAP Client `1.2.3` · Dashboard `0.1.3` · entry `1.3.2`

Server `10.0.86` (engine `9.3.0-emondrian.86`, was `10.0.85`). The modules, the web tools, the Dashboard and the entry page are unchanged; `docker-compose.yml` changes only the server image tag.

### Engine

- **Numbers written with an exponent in a filter.** A `Filter` that compares a measure with a number written with an exponent, such as `[Measures].[Unit Sales] > 1E+9` or `> 5E+4`, failed with "Expected to get decimal, but got 1E+9". It now returns the same result as the number written out (`> 50000`).

## 2026.11.12

Server `10.0.85` · modules `0.0.0.105` · OLAP Client `1.2.3` · Dashboard `0.1.3` · entry `1.3.2`

Modules `0.0.0.105` (were `0.0.0.104`). The server image, the web tools, the Dashboard, the entry page and `docker-compose.yml` are unchanged.

### Synthetic catalogs

- **Fact tables with degenerate dimensions.** This fixes a cube whose fact table holds a dimension's columns itself (for example an order status or an order date on the orders table) next to a foreign key to a separate dimension table. Its synthetic fact table had too few rows, and most of its foreign keys pointed at no member. Now such a fact table:
  - gets the usual fact size;
  - has foreign keys that always point at real dimension rows;
  - has the degenerate dimensions' members drawn per row, every member at least once;
  - has real dates on a date dimension held on the fact table.
- **FoodMart and OnTime.** Their synthetic catalogs are unchanged. A catalog with this kind of cube needs `generate_synthetic_catalog` again to get the corrected data.

## 2026.11.10.1

Server `10.0.85` · modules `0.0.0.104` · OLAP Client `1.2.3` · Dashboard `0.1.3` · entry `1.3.2`

Modules `0.0.0.104` (were `0.0.0.103`). The server image, the web tools, the Dashboard, the entry page and `docker-compose.yml` are unchanged.

### Apache Ossie semantic models

- **Two new MCP tools.** An agent writes a catalog's cube as an Apache Ossie model, or builds a cube from one; the server checks the result.
  - `get_ossie_guide` gives the rules for both directions.
  - `validate_ossie` checks a document for a catalog:
    - against the spec's JSON Schema (`0.3.0.dev0`, a draft);
    - its names against each other;
    - its datasets, fields and metrics against the database, without reading a row;
    - each metric's total against the matching measure's total from the cube.
- **Where totals are compared.** Only on catalogs agents may read, and only over the tables and views the cube is built on.
- **What a model leaves out.** An Ossie model carries no hierarchies, roles or row restrictions, so an exported document has no access rules.
- **Spec 0.2 documents.** Today's converters write spec `0.2`; the guide explains how to bring such a document to `0.3.0.dev0`.

## 2026.11.10

Server `10.0.85` · modules `0.0.0.103` · OLAP Client `1.2.3` · Dashboard `0.1.3` · entry `1.3.2`

Modules `0.0.0.103` (were `0.0.0.102`). The server image, the web tools, the Dashboard, the entry page and `docker-compose.yml` are unchanged.

- **`delete_catalog` no longer deletes a catalog with `agentAccess="synthetic-only"`.** The rule is part of the catalog's entry in `datasources.xml`. An agent could delete the catalog and register it again with `save_catalog` under the same name, connect string and schema, and the new entry no longer kept agents from its real data. Such a catalog is now removed by a person. Its `<Catalog> (synthetic)` can still be deleted on its own. A catalog with `agentAccess="none"` was already invisible to agents, and the server-wide setting was never affected.

## 2026.11.09.2

Server `10.0.85` · modules `0.0.0.102` · OLAP Client `1.2.3` · Dashboard `0.1.3` · entry `1.3.2`

Modules `0.0.0.102` (were `0.0.0.101`). The server image, the web tools, the Dashboard, the entry page and `docker-compose.yml` are unchanged.

- `ENABLE_SERVICE_DASHBOARD=false` in `.env` now turns off the MCP dashboard tools as well as the `/dashboard/` page. Before, an agent could still create dashboards through MCP with the page off.
- `delete_catalog` no longer deletes a catalog when it cannot check whether dashboards read it, for example when the key with `DASHBOARD` has expired or the Dashboard does not answer. It says why; `ignoreDashboards=true` deletes anyway. Before, such a delete went ahead and could leave dashboards reading a catalog that was gone.
- The MCP dashboard tools no longer describe dashboards as part of eMondrian Enterprise.

## 2026.11.09.1

Server `10.0.85` · modules `0.0.0.101` · OLAP Client `1.2.3` · Dashboard `0.1.3` · entry `1.3.2`

OLAP Client `1.2.3` (was `1.2.0`) and the Dashboard application, new in Community. The server, the modules, the Schema Editor and Catalog Editor (`1.1.0`) and the entry page are unchanged.

### Dashboards

- The `dashboard` service serves dashboards at `/dashboard/`, built by an AI agent through the MCP dashboard tools. Until now those tools answered that dashboards were part of eMondrian Enterprise.
- It needs a licence key including `DASHBOARD` in `modules/`. Dashboards are kept in the `dashboard_data` volume.
- `ENABLE_SERVICE_DASHBOARD=false` in `.env` turns the route off. Like the rest of Community, the dashboards have no users or access control.

### OLAP Client

- **Pivot tables with two or more hierarchies on rows.** Every row hierarchy after the first was drawn inside the data cells, shifted by the width of the ones before it, and row headers did not stay in place when scrolling sideways.
- **Members with an empty name** (a `NULL` or empty key) read "(blank)" instead of their unique name, such as `[Origin Airport.Origin State].[]`, in the table and in the copied or downloaded one.
- **Long row groups.** Scrolled into a group, the top visible row repeats the group's member, so it never scrolls out of sight.

## 2026.11.09

Server `10.0.85` · modules `0.0.0.101` · web tools `1.2.0` · entry `1.3.2`

Modules `0.0.0.101` (were `0.0.0.100`) and `schema/Foodmart.xml`. The server image, the web tools, the entry page and `docker-compose.yml` are unchanged.

### Schemas: the classic form is obsolete

- New schemas use the attribute model (`<DimensionAttribute>`). A classic dimension, one with no `<DimensionAttribute>`, still loads and answers MDX, but `validate_schema`, `save_schema` and `save_catalog` name it in a warning. `get_cube_authoring_guide` says the same.
- DAX and Power BI need the attribute model. A DAX query naming a classic dimension's column now says so, instead of "Hierarchy … have not found".
- `schema/Foodmart.xml` no longer has `Store_my`, an unused classic dimension over a table the database does not have.

### Connecting a new database with an agent

- `save_catalog` without `xml`, for a catalog with no schema file yet, writes an empty schema and registers the catalog, so `describe_source` and `validate_source_sql` work before the cube is written. It used to refuse.
- Right after `save_catalog` or `save_schema`, `get_schema`, `validate_schema`, `add_time_measures` and `list_catalogs` see the new schema. For a few seconds they used to answer "Schema resource not found", or read the previous version.
- `validate_schema` with `checkSource`:
  - looks tables up in the catalog's own database by their exact name. On MySQL and MariaDB it searched every database on the server and also tried other letter cases, so a table could pass because another database had one of that name;
  - a name in the wrong case is an error that gives the database's spelling;
  - checks the columns of attribute-model dimensions against the dimension's own table.
- On MySQL and MariaDB, `describe_source`'s `schema` is the database name; it used to list every database's tables.
- An error that quotes a table with its database name (MariaDB: `Table 'db.table' doesn't exist`) keeps the name instead of showing `'?'`.

## 2026.11.08.3

Server `10.0.85` · modules `0.0.0.100` · web tools `1.2.0` · entry `1.3.2`

Modules `0.0.0.100` (were `0.0.0.99`). The server image, the web tools, the entry page and `docker-compose.yml` are unchanged.

### Deleting a catalog through MCP

- **`delete_catalog`** deletes a catalog in one call: its entry in `datasources.xml`, its schema file, its `<Catalog> (synthetic)` catalog with the generated schemas, and the generated `syn_*` databases. No restart is needed; the catalog is gone for the next request, and a session that still had it open fails on its next query.
- The deletion is permanent: nothing is kept aside. Keep your schemas in git if you may want them back; synthetic data can be generated again.
- A schema file that another catalog also uses is kept, and the answer says which catalog uses it. Given `<Catalog> (synthetic)`, only the synthetic catalog and its data are deleted.
- With the Enterprise Dashboard application, a catalog that dashboards read is not deleted unless `ignoreDashboards` is true, and the dashboards are named in the answer; they are never changed.
- **`delete_schema`** deletes a schema file under `/WEB-INF/schema/` that no catalog uses any more.
- Both need the same rights as `save_catalog`, and a server started with `-Demondrian.mcp.readOnly=true` does not offer them.

## 2026.11.08.2

Server `10.0.85` · modules `0.0.0.99` · web tools `1.2.0` · entry `1.3.2`

Modules `0.0.0.99` (were `0.0.0.98`). The server image, the web tools, the entry page and `docker-compose.yml` are unchanged.

### Licence keys

- **No licence change needs a restart.** Until now a key that had passed once was used until the server restarted, so an expiry or a replaced key waited for a restart. Now, for each module, the server uses the first key in `modules/` that is valid, includes the module and is within its dates. A new key works from the next request; an extension or a key placed beside the current one takes over when the current one expires, without a gap; an expiry takes effect at the expiry time; a deleted key, or one with fewer modules, stops counting within an hour.
- Old keys can stay in `modules/`: an expired or wrong-module key is skipped.
- The "No eMondrian licence found" message now ends with "A free 30-day evaluation key is available at https://emondrian.com/license"; it no longer lists the modules the evaluation key includes.

## 2026.11.08.1

Server `10.0.85` · modules `0.0.0.98` (now with `synthetic`) · web tools `1.2.0` · entry `1.3.2`

The server image, the web tools and the entry page are unchanged. `modules/` now includes the synthetic module, and `docker-compose.yml` gains a one-time `synthetic-init` service.

### Synthetic catalogs

- **The synthetic module is part of Community**, under a licence key that includes `SYNTHETIC`, as DAX and MCP need theirs. New evaluation keys include it; a key issued earlier keeps the modules it was issued with, so get a new one to try it.
- A synthetic catalog, `<Catalog> (synthetic)`, has a real catalog's cubes, dimensions, measures and roles over generated data. An agent builds it with `generate_synthetic_catalog` and follows it with `synthetic_catalog_status`. Nothing is generated on its own.
- Generated data goes to the bundled ClickHouse, into `syn_*` databases, through two users that cannot read the real data there. `setup.sh` (and `windows-setup.ps1`) creates their passwords in `.env` as `EMONDRIAN_SYN_WRITER_PASSWORD` and `EMONDRIAN_SYN_READER_PASSWORD`. **Upgrading:** run `./setup.sh` once, or set both in `.env` yourself, then `docker compose up -d`. Without them the server starts as before and synthetic catalogs cannot be generated.
- If you load a database of your own into the bundled ClickHouse, add a `REVOKE` for it to `clickhouse/init-scripts/init-synthetic.sh`.

### What an agent sees: an option, off by default

Agents read real data, as before, unless you turn the option on. Nothing in `datasources.xml` or `.env.example` turns it on.

- **On, for one catalog:** add `agentAccess="synthetic-only"` to its `<Catalog>` in `datasources.xml` (or call `generate_synthetic_catalog` with `"restrictSource": true`). It applies from the next MCP call; restart the eMondrian service if your editor replaced the file.
- **On, for every catalog:** add `JAVA_TOOL_OPTIONS=-Demondrian.mcp.agentAccess=synthetic-only` to `.env` and run `docker compose up -d --force-recreate eMondrian`.
- **Off:** remove the attribute (or set `agentAccess="real"`), or remove the `JAVA_TOOL_OPTIONS` line and recreate the service. Where both are set, the stricter one applies.

When it is on, the structure tools work on the real catalog and the tools that return values or member names refuse and point to `<Catalog> (synthetic)`, as described in 2026.11.08. The README's "Synthetic catalogs" section has the details.

## 2026.11.08

Server `10.0.85` · modules `0.0.0.98` · web tools `1.2.0` · entry `1.3.2`

Server `10.0.85` (engine `9.3.0-emondrian.85`, was `10.0.84`) and modules `0.0.0.98` (were `0.0.0.97`). The web tools and the entry page are unchanged. `docker-compose.yml` gains an optional `env_file: .env` and two directories, `drivers/` and `share/`, which `setup.sh` creates; run `mkdir -p drivers share` if you upgrade without it.

### Connecting a new database through MCP

- **Credentials in `.env`.** Put a database's user and password or token in `.env` as `EMONDRIAN_SRC_<NAME>_USER`, `_PASSWORD` or `_TOKEN` and restart the server. A connect string names them as `${env:EMONDRIAN_SRC_SALES_PASSWORD}`, and the value is read only when a connection opens. `save_catalog` refuses a connect string with a password or token written into it, and one that names a variable that is not set. MCP answers, errors and `read_logs` included, show `***` instead of these values. New tool `list_source_credentials` lists the variables and whether each is set, never their values.
- **JDBC drivers at run time.** New tool `install_driver` adds a driver jar from Maven Central coordinates, an https URL on an allowed host (`emondrian.drivers.allowedHosts`, Maven Central by default) or the share. The jar's SHA-256 is required, and for Maven it must also match the repository's own checksum. Installed jars are kept in `drivers/` and loaded without a restart, and again at every start. A driver the image already includes (PostgreSQL, ClickHouse, HSQLDB) is refused with the class name to use. `list_drivers` lists what is installed. `install_driver` is not offered on a read-only server.
- **The share.** `share/` is mounted read-only at `/share`. Put a file there and a tool can use it as `share:path/to/file`; `list_shared_files` lists them. Paths that leave the share are refused.
- **The source's structure, not its data.** `describe_source` lists a database's schemas, tables, columns, types and keys; `validate_source_sql` checks a query or an expression without fetching a row; `validate_schema` with `checkSource: true` checks a schema's tables, columns and views against the database. None of them returns rows, row counts, defaults or statistics.

### What an agent sees of a catalog's data

What an agent sees of a catalog's data is a setting. By default an agent reads a catalog's data like any other client. For an agent to see only the schema and synthetic data, set `agentAccess="synthetic-only"` on the `<Catalog>` in `datasources.xml`, or `-Demondrian.mcp.agentAccess=synthetic-only` for every catalog on the server. The server-wide setting is the one to use where a whole server holds real data.

On a synthetic-only catalog the structure tools (`get_schema`, `save_schema`, `validate_schema`, `save_catalog`, `describe_source`, `validate_source_sql`) now work, so an agent can build a cube on a new database. The tools that return values or member names (`execute_query`, `describe_cube`, `get_csdl`, the Power BI report tools, dashboards) refuse and point to `<Catalog> (synthetic)`. `list_catalogs` lists such a catalog with a note. Without synthetic catalogs on the server, the structure tools still work and the data tools still refuse. Excel, Power BI and the web client are not affected.

Limits worth knowing: on a synthetic-only catalog `validate_source_sql` refuses nested queries (subqueries, derived tables, `WITH`) on every database, because a database can evaluate a subquery before the check's row filter and return its values in an error message. On ClickHouse this applies to every catalog. Errors from structure tools on such a catalog keep only quoted text the agent sent itself. `save_catalog` recognises a restricted catalog's database only by the same JDBC address.

### Fixes

- Synthetic catalogs: a cube whose dimensions are classic hierarchies over their own tables (no attribute model) got a two-row fact table with its measures as text, and every query on it failed.

## 2026.11.07.2

Server `10.0.84` · modules `0.0.0.97` · web tools `1.2.0` · entry `1.3.2`

Modules `0.0.0.97` (were `0.0.0.96`). The server image, the web tools and the entry page are unchanged.

### DAX

- **`ASC` and `DESC` in `TOPN` and `SAMPLE`.** `TOPN(10, 'Table', [Measure], DESC)` was a syntax error: the keywords were accepted only after `ORDER BY`. They now work wherever a sort order goes, in any case, and mean the same as the numbers `0` (descending) and `1` (ascending) that Power BI writes.

### Power BI reports from MCP

- `make_visual` describes the order of conditional-formatting rules plainly: list them as Power BI Desktop's Rules dialog shows them, top to bottom.

## 2026.11.07.1

Server `10.0.84` · modules `0.0.0.96` · web tools `1.2.0` · entry `1.3.2`

Modules `0.0.0.96` (were `0.0.0.95`). The server image, the web tools and the entry page are unchanged.

### Power BI reports from MCP

- **Tooltips.** A column or bar chart takes measures in `Tooltips`, shown when a bar is hovered. `sort` can name one of them, which sorts a chart by a measure it does not show.
- **Conditional formatting in tables and matrices.** `conditionalFormatting` colours a measure's background as a gradient from lowest to highest, colours its background or font by rules on the measure itself or on another measure, or adds data bars (tables). List the rules as Power BI Desktop's Rules dialog shows them, top to bottom: where two match, the later one wins.
- **Tooltip pages.** `make_page` with `"tooltip": true` makes a 400 x 300 page that a chart shows on hover, filtered to the hovered bar; the chart names it with `"tooltipPage"`. The page's visuals are placed for that size.

### Known limitations

- Power BI does not offer three of its visuals on a live connection to eMondrian: the new card visual with categories, a slicer on a hierarchy, and small multiples. Power BI itself declines them for this kind of source; the classic card, slicers on a column and separate charts work.

## 2026.11.07

Server `10.0.84` · modules `0.0.0.95` · web tools `1.2.0` · entry `1.3.2`

Docker image `emondrian/emondrian:10.0.84` (was `10.0.74`), modules `0.0.0.95` (were `0.0.0.89`). The web tools and the entry page are unchanged.

### Power BI

- **Selecting a value in a Top N chart.** Clicking a bar in a chart limited to its Top N showed the Top N's total in the other visuals instead of the clicked value's, and prior-year and plan columns were blank for it. The selection is now the clicked value within the Top N, for every measure.
- **Slicer lists follow the other slicers.** A slicer on one attribute listed every value even when a slicer on another attribute of the same dimension was set (every city under a state filter). It now lists only the values that exist together with the selection, as Analysis Services does.
- **Several values selected in a slicer.** Visuals that filter on the slicer's own field failed under a slicer with more than one value selected; they now show the numbers.
- **Top N over two fields** with fewer rows of data than N could return wrong rows; it returns the rows with data, then the rest.
- **Faster pages under slicers.** Cells and Top N filters read under slicers use the cube's aggregate tables where one carries the slicer's columns; a page that took seconds can take a fraction of one. Before, a Top N under slicers could pick an aggregate table it could not join and run for minutes.
- **Filters:** `'T'[C] IN {"a", "b"}`, and `= BLANK()` / `<> BLANK()` on an attribute with empty values.

### DAX for hand-written queries

- New: `SELECTEDVALUE`, `HASONEVALUE`, `REMOVEFILTERS`, `VAR ... RETURN`, `DATEDIFF`, `EOMONTH`, `WEEKDAY`, `ROUNDUP`, `ROUNDDOWN`, `CEILING`, `FLOOR`, `MOD`, `LOG`, `EXACT`, `SUBSTITUTE`, and `SUM`/`AVERAGE`/`MIN`/`MAX`/`COUNT`/`DISTINCTCOUNT` of a column, which answer with the measure to use.
- `REPLACE` replaces by position, as in DAX (it found and replaced text).
- `VALUES` and `COUNTROWS` follow the filters in effect; `CALCULATE` takes OR and IN conditions, `ALL('T')`, `ALL(c1, c2)`, `KEEPFILTERS` and conditions over several columns. `SAMPLE(n, ...)` returns n rows.
- Forms that are not supported give a clear error that quotes the expression, instead of being ignored.

### Excel and MDX

- **`NON EMPTY` in Excel pivots.** With subtotals in a pivot, rows came back grouped in the wrong order. A calculated measure that sets a member of a field on the rows (for example, a measure fixed to one year) lost rows that had values. Both are fixed.
- **`NON EMPTY` with measures that use their own aggregate function** (`aggregatorImplementation`) returned no rows for crossjoins whose combinations had data.
- A cache flush now also clears the cells read under a subselect.

## 2026.11.05.1

Server `10.0.74` · modules `0.0.0.89` · web tools `1.2.0` · entry `1.3.2`

Docker image `emondrian/emondrian:10.0.74` (was `10.0.73`), modules `0.0.0.89` (were `0.0.0.85`). The web tools and the entry page are unchanged.

### Server

- **Power BI filters on attributes with empty values.** Clicking a row or a slicer value in Power BI on an attribute that has empty (NULL) members put an error message in the cells ("Expected value of type STRING; got value '#null'") instead of the numbers. The empty member is now passed over, as any member that does not match.
- **Prior-year and plan columns under Power BI slicers.** A calculated measure that reads another year or another version (prior year, plan) showed the right totals but was empty on every row of a matrix or chart once slicers were set, because its cells were read together with the actual's and under the actual's year. They are now read under their own coordinates, as the same calculation already did with a `WHERE` clause.

### Power BI reports from MCP

- **Single-select slicers.** A slicer with `"singleSelect": true` lets the reader pick one value at a time. It needs a `selection` (one value, or `{"latest": true}`), because Power BI Desktop otherwise selects the first value when the report opens, even one with no data.
- **Totals off.** `"totals": false` turns off a matrix's subtotals and grand totals; `{"rows": false}` or `{"columns": false}` turns off one side. On a table it removes the total row.
- **Cards fit their value.** A card is as wide as its value when the page opens. When the cards do not fit beside the slicers, they get a row of their own, so a long figure such as `1,464,108,407.19` is no longer cut off.
- **Measure folders.** A measure's `displayFolder` now groups it in Power BI's Data pane; `A\B` gives a subfolder.

## 2026.11.05

Server `10.0.73` · modules `0.0.0.85` · web tools `1.2.0` · entry `1.3.2`

Docker image `emondrian/emondrian:10.0.73` (was `10.0.72`), modules `0.0.0.85` (were `0.0.0.84`). The web tools and the entry page are unchanged.

### Server

- **Power BI slicers on a virtual cube.** In a virtual cube, a measure wrapped in `ValidMeasure` failed when a Power BI slicer was set on a dimension its own cube does not have, and the visual showed "Error fetching data". Power BI sends every slicer as a subselect, which now leaves such a measure unrestricted, as the same member in a `WHERE` clause always did. Slicers on dimensions the measure's cube has still filter it.
- **Schema validation of virtual cubes.** `validate_schema` now checks the attributes of `VirtualCube`, `CubeUsage` and `VirtualCubeMeasure`. `ignoreUnrelatedDimensions` on a `VirtualCubeMeasure`, where the server ignores it, gets a warning that says it belongs on `<CubeUsage>`.

### MCP

- The cube authoring guide explains both, in its section on several fact tables.

## 2026.11.04.4

Server `10.0.72` · modules `0.0.0.84` · web tools `1.2.0` · entry `1.3.2`

Modules `0.0.0.84` (were `0.0.0.83`). The server image, the web tools and the entry page are unchanged.

### Power BI

- **A matrix keeps its rows when the cube's default measure is empty.** A matrix with rows and columns kept a row only when the cube's default measure (its first measure) had data, not the measures the matrix shows. On a cube whose first measure is empty for some rows, those rows were dropped, and a matrix could show only its total. The measures in the visual now decide.

## 2026.11.04.3

Server `10.0.72` · modules `0.0.0.83` · web tools `1.2.0` · entry `1.3.2`

Modules `0.0.0.83` (were `0.0.0.82`), `docker-compose.yml` and the setup scripts. The server image, the web tools and the entry page are unchanged.

### MCP

- **Power BI projects get the address Desktop connects to.** `make_project`'s `dataSource` is the XML/A address Power BI Desktop uses to reach this server, which is often another machine than the one eMondrian runs on. Its description now says so and tells the agent to ask you when it does not know the address; an agent used to guess `http://localhost:8080/emondrian/xmla`, and Desktop could not open the project without an edit. Tell the agent the address, e.g. `http://my-server/xmla`, when you ask it for a project.

### Setup

- **A `.env` with only some settings works.** A `.env` holding just `EMONDRIAN_PORT` left the front door without `/xmla`, the tools and MCP (all 404) while the setup script said "ready". Every route is now on unless `.env` turns it off; the setup scripts list the settings `.env` leaves out, and stop with an error when `/xmla` does not answer.

## 2026.11.04.2

Server `10.0.72` · modules `0.0.0.82` · web tools `1.2.0` · entry `1.3.2`

Docker image `emondrian/emondrian:10.0.72` (was `10.0.70`). The modules, web tools and entry page are unchanged.

### Server

- **Clearer messages for mistyped MDX.** `[Store].[Store State].Members()` with parentheses failed with a bare `UnsupportedOperationException`; it now says `No function matches signature '<Level>.Members()'`. A bracket or a quote left open (`[Unit Sales` with no `]`) reached the client as "Unknown Error"; it is now a syntax error that says the bracket or quote is not closed.
- **A no-break space is whitespace.** A query copied from a web page or a document often carries no-break spaces, which were a syntax error. They are now read as ordinary spaces.
- **Quieter start.** The server no longer logs failed registrations for library classes bundled in the MCP module at every start.

## 2026.11.04.1

Server `10.0.70` · modules `0.0.0.82` · web tools `1.2.0` · entry `1.3.2`

Modules `0.0.0.82` (were `0.0.0.81`). The server image, the web tools and the entry page are unchanged. Recommended for anyone using the time measures of 2026.11.04 in Power BI.

### Time intelligence in Power BI

- **A month with no data of its own stays in the table.** In a table of months with a one-year slicer, Power BI keeps a row while any of its measures is not blank. That check read the measures without the slicer's year, so a month with no sales but a year-to-date value (December, in a year whose data ends in November) was missing. It is there again, with its year-to-date, same-period-last-year and rolling values.
- **The total row shows the year.** Power BI computes a table's total over the months it shows, and the time measures took that for a chosen month and were blank. The total row now shows the year's values: year-to-date, same period last year and year-over-year change, with no rolling value. Time measures created with `add_time_measures` before this release keep the old formula; delete them and run the tool again to get the new one.
- **Several years in an MDX `WHERE` set** make the time measures fail with "the coordinate for the '[Time.Year]' hierarchy contains a set", as in Analysis Services. A subselect, which Excel sends for several years, works. The cube authoring guide now says so.

## 2026.11.04

Server `10.0.70` · modules `0.0.0.81` · web tools `1.2.0` · entry `1.3.2`

Docker image `emondrian/emondrian:10.0.70` (was `10.0.63`), modules `0.0.0.81` (were `0.0.0.76`). The web tools and the entry page are unchanged.

### Time intelligence

- **Time measures in the schema.** The cube authoring guide (`get_cube_authoring_guide`) has a new section on year-to-date, quarter-to-date, same period last year, previous year, year-over-year change and rolling three months, written as calculated members. They give the same numbers in Excel, which uses the user hierarchy, and in Power BI, which uses the attribute hierarchies. A distinct count over a year to date is one query over those months, not the sum of the months. Ratios are built from the time measures of their parts, never by aggregating the ratio itself.
- **New MCP tool `add_time_measures`.** It writes those measures for the stored measures you name, with the cube's own hierarchy names. It previews by default and changes the schema only with `save=true`. It is registered with the other write tools, so a server started with `emondrian.mcp.readOnly=true` does not offer it. It needs a time hierarchy with an All member and a month level; a week hierarchy beside it is left out.
- **Power BI: a year chosen in a slicer reaches the time measures.** With one year chosen and months on the visual, year-to-date, same period last year and rolling measures use that year. With several values chosen there is no single period, so the time measures are blank, while plain measures add up over the selection.
- Report-level DAX time functions such as `TOTALYTD` are not supported: Power BI does not offer report measures on this connection. Use the calculated members above.

### Server

- **Filters on the bundled FoodMart database return the right members.** A filter whose condition uses no measure, such as `Filter([Time].[Month].Members, 1 = 0)`, returned every member, and an aggregation over it returned the unfiltered total. The condition is now applied.
- **An empty distinct count is empty.** A distinct count aggregated over an empty set returned `1.2345E-8`, which showed as `0`. The cell is now empty.
- **Time calculations under a slicer.** A calculated member that reaches into another year, such as the same month last year or a rolling window across January, now gets that year under a subselect on the year. The cells on the axes are still restricted to the selection.
- **A numeric key written as `1998.0`** (as Power BI sends it) now matches the member with key `1998` on ClickHouse.
- **Comparing a member's name with text on a numeric key** (`[Time].[Month].CurrentMember.Name = "x"`) is no longer a SQL error.
- **Calculated members with an explicit `MEMBER_ORDINAL`** no longer make the schema fail to load with "Ordinal N is not unique" when other calculated members are added.
- **`validate_schema` warns about out-of-order cube elements.** A `<CalculatedMember>` after a `<DrillThroughAction>` (or any child of a cube out of the declared order) is ignored when the schema is read; the validator now says so.
- **Boolean keys** are read as booleans, not `0`/`1`, so captions are right, filters on them work and Power BI sorts them correctly.
- **Member names returned by the server parse back.** On a dimension whose attribute hierarchy carries the dimension's own name, a unique name returned by the server (from `TopCount`, say) was not found when sent back, and a calculated member defined there could be referred to by one spelling only. Both spellings now work.
- **A measure filter with a custom aggregate function** (`aggregatorImplementation`, such as `uniqExact`) uses that function in the SQL it sends.
- **Parallel queries and cancels** no longer fail now and then with `ConcurrentModificationException`, and ending a session the server no longer has is not logged as an error.
- **Metrics:** the open-connections gauge (`emondrian_connections`) has samples again, and the query metrics carry a `language` label, `MDX` or `DAX`.

### Power BI

- **A model with an attribute named `<X> Key`** no longer collides with the hidden key property of `X`, which made Power BI refuse the model.
- **DAX resolves hierarchies and levels by object.** On a dimension whose attribute hierarchy carries the dimension's own name, totals (`ROLLUP`) failed and columns could return the All member. A level named differently from the attribute it is built on is a column again.
- `make_page` and `make_project` write an empty key as `null`.

## 2026.11.02.1

Server `10.0.63` · modules `0.0.0.76` · web tools `1.2.0` · entry `1.3.2`

Docker image `emondrian/emondrian:10.0.63` (was `10.0.62`), modules `0.0.0.76` (were `0.0.0.74`). The web tools and the entry page are unchanged. Upgrading is recommended for every installation that connects Claude or another current MCP client.

### MCP

- **Claude can connect again.** Since about 21 October 2026, Claude clients (claude.ai, the desktop app, Claude Code) have sent new optional fields in their first `initialize` request. The MCP server rejected them, so every connection failed with HTTP 400 `Unrecognized field "form"` and the connector reported it could not reach the server. The server now ignores fields it does not know, as the protocol intends, so later additions do not break connecting either.

### Server

- **Queries no longer leave engine connections open.** Every MDX or DAX query, and every cancel request, used to leave one internal connection behind until the next full garbage collection, so the open-connections count only ever grew. They are now closed when the request ends.
- **A failed request no longer leaves its session open.** A request sent without a session gets a temporary one, and after an error it stayed open until the idle timeout (`mondrian.server.IdleOrphanSessionTimeout`, one hour by default). It is now closed whether the request succeeds or fails.

## 2026.11.02

Server `10.0.62` · modules `0.0.0.74` · web tools `1.2.0` · entry `1.3.2`

Docker image `emondrian/emondrian:10.0.62` (was `10.0.58`). The modules, web tools and entry page are unchanged.

### Power BI Service

- **Scheduled refresh through the on-premises data gateway works.** Before a refresh, the Service checks the model for changes. It sends a system-table query and asks for the server description, and both answers now match what Analysis Services returns. Refreshes had been failing with `FailedDeserializeSchema`; dashboard tiles now refresh on their own.
- **System-table (DMV) queries** such as `SELECT [LAST_SCHEMA_UPDATE] FROM $SYSTEM.MDSCHEMA_CUBES` return only the selected columns, as a query result. `SELECT *` is accepted, column names are case-insensitive, and an unknown column is an error. `DBSCHEMA_CATALOGS.DATE_MODIFIED` is the time the schema was loaded.
- **The server description** (`DISCOVER_XML_METADATA`) can be read by Microsoft's AMO/TOM client libraries. It reports a real edition and the server mode, and lists the databases.

### Data sources

- **Credentials can come from the environment.** A connect string in `datasources.xml` may contain `${env:EMONDRIAN_*}` placeholders. They are resolved when the connection is made, so the file is served and saved exactly as written, without the secret.

## 2026.10.30

Server `10.0.58` · modules `0.0.0.74` · web tools `1.2.0` · entry `1.3.2`

Docker image `emondrian/emondrian:10.0.58` (was `10.0.57`). The web tools and the entry page are unchanged. Upgrading is recommended for every installation that exposes the MCP endpoint.

### MCP

- **`execute_query` validates its `cube` argument.** It must be the exact name of a cube in the catalog; anything else is refused with the list of the catalog's cubes.
- **Catalog arguments must be strings**, and a tool that requires `catalog` refuses a call without one before doing anything else.

### MCP traffic log

The MCP server now writes every message between it and agents to `logs/mcp-audit.log`, one JSON object per line, both directions:
- the session, the client and its user agent, and the client network;
- the tool, catalog, cube and query;
- the status, error, duration, size and rows.

- **On by default, in `metadata` mode**: no tool arguments or results, but the query text is kept. `full` adds them; `off` turns the log off (`emondrian.mcp.audit`).
- **Client addresses are truncated before writing**: IPv4 to /24, IPv6 to /48, on by default (`emondrian.mcp.audit.truncateIp=false` keeps full addresses).
- **The local file rotates at 50 MB**, and rotated files are deleted after 30 days.
- Secrets and licence file names are redacted, and `read_logs` does not expose the log.

See [MCP traffic log](README.md#mcp-traffic-log) in the README for the settings, the event format and how to ship it to Loki or ELK.

## 2026.10.29

Server `10.0.57` · modules `0.0.0.71` · web tools `1.2.0` · entry `1.3.2`

Docker image `emondrian/emondrian:10.0.57` (was `10.0.51`). The web tools and the entry page are unchanged.

### Power BI Service through the on-premises data gateway

- **The gateway's connection properties are accepted.** `EffectiveUserName`, `Roles` and `CustomData` no longer fail the request. `EffectiveUserName` is **accepted and ignored** unless the connecting account's role is granted impersonation (`mondrian.security.role.<role>.impersonate=allow` in `mondrian.properties`). This edition grants nothing, so every report viewer is served as the gateway's own connection: there is **no per-viewer security**.
- **Rowset schemas declare the `xmlDocument` type**, which the Service's schema check required.
- **XML/A property names are case-insensitive**, and unknown properties are ignored (logged once) instead of failing the request.
- **`mondrian.xmla.providerVersion`** sets the server version reported in `DISCOVER_PROPERTIES` and `DISCOVER_XML_METADATA`. The default is unchanged.

### DAX, as Power BI visuals send it

- A measure referenced as `[Flights]` in a query that also defines a column named "Flights" resolves to the measure (it used to overflow the stack).
- Matrix subtotals: `ROLLUP` uses the All member of the hierarchy the query names, so a matrix on Day of Week or Distance Group renders its totals.
- An attribute hierarchy named after its dimension gets a unique name of its own, so it no longer clashes with the dimension's user hierarchy.
- `SUMMARIZECOLUMNS` with `ROLLUPADDISSUBTOTAL` returns its subtotal rows and flag columns; table constructors `{ … }` and `TREATAS` over them are supported; `ISINSCOPE` is false on subtotal rows.
- A drill-through combined with a "contains" filter on the same column no longer fails.
- A text filter on a column whose key is numeric (Quarter) no longer fails with a type error.
- A Top N visual filter is applied before a table's row limit, so the table shows the top N rows.
- "Show items with no data" (`GENERATEALL`) is supported.
- The field list leaves out measures the caller's role cannot access.
- The OnTime sample shows names, not keys, for Quarter, Month, Day of Week and Distance Group.

### Power BI reports from MCP

- **New visual types for `make_visual`, `make_page` and `make_project`:** gauge, scatter (with Size and Play), stacked area, area, stacked column, 100% stacked column, ribbon, waterfall, funnel, donut and treemap; a line chart takes a second axis (`Y2`).
- **`colors`** sets fixed colours for a chart's legend members or categories; **`averageLine`** draws an average line on a line chart.

### Known limitations

- The new Card visual with Categories is not supported.
- The hierarchy slicer and small multiples are not yet verified.
- No row-level or per-viewer security through the gateway (see above).
- DAX covers what Power BI visuals generate on a live connection; time-intelligence functions are not implemented.
- DAX and the MCP tools need a licence; this repository ships without one. A free 30-day evaluation key is at https://emondrian.com/license: put the `.lic` file into `modules/` next to `docker-compose.yml`; no restart is needed.

## 2026.10.27.4

Server `10.0.51` · modules `0.0.0.64` · web tools `1.2.0` · entry `1.3.2`

Docker image `emondrian/emondrian:10.0.51` (unchanged). The web tools and the entry page are unchanged.

### Improved

- **Power BI reports from MCP: `arrange_page` keeps charts wide enough.** Given the page's `catalog` and `cube`, it counts each line and column chart's categories, as `make_page` does, and gives it the width they need. Without them it says that no width was checked; `make_visual`'s result names the call to make.
- **Power BI reports from MCP: charts wrap into a second row** when one row cannot give every chart the width its categories need, for new pages and re-arranged ones alike.

## 2026.10.27.3

Server `10.0.51` · modules `0.0.0.63` · web tools `1.2.0` · entry `1.3.2`

Docker image `emondrian/emondrian:10.0.51` (unchanged). The web tools and the entry page are unchanged.

### Improved

- **Power BI reports from MCP: a chart as wide as its categories.** A line or column chart gets 31 px per category on its axis, counted on the server under the page filters and the slicers that filter it, so a line of 30 years is 930 px and shows every year instead of scrolling. The other charts in the row share the rest; when a row cannot fit, the result says which chart is short.
- **Power BI reports from MCP: time in time order.** A column or bar chart on a time dimension's column (Year, Month) sorts by it, so months read 1 to 12; other categories still sort by value, largest first.
- **OnTime schema:** `Time` is declared a time dimension (years, quarters, months), as FoodMart's is. MDX time functions such as `YTD` now work on it. The figures and the Power BI metadata are unchanged.

## 2026.10.27.2

Server `10.0.51` · modules `0.0.0.62` · web tools `1.2.0` · entry `1.3.2`

Docker image `emondrian/emondrian:10.0.51` (unchanged). The web tools and the entry page are unchanged.

### Improved

- **Power BI reports from MCP: a tighter top row.** A card with a title no longer repeats the measure name under its value (`"header": true` keeps it). Dropdown slicers are 70 px and cards 90 px instead of 180 px, so the charts below start higher and are taller. A list slicer keeps 180 px.

### Fixed

- **Count measures show zero as 0.** Flights, Cancelled, Diverted, Late Arrivals and Distinct Tail Numbers in OnTime, and Sales Count, Customer Count, Store Sqft and Grocery Sqft in FoodMart, were formatted `#,###`, which shows zero as an empty cell; in Power BI a value axis read ".0M .2M". They are now `#,##0`. The numbers are unchanged.

## 2026.10.27.1

Server `10.0.51` · modules `0.0.0.61` · web tools `1.2.0` · entry `1.3.2`

Docker image `emondrian/emondrian:10.0.51` (unchanged). The web tools and the entry page are unchanged.

### Improved

- **Power BI reports from MCP: a slicer no longer filters a chart of its own field.** With the Year slicer on 2025, a line chart of the on-time rate by year still shows every year, so the selection is seen in context; a chart on the whole Time hierarchy counts too. Tables, matrices and cards are still filtered. A visual's `"slicers"` option overrides this: `"filter"` lets every slicer filter it, `"ignore"` lets none. The project shows the same settings in Desktop under Format → Edit interactions.

## 2026.10.27

Server `10.0.51` · modules `0.0.0.60` · web tools `1.2.0` · entry `1.3.2`

Docker image `emondrian/emondrian:10.0.51` (engine 9.3.0-emondrian.51). The web tools and the entry page are unchanged.

### Improved

- **Power BI reports from MCP (`make_visual`, `make_page`, `make_project`) start from better defaults.**
  - A `latest` slicer on Year selects the latest *complete* year: a year still in progress is passed over, and the result says which one (`skippedPartial`). `{"latest": true, "complete": false}` takes it anyway.
  - Cards show the whole number (7,001,619, not 7M); `"displayUnits": "auto"` gives Desktop's default back.
  - Slicers are dropdowns and show their field name once; `"style": "list"` and `"header": true` give the list and the header back.
  - Line charts use the smallest axis font, so every year label is shown in full.
- **OnTime schema:** the `KeyColumn` `type` attribute, which the server ignores, is gone, so loading OnTime logs 13 fewer warnings. The model and its numbers are unchanged.

### New

- **Horizontal bar charts.** `"type": "bar"` writes Power BI's clustered bar chart, with the same fields, sort and Top N filter as `column`.

### Fixed

- **`CASE` with no `WHEN`.** `CASE ELSE 1 END` failed with *Index 1 out of bounds for length 1*; it is now an ordinary "No function matches signature" error.

## 2026.10.26.1

Server `10.0.50` · modules `0.0.0.58` · web tools `1.2.0` · entry `1.3.2`

Docker image `emondrian/emondrian:10.0.50` (engine 9.3.0-emondrian.50). The web tools and the entry page are unchanged.

### New

- **MCP `describe_cube`.** One call lists a cube's dimensions (time dimensions marked), hierarchies with their All and default members, levels with their level type, the row count the schema reports and an optional counted one, a sample member, and the stored and calculated measures. An agent checking a cube it has just written no longer needs access to the server's files.
- **MCP sessions see a saved schema the way XML/A sessions do.** After `save_schema` or `save_catalog`, the session that saved and every new session get the new version; sessions already open keep the version they started with until they end.
- **`save_schema` and `save_catalog` check what they saved.** They load the catalog and open a database connection, and report a failure plainly, saying the file was saved, with a hint for the common causes: a host name with an underscore, which the ClickHouse driver rejects, or a host the server cannot resolve.
- **`validate_schema` checks time dimensions.** Every level of a `TimeDimension`, including the attribute hierarchies it generates, must have a time level type (`TimeUndefined` counts), and no other dimension may have one. The server refused such a schema when loading it, without saying why; the validator now reports it with the fix.
- **MCP `make_project` can default its server address.** `-Demondrian.mcp.publicXmlaUrl=<url>` sets the XML/A URL written into a Power BI project when the agent passes no `dataSource`; without it, `dataSource` stays required.
- **The cube authoring guide** (`get_cube_authoring_guide`) covers measures, time dimensions, shared dimensions and virtual cubes, calculated members, and how MDX names members and levels.

### Fixed

- **MCP:** a tool that hit an internal Java error left the client waiting for an answer that never came; it now returns the error. Passwords in connection errors are masked.

## 2026.10.26

Server `10.0.49` · modules `0.0.0.56` · web tools `1.2.0` · entry `1.3.2`

Docker image `emondrian/emondrian:10.0.49` (engine 9.3.0-emondrian.49). The web tools and the entry page are unchanged.

### New

- **Agent access per catalog.** `<Catalog agentAccess="none">` in `datasources.xml` (an attribute on the element) keeps a catalog away from MCP agents: `list_catalogs` leaves it out and every tool that names it refuses. `-Demondrian.mcp.agentAccess` sets the same rule for the whole server. XML/A clients are not affected.
- **`mondrian.result.evaluationLimit`.** With it set, `mondrian.result.limit` applies to the cells a `NON EMPTY` query returns, not to the size it had before the empty rows and columns were removed; the new property bounds that larger, in-memory size. Unset (the default), nothing changes.

### Fixed

- **Excel pivot filters on large levels.** A filter Excel sends as a subquery with an explicit set of members looked every member up again on each cell request, so a few thousand selected members made a query take minutes ([#6](https://github.com/eMondrian/emondrian-community/issues/6)). Filtering 6 000 tail numbers in OnTime now takes 2 s instead of 8 s, with the same numbers.
- **Cell properties.** A query asking for a cell property the server had no element for (`FONT_NAME`, `FONT_SIZE`, `ACTION_TYPE`, …, as some Excel versions do) failed with *XMLA Execute unparse results error* after it had run. All the standard cell properties are returned now, and unknown ones are ignored.
- **MCP:** the dashboard tools are listed, and answer that the Dashboard application is not available on this server; dashboards are part of eMondrian Enterprise. The synthetic-catalog tools answer that their module is not installed.

## 2026.10.22

Server `10.0.47` · modules `0.0.0.54` · web tools `1.2.0` · entry `1.3.2`

Docker image `emondrian/emondrian:10.0.47` (engine 9.3.0-emondrian.47). OLAP Client `1.2.0`; the Schema Editor and Catalog Editor stay `1.1.0`.

### New

- **Server metrics.** The server exports Prometheus metrics at `/metrics`: active users, open sessions and connections per user and catalog, queries started, finished and failed per cube and user, execution times, result sizes, engine errors by class, and the JVM's own metrics. The front door does not expose the endpoint (it carries user names); scrape it on the Docker network. The [demo repository](https://github.com/eMondrian/emondrian-demo) has a Prometheus and Grafana overlay with a ready *User activity* dashboard.
- **OLAP Client understands eMondrian's MDX.** `x IS EMPTY`, `x IN set`, `x NOT IN set`, `s MATCHES pattern`, `||` for strings, numbers like `1.` and the `BEFORE_AND_AFTER` flag no longer show as syntax errors. The server's own functions (`Cache`, `Percentile`, `Parameter`, `CurrentDateMember`, the extra VBA functions, member properties such as `.Caption`) and its forms of `StrToSet`, `StrToTuple`, `StrToMember`, `Levels` and `NonEmptyCrossJoin` are known to validation, completion and hover.

### Improved

- **OLAP Client warns before the server fails:** a comma between WITH clauses, `CALCULATED MEMBER`, an axis given as an expression, functions in DRILLTHROUGH RETURN, single quotes after `AS`, `TRUE`/`FALSE`, the `TYPED`, `CONSTRAINED` and `RECURSIVE` flags, cell properties the server cannot return, `+` on strings, `CURRENTCUBE`, `@param`, CAST types the server lacks, and a function used as a method or a property (`set.Order(…)`, `member.Children()`).

### Fixed

- **Server:** DRILLTHROUGH from an aggregate member, and `NON EMPTY` over a member's children joins the level's table (engine 9.3.0-emondrian.46).
- **Entry:** the `/dashboard/mcp` route is gone; the only MCP endpoint is `/emondrian/mcp`.

## 2026.10.21.1

Server `10.0.45` · modules `0.0.0.54` · web tools `1.1.1` · entry `1.3.1`

OLAP Client `1.1.1`; the Schema Editor and Catalog Editor stay `1.1.0`.

### Fixed

- **OLAP Client:** expanding a member in the pivot no longer hangs on "Running the query…" when the cube was chosen while the client was still starting.

## 2026.10.21

Server `10.0.45` · modules `0.0.0.54` · web tools `1.1.0` · entry `1.3.1`

Docker image `emondrian/emondrian:10.0.45`, which `latest` now points to.

### Improved

- **Power BI reports built by AI agents** cover more of what Power BI Desktop writes: slicers set to the latest month, display units on data labels, sort and several visual filters, matrices with several Rows or Columns fields (collapsed or expanded), and charts drilled down a hierarchy.
- **OLAP Client: a new pivot table.** Drill down and up from a member, expand or collapse all, and a busy state while a query runs. Columns keep their width while you scroll and can be resized; arrow keys move between cells, and a cell menu copies values or rows. The table can be downloaded as CSV.
- **Entry page:** AI agents connect over Streamable HTTP at `/emondrian/mcp` (SSE stays at `/emondrian/mcp/sse` for older clients), and the evaluation key is requested at [emondrian.com/license](https://emondrian.com/license).

### Fixed

- **Several members in the slicer:** a query with a set in its WHERE clause, such as `{[Airline].[AA], [Airline].[DL]}`, no longer returns empty axes.
- **Power BI cross-highlighting** from a chart with a visual Top N no longer fails the other visuals.
- **Entry after a partial restart:** the entry looks containers up on every request, so `/xmla`, MCP and the tools keep working after `docker compose up -d` recreates some of them.
- **OnTime sample:** On-Time Rate is empty where Flights is empty, instead of showing 100%.

## 2026.10.18

Server `10.0.44` · modules `0.0.0.52` · web tools `1.0.1` · entry `1.2.1`

Docker image `emondrian/emondrian:10.0.44`, which `latest` now points to.

### New

- **Power BI reports built by AI agents.** The MCP tools `make_project`, `make_page`, `make_visual`, `arrange_page` and `validate_report` write a Power BI project (PBIP) with a live connection to your eMondrian model, including sort, Top N, filters and slicer selections. They need a key with DAX and MCP.

### Fixed

- **Power BI matrices with subtotals** render, with the total last, filtered by a slicer to the selected columns only, in about 1 second instead of 36.
- **Ratio grand totals** in Power BI are recomputed instead of summed.
- **Measure format strings** reach Power BI, and named formats (Standard, Currency, …) are expanded.
- **Several visuals opening at once** no longer fail one of them with "Session with id … already exists".

## 2026.10.16.1

Server `10.0.43` · modules `0.0.0.50` · web tools `1.0.1` · entry `1.2.1`

### Improved

- **`get_csdl`** returns the CSDL `<Schema>` element instead of the XML/A row around it.
- **Licence errors** say what to do instead of naming a path inside the container; the file names and reasons are in `logs/mondrian.log`.
- **README:** a Licence keys section. Keep exactly one valid `.lic` file in `modules/`: the server uses the first one that validates.

## 2026.10.16

Server `10.0.43` · modules `0.0.0.49` · web tools `1.0.1` · entry `1.2.1`

### New

- **MCP tool `get_csdl`:** a cube's model as Power BI sees it (CSDL), with the field names a Power BI report has to use. Read-only; needs a key with DAX and MCP.

### Fixed

- A rare race when the MCP servlet shut down while answering a CSDL request.

## 2026.10.14

Server `10.0.43` · modules `0.0.0.48` · web tools `1.0.1` · entry `1.2.1`

### Improved

- **Web tools:** the OLAP Client, Schema Editor, Catalog Editor and entry page use navy tints for quiet text and outlines, as on emondrian.com.

## 2026.10.13

Server `10.0.43` · modules `0.0.0.48` · web tools `1.0` · entry `1.0`

### New

- **MCP over Streamable HTTP** at `/emondrian/mcp` (with or without a trailing slash). HTTP+SSE at `/emondrian/mcp/sse` stays for older clients. Same tools on both.
- **`list_catalogs` names each catalog's cubes,** so an agent writes `FROM [OnTime (attributes)]` instead of guessing.

### Fixed

- **`NON EMPTY` on an attribute-mapped level** (for example `NON EMPTY {Descendants([Time].[2025],[Time].[Month])}` on OnTime) failed on ClickHouse with Code 81.
- **MCP error bodies** no longer contain Java stack traces.

### Removed

- **MCP tools `list-cubes` and `run-mdx-query`.** Use `list_catalogs` and `execute_query`. The `emondrian.mcp.connectString` property is gone from `docker-compose.yml`.

## 2026.10.10

Server `10.0.42` · modules `0.0.0.47` · web tools `1.0` · entry `1.0` · tag `v10.0.42`

Mostly fixes, all of them found while building Power BI reports against a live cube.

### Fixed

- **`TopCount` and `BottomCount` on ClickHouse** returned every member instead of the N asked for.
- **A page with many visuals** failed on a random subset of them, differently on each refresh.
- **A slicer on a column that contains empty values** always failed.
- **A measure whose name starts with `#`** stopped Power BI from loading the model.

### New

- **Read-only MCP.** `-Demondrian.mcp.readOnly=true` leaves the tools that write schemas, register catalogs, read logs or report server properties unregistered. This is how the public demo runs.

## 2026.10.09

Server `10.0.39` · modules `0.0.0.46` · web tools `1.0` · entry `1.0`

### New

- **MCP tool `save_catalog`** registers a catalog in `datasources.xml` and writes its schema file in one call; the catalog is usable without a restart.

### Fixed

- **`run-mdx-query`** returned an object description instead of the query result.
- **Licence keys** are checked for their start date as well as their expiry.

## Earlier

Releases up to server `10.0.39` and web tools `1.0` are described in the [release notes](https://docs.emondrian.com/reference/releases).
