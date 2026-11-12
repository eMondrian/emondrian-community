"""Applies auth/identity.yml to Keycloak and to the auth gateway.

    configurator.py apply          make Keycloak match identity.yml, write the gateway's config
    configurator.py check [USER]   test every source; with USER, look the user up and show the
                                   groups and eMondrian roles the gateway would forward

`apply` is idempotent: it creates or updates what identity.yml describes and removes LDAP
sources and identity providers (with their mappers) that identity.yml no longer lists.
identity.yml is the source of truth for the realm's user federation and identity providers;
the rest of the realm comes from realm-emondrian.json.

Environment: KEYCLOAK_URL, KEYCLOAK_REALM, KEYCLOAK_ADMIN_USER, KEYCLOAK_ADMIN_PASSWORD,
PUBLIC_URL, IDENTITY_FILE (default /config/identity.yml), SECRETS_DIR (default /secrets),
GATEWAY_CONFIG (default /generated/gateway.json).
"""
import glob
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import yaml

from presets import LDAP_PRESETS, OIDC_PRESETS, PROXY_PRESETS, SAML_PRESETS

KEYCLOAK_URL = os.environ.get("KEYCLOAK_URL", "http://keycloak:8080/auth").rstrip("/")
REALM = os.environ.get("KEYCLOAK_REALM", "emondrian")
PUBLIC_URL = os.environ.get("PUBLIC_URL", "").rstrip("/")
IDENTITY_FILE = os.environ.get("IDENTITY_FILE", "/config/identity.yml")
SECRETS_DIR = os.environ.get("SECRETS_DIR", "/secrets")
GATEWAY_CONFIG = os.environ.get("GATEWAY_CONFIG", "/generated/gateway.json")

USER_STORAGE = "org.keycloak.storage.UserStorageProvider"
LDAP_MAPPER = "org.keycloak.storage.ldap.mappers.LDAPStorageMapper"
# local: users kept in Keycloak itself (quick start, small installations); the only source whose
# users Keycloak stores
SOURCE_TYPES = ("ldap", "oidc", "saml", "local")
# broker: Keycloak authenticates against the sources; oidc-direct: the gateway is a client of the
# customer's OpenID provider itself; trusted-proxy: the customer's SSO proxy in front of the gateway
# has authenticated the user. The last two need no Keycloak.
MODES = ("broker", "oidc-direct", "trusted-proxy")
TRUSTSTORE_DIR = os.environ.get("TRUSTSTORE_DIR", "/truststore")
# User attribute holding the groups an external identity provider sends; the `emondrian` client
# scope puts it into tokens as the claim of the same name
EXTERNAL_GROUPS = "external_groups"


class ConfigError(Exception):
    pass


def log(message):
    print(message, flush=True)


# --- Keycloak admin API ------------------------------------------------------------------------

