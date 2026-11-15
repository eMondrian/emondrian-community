"""Unit tests of the Kerberos user lookup, without Keycloak or a KDC. Run in the auth-kerberos image,
<project>-auth-kerberos:local (<project>: the compose project, by default the directory name):

    docker run --rm -e SESSION_SECRET=test -v "$PWD/auth/kerberos:/t:ro" -w /t \\
        --entrypoint python3 <project>-auth-kerberos:local -m unittest test_kerberos
"""
import unittest

import kerberos

SETTINGS = {"source_id": "ldap-1"}


class LookupTest(unittest.TestCase):

    def setUp(self):
        kerberos._cache.clear()
        self.saved = kerberos.keycloak_get

    def tearDown(self):
        kerberos.keycloak_get = self.saved
        kerberos._cache.clear()

    def fake(self, users, groups):
        def keycloak_get(s, path, query=None):
            return users if path == "/users" else groups
        kerberos.keycloak_get = keycloak_get

    def test_groups_are_full_paths_nested_ones_included(self):
        # An LDAP group at the top and a nested Keycloak group: both forwarded by their path, as at
        # a password login, never by the nested group's own name (a same-named group elsewhere)
        self.fake([{"id": "u1", "federationLink": "ldap-1", "enabled": True}],
                  [{"name": "BI-Users", "path": "/BI-Users"}, {"name": "Team", "path": "/Sales/Team"}])
        self.assertEqual((["/BI-Users", "/Sales/Team"], None), kerberos.lookup(SETTINGS, "jdoe"))

    def test_a_group_without_a_path_is_taken_as_top_level(self):
        self.assertEqual(["/X"], kerberos.group_paths([{"name": "X"}]))

    def test_disabled_and_foreign_users_are_refused(self):
        self.fake([{"id": "u1", "federationLink": "ldap-1", "enabled": False}], [])
        self.assertEqual((None, "disabled"), kerberos.lookup(SETTINGS, "anna"))
        kerberos._cache.clear()
        self.fake([{"id": "u2", "federationLink": "other", "enabled": True}], [])
        self.assertEqual((None, "belongs to another source"), kerberos.lookup(SETTINGS, "bob"))


if __name__ == "__main__":
    unittest.main()
