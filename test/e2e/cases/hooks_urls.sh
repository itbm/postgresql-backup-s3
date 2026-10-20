# URL lifecycle hooks: which HOOK_*_URL is requested when, how requests are
# made (GET, no redirects, retries), and which URLs are refused without a
# request being sent.

# Prints this case's requests as "<scheme> <method> <kind>/<event>", in order.
_urls_seen() {
  hook_requests | sed "s#/\([^/]*\)/$CASE_SLUG/#\1/#"
}

# Options that point every backup URL hook at the receiver over HTTPS.
_urls_backup_opts() {
  _URLS_OPTS=(-v "$(e2e_ca_system_mount)"
    -e "HOOK_PRE_BACKUP_URL=$(hook_url https "${1:-ok}" pre-backup)"
    -e "HOOK_POST_BACKUP_URL=$(hook_url https "${2:-ok}" post-backup)"
    -e "HOOK_BACKUP_ERROR_URL=$(hook_url https "${3:-ok}" backup-error)")
}

_urls_restore_opts() {
  _URLS_OPTS=(-v "$(e2e_ca_system_mount)"
    -e "HOOK_PRE_RESTORE_URL=$(hook_url https ok pre-restore)"
    -e "HOOK_POST_RESTORE_URL=$(hook_url https ok post-restore)"
    -e "HOOK_RESTORE_ERROR_URL=$(hook_url https ok restore-error)")
}

# _urls_assert_refused <url> <reason> [suffix] - a pre-backup URL is refused
# before any request, and the backup fails without uploading. Pass a suffix to
# call it more than once in a case.
_urls_assert_refused() {
  db=$(new_db "${3:-}")
  bucket=$(new_bucket "${3:-}")
  bk_backup refused "$db" "$bucket" -v "$(e2e_ca_system_mount)" -e "HOOK_PRE_BACKUP_URL=$1"
  assert_rc_nonzero "refused pre-backup URL $1"
  assert_log_contains "ERROR: hook URL for pre-backup is not allowed ($2)"
  assert_log_not_contains "Running URL hook for pre-backup"
  assert_log_not_contains "Creating dump of"
  assert_s3_count "$bucket" "" 0 "refused URL must stop the upload"
  assert_eq "$(hook_requests)" "" "requests for a refused URL"
}

test_hookurls_backup_success_pings_pre_then_post() {
  db=$(new_db)
  bucket=$(new_bucket)
  _urls_backup_opts
  bk_backup backup "$db" "$bucket" "${_URLS_OPTS[@]}"
  assert_rc 0
  assert_s3_count "$bucket" backup/ 1
  assert_eq "$(_urls_seen | tr '\n' ',')" "https GET ok/pre-backup,https GET ok/post-backup," "requests"
  assert_log_contains "Running URL hook for pre-backup"
  assert_log_contains "Running URL hook for post-backup"
}

test_hookurls_backup_failure_pings_pre_then_error() {
  db=$(new_db)
  _urls_backup_opts
  bk_backup backup "$db" "$CASE_SLUG-missing" "${_URLS_OPTS[@]}"
  assert_rc 2 "upload to a missing bucket"
  assert_eq "$(_urls_seen | tr '\n' ',')" "https GET ok/pre-backup,https GET ok/backup-error," "requests"
}

test_hookurls_restore_success_pings_pre_then_post() {
  db=$(new_db)
  bucket=$(new_bucket)
  bk_backup backup "$db" "$bucket"
  assert_rc 0
  key=$(s3_single_key "$bucket" backup/) || fail "no backup"
  _urls_restore_opts
  bk_restore restore "${db}_r" "$bucket" "$key" -e CREATE_DATABASE=yes "${_URLS_OPTS[@]}"
  assert_rc 0
  assert_same_data "$db" "${db}_r"
  assert_eq "$(_urls_seen | tr '\n' ',')" "https GET ok/pre-restore,https GET ok/post-restore," "requests"
}

test_hookurls_restore_failure_pings_pre_then_error() {
  db=$(new_db)
  bucket=$(new_bucket)
  _urls_restore_opts
  bk_restore restore "$db" "$bucket" backup/missing.sql.gz "${_URLS_OPTS[@]}"
  assert_rc 2 "restore of a missing object"
  assert_eq "$(_urls_seen | tr '\n' ',')" "https GET ok/pre-restore,https GET ok/restore-error," "requests"
}

test_hookurls_validation_errors_send_no_requests() {
  db=$(new_db)
  _urls_backup_opts
  bk_run backup --unset S3_ACCESS_KEY_ID -e "POSTGRES_DATABASE=$db" -e "S3_BUCKET=$CASE_SLUG" \
    "${_URLS_OPTS[@]}"
  assert_rc 1 "S3_SECRET_ACCESS_KEY without S3_ACCESS_KEY_ID"
  assert_eq "$(hook_requests)" "" "requests after a validation error"
}

# _urls_assert_no_url_in_log - neither the receiver's host nor the case's URL
# path appears in the last log (the bucket is suffixed so it cannot match).
_urls_assert_no_url_in_log() {
  assert_log_not_contains "hooks:8443"
  assert_log_not_contains "hooks:8080"
  assert_log_not_contains "/$CASE_SLUG/"
}

test_hookurls_urls_are_not_logged() {
  db=$(new_db)
  bucket=$(new_bucket b)
  _urls_backup_opts
  bk_backup ok "$db" "$bucket" "${_URLS_OPTS[@]}"
  assert_rc 0
  _urls_assert_no_url_in_log
  # Neither a failing request nor a refused URL prints the URL.
  _urls_backup_opts fail
  bk_backup failing "$db" "$bucket" "${_URLS_OPTS[@]}"
  assert_rc_nonzero
  assert_log_contains "ERROR: URL hook for pre-backup failed"
  _urls_assert_no_url_in_log
  bk_backup refused "$db" "$bucket" -e "HOOK_PRE_BACKUP_URL=$(hook_url http ok refused)"
  assert_rc_nonzero
  assert_log_contains "is not allowed (http-not-allowed)"
  _urls_assert_no_url_in_log
}

