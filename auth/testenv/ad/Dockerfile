FROM debian:12.7-slim

# Samba as an Active Directory domain controller (LDAP, LDAPS, Kerberos KDC), test only
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       samba samba-ad-dc samba-ad-provision krb5-user winbind ldb-tools ca-certificates \
    && rm -rf /var/lib/apt/lists/* /etc/samba/smb.conf

COPY provision.sh /provision.sh
RUN chmod 755 /provision.sh
EXPOSE 88 389 636
ENTRYPOINT ["/provision.sh"]
