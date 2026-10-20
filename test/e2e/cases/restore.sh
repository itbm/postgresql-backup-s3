# Restore (restore.sh): plain and custom formats, CREATE_DATABASE, DROP_DATABASE,
# PARALLEL_JOBS, DECOMPRESSION_CMD, POSTGRES_DATABASE=all and error handling.

# _rst_backup <label> <database> <bucket> [bk_run options...] - takes a backup
# that must succeed.
_rst_backup() {
  bk_backup "$@"
  assert_rc 0 "backup of $2 ($1)"
}

# _rst_empty_db <name> - creates an empty database (from template1).
_rst_empty_db() {
  psql_exec postgres "CREATE DATABASE $(sql_ident "$1")" >/dev/null || fail "could not create database $1"
}

_rst_lit() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"
}

# _rst_table_count <database> - user tables and materialised views in it.
_rst_table_count() {
  psql_exec "$1" "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind IN ('r', 'p', 'm') AND n.nspname NOT IN ('pg_catalog', 'information_schema')
      AND n.nspname NOT LIKE 'pg_toast%'"
}

_rst_assert_db_absent() {
  if db_exists "$1"; then
    fail "${2:-database should not exist}: $1"
  fi
}

# _rst_put_compressed <bucket> <key> <text> [compressor] - uploads text compressed
# with the image's gzip (default) or bzip2, so the host needs nothing beyond Docker.
_rst_put_compressed() {
  printf '%s\n' "$3" | docker run --rm -i --label "e2e.run=$E2E_RUN_ID" --entrypoint "${4:-gzip}" "$E2E_IMAGE" -c \
    >"$CASE_DIR/upload.bin" || fail "could not compress upload for $2"
  s3_put "$1" "$2" "$CASE_DIR/upload.bin"
}

# _rst_truncate <bucket> <key> <new-key> - uploads the first half of an object.
_rst_truncate() {
  s3_get "$1" "$2" "$CASE_DIR/whole"
  _rt_size=$(wc -c <"$CASE_DIR/whole" | tr -d ' ')
  [ "$_rt_size" -gt 1000 ] || fail "object $2 is unexpectedly small ($_rt_size bytes)"
  head -c $((_rt_size / 2)) "$CASE_DIR/whole" >"$CASE_DIR/half"
  s3_put "$1" "$3" "$CASE_DIR/half"
}

# _rst_hold_connection <database> - keeps another session connected to the
# database (as a client would) until it is terminated or the case ends.
_rst_hold_connection() {
  _rh_app="e2e_rst_hold_$(printf '%s' "$CASE_SLUG" | tr '-' '_')"
  trap _rst_release EXIT
  docker exec -d -e "PGAPPNAME=$_rh_app" "$E2E_PG_CTR" psql -X -q -U postgres -d "$1" \
    -c 'SELECT pg_sleep(600)' || fail "could not open the extra session"
  wait_for 30 _rst_holding_at_least 1 || fail "extra session did not connect to $1"
}

_rst_holders() {
  psql_exec postgres "SELECT count(*) FROM pg_stat_activity WHERE application_name = '$_rh_app'"
}

_rst_holding_at_least() {
  [ "$(_rst_holders)" -ge "$1" ]
}

_rst_release() {
  psql_exec postgres "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
    WHERE application_name = '$_rh_app'" >/dev/null 2>&1
}

# _rst_probe_logins <database> - a login event trigger records every session
# that connects, so a test can count pg_restore's connections without racing
# the restore. Needs PostgreSQL 17+; on older servers nothing is counted.
_rst_probe_logins() {
  if [ "$(psql_exec postgres 'SHOW server_version_num')" -lt 170000 ]; then
    note "server older than PostgreSQL 17: pg_restore sessions are not counted"
    return 0
  fi
  psql_exec "$1" "CREATE SCHEMA rst_probe;
    CREATE TABLE rst_probe.logins (pid integer, app text);
    CREATE FUNCTION rst_probe.record_login() RETURNS event_trigger LANGUAGE plpgsql AS
      'BEGIN INSERT INTO rst_probe.logins VALUES (pg_backend_pid(), current_setting(''application_name'')); END';
    CREATE EVENT TRIGGER rst_probe_login ON login EXECUTE FUNCTION rst_probe.record_login()" >/dev/null \
    || fail "could not add the login probe to $1"
}

