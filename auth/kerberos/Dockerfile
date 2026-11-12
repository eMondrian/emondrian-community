FROM debian:12.7-slim

# python3-gssapi: Kerberos acceptor; krb5-user: klist/kinit for diagnostics
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 python3-gssapi krb5-user \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY kerberos.py krb5.conf ./
RUN cp /app/krb5.conf /etc/krb5.conf

# The keytab comes from auth/secrets/kerberos/ (mounted at /etc/kerberos)
ENV KRB5_KTNAME=/etc/kerberos/http.keytab
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --retries=5 \
    CMD python3 -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=2)" || exit 1
ENTRYPOINT ["python3", "-u", "/app/kerberos.py"]
