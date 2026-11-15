# Authentication

eMondrian Community runs behind an authentication gateway (OpenResty) with Keycloak, which checks
user names and passwords. **It starts with authentication off**, so that you can try everything
without logging in; switch it on when other people get access.

```
Browser, Excel, Power BI, MCP agents
              │  EMONDRIAN_PORT (80)
              ▼
     auth_gateway ── checks the login with ──▶ Keycloak ──▶ its own users
              │                                         └─▶ Active Directory / LDAP
              ▼  user name and groups
     eMondrian, OLAP client, editors, dashboards
```

The gateway is the only published port. Browsers log in on a login page; Excel, Power BI, scripts
and MCP agents send the user name and password with every request (HTTP Basic). eMondrian receives
the user name and the user's **groups**, never the password; eMondrian decides what they may
see and do (see [Roles](#roles)).

## Switching authentication on and off

```bash
./auth/scripts/authentication.sh on       # logins required
./auth/scripts/authentication.sh off      # everybody gets in without logging in
./auth/scripts/authentication.sh status
```

On Windows: `.\auth\scripts\authentication.ps1 on` (or `off`, `status`).

Nothing restarts and no data changes: the script writes the switch, `auth/state/open_access.json`,
which the gateway reads on each request, and records the same in `open_access` of
`auth/identity.yml` (which also names the guest and its groups). From eMondrian modules 0.0.0.106
the MCP tools `get_open_access` and `set_open_access` switch it too: anybody may switch
authentication on, only a Keycloak administrator of the realm may switch it off. With authentication **off**, everybody who reaches the port is the user `guest` with
all rights (`/emondrian-admins`); Excel connects with *Windows authentication* and no password, and
a saved user name and password are ignored. Use it on your own machine or a trusted network only.

With authentication **on**, the first user is `admin` with the password `0`. Open the main page
in the browser, log in, and choose a new password (at least 8 characters). Until then the
password works nowhere else, Excel included.

Before switching on for other people:

1. **The address.** `PUBLIC_URL` in `.env` is the address users open (`http://localhost` after
   setup). Set it to the server's name, e.g. `PUBLIC_URL=http://bi.example.com`, then run
   `docker compose up -d`. It must use the port of `EMONDRIAN_PORT`.
2. **HTTPS.** Without it passwords travel unencrypted, and the login page works in a browser on
   the server itself only (Keycloak's cookies need HTTPS on other machines). See [HTTPS](#https).
3. **Users and roles**, below.

## Users

`auth/identity.yml` says where users come from; setup writes
it on the first run, `auth/identity.example.yml` shows every setting. After changing it, run
`./auth/scripts/apply-config.sh`: it takes effect at once, nobody is logged out. Test a user (no
password needed) with `./auth/scripts/check-config.sh <user>`: it shows whether the user may log
in and the groups eMondrian receives.

The two kinds of users below can be combined, e.g. your Active Directory plus the local `admin`
for the day the directory is unreachable.

### Users kept in Keycloak

The `local` source in `identity.yml`. Manage these users in Keycloak's admin console:

- Open `PUBLIC_URL/auth/admin/` and log in as `admin` with `KEYCLOAK_ADMIN_PASSWORD` from `.env`.
  This is Keycloak's own administrator, not the eMondrian user `admin`. The console opens only
  from the addresses in `KEYCLOAK_ADMIN_ALLOW` (this machine and private networks after setup).
- Switch to the realm **emondrian** → *Users* → *Add user*. Under *Credentials*, set a password;
  leave *Temporary* on to make the user choose their own at the first login (in the browser).
- Under *Groups*, join `emondrian-admins`, `emondrian-editors` or `emondrian-viewers`.

Users listed under `users:` in `identity.yml` are created when missing, with the initial password
from the file named there (in `auth/secrets/`); existing users are left alone.

**Members of `emondrian-admins` are also administrators of the realm in Keycloak.** Setup gives
the group Keycloak's role `realm-admin` (of the client `realm-management`), and every apply adds it
again if it is missing. With it, they manage users and groups through the MCP tools and may read
and change the security file and switch authentication off. It is Keycloak's full administration
of the realm: users, groups, clients, identity providers and token settings. Keycloak gives a
group's roles to the members of its subgroups too, while eMondrian does not count them as
`/emondrian-admins` members, so `emondrian-admins` must have no subgroups: while it has any, apply
does not give it `realm-admin` (it takes it back if it is there) and logs an ERROR naming them,
and the MCP tool `create_group` refuses to create one under it. Keycloak's own administrator
(`KEYCLOAK_ADMIN_USER` in `.env`) is never affected.

### Active Directory or LDAP

Users stay in the directory; Keycloak checks their password there at every login and copies
nothing. Add a source to `identity.yml`:

```yaml
sources:
  - name: corp-ad
    type: ldap
    preset: active-directory      # or openldap
    url: ldaps://dc01.corp.example.com:636
    bind_dn: CN=svc_emondrian,OU=Service Accounts,DC=corp,DC=example,DC=com
    bind_password_file: ad-bind-password
    users_dn: OU=Users,DC=corp,DC=example,DC=com
    groups_dn: OU=Groups,DC=corp,DC=example,DC=com
    allowed_groups: [BI-Users, BI-Admins]   # only their members may log in
  - name: local                             # keep the local admin, or remove this source
    type: local
    …
```

and in `auth/emondrian/mondrian.properties`, the AD groups next to the Keycloak groups (see
[Roles](#roles)):

```properties
mondrian.security.schema.write=/emondrian-admins,/emondrian-editors,/BI-Admins
mondrian.security.schema.read=/emondrian-viewers,/BI-Users
mondrian.security.database.manage=/emondrian-admins,/BI-Admins
mondrian.security.database.read=/emondrian-editors,/emondrian-viewers,/BI-Users
mondrian.security.logs.read=/emondrian-admins,/BI-Admins
mondrian.security.license.manage=/emondrian-admins,/BI-Admins
```

1. A service account that may read users and groups (`bind_dn`). Put its password into
   `auth/secrets/ad-bind-password`: the password only, no line break, readable by you only.

   ```bash
   install -m 600 /dev/null auth/secrets/ad-bind-password
   read -rs -p 'bind password: ' P && printf '%s' "$P" > auth/secrets/ad-bind-password; unset P; echo
   ```

2. The CA certificate that signed the domain controllers' LDAPS certificate, as a PEM file in
   `auth/secrets/truststore/` (e.g. `corp-ca.pem`).
3. If the domain controller's name is not in DNS: `LDAP_EXTRA_HOST=dc01.corp.example.com:10.0.0.10`
   in `.env`, then `docker compose up -d`.
4. `./auth/scripts/apply-config.sh`, then `./auth/scripts/check-config.sh jdoe`; after editing
   `mondrian.properties`, `docker compose up -d --force-recreate eMondrian`.

Users log in with their account name (`jdoe`); `attributes: username_attribute: userPrincipalName`
switches to `jdoe@corp.example.com`. Nested groups count. A disabled account cannot log in.

### External identity providers (Entra ID, Google, Okta, ADFS, SAML)

A source of `type: oidc` or `type: saml` in `identity.yml` adds a button to the login page (see the
commented example there). **Every user must already have an account in Keycloak**: signing in
through a provider never creates one, and somebody the provider knows but Keycloak does not is
refused with a page saying to ask the administrator (Keycloak answers 401). With
`link_by_email: true` on a source, a sign-in is linked to the account with the same e-mail address
(or user name): create the account (admin console, or the MCP tool `create_user` with the
person's e-mail) and the person signs in with the provider. Set it only for a provider you trust to
verify e-mail addresses, such as your own Entra ID tenant; never for one where anybody can make an
account with any address. Without it, only accounts an administrator linked by hand are let in
(*Users* → the user → *Identity provider links*). Users of Active Directory or LDAP count as being
in Keycloak: they are looked up in the directory.

These users have no password in Keycloak, so they sign in through the provider in the browser,
with MCP OAuth and with the device code, and **Excel and Power BI need a personal access token**
(`PUBLIC_URL/account/tokens`), checked against the account at every use. The provider's groups
(`groups_claim`, SAML `groups_attribute`) reach eMondrian under the source's name,
`/<source>/<group>` (`/entra/BI-Users`; a `/`, `,` or `%` in a group name is written `%2F`,
`%2C`, `%25`), so a provider can never grant a Keycloak group or a server group: a provider group
called `emondrian-admins` is `/entra/emondrian-admins`. A personal token gets them as of the
user's last login through the provider; disabling the account in Keycloak stops its tokens within
30 seconds.

## Roles

Every user who logs in gets in. The gateway passes the user name and the user's groups on to
eMondrian (`X-Forwarded-User`, `X-Forwarded-Groups`): the groups of Keycloak and of your
directory, each by its **full path**, top-level groups included: `/emondrian-admins`,
`/Sales/WebAppUsers`. A group is never sent by its own name, so that two groups of the same name
under different parents (`/A/Team`, `/B/Team`) are never taken for each other. Name a group the
same way in a right and in a schema's `<RoleMember>`: `<RoleMember name="/Sales/WebAppUsers"/>`.
A plain name (`emondrian-admins`) matches no group. Membership is not inherited: a right for
`/Sales` does not reach the members of `/Sales/WebAppUsers`. What a user may see and do is decided by eMondrian.

Every request also carries `X-Forwarded-Access-Token`: the user's Keycloak access token, with
which a service behind the gateway may call Keycloak as that user (what the user may do there is
Keycloak's decision), also when one service calls another, e.g. from XML/A to MCP. It is there
when the user logged in with a user name and password, an OAuth token or a browser session, not
with a personal access token or with authentication off. On the MCP endpoint (`/emondrian/mcp`)
the gateway adds `X-Forwarded-Client: mcp`, so that eMondrian can tell an AI agent from a person.
The gateway overwrites every one of these headers, whatever the client sent.

On the requests it forwards to eMondrian (XML/A, the REST API, the logs page, MCP) the gateway
also sends `X-Forwarded-Secret`, the value of `EMONDRIAN_FORWARDED_SECRET` in `.env`, which setup
generates for each install. eMondrian believes the user and groups only on a request carrying it,
and refuses (403) a request that names a user without it: so nothing that reaches eMondrian around
the gateway (this machine, another container) can pose as a user. The Dashboard receives it too
and answers nothing without it (`GATEWAY_ONLY`), so it cannot be used around the gateway either;
eMondrian's MCP tools send it when they call the Dashboard. The web tools never receive it. To change it, edit the value in `.env` and run `docker compose up -d`; the
gateway and eMondrian restart with the new one.

**Server rights** are in `auth/emondrian/mondrian.properties`, one line per right naming the users
and groups that hold it. Out of the box they name the three groups setup creates in Keycloak:

| Group | May |
|---|---|
| `/emondrian-admins` | everything: edit schemas and catalogs, read logs, install the licence key |
| `/emondrian-editors` | edit schemas, read the catalog registry |
| `/emondrian-viewers` | read schemas and the catalog registry |

Querying data needs no server right. A user in none of these groups (or of the groups you add)
logs in and queries data, but cannot read or edit schemas, read logs or install a licence key.
Add your directory's groups to the lines, e.g. `mondrian.security.schema.read=/emondrian-viewers,/BI-Users`,
then `docker compose up -d --force-recreate eMondrian`: the server reads the file at startup only.
A higher right includes the lower (`schema.write` includes `schema.read`). The old keys
`mondrian.security.role.<role>.*` of server 10.0.86 and earlier are not read any more: with one of
them left in the file the server denies every right. Do not set `-Dmondrian.security.*` options
on `JAVA_TOOL_OPTIONS` in `.env` (`.env.example` shows them for a server without authentication):
they override this file.

**Which data a user sees** is set in the schemas. A `<Role>` applies to the users and groups named
in its `<RoleMember>` elements:

```xml
<Role name="Sales EMEA">
    <SchemaGrant access="none">
        <CubeGrant cube="Sales" access="all"/>
    </SchemaGrant>
    <RoleMember name="/Sales-EMEA"/>     <!-- a group of Keycloak or of your directory, by its path -->
    <RoleMember name="jdoe"/>            <!-- or a user -->
</Role>
```

A user matching no role gets the schema's `defaultRole`, and **without a `defaultRole` that is
full access**. Give a schema a restrictive `defaultRole` before relying on roles.

## Connecting

| Client | With authentication on |
|---|---|
| Browser | Login page; `PUBLIC_URL/logout` logs out (also of Keycloak). Pages are not kept by the browser, and a page's own request after the session has ended gets 401 without a password dialog (`login_required`; reload to sign in) |
| Excel | *Data → Get Data → From Analysis Services*, server `PUBLIC_URL/xmla`, *Use the following User Name and Password* |
| Power BI | *Analysis Services*, server `PUBLIC_URL/xmla`, then *Database* (user name and password) |
| Scripts | `curl -u jdoe https://bi.example.com/xmla …` |
| MCP agents | the header `Authorization: Basic <base64 of user:password>` |

Claude Code, for example:

```bash
claude mcp add --transport http emondrian https://bi.example.com/emondrian/mcp \
    --header "Authorization: Basic $(printf '%s' 'jdoe:password' | base64)"
```

A login checked once is reused for 5 minutes (`policy.basic_cache`), but never past 30 seconds
before its own access token expires (5 minutes by default), so disabling a user, a new password
or a removed group reaches Excel and Power BI within one token lifetime.

A **personal access token** (`PUBLIC_URL/account/tokens`, used as the password or as a Bearer
token) follows its owner: at each use, at most every 30 seconds, the gateway asks Keycloak whether
the owner still exists and is enabled and which groups it is in now, with its own service account
`emondrian-gateway-lookup` (Keycloak's `view-users` only). A deleted or disabled owner's tokens
stop working and a changed group applies within 30 seconds. While Keycloak cannot be reached, a
token whose last check is older than 30 seconds is refused. Tokens last 90 days unless their owner
chooses otherwise (at most 365, `personal_tokens` in `identity.yml`). A user who signs in through an
external identity provider and is not kept in Keycloak cannot use personal tokens (see *External
identity providers* above).

## HTTPS

HTTPS is on once `auth/secrets/tls/` holds:

- `tls.crt` — the server certificate followed by its intermediate CA certificates (PEM). Its
  names must include the host of `PUBLIC_URL`;
- `tls.key` — its private key (PEM, unencrypted, `chmod 600`).

Then set in `.env` `PUBLIC_URL=https://bi.example.com` and `EMONDRIAN_TLS_PORT=443` (setup leaves
it at `0`, a random unused port), and run `docker compose up -d`. Port `EMONDRIAN_PORT` then only
redirects to HTTPS. Excel and Power BI accept only certificates Windows trusts: use one of your
organisation's CA or a public one, not a self-signed one.

**Once authentication is on, MCP agents that log in with OAuth from another machine need HTTPS**
(with authentication off nobody logs in, so it does not arise). `authentication.sh on`, the MCP
tool `set_open_access` and setup say so when `PUBLIC_URL` is `http://` and not `localhost`. Claude Code and other MCP
clients refuse to send a login to a token endpoint over plain HTTP, except on `localhost`: over
`http://` the OAuth login of `/emondrian/mcp` (and `/emondrian/mcp/sse`) works only from a client on
the server itself, and only with `PUBLIC_URL=http://localhost:…`, since every address in the login
metadata is built from `PUBLIC_URL`. A user name and password (`Authorization: Basic`, see
[Connecting](#connecting)) work over HTTP too, but travel unencrypted. For a test with a self-signed
certificate, give the client its certificate: for Claude Code, `NODE_EXTRA_CA_CERTS=<file>.crt`.

With TLS ending at a reverse proxy in front of the gateway, list the proxy in
`GATEWAY_REAL_IP_FROM` (`.env`); `PUBLIC_URL` is then the proxy's `https://` address.

## Settings

`policy:` in `identity.yml` (defaults shown in `identity.example.yml`): browser session length,
the lockout after failed logins (5 failures block a user for 1 minute, growing to 15), the
password rule for users kept in Keycloak, and the Basic cache.

| Changed | Then |
|---|---|
| `auth/identity.yml`, or a file it names | `./auth/scripts/apply-config.sh` |
| `.env` (`PUBLIC_URL`, ports, …) | `docker compose up -d` |
| `auth/emondrian/mondrian.properties` | `docker compose up -d --force-recreate eMondrian` |
| A renewed certificate | replace the files, `docker compose restart auth_gateway` |

`docker compose …` includes the authentication services through `COMPOSE_FILE` in `.env`.

## Logs

Every request is logged by the gateway with its user, roles and how they logged in
(`method="basic"`, `"session"`, `"open"`, …):

```bash
docker compose logs -f auth_gateway
```

Keycloak's own log (`docker compose logs keycloak`) shows refused logins and lockouts.

## Notes

- `docker compose down -v` deletes the volumes, and with them the users kept in Keycloak.
- The dashboards' server reads data from eMondrian directly, not as the logged-in user: everybody
  who may open `/dashboard/` sees every dashboard with all its data. Turn them off with
  `ENABLE_SERVICE_DASHBOARD=false` where data roles matter.
- Secrets are in `.env` and `auth/secrets/`; keep both out of version control and backups others
  can read.