# _rst_probe_check <database> <test-op> <n> <what> - checks the number of
# pg_restore sessions the probe saw (for example -ge 5), then removes the probe
# so the database can be compared with its source.
_rst_probe_check() {
  [ "$(psql_exec "$1" "SELECT count(*) FROM pg_namespace WHERE nspname = 'rst_probe'")" = 1 ] || return 0
  _rpc_n=$(psql_exec "$1" "SELECT count(DISTINCT pid) FROM rst_probe.logins WHERE app = 'pg_restore'") \
    || fail "could not read the login probe in $1"
  psql_exec "$1" "SET client_min_messages = warning;
    DROP EVENT TRIGGER rst_probe_login; DROP SCHEMA rst_probe CASCADE" >/dev/null \
    || fail "could not remove the login probe from $1"
  [ "$_rpc_n" "$2" "$3" ] || fail "$4: expected $2 $3 pg_restore sessions, got $_rpc_n"
}

# ---------------------------------------------------------------------------
# Plain format round trips.

test_restore_plain_into_new_database() {
  db=$(new_db)
  bucket=$(new_bucket)
  _rst_backup backup "$db" "$bucket"
  key=$(s3_single_key "$bucket" backup/)

  target="${db}_new"
  bk_restore restore "$target" "$bucket" "$key" -e CREATE_DATABASE=yes
  assert_rc 0 "restore into a new database"
  assert_log_contains "Downloading backup file from S3: s3://$bucket/$key"
  assert_log_contains "Creating database $target"
  assert_log_contains "Restoring database $target"
  assert_log_contains "Database restore completed successfully"
  assert_log_not_contains "WARNING"
  assert_log_not_contains "Dropping database"
  assert_same_data "$db" "$target"
  assert_eq "$(bk_tmp_leftovers)" "" "temporary files left in /tmp after restore"
}

test_restore_plain_into_existing_empty_database() {
  db=$(new_db)
  bucket=$(new_bucket)
  _rst_backup backup "$db" "$bucket"
  key=$(s3_single_key "$bucket" backup/)

  target="${db}_existing"
  _rst_empty_db "$target"
  bk_restore restore "$target" "$bucket" "$key"
  assert_rc 0 "restore into an existing empty database"
  assert_log_not_contains "Creating database"
  assert_log_contains "Database restore completed successfully"
  assert_same_data "$db" "$target"
}

test_restore_create_database_when_it_already_exists() {
  db=$(new_db)
  bucket=$(new_bucket)
  _rst_backup backup "$db" "$bucket"
  key=$(s3_single_key "$bucket" backup/)

  target="${db}_existing"
  _rst_empty_db "$target"
  bk_restore restore "$target" "$bucket" "$key" -e CREATE_DATABASE=yes
  assert_rc 0 "CREATE_DATABASE=yes over an existing database"
  assert_log_contains "WARNING: Failed to create database $target. It might already exist."
  assert_log_contains "Database restore completed successfully"
  assert_same_data "$db" "$target"
}

test_restore_plain_ignores_parallel_jobs() {
  db=$(new_db)
  bucket=$(new_bucket)
  _rst_backup backup "$db" "$bucket"
  key=$(s3_single_key "$bucket" backup/)

  bk_restore restore "${db}_copy" "$bucket" "$key" -e CREATE_DATABASE=yes -e PARALLEL_JOBS=4
  assert_rc 0 "plain restore with PARALLEL_JOBS=4"
  assert_log_not_contains "Using parallel restore"
  assert_same_data "$db" "${db}_copy"
}

test_restore_deep_prefix_backup_file() {
  db=$(new_db)
  bucket=$(new_bucket)
  _rst_backup backup "$db" "$bucket" -e S3_PREFIX=a/b/c
  key=$(s3_single_key "$bucket" a/b/c/)
  assert_match "$key" "^a/b/c/${db}_[^/]+\.sql\.gz$" "backup key under the deep prefix"

  bk_restore restore "${db}_copy" "$bucket" "$key" -e CREATE_DATABASE=yes
  assert_rc 0 "restore from a/b/c/"
  assert_log_contains "Downloading backup file from S3: s3://$bucket/$key"
  assert_same_data "$db" "${db}_copy"
  assert_eq "$(bk_tmp_leftovers)" "" "temporary files left in /tmp after restore"
}

