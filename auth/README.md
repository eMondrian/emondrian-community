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
              ▼  user name and eMondrian roles
     eMondrian, OLAP client, editors, dashboards
```

The gateway is the only published port. Browsers log in on a login page; Excel, Power BI, scripts
and MCP agents send the user name and password with every request (HTTP Basic). eMondrian receives
the user name and the user's **eMondrian roles**, never the password.

## Switching authentication on and off

```bash
./auth/scripts/authentication.sh on       # logins required
./auth/scripts/authentication.sh off      # everybody gets in without logging in
./auth/scripts/authentication.sh status
```

On Windows: `.\auth\scripts\authentication.ps1 on` (or `off`, `status`).

Nothing restarts and no data changes: the script edits `open_access` in `auth/identity.yml` and
applies it. With authentication **off**, everybody who reaches the port is the user `guest` with
all rights (`emondrian-admins`); Excel connects with *Windows authentication* and no password, and
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

`auth/identity.yml` says where users come from and which eMondrian roles they get; setup writes
it on the first run, `auth/identity.example.yml` shows every setting. After changing it, run
`./auth/scripts/apply-config.sh`: it takes effect at once, nobody is logged out. Test a user (no
password needed) with `./auth/scripts/check-config.sh <user>`: it shows whether the user may log
in, their groups and the eMondrian roles they get.

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
roles:
  mapping:
    emondrian-admins:  [emondrian-admins, BI-Admins]
    emondrian-viewers: [emondrian-viewers, emondrian-editors, emondrian-admins, BI-Users, BI-Admins]
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
4. `./auth/scripts/apply-config.sh`, then `./auth/scripts/check-config.sh jdoe`.

Users log in with their account name (`jdoe`); `attributes: username_attribute: userPrincipalName`
switches to `jdoe@corp.example.com`. Nested groups count. A disabled account cannot log in.

## Roles

eMondrian works with three server roles; `roles.mapping` in `identity.yml` says which groups hold
them, so nothing else needs changing for your group names:

| Role | May |
|---|---|
| `emondrian-admins` | everything: edit schemas and catalogs, read logs, install the licence key |
| `emondrian-editors` | edit schemas, read the catalog registry |
| `emondrian-viewers` | query data, read schemas and the catalog registry |

Users holding no role of `roles.mapping` cannot log in (403). The permissions themselves are in
`auth/emondrian/mondrian.properties` (`mondrian.security.role.*`).

**Which data a user sees** is set in the schemas. A `<Role>` applies to the users and roles named
in its `<RoleMember>` elements; add your own role names to `roles.mapping` the same way:

```xml
<Role name="Sales EMEA">
    <SchemaGrant access="none">
        <CubeGrant cube="Sales" access="all"/>
    </SchemaGrant>
    <RoleMember name="Sales EMEA"/>      <!-- roles.mapping: Sales EMEA: [Sales-EMEA, user:jdoe] -->
</Role>
```

A user matching no role gets the schema's `defaultRole`, and **without a `defaultRole` that is
full access**. Give a schema a restrictive `defaultRole` before relying on roles.

## Connecting

| Client | With authentication on |
|---|---|
| Browser | Login page; `PUBLIC_URL/logout` logs out |
| Excel | *Data → Get Data → From Analysis Services*, server `PUBLIC_URL/xmla`, *Use the following User Name and Password* |
| Power BI | *Analysis Services*, server `PUBLIC_URL/xmla`, then *Database* (user name and password) |
| Scripts | `curl -u jdoe https://bi.example.com/xmla …` |
| MCP agents | the header `Authorization: Basic <base64 of user:password>` |

Claude Code, for example:

```bash
claude mcp add --transport http emondrian https://bi.example.com/emondrian/mcp \
    --header "Authorization: Basic $(printf '%s' 'jdoe:password' | base64)"
```

A login checked once is reused for 5 minutes (`policy.basic_cache`), so removing a user's
access reaches Excel and Power BI after at most that long.

## HTTPS

HTTPS is on once `auth/secrets/tls/` holds:

- `tls.crt` — the server certificate followed by its intermediate CA certificates (PEM). Its
  names must include the host of `PUBLIC_URL`;
- `tls.key` — its private key (PEM, unencrypted, `chmod 600`).

Then set in `.env` `PUBLIC_URL=https://bi.example.com` and `EMONDRIAN_TLS_PORT=443` (setup leaves
it at `0`, a random unused port), and run `docker compose up -d`. Port `EMONDRIAN_PORT` then only
redirects to HTTPS. Excel and Power BI accept only certificates Windows trusts: use one of your
organisation's CA or a public one, not a self-signed one.

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
