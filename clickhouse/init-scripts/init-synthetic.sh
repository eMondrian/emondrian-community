#!/usr/bin/env bash
# The two ClickHouse users the synthetic module works as: syn_writer creates and fills the
# syn_* databases of synthetic catalogs, syn_reader is what those catalogs connect as. Neither may
# read a real database. ClickHouse 24.3 has no wildcard grant for syn_*, so both get their rights on
# *.* and every real database is revoked by name: `default` (OnTime) here. A real database you add
# to this ClickHouse needs its own REVOKE below.
#
# Their passwords come from .env (EMONDRIAN_SYN_WRITER_PASSWORD, EMONDRIAN_SYN_READER_PASSWORD;
# setup.sh fills them in). Re-running applies the current passwords.
set -Eeuo pipefail

REAL_DATABASES=(default)

if [ -z "${EMONDRIAN_SYN_WRITER_PASSWORD:-}" ] || [ -z "${EMONDRIAN_SYN_READER_PASSWORD:-}" ]; then
  echo "synthetic-init: EMONDRIAN_SYN_WRITER_PASSWORD or EMONDRIAN_SYN_READER_PASSWORD is empty in .env;"
  echo "synthetic-init: the synthetic users are not created, so synthetic catalogs cannot be generated."
  echo "synthetic-init: run ./setup.sh (it fills them in), or set both in .env and run docker compose up -d."
  exit 0
fi

sql_string() {
  # A single-quoted SQL string literal.
  printf "'%s'" "${1//\'/\'\'}"
}

W=$(sql_string "$EMONDRIAN_SYN_WRITER_PASSWORD")
R=$(sql_string "$EMONDRIAN_SYN_READER_PASSWORD")

{
  echo "CREATE USER IF NOT EXISTS syn_writer IDENTIFIED WITH sha256_password BY $W;"
  echo "ALTER USER syn_writer IDENTIFIED WITH sha256_password BY $W;"
  echo "CREATE USER IF NOT EXISTS syn_reader IDENTIFIED WITH sha256_password BY $R SETTINGS readonly = 2;"
  echo "ALTER USER syn_reader IDENTIFIED WITH sha256_password BY $R SETTINGS readonly = 2;"
  echo "GRANT CREATE DATABASE, CREATE TABLE, DROP DATABASE, DROP TABLE, INSERT, SELECT, ALTER, TRUNCATE ON *.* TO syn_writer;"
  echo "GRANT SELECT ON *.* TO syn_reader;"
  for db in "${REAL_DATABASES[@]}"; do
    echo "REVOKE ALL ON ${db}.* FROM syn_writer;"
    echo "REVOKE SELECT ON ${db}.* FROM syn_reader;"
  done
} | clickhouse-client --host=127.0.0.1 --multiquery

echo "synthetic-init: syn_writer and syn_reader are ready; revoked on: ${REAL_DATABASES[*]}"