# ---------------------------------------------------------------------------
# DROP_DATABASE.

test_restore_drop_and_create_replaces_modified_database() {
  db=$(new_db)
  bucket=$(new_bucket)
  _rst_backup backup "$db" "$bucket"
  key=$(s3_single_key "$bucket" backup/)

  target=$(new_db target)
  psql_exec "$target" "DELETE FROM app.orders WHERE id % 2 = 0;
    UPDATE app.users SET name = 'changed' WHERE id < 100;
    DROP VIEW app.user_order_totals;
    CREATE TABLE public.added_after_backup (id integer);
    SELECT setval('app.invoice_seq', 9999);" >/dev/null || fail "could not modify $target"

  bk_restore restore "$target" "$bucket" "$key" -e DROP_DATABASE=yes -e CREATE_DATABASE=yes
  assert_rc 0 "DROP_DATABASE=yes CREATE_DATABASE=yes"
  assert_log_contains "Dropping database $target"
  assert_log_contains "Creating database $target"
  assert_log_not_contains "WARNING"
  assert_same_data "$db" "$target"
}

test_restore_drop_terminates_other_sessions() {
  db=$(new_db)
  bucket=$(new_bucket)
  _rst_backup backup "$db" "$bucket" -e USE_CUSTOM_FORMAT=yes
  key=$(s3_single_key "$bucket" backup/)

  target=$(new_db target)
  psql_exec "$target" "CREATE TABLE public.added_after_backup (id integer)" >/dev/null \
    || fail "could not modify $target"
  _rst_hold_connection "$target"

  bk_restore restore "$target" "$bucket" "$key" -e DROP_DATABASE=yes -e CREATE_DATABASE=yes
  assert_rc 0 "drop while another session is connected"
  assert_log_contains "Dropping database $target"
  assert_log_not_contains "WARNING"
  assert_eq "$(_rst_holders)" 0 "the other session should have been terminated"
  assert_same_data "$db" "$target"
}

test_restore_drop_without_create_fails() {
  db=$(new_db)
  bucket=$(new_bucket)
  _rst_backup plain "$db" "$bucket" -e S3_PREFIX=plain
  _rst_backup custom "$db" "$bucket" -e S3_PREFIX=custom -e USE_CUSTOM_FORMAT=yes

  for fmt in plain custom; do
    key=$(s3_single_key "$bucket" "$fmt/")
    target=$(new_db "$fmt")
    bk_restore "restore-$fmt" "$target" "$bucket" "$key" -e DROP_DATABASE=yes
    assert_rc_nonzero "$fmt restore after dropping the database without recreating it"
    assert_log_contains "Dropping database $target"
    assert_log_contains "does not exist"
    assert_log_not_contains "Database restore completed successfully"
    _rst_assert_db_absent "$target" "DROP_DATABASE=yes should have dropped it"
    assert_eq "$(bk_tmp_leftovers)" "" "temporary files left in /tmp after a failed $fmt restore"
  done
}

test_restore_quoted_database_names() {
  src='Rst Src "Q"-Upper'
  target='Rst Dst "Q"-Upper'
  new_db_named "$src"
  bucket=$(new_bucket)
  _rst_backup plain "$src" "$bucket" -e S3_PREFIX=plain
  _rst_backup custom "$src" "$bucket" -e S3_PREFIX=custom -e USE_CUSTOM_FORMAT=yes
  plain_key=$(s3_single_key "$bucket" plain/)
  custom_key=$(s3_single_key "$bucket" custom/)

  # DROP of a database that does not exist yet is not an error.
  bk_restore plain "$target" "$bucket" "$plain_key" -e DROP_DATABASE=yes -e CREATE_DATABASE=yes
  assert_rc 0 "plain restore into a database whose name needs quoting"
  assert_log_contains "Creating database $target"
  assert_log_not_contains "WARNING"
  assert_same_data "$src" "$target"

  psql_exec "$target" "CREATE TABLE public.added_after_backup (id integer)" >/dev/null \
    || fail "could not modify $target"
  bk_restore custom "$target" "$bucket" "$custom_key" -e DROP_DATABASE=yes -e CREATE_DATABASE=yes \
    -e PARALLEL_JOBS=2
  assert_rc 0 "custom restore over a database whose name needs quoting"
  assert_log_contains "Dropping database $target"
  assert_log_not_contains "WARNING"
  assert_same_data "$src" "$target"
  assert_eq "$(bk_tmp_leftovers)" "" "temporary files left in /tmp after restore"
}