class Keycloak:
    def __init__(self):
        self.token = None
        self.token_expires = 0

    def _login(self):
        body = urllib.parse.urlencode({
            "grant_type": "password", "client_id": "admin-cli",
            "username": os.environ["KEYCLOAK_ADMIN_USER"],
            "password": os.environ["KEYCLOAK_ADMIN_PASSWORD"],
        }).encode()
        req = urllib.request.Request(f"{KEYCLOAK_URL}/realms/master/protocol/openid-connect/token", body)
        with urllib.request.urlopen(req, timeout=30) as r:
            data = json.load(r)
        self.token = data["access_token"]
        self.token_expires = time.time() + data.get("expires_in", 60) - 10

    def wait(self, seconds=300):
        deadline = time.time() + seconds
        while True:
            try:
                self._login()
                return
            except (urllib.error.URLError, ConnectionError, KeyError) as e:
                if time.time() > deadline:
                    raise ConfigError(f"Keycloak at {KEYCLOAK_URL} is not reachable: {e}")
                time.sleep(3)

    def call(self, method, path, body=None, query=None):
        if time.time() > self.token_expires:
            self._login()
        url = f"{KEYCLOAK_URL}/admin/realms/{REALM}{path}"
        if query:
            url += "?" + urllib.parse.urlencode(query)
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data, method=method, headers={
            "Authorization": f"Bearer {self.token}", "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                raw = r.read()
                if r.status == 201 and not raw:
                    return r.headers.get("Location", "").rsplit("/", 1)[-1]
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", "replace")[:500]
            raise ConfigError(f"Keycloak {method} {path}: HTTP {e.code} {detail}") from None


# --- identity.yml ------------------------------------------------------------------------------

def load_identity():
    try:
        with open(IDENTITY_FILE) as f:
            identity = yaml.safe_load(f) or {}
    except FileNotFoundError:
        raise ConfigError(f"{IDENTITY_FILE} not found; copy auth/identity.example.yml to auth/identity.yml")
    identity.setdefault("mode", "broker")
    if identity["mode"] not in MODES:
        raise ConfigError(f"identity.yml: mode '{identity['mode']}' is not supported (supported: {', '.join(MODES)})")
    if identity["mode"] == "trusted-proxy":
        if identity.get("sources"):
            raise ConfigError("identity.yml: mode trusted-proxy takes no sources: the proxy has authenticated the user")
        if not isinstance(identity.get("trusted_proxy"), dict):
            raise ConfigError("identity.yml: mode trusted-proxy needs a trusted_proxy section")
        identity["sources"] = []
        return identity
    if not isinstance(identity.get("sources"), list) or not identity["sources"]:
        raise ConfigError("identity.yml: 'sources' must list at least one source")
    names = [s.get("name") for s in identity["sources"]]
    if any(not n for n in names) or len(set(names)) != len(names):
        raise ConfigError("identity.yml: every source needs a unique 'name'")
    for source in identity["sources"]:
        if source.get("type") == "local" and identity.get("mode", "broker") != "broker":
            raise ConfigError(f"source {source['name']}: type local needs mode: broker")
        if source.get("type") not in SOURCE_TYPES:
            raise ConfigError(f"source {source['name']}: type '{source.get('type')}' is not supported "
                              f"(supported: {', '.join(SOURCE_TYPES)})")
        if not all(c.isalnum() or c in "-_" for c in source["name"]):
            raise ConfigError(f"source {source['name']}: use letters, digits, - and _ in the name")
    default = (identity.get("login") or {}).get("default_source")
    if default and default not in [s["name"] for s in identity["sources"] if s["type"] != "ldap"]:
        raise ConfigError(f"login.default_source: '{default}' is not an oidc or saml source")
    if len([s for s in identity["sources"] if s["type"] == "local"]) > 1:
        raise ConfigError("identity.yml: at most one source of type local")
    if identity["mode"] == "oidc-direct":
        if len(identity["sources"]) != 1 or identity["sources"][0]["type"] != "oidc":
            raise ConfigError("identity.yml: mode oidc-direct takes exactly one source, of type oidc "
                              "(several sources or LDAP/SAML need mode: broker)")
        if default:
            raise ConfigError("identity.yml: login.default_source is for mode: broker")
    return identity


def sources_of(identity, *types):
    return [s for s in identity["sources"] if s["type"] in types]


def read_secret(source, key):
    name = source.get(key)
    if not name:
        raise ConfigError(f"source {source['name']}: '{key}' is required")
    path = os.path.join(SECRETS_DIR, name)
    try:
        with open(path, encoding="utf-8") as f:
            value = f.read().rstrip("\r\n")
    except OSError as e:
        raise ConfigError(f"source {source['name']}: cannot read {key} '{name}' in the secrets "
                          f"directory: {e.strerror}") from None
    if not value:
        raise ConfigError(f"source {source['name']}: {key} '{name}' is empty")
    return value


# --- LDAP sources ------------------------------------------------------------------------------

def ldap_settings(source):
    preset_name = source.get("preset", "active-directory")
    if preset_name not in LDAP_PRESETS:
        raise ConfigError(f"source {source['name']}: unknown preset '{preset_name}' "
                          f"(known: {', '.join(LDAP_PRESETS)})")
    settings = dict(LDAP_PRESETS[preset_name])
    settings.update(source.get("attributes") or {})
    for key in ("url", "bind_dn", "users_dn"):
        if not source.get(key):
            raise ConfigError(f"source {source['name']}: '{key}' is required")
    return settings


def user_filter(source, s):
    """Who may log in: the preset's base filter, membership in allowed_groups, and user_filter."""
    parts = [s["base_user_filter"]]
    allowed = source.get("allowed_groups") or []
    if allowed:
        if not source.get("groups_dn"):
            raise ConfigError(f"source {source['name']}: allowed_groups needs groups_dn")
        members = "".join(s["member_of_filter"].format(dn=f"{s['group_rdn']}={g},{source['groups_dn']}")
                          for g in allowed)
        parts.append(f"(|{members})" if len(allowed) > 1 else members)
    if source.get("user_filter"):
        parts.append(source["user_filter"])
    return parts[0] if len(parts) == 1 else "(&" + "".join(parts) + ")"


def ldap_component(source, s, realm_id, kerberos=None):
    def one(value):
        # Keycloak component config: lists of strings, booleans as "true"/"false"
        return [str(value).lower() if isinstance(value, bool) else str(value)]
    config = {
        "enabled": one(source.get("enabled", True)),
        "priority": one(source.get("priority", 0)),
        "vendor": one(s["vendor"]),
        "connectionUrl": one(source["url"]),
        "useTruststoreSpi": one("always"),
        "startTls": one(source.get("start_tls", False)),
        "connectionPooling": one(True),
        "connectionTimeout": one(source.get("connection_timeout_ms", 5000)),
        "readTimeout": one(source.get("read_timeout_ms", 10000)),
        "authType": one("simple"),
        "bindDn": one(source["bind_dn"]),
        "bindCredential": one(read_secret(source, "bind_password_file")),
        "usersDn": one(source["users_dn"]),
        "searchScope": one(2),
        "customUserSearchFilter": one(user_filter(source, s)),
        "userObjectClasses": one(s["user_object_classes"]),
        "usernameLDAPAttribute": one(s["username_attribute"]),
        "rdnLDAPAttribute": one(s["rdn_attribute"]),
        "uuidLDAPAttribute": one(s["uuid_attribute"]),
        "krbPrincipalAttribute": one(""),
        "pagination": one(True),
        # Users are looked up in the directory at every login and never copied into Keycloak
        "importEnabled": one(False),
        "editMode": one("READ_ONLY"),
        "syncRegistrations": one(False),
        "trustEmail": one(False),
        "validatePasswordPolicy": one(False),
        "allowKerberosAuthentication": one(False),
        "useKerberosForPasswordAuthentication": one(False),
        "cachePolicy": one("DEFAULT"),
        "batchSizeForSync": one(1000),
        "fullSyncPeriod": one(-1),
        "changedSyncPeriod": one(-1),
    }
    if kerberos and kerberos["source"] == source["name"] and kerberos["browser"]:
        # Browser login with the Windows session (SPNEGO) on Keycloak's login page
        config.update({
            "allowKerberosAuthentication": one(True),
            "kerberosRealm": one(kerberos["kerberos_realm"]),
            "serverPrincipal": one(kerberos["service_principal"]),
            "keyTab": one(f"/opt/keycloak/conf/kerberos/{kerberos['keytab_file']}"),
        })
    return {"name": source["name"], "providerId": "ldap", "providerType": USER_STORAGE,
            "parentId": realm_id, "config": config}


def ldap_mappers(source, s):
    def attribute(name, ldap_attribute, model_attribute, mandatory=False, always_read=True):
        return {"name": name, "providerId": "user-attribute-ldap-mapper", "config": {
            "ldap.attribute": [ldap_attribute], "user.model.attribute": [model_attribute],
            "read.only": ["true"], "always.read.value.from.ldap": [str(always_read).lower()],
            "is.mandatory.in.ldap": [str(mandatory).lower()]}}

    mappers = [
        attribute("username", s["username_attribute"], "username", mandatory=True, always_read=False),
        attribute("first name", s["first_name_attribute"], "firstName"),
        attribute("last name", s["last_name_attribute"], "lastName"),
        attribute("email", s["email_attribute"], "email"),
    ]
    if s["account_controls_mapper"]:
        mappers.append({"name": "account controls", "providerId": "msad-user-account-control-mapper",
                        "config": {}})
    if source.get("groups_dn"):
        mappers.append({"name": "groups", "providerId": "group-ldap-mapper", "config": {
            "mode": ["READ_ONLY"],
            "groups.dn": [source["groups_dn"]],
            "groups.path": ["/"],
            "group.name.ldap.attribute": [s["group_name_attribute"]],
            "group.object.classes": [s["group_object_classes"]],
            "groups.ldap.filter": [source.get("groups_filter", "")],
            "preserve.group.inheritance": ["false"],
            "ignore.missing.groups": ["false"],
            "membership.ldap.attribute": [s["membership_attribute"]],
            "membership.attribute.type": [s["membership_attribute_type"]],
            "membership.user.ldap.attribute": [s["username_attribute"]],
            "memberof.ldap.attribute": ["memberOf"],
            "user.roles.retrieve.strategy": [s["groups_strategy"]],
            "mapped.group.attributes": [""],
            "drop.non.existing.groups.during.sync": ["false"],
        }})
    return mappers


def upsert_children(kc, parent_id, desired):
    """Makes the mappers of an LDAP provider exactly `desired` (matched by name)."""
    existing = {c["name"]: c for c in kc.call("GET", "/components", query={"parent": parent_id})}
    for mapper in desired:
        body = dict(mapper, parentId=parent_id, providerType=LDAP_MAPPER)
        current = existing.pop(mapper["name"], None)
        if current is None:
            kc.call("POST", "/components", body)
        elif current["providerId"] != mapper["providerId"]:
            kc.call("DELETE", f"/components/{current['id']}")
            kc.call("POST", "/components", body)
        elif current.get("config") != body["config"]:
            kc.call("PUT", f"/components/{current['id']}", dict(body, id=current["id"]))
    for leftover in existing.values():
        kc.call("DELETE", f"/components/{leftover['id']}")


def apply_ldap_sources(kc, identity, realm_id):
    # Build every source first, so that a mistake in any of them (missing secret, unknown preset)
    # stops before Keycloak is changed at all
    desired = []
    for source in sources_of(identity, "ldap"):
        s = ldap_settings(source)
        desired.append((source, ldap_component(source, s, realm_id, kerberos_settings(identity)),
                        ldap_mappers(source, s)))

    existing = {c["name"]: c for c in kc.call("GET", "/components", query={"type": USER_STORAGE})
                if c["providerId"] == "ldap"}
    for source, component, mappers in desired:
        current = existing.pop(source["name"], None)
        if current is None:
            kc.call("POST", "/components", component)
            current = kc.call("GET", "/components", query={"type": USER_STORAGE, "name": source["name"]})[0]
            log(f"source {source['name']}: created ({source.get('preset', 'active-directory')})")
        else:
            kc.call("PUT", f"/components/{current['id']}", dict(component, id=current["id"]))
            log(f"source {source['name']}: updated ({source.get('preset', 'active-directory')})")
        upsert_children(kc, current["id"], mappers)
    for name, stale in existing.items():
        kc.call("DELETE", f"/components/{stale['id']}")
        log(f"source {name}: removed (no longer in identity.yml)")


# --- local users (Keycloak's own) ----------------------------------------------------------------

def local_user_password(source, user):
    if user.get("initial_password_file"):
        return read_secret({"name": f"{source['name']}/{user['username']}",
                            "initial_password_file": user["initial_password_file"]}, "initial_password_file")
    if user.get("initial_password") is not None:
        return str(user["initial_password"])
    raise ConfigError(f"source {source['name']}: user {user['username']} needs initial_password or initial_password_file")


def apply_local_users(kc, identity):
    """Creates the users listed in a local source when they do not exist yet, with a temporary
    password that must be changed at the first login, and their groups. Existing users are left
    alone: passwords, groups and further users are managed in Keycloak's admin console."""
    for source in sources_of(identity, "local"):
        users = source.get("users") or []
        groups = {g["name"]: g for g in kc.call("GET", "/groups", query={"briefRepresentation": "true", "max": "1000"})}
        wanted = {g for u in users for g in (u.get("groups") or [])} | set(source.get("groups") or [])
        for name in sorted(wanted - set(groups)):
            kc.call("POST", "/groups", {"name": name})
            log(f"source {source['name']}: group {name} created")
        groups = {g["name"]: g for g in kc.call("GET", "/groups", query={"briefRepresentation": "true", "max": "1000"})}
        # The password policy applies to passwords an administrator sets too; the initial ones
        # (temporary, changed at the first login) are exempt: lifted here, set again by
        # apply_password_policy right after
        pending = [u for u in users if u.get("username") and
                   not kc.call("GET", "/users", query={"username": u["username"], "exact": "true"})]
        if pending and kc.call("GET", "").get("passwordPolicy"):
            kc.call("PUT", "", {"passwordPolicy": ""})
        for user in users:
            name = user.get("username")
            if not name:
                raise ConfigError(f"source {source['name']}: every user needs a username")
            existing = kc.call("GET", "/users", query={"username": name, "exact": "true"})
            if existing:
                if existing[0].get("federationLink"):
                    raise ConfigError(f"source {source['name']}: user {name} already exists in another source")
                continue
            kc.call("POST", "/users", {
                "username": name, "enabled": True, "emailVerified": True,
                "firstName": user.get("first_name", ""), "lastName": user.get("last_name", ""),
                "email": user.get("email") or None,
                "requiredActions": ["UPDATE_PASSWORD"],
                "credentials": [{"type": "password", "value": local_user_password(source, user), "temporary": True}],
            })
            created = kc.call("GET", "/users", query={"username": name, "exact": "true"})[0]
            for group in user.get("groups") or []:
                kc.call("PUT", f"/users/{created['id']}/groups/{groups[group]['id']}")
            log(f"source {source['name']}: user {name} created (groups {', '.join(user.get('groups') or []) or '-'}); "
                f"the password must be changed at the first login")


# --- OIDC and SAML identity providers ----------------------------------------------------------

def broker_url(source):
    """What the customer registers at their identity provider for this source."""
    base = f"{PUBLIC_URL}/auth/realms/{REALM}/broker/{source['name']}/endpoint"
    return base if source["type"] == "oidc" else base + "/descriptor"


def preset_for(source, presets):
    name = source.get("preset", "generic")
    if name not in presets:
        raise ConfigError(f"source {source['name']}: unknown preset '{name}' (known: {', '.join(presets)})")
    return dict(presets[name])


def import_config(kc, source, provider_id, url):
    """Keycloak reads the provider's discovery document or SAML metadata itself."""
    try:
        return kc.call("POST", "/identity-provider/import-config", {"providerId": provider_id, "fromUrl": url})
    except ConfigError as e:
        raise ConfigError(f"source {source['name']}: Keycloak cannot read {url}: {e}") from None


def idp_common(source, config):
    config.update({
        "syncMode": "FORCE",
        # Transient user: nothing about the user is stored beyond their session (experimental
        # in Keycloak 26; store_users: true keeps a local copy instead)
        "doNotStoreUsers": str(not source.get("store_users", False)).lower(),
        "hideOnLoginPage": str(source.get("hidden", False)).lower(),
        "guiOrder": str(source.get("priority", 0)),
    })
    return {
        "alias": source["name"],
        "displayName": source.get("display_name", source["name"]),
        "providerId": source["type"],
        "enabled": bool(source.get("enabled", True)),
        "trustEmail": False,
        "storeToken": False,
        "linkOnly": False,
        "firstBrokerLoginFlowAlias": "first broker login",
        "config": {k: str(v) for k, v in config.items() if v is not None},
    }


def oidc_provider(kc, source):
    p = preset_for(source, OIDC_PRESETS)
    for key in ("issuer", "client_id", "client_secret_file"):
        if not source.get(key):
            raise ConfigError(f"source {source['name']}: '{key}' is required")
    discovery = source.get("discovery_url") or source["issuer"].rstrip("/") + "/.well-known/openid-configuration"
    config = import_config(kc, source, "oidc", discovery)
    config.update({
        "clientId": source["client_id"],
        "clientSecret": read_secret(source, "client_secret_file"),
        "clientAuthMethod": "client_secret_post",
        "defaultScope": source.get("scopes", p["scopes"]),
        "validateSignature": "true",
        "useJwksUrl": "true",
        "pkceEnabled": "true",
        "pkceMethod": "S256",
        # Claims from the ID token only, for providers whose userinfo endpoint refuses our token
        "disableUserInfo": str(source.get("disable_userinfo", p.get("disable_userinfo", False))).lower(),
    })
    username_claim = source.get("username_claim", p["username_claim"])
    groups_claim = source.get("groups_claim", p["groups_claim"])
    mappers = [{"name": "username", "identityProviderMapper": "oidc-username-idp-mapper",
                "config": {"template": source.get("username_template", "${CLAIM." + username_claim + "}"),
                           "target": "LOCAL", "syncMode": "FORCE"}}]
    if groups_claim:
        mappers.append({"name": "groups", "identityProviderMapper": "oidc-user-attribute-idp-mapper",
                        "config": {"claim": groups_claim, "user.attribute": EXTERNAL_GROUPS, "syncMode": "FORCE"}})
    return idp_common(source, config), mappers


def saml_provider(kc, source):
    p = preset_for(source, SAML_PRESETS)
    if not source.get("metadata_url"):
        raise ConfigError(f"source {source['name']}: 'metadata_url' is required")
    config = import_config(kc, source, "saml", source["metadata_url"])
    username_attribute = source.get("username_attribute", p["username_attribute"])
    groups_attribute = source.get("groups_attribute", p["groups_attribute"])
    config.update({
        # Keycloak's SAML entity ID towards the provider: the realm URL
        "entityId": f"{PUBLIC_URL}/auth/realms/{REALM}",
        "nameIDPolicyFormat": "urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified",
        "principalType": "ATTRIBUTE" if username_attribute else "SUBJECT",
        "principalAttribute": username_attribute or "",
        "postBindingAuthnRequest": "true",
        "postBindingResponse": "true",
        "postBindingLogout": "true",
        "validateSignature": "true",
        "wantAssertionsSigned": str(source.get("want_assertions_signed", True)).lower(),
        "wantAuthnRequestsSigned": "false",
        # Seconds of clock difference tolerated. AD FS sets NotBefore to the very moment it issues
        # the assertion, so with Keycloak's default of 0 a clock a few milliseconds behind refuses it.
        "allowedClockSkew": str(source.get("allowed_clock_skew", 30)),
    })
    username = source.get("username_template",
                          "${ATTRIBUTE." + username_attribute + "}" if username_attribute else "${NAMEID}")
    mappers = [{"name": "username", "identityProviderMapper": "saml-username-idp-mapper",
                "config": {"template": username, "target": "LOCAL", "syncMode": "FORCE"}}]
    if groups_attribute:
        mappers.append({"name": "groups", "identityProviderMapper": "saml-user-attribute-idp-mapper",
                        "config": {"attribute.name": groups_attribute, "user.attribute": EXTERNAL_GROUPS,
                                   "syncMode": "FORCE"}})
    return idp_common(source, config), mappers


def apply_identity_providers(kc, identity):
    desired = []
    for source in sources_of(identity, "oidc", "saml"):
        build = oidc_provider if source["type"] == "oidc" else saml_provider
        desired.append((source, *build(kc, source)))

    existing = {p["alias"]: p for p in kc.call("GET", "/identity-provider/instances")}
    for source, provider, mappers in desired:
        alias = source["name"]
        if alias in existing:
            kc.call("PUT", f"/identity-provider/instances/{alias}", dict(provider, internalId=existing.pop(alias)["internalId"]))
            log(f"source {alias}: updated ({source['type']}, {source.get('preset', 'generic')})")
        else:
            kc.call("POST", "/identity-provider/instances", provider)
            log(f"source {alias}: created ({source['type']}, {source.get('preset', 'generic')})")
        current = {m["name"]: m for m in kc.call("GET", f"/identity-provider/instances/{alias}/mappers")}
        for mapper in mappers:
            body = dict(mapper, identityProviderAlias=alias)
            old = current.pop(mapper["name"], None)
            if old is None:
                kc.call("POST", f"/identity-provider/instances/{alias}/mappers", body)
            else:
                kc.call("PUT", f"/identity-provider/instances/{alias}/mappers/{old['id']}", dict(body, id=old["id"]))
        for leftover in current.values():
            kc.call("DELETE", f"/identity-provider/instances/{alias}/mappers/{leftover['id']}")
        log(f"source {alias}: register at the provider: {broker_url(source)}")
    for alias in existing:
        kc.call("DELETE", f"/identity-provider/instances/{alias}")
        log(f"source {alias}: removed (no longer in identity.yml)")


def ensure_user_profile(kc):
    """Users of external providers often come without e-mail or names: make those optional, and
    declare external_groups, which only administrators (and the identity provider mappers) may set,
    so that nobody can add groups to themselves in the account console."""
    profile = kc.call("GET", "/users/profile")
    changed = False
    for attribute in profile["attributes"]:
        if attribute["name"] in ("email", "firstName", "lastName") and attribute.get("required"):
            attribute.pop("required")
            changed = True
    if not any(a["name"] == EXTERNAL_GROUPS for a in profile["attributes"]):
        profile["attributes"].append({
            "name": EXTERNAL_GROUPS, "displayName": "External groups", "multivalued": True,
            "permissions": {"view": ["admin"], "edit": ["admin"]},
        })
        changed = True
    if changed:
        kc.call("PUT", "/users/profile", profile)
        log("user profile: e-mail and names optional, external_groups admin-only")


def ensure_external_groups_claim(kc):
    """Puts external_groups into the tokens of every client, through the `emondrian` scope."""
    scope = next((s for s in kc.call("GET", "/client-scopes") if s["name"] == "emondrian"), None)
    if scope is None:
        raise ConfigError("client scope 'emondrian' missing; run auth/scripts/reimport-realm.sh")
    mapper = {"name": "external groups", "protocol": "openid-connect",
              "protocolMapper": "oidc-usermodel-attribute-mapper", "config": {
                  "user.attribute": EXTERNAL_GROUPS, "claim.name": EXTERNAL_GROUPS, "multivalued": "true",
                  "aggregate.attrs": "false", "jsonType.label": "String", "id.token.claim": "true",
                  "access.token.claim": "true", "userinfo.token.claim": "true",
                  "introspection.token.claim": "true"}}
    path = f"/client-scopes/{scope['id']}/protocol-mappers/models"
    current = next((m for m in kc.call("GET", path) if m["name"] == mapper["name"]), None)
    if current is None:
        kc.call("POST", path, mapper)
    elif current.get("config") != mapper["config"]:
        kc.call("PUT", f"{path}/{current['id']}", dict(mapper, id=current["id"]))


def ensure_offline_access_scope(kc):
    """The offline_access scope maps the offline_access realm role, as in a realm Keycloak creates
    itself; the imported realm lacks the mapping, so clients without full scope (every client that
    registered itself) cannot get offline tokens: "Offline tokens not allowed for the user or client"."""
    scope = next((s for s in kc.call("GET", "/client-scopes") if s["name"] == "offline_access"), None)
    if scope is None:
        return
    path = f"/client-scopes/{scope['id']}/scope-mappings/realm"
    if not any(r["name"] == "offline_access" for r in kc.call("GET", path)):
        kc.call("POST", path, [kc.call("GET", "/roles/offline_access")])
        log("offline_access scope: maps the offline_access role")


def ensure_gateway_client_urls(kc):
    """The gateway client's redirect URIs follow PUBLIC_URL. The realm file sets them only when
    the realm is imported; keeping them here means a changed PUBLIC_URL needs `up -d` only, not
    a realm re-import (which would delete the users kept in Keycloak)."""
    if not PUBLIC_URL:
        return
    clients = kc.call("GET", "/clients", query={"clientId": "emondrian-gateway"})
    if not clients:
        return
    client = clients[0]
    redirect, logout = [f"{PUBLIC_URL}/redirect_uri"], f"{PUBLIC_URL}/*"
    attributes = client.get("attributes") or {}
    if client.get("redirectUris") != redirect or attributes.get("post.logout.redirect.uris") != logout:
        client["redirectUris"] = redirect
        client["attributes"] = dict(attributes, **{"post.logout.redirect.uris": logout})
        kc.call("PUT", f"/clients/{client['id']}", client)
        log(f"gateway client: redirect URIs set to {PUBLIC_URL}")


# --- mode oidc-direct --------------------------------------------------------------------------

def tls_context():
    """System CAs plus the PEM files in auth/secrets/truststore/."""
    context = ssl.create_default_context()
    for pem in sorted(glob.glob(os.path.join(TRUSTSTORE_DIR, "*.pem")) + glob.glob(os.path.join(TRUSTSTORE_DIR, "*.crt"))):
        context.load_verify_locations(cafile=pem)
    return context


def fetch_discovery(source, url):
    try:
        with urllib.request.urlopen(url, timeout=15, context=tls_context()) as r:
            return json.load(r)
    except (urllib.error.URLError, ValueError, OSError) as e:
        raise ConfigError(f"source {source['name']}: cannot read {url}: {getattr(e, 'reason', e)}") from None


def direct_config(source):
    """The gateway's own OIDC client settings for mode oidc-direct (gateway.json, with the secret)."""
    p = preset_for(source, OIDC_PRESETS)
    for key in ("issuer", "client_id", "client_secret_file"):
        if not source.get(key):
            raise ConfigError(f"source {source['name']}: '{key}' is required")
    discovery_url = source.get("discovery_url") or source["issuer"].rstrip("/") + "/.well-known/openid-configuration"
    discovery = fetch_discovery(source, discovery_url)
    values = {"issuer": discovery["issuer"], "client_id": source["client_id"],
              "host": urllib.parse.urlsplit(discovery["issuer"]).netloc}

    def expand(items):
        return [str(item).format(**values) for item in items]

    params = {k: str(v).format(**values) for k, v in (source.get("password_grant_params") or
                                                      p.get("password_grant_params") or {}).items()}
    return {
        "discovery_url": discovery_url,
        "client_id": source["client_id"],
        "client_secret": read_secret(source, "client_secret_file"),
        "scopes": source.get("scopes", p["scopes"]),
        # Accepted iss and aud of access tokens (Bearer, password grant)
        "token_issuers": expand(source.get("token_issuers") or p.get("token_issuers") or ["{issuer}"]),
        "token_audiences": expand(source.get("token_audiences") or p.get("token_audiences") or ["{client_id}"]),
        # Basic credentials checked by the provider's password grant (Excel, Power BI)
        "password_grant": bool(source.get("basic_password_grant", False)),
        "password_grant_params": params,
    }


# --- policy ------------------------------------------------------------------------------------

DURATION_UNITS = {"s": 1, "m": 60, "h": 3600, "d": 86400}

POLICY_DEFAULTS = {
    "password": "length(8) and notUsername",  # new passwords of local users (Keycloak syntax)
    "session_idle": "30m",        # browser session without activity
    "session_max": "10h",         # browser session at most, active or not
    "token_lifetime": "5m",       # Keycloak access tokens (mode broker)
    "basic_cache": "5m",          # a checked Basic login is reused this long
    "basic_failure_cache": "10s",  # a refused one is refused again without asking
}
LOCKOUT_DEFAULTS = {"failures": 5, "wait": "1m", "max_wait": "15m"}


def duration(value, name):
    """30 (seconds), "45s", "30m", "10h", "2d" -> seconds."""
    if isinstance(value, bool):
        raise ConfigError(f"identity.yml: policy.{name}: expected a duration like 30m, got {value!r}")
    if isinstance(value, int):
        return value
    text = str(value).strip().lower()
    if text[-1:] in DURATION_UNITS and text[:-1].isdigit():
        return int(text[:-1]) * DURATION_UNITS[text[-1]]
    if text.isdigit():
        return int(text)
    raise ConfigError(f"identity.yml: policy.{name}: expected a duration like 30s, 30m, 10h or 2d, got {value!r}")


def policy_settings(identity):
    policy = identity.get("policy") or {}
    unknown = set(policy) - set(POLICY_DEFAULTS) - {"lockout"}
    if unknown:
        raise ConfigError(f"identity.yml: unknown policy setting(s): {', '.join(sorted(unknown))}")
    result = {key: duration(policy.get(key, default), key) for key, default in POLICY_DEFAULTS.items()
              if key != "password"}
    result["password"] = str(policy.get("password", POLICY_DEFAULTS["password"]))
    lockout = policy.get("lockout", {})
    if lockout is False:
        result["lockout"] = None
    else:
        lockout = dict(LOCKOUT_DEFAULTS, **(lockout or {}))
        result["lockout"] = {"failures": int(lockout["failures"]),
                             "wait": duration(lockout["wait"], "lockout.wait"),
                             "max_wait": duration(lockout["max_wait"], "lockout.max_wait")}
    if result["session_idle"] > result["session_max"]:
        raise ConfigError("identity.yml: policy.session_idle is longer than policy.session_max")
    if result["token_lifetime"] < 60:
        raise ConfigError("identity.yml: policy.token_lifetime must be at least 1m")
    return result


def apply_password_policy(kc, policy):
    """After the local users are created: their temporary passwords are not held to it."""
    realm = kc.call("GET", "")
    if realm.get("passwordPolicy") != policy["password"]:
        kc.call("PUT", "", {"passwordPolicy": policy["password"]})
        log(f"realm policy: passwords of local users: {policy['password']}")


def apply_realm_policy(kc, policy):
    """Session, token and lockout settings of the realm (mode broker)."""
    lockout = policy["lockout"]
    settings = {
        "ssoSessionIdleTimeout": policy["session_idle"],
        "ssoSessionMaxLifespan": policy["session_max"],
        "accessTokenLifespan": policy["token_lifetime"],
        "bruteForceProtected": lockout is not None,
    }
    if lockout:
        settings.update({"failureFactor": lockout["failures"], "waitIncrementSeconds": lockout["wait"],
                         "maxFailureWaitSeconds": lockout["max_wait"], "permanentLockout": False})
    realm = kc.call("GET", "")
    if any(realm.get(k) != v for k, v in settings.items()):
        kc.call("PUT", "", settings)
        log(f"realm policy: session idle {policy['session_idle']}s / max {policy['session_max']}s, "
            f"tokens {policy['token_lifetime']}s, lockout "
            f"{'after ' + str(lockout['failures']) + ' failures' if lockout else 'off'}")


def tokens_settings(identity):
    """personal_tokens in identity.yml: tokens users create for Excel, Power BI, scripts and MCP."""
    section = identity.get("personal_tokens")
    if section is False:
        section = {"enabled": False}
    section = section or {}
    unknown = set(section) - {"enabled", "default_lifetime", "max_lifetime", "max_per_user"}
    if unknown:
        raise ConfigError(f"identity.yml: unknown personal_tokens setting(s): {', '.join(sorted(unknown))}")
    days = {}
    for key, default in (("default_lifetime", "90d"), ("max_lifetime", "365d")):
        seconds = duration(section.get(key, default), f"personal_tokens.{key}")
        if seconds < 86400 or seconds % 86400:
            raise ConfigError(f"identity.yml: personal_tokens.{key} must be whole days, e.g. 90d")
        days[key] = seconds // 86400
    if days["default_lifetime"] > days["max_lifetime"]:
        raise ConfigError("identity.yml: personal_tokens.default_lifetime is longer than max_lifetime")
    return {"enabled": bool(section.get("enabled", True)), "default_days": days["default_lifetime"],
            "max_days": days["max_lifetime"], "max_per_user": int(section.get("max_per_user", 10))}


def open_access_settings(identity):
    """open_access in identity.yml: everybody gets in without logging in, as one guest user with
    the roles listed (a demo or an evaluation). Sources stay configured, so switching it off
    again (enabled: false, apply-config.sh) needs nothing else. None when off."""
    section = identity.get("open_access")
    if section in (None, False):
        return None
    if section is True:
        section = {"enabled": True}
    if not isinstance(section, dict):
        raise ConfigError("identity.yml: open_access must be a section (enabled, user, roles)")
    unknown = set(section) - {"enabled", "user", "roles"}
    if unknown:
        raise ConfigError(f"identity.yml: unknown open_access setting(s): {', '.join(sorted(unknown))}")
    if not section.get("enabled", True):
        return None
    user = str(section.get("user") or "guest")
    if not all(c.isalnum() or c in "._@-" for c in user):
        raise ConfigError("identity.yml: open_access.user: letters, digits and . _ @ - only")
    roles = section.get("roles", ["emondrian-admins"])
    if not isinstance(roles, list) or not roles or not all(isinstance(r, str) and r and "," not in r for r in roles):
        raise ConfigError("identity.yml: open_access.roles must list eMondrian roles, e.g. [emondrian-admins]")
    return {"user": user, "roles": roles}


def write_tokens_settings(identity):
    """For the auth-tokens service (no secrets in it)."""
    path = os.path.join(os.path.dirname(GATEWAY_CONFIG), "tokens.json")
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(tokens_settings(identity), f)
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


# --- MCP ---------------------------------------------------------------------------------------

CLI_CLIENT = "emondrian-cli"
REGISTRATION_POLICY = "org.keycloak.services.clientregistration.policy.ClientRegistrationPolicy"


def mcp_settings(identity):
    """mcp in identity.yml: OAuth for MCP clients (mode broker)."""
    section = identity.get("mcp") or {}
    unknown = set(section) - {"oauth", "redirect_hosts", "device_client"}
    if unknown:
        raise ConfigError(f"identity.yml: unknown mcp setting(s): {', '.join(sorted(unknown))}")
    broker = identity["mode"] == "broker"
    hosts = section.get("redirect_hosts", ["localhost", "127.0.0.1"])
    if not isinstance(hosts, list) or not all(isinstance(h, str) and h for h in hosts):
        raise ConfigError("identity.yml: mcp.redirect_hosts must be a list of host names")
    return {"oauth": broker and bool(section.get("oauth", True)), "redirect_hosts": hosts,
            "device_client": broker and bool(section.get("device_client", True))}


def apply_mcp(kc, settings):
    """Lets MCP clients register themselves (dynamic client registration, anonymous) when their
    redirect URIs point at redirect_hosts, and keeps the device-code client for command-line tools.
    Such clients get nothing without a user's login (and consent)."""
    policies = kc.call("GET", "/components", query={"type": REGISTRATION_POLICY})
    trusted = next((c for c in policies if c["providerId"] == "trusted-hosts" and c["subType"] == "anonymous"), None)
    if trusted is None:
        raise ConfigError("the realm has no anonymous Trusted Hosts registration policy")
    config = dict(trusted.get("config") or {})
    if settings["oauth"]:
        config.update({"trusted-hosts": settings["redirect_hosts"],
                       "host-sending-registration-request-must-match": ["false"],
                       "client-uris-must-match": ["true"]})
    else:
        config.update({"trusted-hosts": [], "host-sending-registration-request-must-match": ["true"],
                       "client-uris-must-match": ["true"]})
    if config != trusted.get("config"):
        kc.call("PUT", f"/components/{trusted['id']}", dict(trusted, config=config))
    log(f"mcp: self-registration of MCP clients {'allowed for redirects to ' + ', '.join(settings['redirect_hosts']) if settings['oauth'] else 'off'}")

    # MCP clients register with the scopes of the protected resource metadata (openid profile
    # email). openid is no client scope in Keycloak, and Allowed Client Scopes refuses what it does
    # not know: 403 insufficient_scope.
    if settings["oauth"]:
        for policy in policies:
            if policy["providerId"] != "allowed-client-templates":
                continue
            config = dict(policy.get("config") or {})
            allowed = list(config.get("allowed-client-scopes") or [])
            if "openid" not in allowed:
                config["allowed-client-scopes"] = allowed + ["openid"]
                kc.call("PUT", f"/components/{policy['id']}", dict(policy, config=config))
        log("mcp: registrations may ask for scope openid (Allowed Client Scopes, anonymous and authenticated)")
    ensure_claims_in_basic(kc, settings["oauth"])

    existing = kc.call("GET", "/clients", query={"clientId": CLI_CLIENT})
    if settings["device_client"]:
        client = {"clientId": CLI_CLIENT, "name": "eMondrian command-line tools",
                  "description": "Device code login for CLI tools and MCP agents in a terminal",
                  "enabled": True, "publicClient": True, "protocol": "openid-connect",
                  "standardFlowEnabled": False, "directAccessGrantsEnabled": False,
                  "implicitFlowEnabled": False, "serviceAccountsEnabled": False,
                  "attributes": {"oauth2.device.authorization.grant.enabled": "true"}}
        if existing:
            kc.call("PUT", f"/clients/{existing[0]['id']}", dict(existing[0], **client))
        else:
            kc.call("POST", "/clients", client)
        log(f"mcp: device code client {CLI_CLIENT} ready")
    elif existing:
        kc.call("DELETE", f"/clients/{existing[0]['id']}")
        log(f"mcp: device code client {CLI_CLIENT} removed")


BASIC_PREFIX = "emondrian "


def ensure_claims_in_basic(kc, wanted):
    """A client that registers itself with a scope list gets just `basic` as default scope and
    the requested ones as optional, so the `emondrian` scope (audience, groups) and `profile`
    (user name) reach its tokens only if it asks for them at login; the gateway then refuses the
    token (not issued for emondrian) or finds no user. Copies of those mappers in `basic`, which
    every client has, put them into every token of the realm."""
    scopes = {s["name"]: s for s in kc.call("GET", "/client-scopes")}
    if "basic" not in scopes or "emondrian" not in scopes:
        raise ConfigError("client scope 'basic' or 'emondrian' missing; run auth/scripts/reimport-realm.sh")

    def mappers(name):
        return kc.call("GET", f"/client-scopes/{scopes[name]['id']}/protocol-mappers/models")

    copies = {}
    if wanted:
        sources = mappers("emondrian") + [m for m in (mappers("profile") if "profile" in scopes else [])
                                          if m["name"] == "username"]
        for m in sources:
            copies[BASIC_PREFIX + m["name"]] = {"name": BASIC_PREFIX + m["name"], "protocol": m["protocol"],
                                                "protocolMapper": m["protocolMapper"], "config": m["config"]}
    path = f"/client-scopes/{scopes['basic']['id']}/protocol-mappers/models"
    current = {m["name"]: m for m in mappers("basic") if m["name"].startswith(BASIC_PREFIX)}
    for name, mapper in copies.items():
        old = current.pop(name, None)
        if old is None:
            kc.call("POST", path, mapper)
        elif old.get("protocolMapper") != mapper["protocolMapper"] or old.get("config") != mapper["config"]:
            kc.call("PUT", f"{path}/{old['id']}", dict(mapper, id=old["id"]))
    for old in current.values():
        kc.call("DELETE", f"{path}/{old['id']}")
    if wanted:
        log("mcp: audience, groups and user name in every token (scope basic), for self-registered clients")


# --- Kerberos ----------------------------------------------------------------------------------

KERBEROS_CLIENT = "emondrian-kerberos"
KERBEROS_DIR = "/kerberos"  # auth/secrets/kerberos/, mounted read-only


def kerberos_settings(identity):
    """kerberos in identity.yml: Windows logins (SPNEGO) for users of one LDAP source."""
    section = identity.get("kerberos")
    if not section:
        return None
    unknown = set(section) - {"source", "service_principal", "keytab_file", "browser", "enabled"}
    if unknown:
        raise ConfigError(f"identity.yml: unknown kerberos setting(s): {', '.join(sorted(unknown))}")
    if section.get("enabled", True) is False:
        return None
    if identity["mode"] != "broker":
        raise ConfigError("identity.yml: kerberos needs mode: broker (users are looked up in an LDAP source)")
    source = next((x for x in identity["sources"] if x["name"] == section.get("source")), None)
    if source is None or source["type"] != "ldap":
        raise ConfigError("identity.yml: kerberos.source must name an ldap source")
    principal = str(section.get("service_principal") or "")
    if not principal.startswith("HTTP/") or "@" not in principal:
        raise ConfigError("identity.yml: kerberos.service_principal must look like HTTP/host.example.com@EXAMPLE.COM")
    return {"source": source["name"], "service_principal": principal,
            "kerberos_realm": principal.rsplit("@", 1)[1],
            "keytab_file": section.get("keytab_file", "http.keytab"),
            "browser": bool(section.get("browser", True))}


def apply_kerberos_login(kc, identity):
    """The Kerberos step of the browser login flow, set from identity.yml. Keycloak changes it
    itself when an LDAP source with Kerberos is created, updated or removed, which goes wrong when
    one such source replaces another (the removal of the old one turns it off)."""
    settings = kerberos_settings(identity)
    wanted = "ALTERNATIVE" if settings and settings["browser"] else "DISABLED"
    for execution in kc.call("GET", "/authentication/flows/browser/executions"):
        if execution.get("providerId") == "auth-spnego" and execution.get("requirement") != wanted:
            kc.call("PUT", "/authentication/flows/browser/executions", dict(execution, requirement=wanted))
            log(f"kerberos: browser login with a ticket {'on' if wanted == 'ALTERNATIVE' else 'off'}")


def apply_kerberos(kc, identity):
    """Service account for auth-kerberos (may only look users up) and its settings file."""
    settings = kerberos_settings(identity)
    path = os.path.join(os.path.dirname(GATEWAY_CONFIG), "kerberos.json")
    if settings is None:
        content = {"enabled": False}
    else:
        if not os.path.isfile(os.path.join(KERBEROS_DIR, settings["keytab_file"])):
            raise ConfigError(f"kerberos: keytab '{settings['keytab_file']}' not found in auth/secrets/kerberos/")
        client = {"clientId": KERBEROS_CLIENT, "name": "eMondrian Kerberos user lookup",
                  "description": "Service account of auth-kerberos: looks up the groups of Kerberos users",
                  "enabled": True, "publicClient": False, "protocol": "openid-connect",
                  "standardFlowEnabled": False, "directAccessGrantsEnabled": False,
                  "serviceAccountsEnabled": True}
        existing = kc.call("GET", "/clients", query={"clientId": KERBEROS_CLIENT})
        if existing:
            client_uuid = existing[0]["id"]
        else:
            kc.call("POST", "/clients", client)
            client_uuid = kc.call("GET", "/clients", query={"clientId": KERBEROS_CLIENT})[0]["id"]
        account = kc.call("GET", f"/clients/{client_uuid}/service-account-user")
        management = kc.call("GET", "/clients", query={"clientId": "realm-management"})[0]["id"]
        granted = {r["name"] for r in kc.call("GET", f"/users/{account['id']}/role-mappings/clients/{management}")}
        if "view-users" not in granted:
            role = kc.call("GET", f"/clients/{management}/roles/view-users")
            kc.call("POST", f"/users/{account['id']}/role-mappings/clients/{management}", [role])
        secret = kc.call("GET", f"/clients/{client_uuid}/client-secret")["value"]
        source_id = next(c["id"] for c in kc.call("GET", "/components", query={"type": USER_STORAGE})
                         if c["name"] == settings["source"])
        content = {"enabled": True, "keycloak_url": KEYCLOAK_URL, "realm": REALM, "client_id": KERBEROS_CLIENT,
                   "client_secret": secret, "source_id": source_id,
                   "service_principal": settings["service_principal"], "kerberos_realm": settings["kerberos_realm"],
                   # auth-kerberos mounts auth/secrets/kerberos/ at /etc/kerberos
                   "keytab": f"/etc/kerberos/{settings['keytab_file']}"}
        log(f"kerberos: tickets for {settings['service_principal']}, users of source {settings['source']}"
            f"{', browser login too' if settings['browser'] else ''}")
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(content, f)
    # auth-kerberos runs as uid 1000 (like Keycloak); the file holds its client secret
    os.chown(tmp, 1000, 1000)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


# --- mode trusted-proxy ------------------------------------------------------------------------

def proxy_config(identity):
    """The gateway's rules for trusting the SSO proxy (gateway.json; may hold the shared secret)."""
    section = dict(identity["trusted_proxy"])
    preset_name = section.pop("preset", "generic")
    if preset_name not in PROXY_PRESETS:
        raise ConfigError(f"trusted_proxy: unknown preset '{preset_name}' (known: {', '.join(PROXY_PRESETS)})")
    settings = dict(PROXY_PRESETS[preset_name])
    params = {k: section.pop(k) for k in ("team", "authenticate") if k in section}
    known = {"addresses", "secret_file", "secret_header", "user_header", "groups_header", "groups_separator",
             "jwt_header", "jwks_url", "issuer", "audience", "username_claim", "groups_claim", "algorithms",
             "logout_url"}
    unknown = set(section) - known
    if unknown:
        raise ConfigError(f"trusted_proxy: unknown setting(s): {', '.join(sorted(unknown))}")
    settings.update(section)
    for key in ("jwks_url", "issuer"):
        if isinstance(settings.get(key), str):
            try:
                settings[key] = settings[key].format(**params)
            except KeyError as e:
                raise ConfigError(f"trusted_proxy: preset {preset_name} needs '{e.args[0]}'") from None

    addresses = settings.get("addresses") or []
    if not isinstance(addresses, list) or not all(isinstance(a, str) for a in addresses):
        raise ConfigError("trusted_proxy.addresses must be a list of addresses or CIDRs")
    for address in addresses:
        ip, _, bits = address.partition("/")
        octets = ip.split(".")
        if ":" in ip:
            if bits:
                raise ConfigError(f"trusted_proxy.addresses: '{address}': IPv6 is supported as single addresses only")
        elif len(octets) != 4 or not all(o.isdigit() and int(o) < 256 for o in octets) or \
                (bits and not (bits.isdigit() and int(bits) <= 32)):
            raise ConfigError(f"trusted_proxy.addresses: '{address}' is not an IPv4 address or CIDR")
    jwt = bool(settings.get("jwt_header"))
    if jwt:
        for key in ("jwks_url", "audience"):
            if not settings.get(key):
                raise ConfigError(f"trusted_proxy: '{key}' is required for a JWT-signing proxy ({preset_name})")
    elif not addresses:
        # Without a signature, only the network position tells the proxy apart from anybody else
        raise ConfigError("trusted_proxy.addresses is required for a header-based proxy: only requests from "
                          "these addresses may name the user")
    if not jwt and not settings.get("user_header"):
        raise ConfigError("trusted_proxy.user_header is required")
    secret = None
    if settings.get("secret_file"):
        secret = read_secret({"name": "trusted_proxy", "secret_file": settings["secret_file"]}, "secret_file")
    return {
        "preset": preset_name,
        "addresses": addresses,
        "secret_header": settings.get("secret_header", "X-Proxy-Secret") if secret else None,
        "secret": secret,
        "user_header": None if jwt else settings["user_header"],
        "groups_header": None if jwt else settings.get("groups_header"),
        "groups_separator": settings.get("groups_separator", ","),
        "jwt_header": settings.get("jwt_header"),
        "jwks_url": settings.get("jwks_url"),
        "issuer": settings.get("issuer"),
        "audience": settings.get("audience"),
        "username_claim": settings.get("username_claim", "email"),
        "groups_claim": settings.get("groups_claim"),
        "algorithms": settings.get("algorithms", ["RS256", "ES256"]),
        "logout_url": settings.get("logout_url"),
    }


# --- gateway config ----------------------------------------------------------------------------

def gateway_config(identity):
    claims = identity.get("claims") or {}
    roles = identity.get("roles") or {}
    mapping = roles.get("mapping")
    if mapping is not None:
        if not isinstance(mapping, dict) or not all(isinstance(v, list) for v in mapping.values()):
            raise ConfigError("identity.yml: roles.mapping must map role names to lists of groups/users")
        mapping = {role: [str(m) for m in members] for role, members in mapping.items()}
    direct = identity["mode"] in ("oidc-direct", "trusted-proxy")
    if identity["mode"] == "trusted-proxy":
        # trusted_proxy.lua hands over {user=…, groups={…}}, whatever headers or claims it read
        username_claim, groups_claims = "user", ["groups"]
    elif direct:
        # The provider's own claims: the source's (or its preset's) user name and group claims
        source = identity["sources"][0]
        p = preset_for(source, OIDC_PRESETS)
        username_claim = claims.get("username", source.get("username_claim", p["username_claim"]))
        groups_claims = claims.get("groups", source.get("groups_claim", p["groups_claim"])) or []
    else:
        username_claim = claims.get("username", "preferred_username")
        groups_claims = claims.get("groups", "groups")
    groups_claims = [groups_claims] if isinstance(groups_claims, str) else list(groups_claims)
    if not direct and EXTERNAL_GROUPS not in groups_claims:
        groups_claims.append(EXTERNAL_GROUPS)
    policy = policy_settings(identity)
    return {
        "mode": identity["mode"],
        "personal_tokens": tokens_settings(identity)["enabled"],
        # 401 on MCP points to the OAuth metadata (Protected Resource Metadata)
        "mcp_oauth": mcp_settings(identity)["oauth"],
        # XML/A and the API offer and accept Negotiate (Kerberos)
        "kerberos": kerberos_settings(identity) is not None,
        # Browser sessions and the Basic cache of the gateway (seconds)
        "policy": {key: policy[key] for key in ("session_idle", "session_max", "basic_cache", "basic_failure_cache")},
        "username_claim": username_claim,
        # Directory groups (LDAP group mapper) and groups sent by external identity providers
        "groups_claims": groups_claims,
        "role_mapping": mapping,
        # With a mapping, eMondrian gets the mapped roles only, unless forward_groups is true
        "forward_groups": bool(roles.get("forward_groups", mapping is None)),
        # With a mapping, a user holding no eMondrian role is refused (403)
        "require_role": bool(roles.get("require_role", mapping is not None)),
        # Login straight at this identity provider instead of Keycloak's login page
        "default_idp": (identity.get("login") or {}).get("default_source"),
        # Sources a browser may pick with ?idp=<name>
        "idp_aliases": [] if direct else [s["name"] for s in sources_of(identity, "oidc", "saml")],
        # Authentication switched off: every request is this user with these roles
        "open_access": open_access_settings(identity),
    }


def write_gateway_config(identity, oidc=None, proxy=None):
    config = gateway_config(identity)
    if oidc:
        config["oidc"] = oidc
    if proxy:
        config["trusted_proxy"] = proxy
    os.makedirs(os.path.dirname(GATEWAY_CONFIG), exist_ok=True)
    tmp = GATEWAY_CONFIG + ".tmp"
    # May hold the OIDC client secret (oidc-direct): readable by root (the gateway's master) only
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(config, f, indent=2)
    os.chmod(tmp, 0o600)
    os.replace(tmp, GATEWAY_CONFIG)
    write_tokens_settings(identity)
    if config["open_access"]:
        guest = config["open_access"]
        log(f"WARNING: authentication is OFF (open_access): everybody who reaches the server gets in "
            f"as {guest['user']} with {', '.join(guest['roles'])}, without logging in")
    log(f"gateway config written: mode {config['mode']}, roles "
        f"{'mapped (' + str(len(config['role_mapping'])) + ' roles)' if config['role_mapping'] is not None else 'not mapped, groups forwarded as they are'}")
    return config


def map_roles(config, user, groups):
    """The same mapping the gateway applies (lua/emondrian/identity.lua), for `check`."""
    if config["role_mapping"] is None:
        return list(groups)
    lower = {g.lower() for g in groups}
    roles = sorted(role for role, members in config["role_mapping"].items()
                   if any(m.lower() in lower or m.lower() == f"user:{user}".lower() for m in members))
    if config["forward_groups"]:
        roles += [g for g in groups if g not in roles]
    return roles


# --- commands ----------------------------------------------------------------------------------

def apply():
    identity = load_identity()
    gateway_config(identity)  # validate roles/claims (and kerberos, mcp, policy) before changing anything
    if identity["mode"] == "trusted-proxy":
        proxy = proxy_config(identity)
        how = (f"JWT in {proxy['jwt_header']} signed with {proxy['jwks_url']}" if proxy["jwt_header"]
               else f"headers {proxy['user_header']} / {proxy['groups_header']}")
        log(f"trusted-proxy ({proxy['preset']}): {how}"
            f"{', from ' + ', '.join(proxy['addresses']) if proxy['addresses'] else ''}"
            f"{', with shared secret' if proxy['secret'] else ''} (no Keycloak)")
        apply_kerberos(None, identity)
        write_gateway_config(identity, proxy=proxy)
        log("identity.yml applied")
        return
    if identity["mode"] == "oidc-direct":
        source = identity["sources"][0]
        oidc = direct_config(source)
        log(f"source {source['name']}: the gateway is a client of {oidc['discovery_url']} (no Keycloak)")
        log(f"source {source['name']}: register at the provider: {PUBLIC_URL}/redirect_uri")
        if (identity.get("policy") or {}).keys() & {"token_lifetime", "lockout"}:
            log("policy: token_lifetime and lockout are the provider's business in mode oidc-direct; ignored")
        apply_kerberos(None, identity)  # writes "off": kerberos needs mode broker
        write_gateway_config(identity, oidc)
        log("identity.yml applied")
        return
    kc = Keycloak()
    kc.wait()
    realm = kc.call("GET", "")
    apply_realm_policy(kc, policy_settings(identity))
    ensure_user_profile(kc)
    ensure_external_groups_claim(kc)
    ensure_offline_access_scope(kc)
    ensure_gateway_client_urls(kc)
    apply_ldap_sources(kc, identity, realm["id"])
    apply_local_users(kc, identity)
    apply_password_policy(kc, policy_settings(identity))
    apply_identity_providers(kc, identity)
    apply_mcp(kc, mcp_settings(identity))
    apply_kerberos(kc, identity)
    apply_kerberos_login(kc, identity)
    write_gateway_config(identity)
    log("identity.yml applied")


def check(username=None):
    identity = load_identity()
    config = gateway_config(identity)
    if config["open_access"]:
        guest = config["open_access"]
        log(f"     | open_access | authentication is OFF: every request is {guest['user']} "
            f"({', '.join(guest['roles'])}); the sources below apply once it is switched off")
    if identity["mode"] == "trusted-proxy":
        try:
            proxy = proxy_config(identity)
        except ConfigError as e:
            log(f"FAIL | trusted_proxy | {e}")
            return 1
        if proxy["jwt_header"]:
            try:
                fetch_discovery({"name": "trusted_proxy"}, proxy["jwks_url"])
                log(f"OK   | trusted_proxy | the gateway reads the proxy's keys at {proxy['jwks_url']}")
            except ConfigError as e:
                log(f"FAIL | trusted_proxy | {e}")
                return 1
        log(f"     | trusted_proxy | user from {proxy['jwt_header'] or proxy['user_header']}, accepted from "
            f"{', '.join(proxy['addresses']) or 'any address (signed JWT)'}")
        log("     | users can only be checked by a request through the proxy")
        return 0
    if identity["mode"] == "oidc-direct":
        source = identity["sources"][0]
        try:
            oidc = direct_config(source)
        except ConfigError as e:
            log(f"FAIL | {source['name']} | {e}")
            return 1
        log(f"OK   | {source['name']} | the gateway reads {oidc['discovery_url']}")
        log(f"     | {source['name']} | redirect URI to register at the provider: {PUBLIC_URL}/redirect_uri")
        log(f"     | {source['name']} | access tokens accepted from {oidc['token_issuers']} for {oidc['token_audiences']}")
        log(f"     | {source['name']} | Basic (Excel, Power BI): "
            f"{'password grant at the provider' if oidc['password_grant'] else 'off (basic_password_grant: false)'}")
        log("     | users can only be checked by logging in (browser) or with a token")
        return 0
    kc = Keycloak()
    kc.wait(60)
    failures = 0
    providers = {c["name"]: c for c in kc.call("GET", "/components", query={"type": USER_STORAGE})}
    idps = {p["alias"]: p for p in kc.call("GET", "/identity-provider/instances")}
    for source in sources_of(identity, "oidc", "saml"):
        if source["name"] not in idps:
            log(f"FAIL | {source['name']} | not in Keycloak; run apply first")
            failures += 1
            continue
        url = (source.get("metadata_url") if source["type"] == "saml" else
               source.get("discovery_url") or source["issuer"].rstrip("/") + "/.well-known/openid-configuration")
        try:
            import_config(kc, source, source["type"], url)
            log(f"OK   | {source['name']} | Keycloak reads {url}")
        except ConfigError as e:
            log(f"FAIL | {source['name']} | {e}")
            failures += 1
        what = "redirect URI" if source["type"] == "oidc" else "SP metadata"
        log(f"     | {source['name']} | {what} to register at the provider: {broker_url(source)}")
    for source in sources_of(identity, "ldap"):
        component = providers.get(source["name"])
        if component is None:
            log(f"FAIL | {source['name']} | not in Keycloak; run apply first")
            failures += 1
            continue
        for action, label in (("testConnection", "connection"), ("testAuthentication", "bind as bind_dn")):
            body = {"action": action, "componentId": component["id"]}
            body.update({k: v[0] for k, v in component["config"].items()
                         if k in ("connectionUrl", "bindDn", "bindCredential", "useTruststoreSpi",
                                  "connectionTimeout", "startTls", "authType")})
            try:
                kc.call("POST", "/testLDAPConnection", body)
                log(f"OK   | {source['name']} | {label}")
            except ConfigError as e:
                log(f"FAIL | {source['name']} | {label}: {e}")
                failures += 1
    if username:
        try:
            users = kc.call("GET", "/users", query={"username": username, "exact": "true"})
        except ConfigError as e:
            log(f"FAIL | user {username} | lookup failed; a broken source breaks lookups in all "
                f"sources, fix the failures above first ({e})")
            return failures + 1
        if not users:
            log(f"FAIL | user {username} | not found, or not allowed to log in (allowed_groups / user_filter)")
            failures += 1
        else:
            user = users[0]
            source = next((n for n, c in providers.items() if c["id"] == user.get("federationLink")),
                          "?" if user.get("federationLink") else next((x["name"] for x in sources_of(identity, "local")), "Keycloak"))
            groups = [g["name"] for g in kc.call("GET", f"/users/{user['id']}/groups")]
            log(f"OK   | user {username} | source {source}, enabled {user['enabled']}, groups {groups}")
            roles = map_roles(config, user["username"], groups)
            log(f"     | forwarded to eMondrian | X-Forwarded-User: {user['username']}  "
                f"X-Forwarded-Groups: {','.join(roles) or '(none)'}")
            if not roles and config["require_role"]:
                log(f"FAIL | user {username} | holds no eMondrian role and would be refused (roles.mapping)")
                failures += 1
    if sources_of(identity, "oidc", "saml"):
        log("     | users of oidc/saml sources can only be checked by logging in "
            f"({PUBLIC_URL}/?idp=<source>); their groups arrive in the {EXTERNAL_GROUPS} claim")
    return failures


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else "apply"
    try:
        if command == "apply":
            apply()
            return 0
        if command == "check":
            return 1 if check(sys.argv[2] if len(sys.argv) > 2 else None) else 0
        log(__doc__)
        return 2
    except ConfigError as e:
        log(f"ERROR: {e}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
