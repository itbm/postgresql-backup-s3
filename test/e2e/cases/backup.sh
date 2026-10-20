# Backups (backup.sh): plain and custom formats, compression, pg_dumpall, the
# POSTGRES_* connection and dump options, and how failures are handled.

_BACKUP_TS_RE='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'
_BACKUP_OLD_PG_IMAGE=postgres:16-alpine

# _backup_tool <command> [args...] - runs a client tool from the image under
# test on the e2e network with stdin attached, bypassing backup.sh/restore.sh.
_backup_tool() {
  _bt_cmd=$1
  shift
  docker run --rm -i --network "$E2E_NET" --label "e2e.run=$E2E_RUN_ID" --label "e2e.case=$CASE_SLUG" \
    -e "PGPASSWORD=$PG_PASSWORD" --entrypoint "$_bt_cmd" "$E2E_IMAGE" "$@"
}

# _backup_sql <container> <port> <database> <sql> - runs SQL on a case-scoped server.
_backup_sql() {
  docker exec -i -e "PGPORT=$2" "$1" psql -X -q -U postgres -d "$3" -v ON_ERROR_STOP=1 -c "$4" >/dev/null \
    || fail "SQL failed on $1/$3: $4"
}

# _backup_epoch <YYYY-MM-DDTHH:MM:SSZ> - seconds since the epoch. Pure bash
# because GNU and BSD date parse dates differently.
_backup_epoch() {
  _be_y=$((10#${1:0:4})) _be_m=$((10#${1:5:2})) _be_d=$((10#${1:8:2}))
  [ "$_be_m" -gt 2 ] || _be_y=$((_be_y - 1))
  _be_era=$((_be_y / 400))
  _be_yoe=$((_be_y - _be_era * 400))
  _be_doy=$(((153 * ((_be_m + 9) % 12) + 2) / 5 + _be_d - 1))
  _be_doe=$((_be_yoe * 365 + _be_yoe / 4 - _be_yoe / 100 + _be_doy))
  printf '%s\n' $(((_be_era * 146097 + _be_doe - 719468) * 86400 \
    + 10#${1:11:2} * 3600 + 10#${1:14:2} * 60 + 10#${1:17:2}))
}

# _backup_assert_key <key> <prefix> <suffix> [<epoch-before> <epoch-after>] -
# checks that key is <prefix>_<timestamp><suffix> and, given the epoch bounds
# of the run, that the timestamp is the UTC time of the run.
_backup_assert_key() {
  _bak_rest=${1#"$2"_}
  [ "$_bak_rest" != "$1" ] || fail "backup key '$1' does not start with '$2_'"
  _bak_ts=${_bak_rest%"$3"}
  [ "$_bak_ts" != "$_bak_rest" ] || fail "backup key '$1' does not end with '$3'"
  assert_match "$_bak_ts" "^${_BACKUP_TS_RE}\$" "timestamp in backup key '$1'"
  if [ $# -ge 5 ]; then
    _bak_at=$(_backup_epoch "$_bak_ts")
    # A few seconds of slack in case host and daemon clocks differ slightly.
    if [ "$_bak_at" -lt $(($4 - 5)) ] || [ "$_bak_at" -gt $(($5 + 5)) ]; then
      fail "timestamp $_bak_ts in '$1' is $((_bak_at - $4))s from the UTC start of the run, which took $(($5 - $4))s"
    fi
  fi
}

# _backup_fetch_plain <bucket> <key> <name> - downloads a plain backup, checks
# it is a complete gzip stream and writes the SQL to CASE_DIR/<name>.sql.
_backup_fetch_plain() {
  s3_get "$1" "$2" "$CASE_DIR/$3.sql.gz"
  assert_eq "$(od -An -tx1 -N2 "$CASE_DIR/$3.sql.gz" | tr -d ' \n')" "1f8b" "gzip magic of s3://$1/$2"
  _backup_tool gzip -dc <"$CASE_DIR/$3.sql.gz" >"$CASE_DIR/$3.sql" \
    || fail "s3://$1/$2 is not a valid gzip stream"
  [ -s "$CASE_DIR/$3.sql" ] || fail "s3://$1/$2 decompresses to nothing"
}

# _backup_new_empty_db <name> - creates an empty database on the main server.
_backup_new_empty_db() {
  psql_exec postgres "CREATE DATABASE $(sql_ident "$1")" >/dev/null || fail "could not create database $1"
}

# _backup_load_plain <sql-file> <new-database> - loads a plain dump into a new
# database on the main server with the image's psql.
_backup_load_plain() {
  _backup_new_empty_db "$2"
  _backup_tool psql -X -q -h pg -U postgres -d "$2" -v ON_ERROR_STOP=1 -f - <"$1" >"$CASE_DIR/load-$2.log" 2>&1 || {
    tail -n 20 "$CASE_DIR/load-$2.log" >&2
    fail "plain dump $1 does not load into a new database"
  }
}

# _backup_load_custom <dump-file> <new-database> - same for a custom-format archive.
_backup_load_custom() {
  _backup_new_empty_db "$2"
  _backup_tool pg_restore -h pg -U postgres -d "$2" --exit-on-error <"$1" >"$CASE_DIR/load-$2.log" 2>&1 || {
    tail -n 20 "$CASE_DIR/load-$2.log" >&2
    fail "custom-format dump $1 does not restore into a new database"
  }
}

# _backup_assert_failed_cleanly <bucket> [message] - the last run failed,
# uploaded nothing and left no temporary files behind.
_backup_assert_failed_cleanly() {
  assert_rc_nonzero "${2:-backup should fail}"
  assert_log_not_contains "Uploading dump to" "${2:-failed backup} still tried to upload"
  assert_log_not_contains "SQL backup finished" "${2:-failed backup} reported success"
  assert_s3_count "$1" "" 0 "objects uploaded by a failed backup (${2:-})"
  assert_eq "$(bk_tmp_leftovers)" "" "temporary files left in /tmp after a failed backup (${2:-})"
}

# _backup_make_cluster <container> - a marker role and two small databases on a
# case-scoped server, for pg_dumpall.
_backup_make_cluster() {
  docker exec -i "$1" psql -X -q -U postgres -v ON_ERROR_STOP=1 >/dev/null <<'SQL' || fail "could not prepare $1"
CREATE ROLE bk_marker_role NOLOGIN;
CREATE DATABASE db_one;
CREATE DATABASE db_two;
\connect db_one
CREATE TABLE marker (v text);
INSERT INTO marker VALUES ('marker-of-db-one');
\connect db_two
CREATE TABLE marker (v text);
INSERT INTO marker VALUES ('marker-of-db-two');
SQL
}

# ---------------------------------------------------------------------------
# Plain format (the default).

test_backup_plain_default_format() {
  db=$(new_db) || exit 1
  bucket=$(new_bucket) || exit 1

  before=$(date -u +%s)
  bk_backup backup "$db" "$bucket"
  after=$(date -u +%s)
  assert_rc 0 "default backup"
  assert_log_contains "Creating dump of $db database from pg..."
  assert_log_contains "Uploading dump to $bucket"
  assert_log_contains "SQL backup finished"
  assert_log_not_contains 'pg_dump: dumping contents of table' "pg_dump is verbose without POSTGRES_EXTRA_OPTS"
  assert_log_not_contains "$PG_PASSWORD" "PostgreSQL password in the log"
  assert_log_not_contains "$S3_SECRET" "S3 secret key in the log"
  assert_eq "$(bk_tmp_leftovers)" "" "temporary files left in /tmp after backup"

  assert_s3_count "$bucket" "" 1 "objects in the bucket"
  key=$(s3_single_key "$bucket" backup/) || exit 1
  _backup_assert_key "$key" "backup/$db" .sql.gz "$before" "$after"

  _backup_fetch_plain "$bucket" "$key" dump
  sql=$CASE_DIR/dump.sql
  head -n 5 "$sql" | grep -Fxq -- "-- PostgreSQL database dump" || fail "dump does not start with a pg_dump header"
  assert_file_contains "$sql" "CREATE SCHEMA app;"
  assert_file_contains "$sql" "CREATE TABLE app.users ("
  assert_file_contains "$sql" "COPY app.users (id, email, name, created_at, profile, tags, avatar, balance) FROM stdin;"
  assert_file_contains "$sql" "CREATE TABLE public.excluded_table ("
  assert_file_contains "$sql" "COMMENT ON TABLE app.users IS"
  assert_file_contains "$sql" "ALTER TABLE app.users OWNER TO postgres;"
  assert_file_contains "$sql" "SELECT pg_catalog.lo_create('424242');"
  # The large object's payload, 'large object payload', hex-encoded.
  assert_file_contains "$sql" "SELECT pg_catalog.lowrite(0, '\\x6c61726765206f626a656374207061796c6f6164');"
  assert_file_contains "$sql" "-- PostgreSQL database dump complete"
  # Without CREATE DATABASE or \connect the dump can be loaded into any database.
  assert_file_not_contains "$sql" "CREATE DATABASE"
  assert_file_not_contains "$sql" '\connect'

  _backup_load_plain "$sql" "${db}_loaded"
  assert_same_data "$db" "${db}_loaded"
}

test_backup_key_timestamp_is_utc() {
  db=$(new_db) || exit 1
  bucket=$(new_bucket) || exit 1

  # Local time 14 hours ahead of UTC (POSIX TZ syntax, no tzdata needed).
  before=$(date -u +%s)
  bk_backup backup "$db" "$bucket" -e TZ=XYZ-14
  after=$(date -u +%s)
  assert_rc 0 "backup with TZ set"
  key=$(s3_single_key "$bucket" backup/) || exit 1
  _backup_assert_key "$key" "backup/$db" .sql.gz "$before" "$after"
}

test_backup_compression_pigz() {
  db=$(new_db) || exit 1
  bucket=$(new_bucket) || exit 1

  bk_backup backup "$db" "$bucket" -e COMPRESSION_CMD=pigz
  assert_rc 0 "backup with COMPRESSION_CMD=pigz"
  assert_log_contains "SQL backup finished"
  key=$(s3_single_key "$bucket" backup/) || exit 1
  _backup_assert_key "$key" "backup/$db" .sql.gz
  assert_eq "$(bk_tmp_leftovers)" "" "temporary files left in /tmp"

  _backup_fetch_plain "$bucket" "$key" dump
  assert_file_contains "$CASE_DIR/dump.sql" "CREATE TABLE app.users ("
  assert_file_contains "$CASE_DIR/dump.sql" "-- PostgreSQL database dump complete"
}

test_backup_compression_cmd_with_arguments() {
  db=$(new_db) || exit 1
  bucket=$(new_bucket) || exit 1

  bk_backup backup "$db" "$bucket" -e "COMPRESSION_CMD=gzip -9"
  assert_rc 0 "backup with COMPRESSION_CMD='gzip -9'"
  key=$(s3_single_key "$bucket" backup/) || exit 1
  _backup_assert_key "$key" "backup/$db" .sql.gz

  _backup_fetch_plain "$bucket" "$key" dump
  # RFC 1952: XFL (byte 9) is 2 when the maximum compression level was used,
  # which proves -9 reached gzip (the default level writes 0).
  assert_eq "$(od -An -tx1 -j8 -N1 "$CASE_DIR/dump.sql.gz" | tr -d ' \n')" "02" "gzip XFL byte"
  assert_file_contains "$CASE_DIR/dump.sql" "CREATE TABLE app.users ("
  assert_file_contains "$CASE_DIR/dump.sql" "-- PostgreSQL database dump complete"
}

test_backup_failing_compression_cmd_uploads_nothing() {
  db=$(new_db) || exit 1
  bucket=$(new_bucket) || exit 1

  bk_backup false "$db" "$bucket" -e COMPRESSION_CMD=false
  _backup_assert_failed_cleanly "$bucket" "backup with COMPRESSION_CMD=false"

  bk_backup missing "$db" "$bucket" -e COMPRESSION_CMD=no-such-compressor
  _backup_assert_failed_cleanly "$bucket" "backup with a COMPRESSION_CMD that does not exist"
  assert_log_contains "no-such-compressor"
}

# ---------------------------------------------------------------------------
# Custom format.

test_backup_custom_format() {
  db=$(new_db) || exit 1
  bucket=$(new_bucket) || exit 1

  # COMPRESSION_CMD is documented as ignored for the custom format.
  before=$(date -u +%s)
  bk_backup backup "$db" "$bucket" -e USE_CUSTOM_FORMAT=yes -e COMPRESSION_CMD=false
  after=$(date -u +%s)
  assert_rc 0 "custom-format backup with COMPRESSION_CMD=false"
  assert_log_contains "Creating dump of $db database from pg..."
  assert_log_contains "Uploading dump to $bucket"
  assert_log_contains "SQL backup finished"
  assert_eq "$(bk_tmp_leftovers)" "" "temporary files left in /tmp after backup"

  assert_s3_count "$bucket" "" 1 "objects in the bucket"
  key=$(s3_single_key "$bucket" backup/) || exit 1
  _backup_assert_key "$key" "backup/$db" .dump "$before" "$after"

  s3_get "$bucket" "$key" "$CASE_DIR/dump.dump"
  assert_eq "$(head -c 5 "$CASE_DIR/dump.dump")" "PGDMP" "custom-format archive magic"
  # README promises built-in compression; an uncompressed archive says "none".
  _backup_tool pg_restore -l <"$CASE_DIR/dump.dump" >"$CASE_DIR/toc.txt" || fail "pg_restore cannot list the archive"
  compression=$(sed -n 's/^;[[:space:]]*Compression: *//p' "$CASE_DIR/toc.txt")
  assert_match "$compression" '^[a-z0-9]+' "compression in the archive header"
  assert_ne "$compression" "none" "custom-format archive compression"
  _backup_load_custom "$CASE_DIR/dump.dump" "${db}_loaded"
  assert_same_data "$db" "${db}_loaded"
}

test_backup_custom_format_honours_extra_dump_opts() {
  db=$(new_db) || exit 1
  bucket=$(new_bucket) || exit 1

  bk_backup backup "$db" "$bucket" -e USE_CUSTOM_FORMAT=yes \
    -e POSTGRES_EXTRA_DUMP_OPTS=--exclude-table=public.excluded_table
  assert_rc 0 "custom-format backup with --exclude-table"
  key=$(s3_single_key "$bucket" backup/) || exit 1
  _backup_assert_key "$key" "backup/$db" .dump

  s3_get "$bucket" "$key" "$CASE_DIR/dump.dump"
  _backup_tool pg_restore -l <"$CASE_DIR/dump.dump" >"$CASE_DIR/toc.txt" || fail "pg_restore cannot list the archive"
  assert_file_contains "$CASE_DIR/toc.txt" "TABLE app users"
  assert_file_contains "$CASE_DIR/toc.txt" "BLOB"
  assert_file_not_contains "$CASE_DIR/toc.txt" "excluded_table"
}

# ---------------------------------------------------------------------------
# POSTGRES_DATABASE=all (pg_dumpall).

test_backup_all_plain_pg_dumpall() {
  # A private server, so the dump holds a known set of databases.
  ctr=$(start_postgres bkall) || exit 1
  _backup_make_cluster "$ctr"
  bucket=$(new_bucket) || exit 1

  before=$(date -u +%s)
  bk_backup backup all "$bucket" -e POSTGRES_HOST=bkall
  after=$(date -u +%s)
  assert_rc 0 "pg_dumpall backup"
  assert_log_contains "Creating dump of all database from bkall..."
  assert_log_contains "SQL backup finished"
  assert_eq "$(bk_tmp_leftovers)" "" "temporary files left in /tmp after backup"
  key=$(s3_single_key "$bucket" backup/) || exit 1
  _backup_assert_key "$key" "backup/all" .sql.gz "$before" "$after"

  _backup_fetch_plain "$bucket" "$key" all
  sql=$CASE_DIR/all.sql
  assert_file_contains "$sql" "-- PostgreSQL database cluster dump"
  assert_file_contains "$sql" "CREATE ROLE bk_marker_role;"
  assert_file_contains "$sql" "CREATE ROLE postgres;"
  assert_file_contains "$sql" "CREATE DATABASE db_one "
  assert_file_contains "$sql" "CREATE DATABASE db_two "
  assert_file_contains "$sql" '\connect db_one'
  assert_file_contains "$sql" '\connect db_two'
  assert_file_contains "$sql" '\connect postgres'
  assert_file_contains "$sql" "marker-of-db-one"
  assert_file_contains "$sql" "marker-of-db-two"
  assert_file_contains "$sql" "-- PostgreSQL database cluster dump complete"
}

test_backup_all_honours_dump_and_compression_options() {
  ctr=$(start_postgres bkallx) || exit 1
  _backup_make_cluster "$ctr"
  bucket=$(new_bucket) || exit 1

  bk_backup backup all "$bucket" -e POSTGRES_HOST=bkallx -e "COMPRESSION_CMD=gzip -9" \
    -e POSTGRES_EXTRA_DUMP_OPTS=--exclude-database=db_two -e POSTGRES_EXTRA_OPTS=--verbose
  assert_rc 0 "pg_dumpall backup with --exclude-database, --verbose and gzip -9"
  assert_log_contains 'pg_dumpall: dumping database "db_one"' "POSTGRES_EXTRA_OPTS=--verbose did not reach pg_dumpall"
  assert_log_contains 'pg_dumpall: excluding database "db_two"'
  # Verbose pg_dumpall prints its connection strings; the password must not be in them.
  assert_log_not_contains "$PG_PASSWORD" "PostgreSQL password in the verbose log"

  key=$(s3_single_key "$bucket" backup/) || exit 1
  _backup_assert_key "$key" "backup/all" .sql.gz
  _backup_fetch_plain "$bucket" "$key" all
  # gzip XFL byte 02: COMPRESSION_CMD and its argument reached the pg_dumpall pipeline.
  assert_eq "$(od -An -tx1 -j8 -N1 "$CASE_DIR/all.sql.gz" | tr -d ' \n')" "02" "gzip XFL byte of the pg_dumpall backup"
  sql=$CASE_DIR/all.sql
  assert_file_contains "$sql" '\connect db_one'
  assert_file_contains "$sql" "marker-of-db-one"
  assert_file_not_contains "$sql" '\connect db_two'
  assert_file_not_contains "$sql" "marker-of-db-two"
  assert_file_contains "$sql" "-- PostgreSQL database cluster dump complete"
}

test_backup_all_with_custom_format_is_rejected() {
  bucket=$(new_bucket) || exit 1

  bk_backup backup all "$bucket" -e USE_CUSTOM_FORMAT=yes
  assert_rc 1 "POSTGRES_DATABASE=all with USE_CUSTOM_FORMAT=yes"
  assert_log_contains "ERROR: Custom format (-Fc) is not supported with pg_dumpall."
  _backup_assert_failed_cleanly "$bucket" "all with custom format"
}

# ---------------------------------------------------------------------------
# Connection settings.

test_backup_postgres_port_non_default() {
  ctr=$(start_postgres bkport 5433) || exit 1
  _backup_sql "$ctr" 5433 postgres "CREATE DATABASE port_db"
  _backup_sql "$ctr" 5433 port_db "CREATE TABLE port_marker (v text); INSERT INTO port_marker VALUES ('reached-on-port-5433')"
  bucket=$(new_bucket) || exit 1

  # Control: the default port reaches nothing on this server.
  bk_backup default-port port_db "$bucket" -e POSTGRES_HOST=bkport
  _backup_assert_failed_cleanly "$bucket" "backup to port 5432 of a server on 5433"
  assert_log_contains "port 5432 failed"

  bk_backup port-5433 port_db "$bucket" -e POSTGRES_HOST=bkport -e POSTGRES_PORT=5433
  assert_rc 0 "backup with POSTGRES_PORT=5433"
  assert_log_contains "Creating dump of port_db database from bkport..."
  key=$(s3_single_key "$bucket" backup/) || exit 1
  _backup_assert_key "$key" "backup/port_db" .sql.gz
  _backup_fetch_plain "$bucket" "$key" dump
  assert_file_contains "$CASE_DIR/dump.sql" "reached-on-port-5433"

  # The custom-format and pg_dumpall commands are built separately.
  bucket_fc=$(new_bucket fc) || exit 1
  bk_backup port-5433-custom port_db "$bucket_fc" -e POSTGRES_HOST=bkport -e POSTGRES_PORT=5433 \
    -e USE_CUSTOM_FORMAT=yes
  assert_rc 0 "custom-format backup with POSTGRES_PORT=5433"
  key=$(s3_single_key "$bucket_fc" backup/) || exit 1
  _backup_assert_key "$key" "backup/port_db" .dump
  s3_get "$bucket_fc" "$key" "$CASE_DIR/dump.dump"
  _backup_tool pg_restore -f - <"$CASE_DIR/dump.dump" >"$CASE_DIR/dump-fc.sql" || fail "pg_restore cannot read the archive"
  assert_file_contains "$CASE_DIR/dump-fc.sql" "reached-on-port-5433"

  bucket_all=$(new_bucket all) || exit 1
  bk_backup port-5433-all all "$bucket_all" -e POSTGRES_HOST=bkport -e POSTGRES_PORT=5433
  assert_rc 0 "pg_dumpall backup with POSTGRES_PORT=5433"
  key=$(s3_single_key "$bucket_all" backup/) || exit 1
  _backup_assert_key "$key" "backup/all" .sql.gz
  _backup_fetch_plain "$bucket_all" "$key" all
  assert_file_contains "$CASE_DIR/all.sql" '\connect port_db'
  assert_file_contains "$CASE_DIR/all.sql" "reached-on-port-5433"
}

test_backup_docker_link_env_fallback() {
  # Legacy Docker links: without POSTGRES_HOST, host and port come from
  # POSTGRES_PORT_5432_TCP_ADDR and POSTGRES_PORT_5432_TCP_PORT. A link aliased
  # "postgres" also sets POSTGRES_PORT to a tcp:// URL, which must not be used.
  ctr=$(start_postgres bklink 5433) || exit 1
  _backup_sql "$ctr" 5433 postgres "CREATE DATABASE link_db"
  _backup_sql "$ctr" 5433 link_db "CREATE TABLE link_marker (v text); INSERT INTO link_marker VALUES ('reached-through-link-env')"
  bucket=$(new_bucket) || exit 1

  bk_backup backup link_db "$bucket" --unset POSTGRES_HOST -e POSTGRES_PORT=tcp://bklink:5433 \
    -e POSTGRES_PORT_5432_TCP_ADDR=bklink -e POSTGRES_PORT_5432_TCP_PORT=5433
  assert_rc 0 "backup through Docker link variables"
  assert_log_contains "Creating dump of link_db database from bklink..."
  key=$(s3_single_key "$bucket" backup/) || exit 1
  _backup_fetch_plain "$bucket" "$key" dump
  assert_file_contains "$CASE_DIR/dump.sql" "reached-through-link-env"
}

test_backup_postgres_user_and_password() {
  db=$(new_db) || exit 1
  bucket=$(new_bucket) || exit 1
  role=$(printf 'bk_%s' "$CASE_SLUG" | tr '-' '_')
  # Characters a shell could mangle: spaces, quotes, $, a glob and a backslash.
  role_pw="bk pass 'q' \"dq\" \$HOME * \\ end"
  psql_exec postgres "CREATE ROLE $(sql_ident "$role") LOGIN SUPERUSER PASSWORD '$(printf '%s' "$role_pw" | sed "s/'/''/g")'" \
    >/dev/null || fail "could not create role $role"

  # The other role with the postgres password: proves POSTGRES_USER reaches pg_dump.
  bk_backup wrong-password "$db" "$bucket" -e "POSTGRES_USER=$role"
  _backup_assert_failed_cleanly "$bucket" "backup as $role with the wrong password"
  assert_log_contains "password authentication failed for user \"$role\""

  bk_backup backup "$db" "$bucket" -e "POSTGRES_USER=$role" -e "POSTGRES_PASSWORD=$role_pw"
  assert_rc 0 "backup as $role with its own password"
  assert_log_not_contains "$role_pw" "role password in the log"
  key=$(s3_single_key "$bucket" backup/) || exit 1
  _backup_fetch_plain "$bucket" "$key" dump
  assert_file_contains "$CASE_DIR/dump.sql" "CREATE TABLE app.users ("
}

test_backup_postgres_user_with_space() {
  xfail "backup.sh expands POSTGRES_USER unquoted (-U \$POSTGRES_USER), so a role name containing a space breaks the pg_dump command line"
  db=$(new_db) || exit 1
  bucket=$(new_bucket) || exit 1
  role="bk user $(printf '%s' "$CASE_SLUG" | cut -c1-30)"
  psql_exec postgres "CREATE ROLE $(sql_ident "$role") LOGIN SUPERUSER PASSWORD 'bk-space-role-pw'" >/dev/null \
    || fail "could not create role $role"

  bk_backup backup "$db" "$bucket" -e "POSTGRES_USER=$role" -e POSTGRES_PASSWORD=bk-space-role-pw
  assert_rc 0 "backup as role '$role'"
  key=$(s3_single_key "$bucket" backup/) || exit 1
  _backup_fetch_plain "$bucket" "$key" dump
  assert_file_contains "$CASE_DIR/dump.sql" "CREATE TABLE app.users ("
}

test_backup_requires_postgres_settings() {
  db=$(new_db) || exit 1
  bucket=$(new_bucket) || exit 1

  for var in POSTGRES_HOST POSTGRES_USER POSTGRES_PASSWORD; do
    bk_backup "$(printf 'no-%s' "$var" | tr 'A-Z_' 'a-z-')" "$db" "$bucket" --unset "$var"
    assert_rc 1 "backup without $var"
    assert_log_contains "You need to set the $var environment variable"
    assert_log_not_contains "Creating dump of" "dump started without $var"
  done

  bk_run no-postgres-database -e "S3_BUCKET=$bucket"
  assert_rc 1 "backup without POSTGRES_DATABASE"
  assert_log_contains "You need to set the POSTGRES_DATABASE environment variable."
  assert_s3_count "$bucket" "" 0 "objects uploaded without the required settings"
}

test_backup_older_server_version() {
  ctr=$(E2E_POSTGRES_IMAGE=$_BACKUP_OLD_PG_IMAGE start_postgres bkold) || exit 1
  _backup_sql "$ctr" 5432 postgres "CREATE DATABASE old_db"
  docker exec -i "$ctr" psql -X -q -U postgres -d old_db -v ON_ERROR_STOP=1 -f - \
    <"$E2E_DIR/fixtures/seed.sql" >/dev/null || fail "could not seed old_db"
  server_version=$(docker exec "$ctr" psql -X -U postgres -Atc 'SHOW server_version')
  main_version=$(psql_exec postgres 'SHOW server_version')
  [ "${server_version%%.*}" -lt "${main_version%%.*}" ] \
    || fail "server $server_version is not older than the main server $main_version"
  bucket=$(new_bucket) || exit 1

  bk_backup backup old_db "$bucket" -e POSTGRES_HOST=bkold
  assert_rc 0 "backup of a $server_version server"
  key=$(s3_single_key "$bucket" backup/) || exit 1
  _backup_fetch_plain "$bucket" "$key" dump
  assert_file_contains "$CASE_DIR/dump.sql" "-- Dumped from database version $server_version"

  # Upgrade path: load into the newer main server and compare. Newer servers
  # also list NOT NULL constraints in pg_constraint, so those lines are ignored.
  loaded=$(printf 't_%s_loaded' "$CASE_SLUG" | tr '-' '_')
  _backup_load_plain "$CASE_DIR/dump.sql" "$loaded"
  PG_CTR=$ctr db_fingerprint old_db | grep -v '^constraint .*_not_null ' >"$CASE_DIR/fingerprint-src.txt"
  db_fingerprint "$loaded" | grep -v '^constraint .*_not_null ' >"$CASE_DIR/fingerprint-dst.txt"
  [ -s "$CASE_DIR/fingerprint-src.txt" ] || fail "empty fingerprint for old_db"
  diff -u "$CASE_DIR/fingerprint-src.txt" "$CASE_DIR/fingerprint-dst.txt" >&2 \
    || fail "data loaded from the $server_version backup differs from the source"
}

# ---------------------------------------------------------------------------
# POSTGRES_EXTRA_DUMP_OPTS and POSTGRES_EXTRA_OPTS.

test_backup_extra_dump_opts_exclude_table() {
  db=$(new_db) || exit 1
  bucket=$(new_bucket) || exit 1

  bk_backup backup "$db" "$bucket" -e POSTGRES_EXTRA_DUMP_OPTS=--exclude-table=public.excluded_table
  assert_rc 0 "backup with --exclude-table"
  key=$(s3_single_key "$bucket" backup/) || exit 1
  _backup_fetch_plain "$bucket" "$key" dump
  assert_file_contains "$CASE_DIR/dump.sql" "CREATE TABLE app.users ("
  assert_file_not_contains "$CASE_DIR/dump.sql" "excluded_table"
}

test_backup_extra_dump_opts_several_options() {
  db=$(new_db) || exit 1
  bucket=$(new_bucket) || exit 1

  bk_backup backup "$db" "$bucket" \
    -e "POSTGRES_EXTRA_DUMP_OPTS=--exclude-table=public.excluded_table --no-comments --no-owner"
  assert_rc 0 "backup with several dump options"
  key=$(s3_single_key "$bucket" backup/) || exit 1
  _backup_fetch_plain "$bucket" "$key" dump
  sql=$CASE_DIR/dump.sql
  assert_file_contains "$sql" "CREATE TABLE app.users ("
  assert_file_contains "$sql" "-- PostgreSQL database dump complete"
  assert_file_not_contains "$sql" "excluded_table" "--exclude-table was not applied"
  assert_file_not_contains "$sql" "COMMENT ON TABLE" "--no-comments was not applied"
  assert_file_not_contains "$sql" "OWNER TO" "--no-owner was not applied"
}

test_backup_extra_opts_reach_pg_dump_and_pg_dumpall() {
  db=$(new_db) || exit 1
  bucket=$(new_bucket) || exit 1

  bk_backup verbose "$db" "$bucket" -e POSTGRES_EXTRA_OPTS=--verbose
  assert_rc 0 "backup with POSTGRES_EXTRA_OPTS=--verbose"
  assert_log_contains 'pg_dump: dumping contents of table "app.users"' "--verbose did not reach pg_dump"
  assert_log_not_contains "$PG_PASSWORD" "PostgreSQL password in the verbose log"
  assert_s3_count "$bucket" backup/ 1 "objects after the verbose backup"

  bk_backup verbose-custom "$db" "$bucket" -e USE_CUSTOM_FORMAT=yes -e POSTGRES_EXTRA_OPTS=--verbose
  assert_rc 0 "custom-format backup with POSTGRES_EXTRA_OPTS=--verbose"
  assert_log_contains 'pg_dump: dumping contents of table "app.users"' "--verbose did not reach the custom-format pg_dump"
  assert_s3_count "$bucket" backup/ 2 "objects after the verbose backups"

  bk_backup invalid "$db" "$bucket" -e POSTGRES_EXTRA_OPTS=--no-such-option
  assert_rc_nonzero "pg_dump with an invalid option"
  assert_log_contains "pg_dump: unrecognized option"
  assert_log_contains "no-such-option"
  assert_eq "$(bk_tmp_leftovers)" "" "temporary files left in /tmp after a failed backup"

  bk_backup invalid-all all "$bucket" -e POSTGRES_EXTRA_OPTS=--no-such-option
  assert_rc_nonzero "pg_dumpall with an invalid option"
  assert_log_contains "pg_dumpall: unrecognized option"
  assert_log_not_contains "Uploading dump to" "failed pg_dumpall still uploaded"
  assert_s3_count "$bucket" backup/ 2 "objects after the failed backups"
}

# ---------------------------------------------------------------------------
# Failures.

test_backup_pg_dump_failure_uploads_nothing() {
  db=$(new_db) || exit 1
  bucket=$(new_bucket) || exit 1

  # pg_dump fails inside "pg_dump | gzip"; only pipefail stops an empty
  # but valid gzip file from being uploaded as a backup.
  bk_backup strict-names "$db" "$bucket" -e "POSTGRES_EXTRA_DUMP_OPTS=--table=no_such_table --strict-names"
  _backup_assert_failed_cleanly "$bucket" "pg_dump error in the compression pipeline"
  assert_log_contains 'no matching tables were found for pattern "no_such_table"'

  bk_backup wrong-password "$db" "$bucket" -e POSTGRES_PASSWORD=wrong-password
  _backup_assert_failed_cleanly "$bucket" "backup with a wrong password"
  assert_log_contains 'password authentication failed for user "postgres"'

  bk_backup missing-db "${db}_missing" "$bucket"
  _backup_assert_failed_cleanly "$bucket" "backup of a database that does not exist"
  assert_log_contains "database \"${db}_missing\" does not exist"

  bk_backup missing-db-custom "${db}_missing" "$bucket" -e USE_CUSTOM_FORMAT=yes
  _backup_assert_failed_cleanly "$bucket" "custom-format backup of a database that does not exist"
  assert_log_contains "database \"${db}_missing\" does not exist"
}

test_backup_upload_failure_exits_2() {
  db=$(new_db) || exit 1
  missing="$CASE_SLUG-missing"

  bk_backup plain "$db" "$missing"
  assert_rc 2 "upload to a bucket that does not exist"
  assert_log_contains "Uploading dump to $missing"
  assert_log_contains "NoSuchBucket"
  assert_log_not_contains "SQL backup finished"
  assert_eq "$(bk_tmp_leftovers)" "" "temporary files left in /tmp after a failed upload"

  bk_backup custom "$db" "$missing" -e USE_CUSTOM_FORMAT=yes
  assert_rc 2 "custom-format upload to a bucket that does not exist"
  assert_log_contains "NoSuchBucket"
  assert_log_not_contains "SQL backup finished"
  assert_eq "$(bk_tmp_leftovers)" "" "temporary files left in /tmp after a failed custom-format upload"

  if mc_cli ls "e2e/$missing" >/dev/null 2>&1; then
    fail "the failed upload created bucket $missing"
  fi
}

# ---------------------------------------------------------------------------
# Database names.

test_backup_database_names_needing_quoting() {
  bucket=$(new_bucket) || exit 1
  base=$(printf 't_%s' "$CASE_SLUG" | tr '-' '_' | cut -c1-24)

  # Small databases with a marker each: the names matter here, not the data.
  i=0
  for name in "${base}_UPPER_Case" "${base}-with-hyphen" "${base} with space" \
    "${base}_ünïcødé_データ" "${base}_it's \"quoted\""; do
    i=$((i + 1))
    _backup_new_empty_db "$name"
    psql_exec "$name" "CREATE TABLE name_marker (v text); INSERT INTO name_marker VALUES ('name-marker-$i-end')" >/dev/null \
      || fail "could not add a marker to database $name"

    bk_backup "name$i" "$name" "$bucket"
    assert_rc 0 "backup of database '$name'"
    assert_log_contains "Creating dump of $name database from pg..."
    key=$(s3_single_key "$bucket" "backup/${name}_") || exit 1
    _backup_assert_key "$key" "backup/$name" .sql.gz
    _backup_fetch_plain "$bucket" "$key" "name$i"
    assert_file_contains "$CASE_DIR/name$i.sql" "name-marker-$i-end" "dump of '$name' is not of that database"
  done
  assert_s3_count "$bucket" "" 5 "objects for five databases"

  # The custom-format command is built separately.
  spaced="${base} with space"
  bucket_fc=$(new_bucket fc) || exit 1
  bk_backup custom "$spaced" "$bucket_fc" -e USE_CUSTOM_FORMAT=yes
  assert_rc 0 "custom-format backup of database '$spaced'"
  key=$(s3_single_key "$bucket_fc" backup/) || exit 1
  _backup_assert_key "$key" "backup/$spaced" .dump
  s3_get "$bucket_fc" "$key" "$CASE_DIR/custom.dump"
  _backup_tool pg_restore -f - <"$CASE_DIR/custom.dump" >"$CASE_DIR/custom.sql" || fail "pg_restore cannot read the archive"
  assert_file_contains "$CASE_DIR/custom.sql" "name-marker-3-end" "custom-format dump of '$spaced' is not of that database"
}

test_backup_database_name_starting_with_hyphen() {
  xfail "backup.sh passes POSTGRES_DATABASE to pg_dump as a bare argument, so a name starting with '-' is parsed as options (-d<rest> dumps database <rest>)"
  bucket=$(new_bucket) || exit 1
  # pg_dump reads "-d<decoy>" as "-d <decoy>"; the decoy makes the mix-up visible.
  decoy=$(printf 't_%s_decoy' "$CASE_SLUG" | tr '-' '_')
  _backup_new_empty_db "$decoy"
  psql_exec "$decoy" "CREATE TABLE decoy_marker (v text)" >/dev/null || fail "could not prepare $decoy"
  name="-d$decoy"
  new_db_named "$name"

  bk_backup backup "$name" "$bucket"
  assert_rc 0 "backup of database '$name'"
  key=$(s3_single_key "$bucket" "backup/${name}_") || exit 1
  _backup_fetch_plain "$bucket" "$key" dump
  assert_file_not_contains "$CASE_DIR/dump.sql" "decoy_marker" "backup of '$name' holds database '$decoy' instead"
  assert_file_contains "$CASE_DIR/dump.sql" "CREATE TABLE app.users ("
}

test_backup_database_name_with_equals_sign() {
  xfail "backup.sh passes POSTGRES_DATABASE to pg_dump as a bare argument, so a name containing '=' is parsed as a connection string"
  bucket=$(new_bucket) || exit 1
  name="$(printf 't_%s' "$CASE_SLUG" | tr '-' '_' | cut -c1-40)_a=b"
  new_db_named "$name"

  bk_backup backup "$name" "$bucket"
  assert_rc 0 "backup of database '$name'"
  key=$(s3_single_key "$bucket" "backup/${name}_") || exit 1
  _backup_assert_key "$key" "backup/$name" .sql.gz
  _backup_fetch_plain "$bucket" "$key" dump
  assert_file_contains "$CASE_DIR/dump.sql" "CREATE TABLE app.users ("
}