# ---------------------------------------------------------------------------
# Custom format and PARALLEL_JOBS.

test_restore_custom_format_parallel_jobs() {
  db=$(new_db)
  bucket=$(new_bucket)
  _rst_backup backup "$db" "$bucket" -e USE_CUSTOM_FORMAT=yes
  key=$(s3_single_key "$bucket" backup/)
  assert_match "$key" '\.dump$' "custom format key"

  _rst_empty_db "${db}_default"
  _rst_probe_logins "${db}_default"
  bk_restore default "${db}_default" "$bucket" "$key"
  assert_rc 0 "custom restore with the default PARALLEL_JOBS"
  assert_log_contains "Restoring database ${db}_default from custom format"
  assert_log_not_contains "Using parallel restore"
  _rst_probe_check "${db}_default" -eq 1 "serial restore"
  assert_same_data "$db" "${db}_default"

  bk_restore one "${db}_one" "$bucket" "$key" -e CREATE_DATABASE=yes -e PARALLEL_JOBS=1
  assert_rc 0 "custom restore with PARALLEL_JOBS=1"
  assert_log_not_contains "Using parallel restore"
  assert_same_data "$db" "${db}_one"

  _rst_empty_db "${db}_four"
  _rst_probe_logins "${db}_four"
  bk_restore four "${db}_four" "$bucket" "$key" -e PARALLEL_JOBS=4
  assert_rc 0 "custom restore with PARALLEL_JOBS=4"
  assert_log_contains "Using parallel restore with 4 jobs"
  # pg_restore -j N opens one session per worker plus the leader's.
  _rst_probe_check "${db}_four" -ge 5 "PARALLEL_JOBS=4"
  assert_same_data "$db" "${db}_four"
  assert_eq "$(bk_tmp_leftovers)" "" "temporary files left in /tmp after restore"
}

test_restore_custom_format_ignores_decompression_cmd() {
  db=$(new_db)
  bucket=$(new_bucket)
  _rst_backup backup "$db" "$bucket" -e USE_CUSTOM_FORMAT=yes
  key=$(s3_single_key "$bucket" backup/)

  bk_restore restore "${db}_copy" "$bucket" "$key" -e CREATE_DATABASE=yes -e DECOMPRESSION_CMD=false
  assert_rc 0 "custom restore with DECOMPRESSION_CMD=false"
  assert_same_data "$db" "${db}_copy"
}

test_restore_custom_format_errors_fail_restore() {
  db=$(new_db)
  bucket=$(new_bucket)
  _rst_backup backup "$db" "$bucket" -e USE_CUSTOM_FORMAT=yes
  key=$(s3_single_key "$bucket" backup/)

  # The objects already exist, so pg_restore reports errors, serial or parallel.
  for jobs in 1 2; do
    target=$(new_db "j$jobs")
    bk_restore "restore-j$jobs" "$target" "$bucket" "$key" -e "PARALLEL_JOBS=$jobs"
    assert_rc_nonzero "pg_restore errors should fail the restore (PARALLEL_JOBS=$jobs)"
    assert_log_contains "errors ignored on restore"
    assert_log_not_contains "Database restore completed successfully"
    assert_eq "$(bk_tmp_leftovers)" "" "temporary files left in /tmp after a failed restore"
  done
  assert_log_contains "Using parallel restore with 2 jobs"
}

# ---------------------------------------------------------------------------
# DECOMPRESSION_CMD.

test_restore_decompression_cmd_pigz() {
  db=$(new_db)
  bucket=$(new_bucket)
  _rst_backup backup "$db" "$bucket"
  key=$(s3_single_key "$bucket" backup/)

  bk_restore restore "${db}_copy" "$bucket" "$key" -e CREATE_DATABASE=yes -e "DECOMPRESSION_CMD=pigz -dc"
  assert_rc 0 "restore with DECOMPRESSION_CMD='pigz -dc'"
  assert_same_data "$db" "${db}_copy"
}

