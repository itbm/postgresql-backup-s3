# TLS to S3 against minio-tls: certificate and hostname verification, S3_CA_BUNDLE,
# CAs mounted into /usr/local/share/ca-certificates, AWS_CA_BUNDLE and S3_SSL_VERIFY.

_TLS_ENDPOINT=https://minio-tls:9000
_TLS_SYS_DIR=/usr/local/share/ca-certificates
_TLS_TS_RE='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'

# ---------------------------------------------------------------------------
# Helpers.

# _tls_begin - call first in every test (after xfail). Databases recorded with
# _tls_db or _tls_track are dropped when the case ends, so a full run does not
# keep growing the server's data volume. E2E_KEEP=1 keeps them.
_tls_begin() {
  : >"$CASE_DIR/tls-dbs"
  [ "${E2E_KEEP:-0}" = 1 ] || trap _tls_end EXIT
}

_tls_end() {
  # fd 3, because psql_exec (docker exec -i) would swallow the rest of stdin.
  while IFS= read -r _te_db <&3; do
    [ -z "$_te_db" ] || drop_db "$_te_db" </dev/null >/dev/null 2>&1
  done 3<"$CASE_DIR/tls-dbs"
}

_tls_track() {
  printf '%s\n' "$@" >>"$CASE_DIR/tls-dbs"
}

# _tls_db [suffix] - new_db, recorded for dropping. Use as db=$(_tls_db) || exit 1.
_tls_db() {
  _td_name=$(new_db "$@") || exit 1
  _tls_track "$_td_name"
  printf '%s\n' "$_td_name"
}

# Buckets on minio-tls, inspected through mc (which trusts the e2e CA).
_tls_bucket() {
  S3_ALIAS=tls new_bucket "$@"
}

_tls_count() {
  S3_ALIAS=tls s3_count "$@"
}

# _tls_backup <label> <database> <bucket> [bk_run options...] - backup to minio-tls.
_tls_backup() {
  _tb_label=$1 _tb_db=$2 _tb_bucket=$3
  shift 3
  bk_backup "$_tb_label" "$_tb_db" "$_tb_bucket" --unset S3_ENDPOINT -e "S3_ENDPOINT=$_TLS_ENDPOINT" "$@"
}

# _tls_restore <label> <database> <bucket> <key> [bk_run options...]
_tls_restore() {
  _tr_label=$1 _tr_db=$2 _tr_bucket=$3 _tr_key=$4
  shift 4
  bk_restore "$_tr_label" "$_tr_db" "$_tr_bucket" "$_tr_key" --unset S3_ENDPOINT \
    -e "S3_ENDPOINT=$_TLS_ENDPOINT" "$@"
}

# _tls_backup_key <database> <bucket> - prints the only backup in the bucket and
# checks its name.
_tls_backup_key() {
  _tk_key=$(S3_ALIAS=tls s3_single_key "$2" backup/) || exit 1
  assert_match "$_tk_key" "^backup/$1_${_TLS_TS_RE}\.sql\.gz\$" "backup key"
  printf '%s\n' "$_tk_key"
}

# _tls_assert_backup_ok <what> - the last backup to minio-tls succeeded.
_tls_assert_backup_ok() {
  assert_rc 0 "$1"
  assert_log_contains "SQL backup finished" "$1"
  assert_log_not_contains "SSL validation failed" "$1"
}

# _tls_assert_rejected <bucket> <what> [reason-regex] - the last backup failed
# the TLS check on upload (exit 2) and nothing reached the bucket.
_tls_assert_rejected() {
  assert_rc 2 "$2"
  assert_log_contains "SSL validation failed for " "$2"
  grep -Eq -- "${3:-CERTIFICATE_VERIFY_FAILED}" "$BK_LOG" \
    || fail "$2: log does not give the expected TLS failure /${3:-CERTIFICATE_VERIFY_FAILED}/"
  assert_log_not_contains "SQL backup finished" "$2"
  assert_eq "$(_tls_count "$1")" 0 "objects uploaded although TLS verification failed ($2)"
}

# _tls_roundtrip <what> [bk_run options...] - backs up a new database to a new
# minio-tls bucket, restores it into a new database, both with the given
# options, and compares the data.
_tls_roundtrip() {
  _rt_what=$1
  shift
  _rt_db=$(_tls_db) || exit 1
  _rt_bucket=$(_tls_bucket) || exit 1

  _tls_backup backup "$_rt_db" "$_rt_bucket" "$@"
  _tls_assert_backup_ok "backup with $_rt_what"
  _rt_key=$(_tls_backup_key "$_rt_db" "$_rt_bucket") || exit 1

  _rt_restored="${_rt_db}_restored"
  _tls_track "$_rt_restored"
  _tls_restore restore "$_rt_restored" "$_rt_bucket" "$_rt_key" -e CREATE_DATABASE=yes "$@"
  assert_rc 0 "restore with $_rt_what"
  assert_log_contains "Database restore completed successfully"
  assert_log_not_contains "SSL validation failed"
  assert_same_data "$_rt_db" "$_rt_restored"
}

