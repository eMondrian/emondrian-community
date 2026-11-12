"""Directory presets: the Keycloak LDAP provider and mapper settings that differ between directory
products. A source in identity.yml picks one with `preset:` and may override single values."""

ACTIVE_DIRECTORY = {
    "vendor": "ad",
    "username_attribute": "sAMAccountName",
    "rdn_attribute": "cn",
    "uuid_attribute": "objectGUID",
    "user_object_classes": "person, organizationalPerson, user",
    "first_name_attribute": "givenName",
    "last_name_attribute": "sn",
    "email_attribute": "mail",
    "group_name_attribute": "cn",
    "group_object_classes": "group",
    "membership_attribute": "member",
    "membership_attribute_type": "DN",
    # AD resolves nested groups itself (LDAP_MATCHING_RULE_IN_CHAIN)
    "groups_strategy": "LOAD_GROUPS_BY_MEMBER_ATTRIBUTE_RECURSIVELY",
    "account_controls_mapper": True,
    # Only enabled accounts: userAccountControl bit 2 (ACCOUNTDISABLE) unset
    "base_user_filter": "(&(objectCategory=person)(objectClass=user)(!(userAccountControl:1.2.840.113556.1.4.803:=2)))",
    # allowed_groups: membership in the group or any group nested in it
    "member_of_filter": "(memberOf:1.2.840.113556.1.4.1941:={dn})",
    "group_rdn": "CN",
}

OPENLDAP = {
    "vendor": "other",
    "username_attribute": "uid",
    "rdn_attribute": "uid",
    "uuid_attribute": "entryUUID",
    "user_object_classes": "inetOrgPerson, organizationalPerson",
    "first_name_attribute": "givenName",
    "last_name_attribute": "sn",
    "email_attribute": "mail",
    "group_name_attribute": "cn",
    "group_object_classes": "groupOfNames",
    "membership_attribute": "member",
    "membership_attribute_type": "DN",
    "groups_strategy": "LOAD_GROUPS_BY_MEMBER_ATTRIBUTE",
    "account_controls_mapper": False,
    "base_user_filter": "(objectClass=inetOrgPerson)",
    # Needs the memberOf overlay, which most OpenLDAP distributions enable
    "member_of_filter": "(memberOf={dn})",
    "group_rdn": "cn",
}

LDAP_PRESETS = {
    "active-directory": ACTIVE_DIRECTORY,
    "openldap": OPENLDAP,
}

# OpenID Connect providers: which scopes to ask for and which ID token claims carry the user name
# and the groups. `issuer` is the provider's issuer URL; its /.well-known/openid-configuration
# supplies the endpoints.
OIDC_PRESETS = {
    # AD FS 2016+ (application group, server application): groups need an issuance transform
    # rule sending "Token-Groups - Unqualified Names" as the "group" claim; allatclaims puts the
    # issued claims into the ID token. Its userinfo endpoint accepts only tokens for
    # urn:microsoft:userinfo, not ones for this application, so the ID token is the only source.
    # In mode oidc-direct, AD FS access tokens are issued by the federation service identifier
    # (http://<host>/adfs/services/trust), and the password grant names the web API as resource.
    "adfs": {"scopes": "openid profile email allatclaims", "username_claim": "upn", "groups_claim": "group",
             "disable_userinfo": True,
             "token_issuers": ["{issuer}", "http://{host}/adfs/services/trust"],
             "token_audiences": ["{client_id}", "microsoft:identityserver:{client_id}"],
             "password_grant_params": {"resource": "{client_id}"}},
    # Microsoft Entra ID (issuer https://login.microsoftonline.com/<tenant>/v2.0): "groups" holds
    # group object IDs unless the app registration emits names (cloud groups) or app roles ("roles").
    "entra": {"scopes": "openid profile email", "username_claim": "preferred_username", "groups_claim": "groups"},
    "keycloak": {"scopes": "openid profile email", "username_claim": "preferred_username", "groups_claim": "groups"},
    # Okta: the authorization server needs a "groups" claim
    "okta": {"scopes": "openid profile email groups", "username_claim": "preferred_username", "groups_claim": "groups"},
    # Google Workspace has no group claim: map users (user:<email>) in roles.mapping
    "google": {"scopes": "openid profile email", "username_claim": "email", "groups_claim": None},
    "generic": {"scopes": "openid profile email", "username_claim": "preferred_username", "groups_claim": "groups"},
}

# SSO proxies in front of eMondrian (mode trusted-proxy). Header-based ones are trusted by the
# address they connect from (and optionally a shared secret); JWT-based ones sign an assertion
# the gateway verifies with the proxy's keys. {placeholders} come from the trusted_proxy section.
PROXY_PRESETS = {
    # oauth2-proxy with --pass-user-headers (--set-xauthrequest behind nginx auth_request)
    "oauth2-proxy": {"user_header": "X-Forwarded-User", "groups_header": "X-Forwarded-Groups",
                     "groups_separator": ","},
    "authelia": {"user_header": "Remote-User", "groups_header": "Remote-Groups", "groups_separator": ","},
    "authentik": {"user_header": "X-authentik-username", "groups_header": "X-authentik-groups",
                  "groups_separator": "|"},
    # Cloudflare Access: team = <team> of <team>.cloudflareaccess.com, audience = the application's AUD tag.
    # Groups only if the Access policy adds them to the token (custom claims).
    "cloudflare-access": {"jwt_header": "Cf-Access-Jwt-Assertion",
                          "jwks_url": "https://{team}.cloudflareaccess.com/cdn-cgi/access/certs",
                          "issuer": "https://{team}.cloudflareaccess.com",
                          "username_claim": "email", "groups_claim": "groups", "algorithms": ["RS256"]},
    # Pomerium: authenticate = the authenticate service's host name
    "pomerium": {"jwt_header": "X-Pomerium-Jwt-Assertion",
                 "jwks_url": "https://{authenticate}/.well-known/pomerium/jwks.json",
                 "issuer": None, "username_claim": "email", "groups_claim": "groups", "algorithms": ["ES256"]},
    # Google Cloud IAP: audience = /projects/<number>/global/backendServices/<id> (or /apps/<project>)
    "google-iap": {"jwt_header": "x-goog-iap-jwt-assertion",
                   "jwks_url": "https://www.gstatic.com/iap/verify/public_key-jwk",
                   "issuer": "https://cloud.google.com/iap",
                   "username_claim": "email", "groups_claim": None, "algorithms": ["ES256"]},
    "generic": {"user_header": "X-Forwarded-User", "groups_header": "X-Forwarded-Groups", "groups_separator": ","},
}

# SAML 2.0 providers: the assertion attributes carrying the user name and the groups.
SAML_PRESETS = {
    # AD FS relying party trust with claim rules sending UPN and "Token-Groups - Unqualified Names"
    # as Group
    "adfs": {
        "username_attribute": "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/upn",
        "groups_attribute": "http://schemas.xmlsoap.org/claims/Group",
    },
    # NameID as the user name, groups in an attribute named "groups"
    "generic": {"username_attribute": None, "groups_attribute": "groups"},
}