test_hookurls_http_refused_by_default() {
  _urls_assert_refused "$(hook_url http ok pre-backup)" http-not-allowed
}

test_hookurls_http_allowed_with_hook_allow_http() {
  db=$(new_db)
  bucket=$(new_bucket)
  bk_backup backup "$db" "$bucket" -e HOOK_ALLOW_HTTP=yes \
    -e "HOOK_PRE_BACKUP_URL=$(hook_url http ok pre-backup)" \
    -e "HOOK_POST_BACKUP_URL=$(hook_url http ok post-backup)"
  assert_rc 0
  assert_eq "$(_urls_seen | tr '\n' ',')" "http GET ok/pre-backup,http GET ok/post-backup," "requests"
}

test_hookurls_other_schemes_refused() {
  _urls_assert_refused "ftp://hooks/ok/$CASE_SLUG/pre-backup" scheme
}

test_hookurls_credentials_in_url_refused() {
  _urls_assert_refused "https://user:hunter2pw@hooks:8443/ok/$CASE_SLUG/pre-backup" userinfo
  assert_log_not_contains "hunter2pw"
}

test_hookurls_whitespace_in_url_refused() {
  _urls_assert_refused "https://hooks:8443/ok/$CASE_SLUG/pre backup" whitespace
}

test_hookurls_loopback_hosts_refused() {
  _urls_assert_refused "https://127.0.0.1:8443/ok/$CASE_SLUG/pre" blocked-host v4
  _urls_assert_refused "https://localhost:8443/ok/$CASE_SLUG/pre" blocked-host name
  _urls_assert_refused "https://[::1]:8443/ok/$CASE_SLUG/pre" blocked-host v6
}

test_hookurls_link_local_and_metadata_hosts_refused() {
  _urls_assert_refused "https://169.254.169.254/ok/$CASE_SLUG/pre" blocked-host ip
  _urls_assert_refused "https://metadata.google.internal/ok/$CASE_SLUG/pre" blocked-host name
}

test_hookurls_pre_backup_403_stops_backup() {
  db=$(new_db)
  bucket=$(new_bucket)
  _urls_backup_opts fail
  bk_backup backup "$db" "$bucket" "${_URLS_OPTS[@]}"
  assert_rc_nonzero "pre-backup URL answered 403"
  assert_log_contains "ERROR: URL hook for pre-backup failed"
  assert_log_not_contains "Creating dump of"
  assert_s3_count "$bucket" "" 0 "failed pre-backup URL must stop the upload"
  assert_eq "$(_urls_seen | tr '\n' ',')" "https GET fail/pre-backup,https GET ok/backup-error," "requests"
}

test_hookurls_post_backup_403_fails_job() {
  db=$(new_db)
  bucket=$(new_bucket)
  _urls_backup_opts ok fail
  bk_backup backup "$db" "$bucket" "${_URLS_OPTS[@]}"
  assert_rc_nonzero "post-backup URL answered 403"
  assert_log_contains "ERROR: URL hook for post-backup failed"
  # The upload had already happened; the job still reports failure.
  assert_s3_count "$bucket" backup/ 1
  assert_eq "$(_urls_seen | tr '\n' ',')" \
    "https GET ok/pre-backup,https GET fail/post-backup,https GET ok/backup-error," "requests"
}

test_hookurls_server_error_is_retried() {
  db=$(new_db)
  bucket=$(new_bucket)
  _urls_backup_opts error500
  bk_backup backup "$db" "$bucket" "${_URLS_OPTS[@]}"
  assert_rc_nonzero "pre-backup URL answered 500"
  assert_eq "$(_urls_seen | grep -c 'error500/pre-backup')" 4 "one request plus three retries"
  assert_s3_count "$bucket" "" 0
}

test_hookurls_redirects_are_not_followed() {
  db=$(new_db)
  bucket=$(new_bucket)
  bk_backup backup "$db" "$bucket" -v "$(e2e_ca_system_mount)" \
    -e "HOOK_POST_BACKUP_URL=$(hook_url https redirect post-backup)"
  assert_eq "$(_urls_seen | tr '\n' ',')" "https GET redirect/post-backup," "requests"
}

test_hookurls_untrusted_https_certificate_fails_closed() {
  db=$(new_db)
  bucket=$(new_bucket)
  # No CA mount, so the receiver's certificate is not trusted.
  bk_backup backup "$db" "$bucket" -e "HOOK_PRE_BACKUP_URL=$(hook_url https ok pre-backup)"
  assert_rc_nonzero "pre-backup URL with an untrusted certificate"
  assert_log_contains "ERROR: URL hook for pre-backup failed"
  assert_s3_count "$bucket" "" 0
  assert_eq "$(hook_requests)" "" "no request completes without a trusted certificate"
}

test_hookurls_failing_error_url_keeps_exit_code() {
  db=$(new_db)
  _urls_backup_opts ok ok fail
  bk_backup backup "$db" "$CASE_SLUG-missing" "${_URLS_OPTS[@]}"
  assert_rc 2 "exit code of the failed upload"
  assert_log_contains "backup-error hook failed; keeping original exit code 2"
  assert_eq "$(_urls_seen | tr '\n' ',')" "https GET ok/pre-backup,https GET fail/backup-error," "requests"
}