# _tls_seed_backup <database> <bucket> - puts a good backup of the database into
# the minio-tls bucket without relying on the image's TLS settings (a plain
# HTTP backup, copied across with mc) and prints its key.
_tls_seed_backup() {
  _sb_plain=$(new_bucket plain) || exit 1
  bk_backup seed "$1" "$_sb_plain"
  assert_rc 0 "plain HTTP backup used as the restore source"
  _sb_key=$(s3_single_key "$_sb_plain" backup/) || exit 1
  mc_cli cp "e2e/$_sb_plain/$_sb_key" "tls/$2/$_sb_key" >/dev/null \
    || fail "could not copy the backup to minio-tls"
  printf '%s\n' "$_sb_key"
}

# _tls_cutoff - prints a time (seconds since the epoch) later than every object
# uploaded so far, and returns once objects uploaded from now on are newer than
# it, so DELETE_OLDER_THAN=@<cutoff> deletes exactly the earlier ones. Two
# seconds of slack either side cover the one-second resolution of S3 listings
# and small clock differences between the host and the Docker VM.
_tls_cutoff() {
  _tc_at=$(($(date +%s) + 2))
  wait_for 15 _tls_now_at_least $((_tc_at + 2)) || fail "clock did not advance"
  printf '%s\n' "$_tc_at"
}

_tls_now_at_least() {
  [ "$(date +%s)" -ge "$1" ]
}

_tls_log_count() {
  bk_logs
  grep -Fc -- "$1" "$BK_LOG" || true
}

_tls_log_has_at_least() {
  [ "$(_tls_log_count "$1")" -ge "$2" ]
}

# ---------------------------------------------------------------------------
# Verification is on by default.

test_tls_no_ca_backup_rejected() {
  _tls_begin
  db=$(_tls_db) || exit 1
  bucket=$(_tls_bucket) || exit 1

  _tls_backup backup "$db" "$bucket"
  _tls_assert_rejected "$bucket" "backup over TLS with no CA configured"
  assert_eq "$(bk_tmp_leftovers)" "" "temporary files left in /tmp after the rejected upload"
}

test_tls_ssl_verify_yes_rejects_unknown_ca() {
  _tls_begin
  db=$(_tls_db) || exit 1
  bucket=$(_tls_bucket) || exit 1

  _tls_backup backup "$db" "$bucket" -e S3_SSL_VERIFY=yes
  _tls_assert_rejected "$bucket" "backup with S3_SSL_VERIFY=yes and no CA configured"
}

test_tls_no_ca_restore_rejected_before_touching_database() {
  _tls_begin
  db=$(_tls_db) || exit 1
  bucket=$(_tls_bucket) || exit 1
  key=$(_tls_seed_backup "$db" "$bucket") || exit 1
  restored="${db}_restored"
  _tls_track "$restored"

  _tls_restore restore "$restored" "$bucket" "$key" -e CREATE_DATABASE=yes
  assert_rc 2 "restore over TLS with no CA configured"
  assert_log_contains "SSL validation failed for "
  assert_log_contains "CERTIFICATE_VERIFY_FAILED"
  assert_log_not_contains "Restoring database"
  assert_log_not_contains "Database restore completed successfully"
  if db_exists "$restored"; then
    fail "restore created $restored although the download was rejected"
  fi
  assert_eq "$(bk_tmp_leftovers)" "" "temporary files left in /tmp after the rejected download"
}

# ---------------------------------------------------------------------------
# Trusting the minio-tls CA.

test_tls_ca_bundle_backup_and_restore() {
  _tls_begin
  _tls_roundtrip "S3_CA_BUNDLE" -e S3_CA_BUNDLE=/certs/ca.crt -v "$E2E_CERTS/ca.crt:/certs/ca.crt:ro"
}

test_tls_ca_bundle_accepts_multi_cert_bundle_at_path_with_space() {
  _tls_begin
  db=$(_tls_db) || exit 1
  bucket=$(_tls_bucket) || exit 1
  # The right CA comes second, so only reading the first certificate would fail.
  cat "$E2E_CERTS/other-ca.crt" "$E2E_CERTS/ca.crt" >"$CASE_DIR/bundle.pem"
  chmod 644 "$CASE_DIR/bundle.pem"

  _tls_backup backup "$db" "$bucket" -e "S3_CA_BUNDLE=/etc/s3 certs/ca bundle.pem" \
    -v "$CASE_DIR/bundle.pem:/etc/s3 certs/ca bundle.pem:ro"
  _tls_assert_backup_ok "backup with a two-certificate S3_CA_BUNDLE at a path with spaces"
  _tls_backup_key "$db" "$bucket" >/dev/null || exit 1
}