test_restore_pigz_backup_with_default_decompression() {
  db=$(new_db)
  bucket=$(new_bucket)
  _rst_backup backup "$db" "$bucket" -e COMPRESSION_CMD=pigz
  key=$(s3_single_key "$bucket" backup/)

  bk_restore restore "${db}_copy" "$bucket" "$key" -e CREATE_DATABASE=yes
  assert_rc 0 "restore of a pigz backup with the default gunzip -c"
  assert_same_data "$db" "${db}_copy"
}

test_restore_decompression_cmd_other_codec() {
  db=$(new_db)
  bucket=$(new_bucket)
  _rst_backup backup "$db" "$bucket" -e COMPRESSION_CMD=bzip2
  key=$(s3_single_key "$bucket" backup/)

  # The object is bzip2 despite its .sql.gz name, so the default gunzip -c must fail.
  _rst_empty_db "${db}_default"
  bk_restore default "${db}_default" "$bucket" "$key"
  assert_rc_nonzero "default DECOMPRESSION_CMD on bzip2 data"
  assert_log_not_contains "Database restore completed successfully"
  assert_eq "$(_rst_table_count "${db}_default")" 0 "nothing should be restored"

  bk_restore bzip2 "${db}_copy" "$bucket" "$key" -e CREATE_DATABASE=yes -e "DECOMPRESSION_CMD=bzip2 -dc"
  assert_rc 0 "restore with DECOMPRESSION_CMD='bzip2 -dc'"
  assert_same_data "$db" "${db}_copy"
}

# ---------------------------------------------------------------------------
# POSTGRES_DATABASE=all.

test_restore_all_databases_into_fresh_server() {
  bucket=$(new_bucket)
  src=$(start_postgres rst-src)
  db=$(printf 't_%s' "$CASE_SLUG" | tr '-' '_')
  other='Rst All Other'
  PG_CTR=$src psql_exec postgres "CREATE DATABASE $db" >/dev/null || fail "could not create $db"
  docker exec -i "$src" psql -X -q -U postgres -d "$db" -v ON_ERROR_STOP=1 -f - \
    <"$E2E_DIR/fixtures/seed.sql" >/dev/null || fail "could not load seed data into $db"
  PG_CTR=$src psql_exec postgres "CREATE ROLE rst_all_owner LOGIN PASSWORD 'rst-owner-pw'" >/dev/null \
    || fail "could not create role rst_all_owner"
  PG_CTR=$src psql_exec postgres "CREATE DATABASE $(sql_ident "$other") OWNER rst_all_owner" >/dev/null \
    || fail "could not create $other"
  PG_CTR=$src psql_exec "$other" "SET ROLE rst_all_owner;
    CREATE TABLE notes (id integer PRIMARY KEY, body text); INSERT INTO notes VALUES (1, 'kept')" >/dev/null \
    || fail "could not fill $other"

  bk_backup backup all "$bucket" --unset POSTGRES_HOST -e POSTGRES_HOST=rst-src
  assert_rc 0 "pg_dumpall backup"
  key=$(s3_single_key "$bucket" backup/)
  assert_match "$key" '^backup/all_[^/]+\.sql\.gz$' "backup key for all"

  dst=$(start_postgres rst-dst)
  bk_restore restore all "$bucket" "$key" --unset POSTGRES_HOST -e POSTGRES_HOST=rst-dst
  assert_rc 0 "restore of all databases into a fresh server"
  assert_log_contains "Restoring all databases"
  assert_log_contains "Database restore completed successfully"
  assert_eq "$(bk_tmp_leftovers)" "" "temporary files left in /tmp after restore"

  PG_CTR=$dst db_exists "$db" || fail "database $db missing on the new server"
  PG_CTR=$dst db_exists "$other" || fail "database $other missing on the new server"
  assert_eq "$(PG_CTR=$dst psql_exec postgres "SELECT pg_get_userbyid(datdba) FROM pg_database
    WHERE datname = $(_rst_lit "$other")")" rst_all_owner "owner of $other"
  # Logging in over TCP proves the role and its password hash came across.
  body=$(docker exec -e PGPASSWORD=rst-owner-pw "$dst" psql -X -h 127.0.0.1 -U rst_all_owner \
    -d "$other" -Atc 'SELECT body FROM notes WHERE id = 1') || fail "could not log in as rst_all_owner"
  assert_eq "$body" kept "row in $other"
  PG_CTR=$src assert_same_data "$db" "$db" "$dst"
}