test_tls_system_ca_dir_backup_and_restore() {
  _tls_begin
  _tls_roundtrip "the CA mounted in $_TLS_SYS_DIR" -v "$(e2e_ca_system_mount)"
}

test_tls_system_ca_dir_trusts_every_crt_file() {
  _tls_begin
  db=$(_tls_db) || exit 1
  bucket=$(_tls_bucket) || exit 1

  # Two files, the right one sorting last.
  _tls_backup backup "$db" "$bucket" \
    -v "$E2E_CERTS/other-ca.crt:$_TLS_SYS_DIR/a-unrelated.crt:ro" \
    -v "$E2E_CERTS/ca.crt:$_TLS_SYS_DIR/z-e2e.crt:ro"
  _tls_assert_backup_ok "backup with two CA files mounted in $_TLS_SYS_DIR"
  _tls_backup_key "$db" "$bucket" >/dev/null || exit 1
}

test_tls_system_ca_dir_ignores_file_without_crt_suffix() {
  _tls_begin
  db=$(_tls_db) || exit 1
  bucket=$(_tls_bucket) || exit 1

  _tls_backup backup "$db" "$bucket" -v "$E2E_CERTS/ca.crt:$_TLS_SYS_DIR/e2e-ca.pem:ro"
  _tls_assert_rejected "$bucket" "backup with the CA mounted as $_TLS_SYS_DIR/e2e-ca.pem"
}

test_tls_system_ca_dir_scheduled_backups() {
  _tls_begin
  db=$(_tls_db) || exit 1
  bucket=$(_tls_bucket) || exit 1

  # run.sh sets up the trust store once, before handing over to go-cron.
  bk_start cron -e "POSTGRES_DATABASE=$db" -e "S3_BUCKET=$bucket" --unset S3_ENDPOINT \
    -e "S3_ENDPOINT=$_TLS_ENDPOINT" -e "SCHEDULE=@every 2s" -v "$(e2e_ca_system_mount)"
  wait_for 90 _tls_log_has_at_least "Command finished" 2 \
    || fail "fewer than 2 scheduled runs finished within 90s"
  assert_log_not_contains "SSL validation failed"
  assert_log_not_contains "Command finished with error"
  assert_log_contains "Command finished successfully"
  bk_stop

  n=$(_tls_count "$bucket" backup/)
  [ "$n" -ge 2 ] || fail "expected at least 2 scheduled backups in s3://$bucket/backup/, got $n"
}

test_tls_aws_ca_bundle_backup_and_restore() {
  _tls_begin
  _tls_roundtrip "AWS_CA_BUNDLE" -e AWS_CA_BUNDLE=/certs/ca.crt -v "$E2E_CERTS/ca.crt:/certs/ca.crt:ro"
}

# ---------------------------------------------------------------------------
# Precedence: S3_CA_BUNDLE, then a pre-set AWS_CA_BUNDLE, then the system path.

test_tls_ca_bundle_overrides_system_ca_dir() {
  _tls_begin
  db=$(_tls_db) || exit 1
  bucket=$(_tls_bucket) || exit 1

  _tls_backup backup "$db" "$bucket" -v "$E2E_CERTS/other-ca.crt:$_TLS_SYS_DIR/other-ca.crt:ro" \
    -e S3_CA_BUNDLE=/certs/ca.crt -v "$E2E_CERTS/ca.crt:/certs/ca.crt:ro"
  _tls_assert_backup_ok "backup with the right S3_CA_BUNDLE and an unrelated CA in $_TLS_SYS_DIR"
  _tls_backup_key "$db" "$bucket" >/dev/null || exit 1
}

test_tls_ca_bundle_overrides_aws_ca_bundle() {
  _tls_begin
  db=$(_tls_db) || exit 1
  bucket=$(_tls_bucket) || exit 1

  _tls_backup backup "$db" "$bucket" -e AWS_CA_BUNDLE=/certs/other-ca.crt \
    -v "$E2E_CERTS/other-ca.crt:/certs/other-ca.crt:ro" \
    -e S3_CA_BUNDLE=/certs/ca.crt -v "$E2E_CERTS/ca.crt:/certs/ca.crt:ro"
  _tls_assert_backup_ok "backup with the right S3_CA_BUNDLE and an unrelated AWS_CA_BUNDLE"
  _tls_backup_key "$db" "$bucket" >/dev/null || exit 1
}

test_tls_aws_ca_bundle_wins_over_system_ca_dir() {
  _tls_begin
  db=$(_tls_db) || exit 1
  bucket=$(_tls_bucket) || exit 1

  _tls_backup backup "$db" "$bucket" -v "$(e2e_ca_system_mount)" \
    -e AWS_CA_BUNDLE=/certs/other-ca.crt -v "$E2E_CERTS/other-ca.crt:/certs/other-ca.crt:ro"
  _tls_assert_rejected "$bucket" "backup with an unrelated AWS_CA_BUNDLE and the right CA in $_TLS_SYS_DIR"
}

# ---------------------------------------------------------------------------
# Misconfigured trust fails closed.

test_tls_ca_bundle_wrong_ca_rejected() {
  _tls_begin
  db=$(_tls_db) || exit 1
  bucket=$(_tls_bucket) || exit 1

  _tls_backup backup "$db" "$bucket" -e S3_CA_BUNDLE=/certs/other-ca.crt \
    -v "$E2E_CERTS/other-ca.crt:/certs/other-ca.crt:ro"
  _tls_assert_rejected "$bucket" "backup with S3_CA_BUNDLE set to an unrelated CA"
}

test_tls_ca_bundle_missing_file_fails_closed() {
  _tls_begin
  db=$(_tls_db) || exit 1
  bucket=$(_tls_bucket) || exit 1

  # The system directory would work; a broken S3_CA_BUNDLE must not fall back to it.
  _tls_backup backup "$db" "$bucket" -e S3_CA_BUNDLE=/certs/missing.crt -v "$(e2e_ca_system_mount)"
  assert_rc_nonzero "backup with S3_CA_BUNDLE pointing at a missing file"
  assert_log_not_contains "SQL backup finished"
  assert_eq "$(_tls_count "$bucket")" 0 "objects uploaded with a missing S3_CA_BUNDLE"
}

test_tls_hostname_mismatch_rejected_with_trusted_ca() {
  _tls_begin
  db=$(_tls_db) || exit 1
  bucket=$(_tls_bucket) || exit 1

  # Same server, reached by its container name, which the certificate does not list.
  bk_backup backup "$db" "$bucket" --unset S3_ENDPOINT -e "S3_ENDPOINT=https://${E2E_RUN_ID}-minio-tls:9000" \
    -e S3_CA_BUNDLE=/certs/ca.crt -v "$E2E_CERTS/ca.crt:/certs/ca.crt:ro"
  # urllib3 and OpenSSL word the mismatch differently.
  _tls_assert_rejected "$bucket" "backup to a host name the certificate does not cover" \
    "hostname '${E2E_RUN_ID}-minio-tls' doesn't match|Hostname mismatch"
}

# ---------------------------------------------------------------------------
# S3_SSL_VERIFY=no.

test_tls_ssl_verify_no_backup_retention_and_restore() {
  _tls_begin
  db=$(_tls_db) || exit 1
  bucket=$(_tls_bucket) || exit 1
  S3_ALIAS=tls s3_put_string "$bucket" backup/old.sql.gz "an old backup"
  cutoff=$(_tls_cutoff) || exit 1

  _tls_backup backup "$db" "$bucket" -e S3_SSL_VERIFY=no -e "DELETE_OLDER_THAN=@$cutoff"
  _tls_assert_backup_ok "backup with S3_SSL_VERIFY=no, no CA and DELETE_OLDER_THAN"
  assert_log_contains "DELETING old.sql.gz"
  S3_ALIAS=tls assert_s3_absent "$bucket" backup/old.sql.gz "retention over TLS did not delete the old backup"
  key=$(_tls_backup_key "$db" "$bucket") || exit 1

  restored="${db}_restored"
  _tls_track "$restored"
  _tls_restore restore "$restored" "$bucket" "$key" -e CREATE_DATABASE=yes -e S3_SSL_VERIFY=no
  assert_rc 0 "restore with S3_SSL_VERIFY=no and no CA"
  assert_log_contains "Database restore completed successfully"
  assert_same_data "$db" "$restored"
}

test_tls_ssl_verify_no_ignores_wrong_ca_bundle() {
  _tls_begin
  db=$(_tls_db) || exit 1
  bucket=$(_tls_bucket) || exit 1

  _tls_backup backup "$db" "$bucket" -e S3_SSL_VERIFY=no -e S3_CA_BUNDLE=/certs/other-ca.crt \
    -v "$E2E_CERTS/other-ca.crt:/certs/other-ca.crt:ro"
  _tls_assert_backup_ok "backup with S3_SSL_VERIFY=no and an unrelated S3_CA_BUNDLE"
  _tls_backup_key "$db" "$bucket" >/dev/null || exit 1
}