test_restore_all_uses_decompression_cmd() {
  bucket=$(new_bucket)
  marker=$(printf 't_%s_marker' "$CASE_SLUG" | tr '-' '_')
  _rst_put_compressed "$bucket" backup/all.sql.gz "CREATE DATABASE $marker;" bzip2

  bk_restore default all "$bucket" backup/all.sql.gz
  assert_rc_nonzero "default DECOMPRESSION_CMD on bzip2 data with POSTGRES_DATABASE=all"
  assert_log_contains "Restoring all databases"
  assert_log_not_contains "Database restore completed successfully"
  _rst_assert_db_absent "$marker" "nothing should be restored"

  bk_restore bzip2 all "$bucket" backup/all.sql.gz -e "DECOMPRESSION_CMD=bzip2 -dc"
  assert_rc 0 "restore of all databases with DECOMPRESSION_CMD='bzip2 -dc'"
  assert_log_contains "Database restore completed successfully"
  db_exists "$marker" || fail "the bzip2 backup was not restored: $marker is missing"
}

test_restore_all_rejects_custom_format() {
  bucket=$(new_bucket)
  s3_put_string "$bucket" backup/all_custom.dump "not really a dump"

  bk_restore restore all "$bucket" backup/all_custom.dump
  assert_rc 1 "custom format with POSTGRES_DATABASE=all"
  assert_log_contains "ERROR: Custom format backup cannot be used to restore all databases."
  assert_log_not_contains "Database restore completed successfully"
  assert_eq "$(bk_tmp_leftovers)" "" "temporary files left in /tmp after a failed restore"
}

test_restore_all_rejects_drop_and_create() {
  bucket=$(new_bucket)
  marker=$(printf 't_%s_marker' "$CASE_SLUG" | tr '-' '_')
  # Restoring this would create the marker database.
  _rst_put_compressed "$bucket" backup/all.sql.gz "CREATE DATABASE $marker;"

  bk_restore drop all "$bucket" backup/all.sql.gz -e DROP_DATABASE=yes
  assert_rc 1 "DROP_DATABASE=yes with POSTGRES_DATABASE=all"
  assert_log_contains "Cannot drop all databases"
  _rst_assert_db_absent "$marker" "the backup should not have been restored"

  bk_restore create all "$bucket" backup/all.sql.gz -e CREATE_DATABASE=yes
  assert_rc 1 "CREATE_DATABASE=yes with POSTGRES_DATABASE=all"
  assert_log_contains "Cannot create all databases"
  _rst_assert_db_absent "$marker" "the backup should not have been restored"
  assert_eq "$(bk_tmp_leftovers)" "" "temporary files left in /tmp after a failed restore"
}

# ---------------------------------------------------------------------------
# Errors.

test_restore_missing_object_exits_2() {
  db=$(new_db)
  bucket=$(new_bucket)

  bk_restore restore "$db" "$bucket" "backup/${db}_missing.sql.gz" -e DROP_DATABASE=yes -e CREATE_DATABASE=yes
  assert_rc 2 "restore of a missing object"
  assert_log_contains "Downloading backup file from S3: s3://$bucket/backup/${db}_missing.sql.gz"
  assert_log_not_contains "Dropping database"
  assert_log_not_contains "Database restore completed successfully"
  assert_same_data e2e_seed "$db"
  assert_eq "$(bk_tmp_leftovers)" "" "temporary files left in /tmp after a failed restore"
}

test_restore_unsupported_extensions_rejected() {
  bucket=$(new_bucket)
  target=$(printf 't_%s' "$CASE_SLUG" | tr '-' '_')
  _rst_empty_db "$target"

  for ext in txt sql; do
    s3_put_string "$bucket" "backup/dump.$ext" "CREATE TABLE rst_marker_$ext (id integer);"
    bk_restore "restore-$ext" "$target" "$bucket" "backup/dump.$ext"
    assert_rc 1 ".$ext backup file"
    assert_log_contains "ERROR: Unsupported backup format. Expected *.sql.gz or *.dump file."
    assert_log_not_contains "Database restore completed successfully"
    assert_eq "$(_rst_table_count "$target")" 0 "the .$ext file should not have been executed"
    assert_eq "$(bk_tmp_leftovers)" "" "temporary files left in /tmp after a failed restore"
  done
}

test_restore_unsupported_format_keeps_dropped_database() {
  xfail "DROP_DATABASE runs before the format check, so an unsupported file name drops the database and restores nothing"
  db=$(new_db)
  bucket=$(new_bucket)
  s3_put_string "$bucket" "backup/${db}.sql" "SELECT 1;"

  bk_restore restore "$db" "$bucket" "backup/${db}.sql" -e DROP_DATABASE=yes -e CREATE_DATABASE=yes
  assert_rc 1 "unsupported backup file with DROP_DATABASE=yes"
  assert_log_contains "Unsupported backup format"
  assert_same_data e2e_seed "$db"
}

test_restore_corrupt_files_fail() {
  db=$(new_db)
  bucket=$(new_bucket)
  _rst_backup plain "$db" "$bucket" -e S3_PREFIX=plain
  _rst_backup custom "$db" "$bucket" -e S3_PREFIX=custom -e USE_CUSTOM_FORMAT=yes
  _rst_truncate "$bucket" "$(s3_single_key "$bucket" plain/)" broken/truncated.sql.gz
  _rst_truncate "$bucket" "$(s3_single_key "$bucket" custom/)" broken/truncated.dump
  s3_put_string "$bucket" broken/garbage.sql.gz "this is not gzip data"

  for name in garbage.sql.gz truncated.sql.gz truncated.dump; do
    label=$(printf '%s' "$name" | tr '.' '-')
    bk_restore "$label" "${db}_$(printf '%s' "$label" | tr '-' '_')" "$bucket" "broken/$name" \
      -e CREATE_DATABASE=yes
    assert_rc_nonzero "restore of $name"
    assert_log_not_contains "Database restore completed successfully"
    assert_eq "$(bk_tmp_leftovers)" "" "temporary files left in /tmp after restoring $name"
  done
}

# ---------------------------------------------------------------------------
# POSTGRES_EXTRA_OPTS.

test_restore_extra_opts_reach_psql_and_pg_restore() {
  db=$(new_db)
  bucket=$(new_bucket)
  _rst_backup plain "$db" "$bucket" -e S3_PREFIX=plain
  _rst_backup custom "$db" "$bucket" -e S3_PREFIX=custom -e USE_CUSTOM_FORMAT=yes
  plain_key=$(s3_single_key "$bucket" plain/)
  custom_key=$(s3_single_key "$bucket" custom/)
  target="${db}_copy"

  # Nothing listens on port 1; a later -p in POSTGRES_EXTRA_OPTS wins.
  bk_restore control "$target" "$bucket" "$plain_key" -e CREATE_DATABASE=yes -e POSTGRES_PORT=1
  assert_rc_nonzero "control: wrong POSTGRES_PORT without extra options"
  assert_log_contains "port 1 failed"

  bk_restore plain "$target" "$bucket" "$plain_key" -e CREATE_DATABASE=yes -e POSTGRES_PORT=1 \
    -e "POSTGRES_EXTRA_OPTS=-p 5432"
  assert_rc 0 "plain restore with the port from POSTGRES_EXTRA_OPTS"
  assert_log_not_contains "WARNING"
  assert_same_data "$db" "$target"

  psql_exec "$target" "CREATE TABLE public.added_after_backup (id integer)" >/dev/null \
    || fail "could not modify $target"
  bk_restore custom "$target" "$bucket" "$custom_key" -e DROP_DATABASE=yes -e CREATE_DATABASE=yes \
    -e PARALLEL_JOBS=2 -e POSTGRES_PORT=1 -e "POSTGRES_EXTRA_OPTS=-p 5432"
  assert_rc 0 "custom restore with the port from POSTGRES_EXTRA_OPTS"
  assert_log_not_contains "WARNING"
  assert_same_data "$db" "$target"
}
