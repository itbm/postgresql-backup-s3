# Script lifecycle hooks: events, arguments and the unprivileged hook user,
# the scrubbed environment and HOOK_INHERIT_ENV, HOOKS_DIR, and failing hooks.

# Hook body that records the event, its arguments, identity and environment
# under /hook-out (<event>.env, .args, .uid, .groups).
_HS_RECORDER='#!/bin/sh
echo "$1" >> /hook-out/events
env | sort > "/hook-out/$1.env"
printf "%s\n" "$#" "$*" > "/hook-out/$1.args"
id -u > "/hook-out/$1.uid"
id -G > "/hook-out/$1.groups"'

# Names a scrubbed hook may see: the README allowlist plus PWD and SHLVL,
# which the hook's own shell adds.
_HS_ALLOWED=" PATH HOME HOOK_EVENT POSTGRES_DATABASE POSTGRES_HOST POSTGRES_PORT POSTGRES_USER S3_BUCKET S3_PREFIX S3_REGION S3_ENDPOINT BACKUP_DEST_FILE BACKUP_S3_URI BACKUP_FILE TZ HOOK_EXIT_CODE PWD SHLVL "

_HS_SECRET_NAMES="POSTGRES_PASSWORD PGPASSWORD S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN ENCRYPTION_PASSWORD AWS_WEB_IDENTITY_TOKEN_FILE AWS_ROLE_ARN AWS_CONTAINER_AUTHORIZATION_TOKEN"

_HS_ENC_PASSWORD=hs-encryption-secret-6f1d
_HS_ALL_EVENTS="pre-backup post-backup backup-error pre-restore post-restore restore-error"

# _hs_record <event>... - installs the recorder for each event.
_hs_record() {
  for _hs_ev in "$@"; do
    write_hook "$_hs_ev" "$_HS_RECORDER"
  done
}

# _hs_failing_hook <event> <exit-code> - records the event, then fails.
_hs_failing_hook() {
  write_hook "$1" "#!/bin/sh
echo \"\$1\" >> /hook-out/events
exit $2"
}

_hs_env_file() {
  printf '%s\n' "$CASE_DIR/hook-out/$1.env"
}

# _hs_env <event> <name> - value of name in the event's env dump.
_hs_env() {
  sed -n "s/^$2=//p" "$(_hs_env_file "$1")"
}

_hs_assert_env() {
  assert_file_exists "$(_hs_env_file "$1")" "no env dump for $1"
  grep -Fxq -- "$2=$3" "$(_hs_env_file "$1")" \
    || fail "$1 hook: expected $2=$3, got '$(_hs_env "$1" "$2")'"
}

_hs_assert_env_absent() {
  assert_file_exists "$(_hs_env_file "$1")" "no env dump for $1"
  if grep -q "^$2=" "$(_hs_env_file "$1")"; then
    fail "$1 hook: $2 should be absent, got '$(_hs_env "$1" "$2")'"
  fi
}

# _hs_assert_scrubbed <event> [extra secret values...] - no secret names or
# values, and nothing outside the documented allowlist.
_hs_assert_scrubbed() {
  _hs_f=$(_hs_env_file "$1")
  _hs_ev=$1
  shift
  assert_file_exists "$_hs_f" "no env dump for $_hs_ev"
  for _hs_n in $_HS_SECRET_NAMES; do
    _hs_assert_env_absent "$_hs_ev" "$_hs_n"
  done
  for _hs_v in "$PG_PASSWORD" "$S3_KEY" "$S3_SECRET" "$@"; do
    assert_file_not_contains "$_hs_f" "$_hs_v" "$_hs_ev hook environment leaks a secret value"
  done
  for _hs_n in $(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$_hs_f"); do
    case $_HS_ALLOWED in
      *" $_hs_n "*) ;;
      *) fail "$_hs_ev hook environment has $_hs_n, which is not on the allowlist" ;;
    esac
  done
}

_hs_assert_uid() {
  assert_file_exists "$CASE_DIR/hook-out/$1.uid" "no uid recorded for $1"
  assert_eq "$(cat "$CASE_DIR/hook-out/$1.uid")" 1000 "$1 hook uid"
  assert_eq "$(cat "$CASE_DIR/hook-out/$1.groups")" 1000 "$1 hook groups"
}

# _hs_assert_args <event> - the script got exactly one argument, the event.
_hs_assert_args() {
  assert_file_exists "$CASE_DIR/hook-out/$1.args" "no arguments recorded for $1"
  assert_eq "$(sed -n 1p "$CASE_DIR/hook-out/$1.args")" 1 "$1 hook argument count"
  assert_eq "$(sed -n 2p "$CASE_DIR/hook-out/$1.args")" "$1" "$1 hook \$1"
}

# First line of the last bk_run log that contains the text, or 0.
_hs_log_line() {
  _hs_l=$(grep -nF -- "$1" "$BK_LOG" | head -n 1 | cut -d: -f1)
  printf '%s\n' "${_hs_l:-0}"
}

_hs_assert_log_order() {
  _hs_a=$(_hs_log_line "$1")
  _hs_b=$(_hs_log_line "$2")
  [ "$_hs_a" -gt 0 ] || fail "log is missing '$1'"
  [ "$_hs_b" -gt 0 ] || fail "log is missing '$2'"
  [ "$_hs_a" -lt "$_hs_b" ] || fail "expected '$1' (line $_hs_a) before '$2' (line $_hs_b)"
}

_hs_count_event() {
  if [ -f "$CASE_DIR/hook-out/events" ]; then
    grep -cx -- "$1" "$CASE_DIR/hook-out/events" || true
  else
    echo 0
  fi
}

_hs_event_seen_at_least() {
  [ "$(_hs_count_event "$1")" -ge "$2" ]
}

# _hs_backup_key <db> <bucket> - plain backup without hooks; prints its key.
_hs_backup_key() {
  bk_backup source "$1" "$2"
  assert_rc 0 "backup to restore from"
  s3_single_key "$2" "backup/"
}

# ---------------------------------------------------------------------------
# Events, arguments and the hook user.

test_hookscripts_backup_success_events_args_and_uid() {
  db=$(new_db)
  bucket=$(new_bucket)
  hooks_setup
  _hs_record $_HS_ALL_EVENTS

  bk_backup backup "$db" "$bucket" "${HOOK_MOUNTS[@]}"
  assert_rc 0 "backup with script hooks"
  assert_eq "$(hook_events)" "pre-backup post-backup" "hook events"
  for ev in pre-backup post-backup; do
    _hs_assert_args "$ev"
    _hs_assert_env "$ev" HOOK_EVENT "$ev"
    _hs_assert_env_absent "$ev" HOOK_EXIT_CODE
    _hs_assert_uid "$ev"
  done
  _hs_assert_log_order "Running script hook for pre-backup" "Creating dump of $db database"
  _hs_assert_log_order "SQL backup finished" "Running script hook for post-backup"
  key=$(s3_single_key "$bucket" "backup/") || fail "expected one backup"
  _hs_assert_env_absent pre-backup BACKUP_DEST_FILE
  _hs_assert_env_absent pre-backup BACKUP_S3_URI
  _hs_assert_env post-backup BACKUP_DEST_FILE "${key#backup/}"
  _hs_assert_env post-backup BACKUP_S3_URI "s3://$bucket/$key"
}

test_hookscripts_backup_upload_failure_fires_backup_error() {
  db=$(new_db)
  missing="${CASE_SLUG}-missing"
  hooks_setup
  _hs_record $_HS_ALL_EVENTS

  bk_backup backup "$db" "$missing" "${HOOK_MOUNTS[@]}"
  assert_rc 2 "upload to a missing bucket"
  assert_log_contains "Uploading dump to $missing"
  assert_eq "$(hook_events)" "pre-backup backup-error" "hook events"
  _hs_assert_env backup-error HOOK_EXIT_CODE 2
  _hs_assert_env backup-error HOOK_EVENT backup-error
  _hs_assert_args backup-error
  _hs_assert_uid backup-error
}

test_hookscripts_restore_success_events() {
  db=$(new_db)
  bucket=$(new_bucket)
  key=$(_hs_backup_key "$db" "$bucket") || fail "could not make a backup to restore from"
  hooks_setup
  _hs_record $_HS_ALL_EVENTS

  restored="${db}_restored"
  bk_restore restore "$restored" "$bucket" "$key" "${HOOK_MOUNTS[@]}" -e CREATE_DATABASE=yes
  assert_rc 0 "restore with script hooks"
  assert_eq "$(hook_events)" "pre-restore post-restore" "hook events"
  for ev in pre-restore post-restore; do
    _hs_assert_args "$ev"
    _hs_assert_env "$ev" HOOK_EVENT "$ev"
    _hs_assert_env "$ev" BACKUP_FILE "$key"
    _hs_assert_env "$ev" POSTGRES_DATABASE "$restored"
    _hs_assert_env_absent "$ev" HOOK_EXIT_CODE
    _hs_assert_uid "$ev"
  done
  _hs_assert_log_order "Running script hook for pre-restore" "Downloading backup file from S3"
  _hs_assert_log_order "Database restore completed successfully" "Running script hook for post-restore"
  assert_same_data "$db" "$restored"
}

test_hookscripts_restore_missing_object_fires_restore_error() {
  db=$(new_db)
  bucket=$(new_bucket)
  hooks_setup
  _hs_record $_HS_ALL_EVENTS

  bk_restore restore "$db" "$bucket" "backup/does-not-exist.sql.gz" "${HOOK_MOUNTS[@]}"
  assert_rc 2 "restore of a missing object"
  assert_eq "$(hook_events)" "pre-restore restore-error" "hook events"
  _hs_assert_env restore-error HOOK_EXIT_CODE 2
  _hs_assert_env restore-error HOOK_EVENT restore-error
  _hs_assert_env restore-error BACKUP_FILE "backup/does-not-exist.sql.gz"
  _hs_assert_args restore-error
  _hs_assert_uid restore-error
}

test_hookscripts_scheduled_runs_fire_hooks_each_time() {
  db=$(new_db)
  bucket=$(new_bucket)
  hooks_setup
  _hs_record pre-backup backup-error
  write_hook post-backup "$_HS_RECORDER
echo \"hs-sched-stdout from \$1\"
echo \"hs-sched-stderr from \$1\" >&2"

  bk_start sched "${HOOK_MOUNTS[@]}" -e "POSTGRES_DATABASE=$db" -e "S3_BUCKET=$bucket" \
    -e "SCHEDULE=@every 2s"
  wait_for 90 _hs_event_seen_at_least post-backup 2 || {
    bk_logs
    fail "two scheduled backups did not both fire post-backup (events: $(hook_events))"
  }
  # Judge only the runs before the stop: stopping the container may land in
  # a run and fail it, which may rightly fire backup-error.
  events=$(hook_events)
  bk_stop 2
  case "$events" in
    "pre-backup post-backup pre-backup post-backup"*) ;;
    *) fail "unexpected scheduled hook events: $events" ;;
  esac
  case " $events " in
    *" backup-error "*) fail "backup-error fired during successful scheduled runs: $events" ;;
  esac
  assert_log_contains "Running script hook for post-backup"
  # The hook's own stdout and stderr must come through go-cron.
  assert_log_contains "hs-sched-stdout from post-backup"
  assert_log_contains "hs-sched-stderr from post-backup"
  s3_has_at_least "$bucket" "backup/" 2 || fail "expected at least two scheduled backups"
}

# ---------------------------------------------------------------------------
# Environment.

test_hookscripts_env_is_scrubbed_on_backup_and_restore() {
  db=$(new_db)
  bucket=$(new_bucket)
  hooks_setup
  _hs_record $_HS_ALL_EVENTS

  bk_backup backup "$db" "$bucket" "${HOOK_MOUNTS[@]}" \
    -e "ENCRYPTION_PASSWORD=$_HS_ENC_PASSWORD" -e TZ=Europe/London \
    -e S3_PREFIX=hs/nested -e S3_REGION=eu-west-2 -e POSTGRES_PORT=5432
  assert_rc 0 "encrypted backup with script hooks"
  assert_eq "$(hook_events)" "pre-backup post-backup" "backup hook events"
  key=$(s3_single_key "$bucket" "hs/nested/") || fail "expected one backup"
  assert_match "$key" '\.sql\.gz\.enc$' "encrypted backup key"

  for ev in pre-backup post-backup; do
    _hs_assert_scrubbed "$ev" "$_HS_ENC_PASSWORD"
    _hs_assert_env "$ev" PATH /usr/local/bin:/usr/bin:/bin
    _hs_assert_env "$ev" HOME /tmp
    _hs_assert_env "$ev" POSTGRES_DATABASE "$db"
    _hs_assert_env "$ev" POSTGRES_HOST pg
    _hs_assert_env "$ev" POSTGRES_PORT 5432
    _hs_assert_env "$ev" POSTGRES_USER postgres
    _hs_assert_env "$ev" S3_BUCKET "$bucket"
    _hs_assert_env "$ev" S3_PREFIX hs/nested
    _hs_assert_env "$ev" S3_REGION eu-west-2
    _hs_assert_env "$ev" S3_ENDPOINT http://minio:9000
    _hs_assert_env "$ev" TZ Europe/London
    _hs_assert_env_absent "$ev" BACKUP_FILE
  done
  _hs_assert_env_absent pre-backup BACKUP_DEST_FILE
  _hs_assert_env_absent pre-backup BACKUP_S3_URI
  _hs_assert_env post-backup BACKUP_DEST_FILE "${key##*/}"
  _hs_assert_env post-backup BACKUP_S3_URI "s3://$bucket/$key"

  rm -f "$CASE_DIR/hook-out/events"
  restored="${db}_restored"
  bk_restore restore "$restored" "$bucket" "$key" "${HOOK_MOUNTS[@]}" \
    -e "ENCRYPTION_PASSWORD=$_HS_ENC_PASSWORD" -e CREATE_DATABASE=yes
  assert_rc 0 "restore of the encrypted backup"
  assert_eq "$(hook_events)" "pre-restore post-restore" "restore hook events"
  for ev in pre-restore post-restore; do
    _hs_assert_scrubbed "$ev" "$_HS_ENC_PASSWORD"
    _hs_assert_env "$ev" BACKUP_FILE "$key"
    _hs_assert_env "$ev" POSTGRES_DATABASE "$restored"
    _hs_assert_env "$ev" S3_PREFIX backup
    _hs_assert_env "$ev" S3_REGION us-west-1
    _hs_assert_env_absent "$ev" TZ
  done
  assert_same_data "$db" "$restored"
}

test_hookscripts_env_is_scrubbed_on_error_events() {
  db=$(new_db)
  bucket=$(new_bucket)
  hooks_setup
  _hs_record $_HS_ALL_EVENTS
  # Credential-chain variables the image never reads itself; each must still
  # be kept away from hooks.
  secrets=(-e "ENCRYPTION_PASSWORD=$_HS_ENC_PASSWORD"
    -e AWS_SESSION_TOKEN=hs-session-token-9a2c
    -e AWS_ROLE_ARN=arn:aws:iam::123456789012:role/hs-role-4b7e
    -e AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/hs-token-3c8d
    -e AWS_CONTAINER_AUTHORIZATION_TOKEN=hs-container-token-5e1f)
  values="$_HS_ENC_PASSWORD hs-session-token-9a2c hs-role-4b7e hs-token-3c8d hs-container-token-5e1f"

  # S3 may reject the bogus session token before it notices the missing
  # bucket; either way the upload fails.
  bk_backup backup "$db" "${CASE_SLUG}-missing" "${HOOK_MOUNTS[@]}" "${secrets[@]}"
  assert_rc 2 "encrypted backup to a missing bucket"
  assert_eq "$(hook_events)" "pre-backup backup-error" "backup hook events"
  for ev in pre-backup backup-error; do
    # shellcheck disable=SC2086
    _hs_assert_scrubbed "$ev" $values
  done
  _hs_assert_env backup-error HOOK_EXIT_CODE 2

  rm -f "$CASE_DIR"/hook-out/*
  bk_restore restore "$db" "$bucket" "backup/missing.sql.gz.enc" "${HOOK_MOUNTS[@]}" "${secrets[@]}"
  assert_rc 2 "restore of a missing object"
  assert_eq "$(hook_events)" "pre-restore restore-error" "restore hook events"
  for ev in pre-restore restore-error; do
    # shellcheck disable=SC2086
    _hs_assert_scrubbed "$ev" $values
  done
  _hs_assert_env restore-error HOOK_EXIT_CODE 2
}

test_hookscripts_post_backup_names_custom_format_keys() {
  db=$(new_db)
  bucket=$(new_bucket)
  hooks_setup
  _hs_record pre-backup post-backup

  # Plain and encrypted custom-format backups name the object in different places.
  bk_backup plain "$db" "$bucket" "${HOOK_MOUNTS[@]}" -e USE_CUSTOM_FORMAT=yes -e S3_PREFIX=plain
  assert_rc 0 "custom format backup"
  assert_eq "$(hook_events)" "pre-backup post-backup" "hook events"
  key=$(s3_single_key "$bucket" "plain/") || fail "expected one plain backup"
  assert_match "$key" "^plain/${db}_[0-9TZ:-]+\.dump$" "backup key"
  _hs_assert_env post-backup BACKUP_DEST_FILE "${key#plain/}"
  _hs_assert_env post-backup BACKUP_S3_URI "s3://$bucket/$key"
  _hs_assert_env_absent pre-backup BACKUP_DEST_FILE

  rm -f "$CASE_DIR"/hook-out/*
  bk_backup enc "$db" "$bucket" "${HOOK_MOUNTS[@]}" -e USE_CUSTOM_FORMAT=yes -e S3_PREFIX=enc \
    -e "ENCRYPTION_PASSWORD=$_HS_ENC_PASSWORD"
  assert_rc 0 "custom format encrypted backup"
  assert_eq "$(hook_events)" "pre-backup post-backup" "hook events"
  key=$(s3_single_key "$bucket" "enc/") || fail "expected one encrypted backup"
  assert_match "$key" "^enc/${db}_[0-9TZ:-]+\.dump\.enc$" "backup key"
  _hs_assert_env post-backup BACKUP_DEST_FILE "${key#enc/}"
  _hs_assert_env post-backup BACKUP_S3_URI "s3://$bucket/$key"
  _hs_assert_env_absent pre-backup BACKUP_DEST_FILE
  _hs_assert_env_absent pre-backup BACKUP_S3_URI
}

test_hookscripts_inherit_env_passes_secrets() {
  db=$(new_db)
  bucket=$(new_bucket)
  hooks_setup
  _hs_record pre-backup post-backup

  bk_backup backup "$db" "$bucket" "${HOOK_MOUNTS[@]}" -e HOOK_INHERIT_ENV=yes \
    -e "ENCRYPTION_PASSWORD=$_HS_ENC_PASSWORD"
  assert_rc 0 "backup with HOOK_INHERIT_ENV=yes"
  assert_eq "$(hook_events)" "pre-backup post-backup" "hook events"
  key=$(s3_single_key "$bucket" "backup/") || fail "expected one backup"
  for ev in pre-backup post-backup; do
    _hs_assert_env "$ev" POSTGRES_PASSWORD "$PG_PASSWORD"
    _hs_assert_env "$ev" PGPASSWORD "$PG_PASSWORD"
    _hs_assert_env "$ev" S3_ACCESS_KEY_ID "$S3_KEY"
    _hs_assert_env "$ev" S3_SECRET_ACCESS_KEY "$S3_SECRET"
    _hs_assert_env "$ev" AWS_ACCESS_KEY_ID "$S3_KEY"
    _hs_assert_env "$ev" AWS_SECRET_ACCESS_KEY "$S3_SECRET"
    _hs_assert_env "$ev" ENCRYPTION_PASSWORD "$_HS_ENC_PASSWORD"
    _hs_assert_env "$ev" POSTGRES_DATABASE "$db"
    _hs_assert_args "$ev"
    _hs_assert_uid "$ev"
  done
  _hs_assert_env post-backup BACKUP_DEST_FILE "${key#backup/}"
  _hs_assert_env post-backup BACKUP_S3_URI "s3://$bucket/$key"
}

test_hookscripts_inherit_env_keeps_hook_event_and_exit_code() {
  db=$(new_db)
  missing="${CASE_SLUG}-missing"
  hooks_setup
  _hs_record pre-backup post-backup backup-error

  bk_backup backup "$db" "$missing" "${HOOK_MOUNTS[@]}" -e HOOK_INHERIT_ENV=yes
  assert_rc 2 "upload to a missing bucket"
  assert_eq "$(hook_events)" "pre-backup backup-error" "hook events"
  _hs_assert_env backup-error POSTGRES_PASSWORD "$PG_PASSWORD"
  _hs_assert_env pre-backup HOOK_EVENT pre-backup
  _hs_assert_env backup-error HOOK_EVENT backup-error
  _hs_assert_env backup-error HOOK_EXIT_CODE 2
}

# ---------------------------------------------------------------------------
# HOOKS_DIR.

test_hookscripts_custom_hooks_dir() {
  db=$(new_db)
  bucket=$(new_bucket)
  hooks_setup
  _hs_record pre-backup post-backup backup-error
  # A failing hook in the default /hooks must be ignored when HOOKS_DIR points elsewhere.
  mkdir -p "$CASE_DIR/decoy"
  printf '#!/bin/sh\necho decoy >> /hook-out/events\nexit 1\n' >"$CASE_DIR/decoy/pre-backup"
  chmod 755 "$CASE_DIR/decoy" "$CASE_DIR/decoy/pre-backup"

  bk_backup backup "$db" "$bucket" -v "$CASE_DIR/hooks:/opt/my hooks:ro" \
    -v "$CASE_DIR/decoy:/hooks:ro" -v "$CASE_DIR/hook-out:/hook-out" \
    -e "HOOKS_DIR=/opt/my hooks/"
  assert_rc 0 "backup with a custom HOOKS_DIR"
  assert_eq "$(hook_events)" "pre-backup post-backup" "hook events"
  _hs_assert_uid post-backup
  assert_s3_count "$bucket" "backup/" 1
}

test_hookscripts_missing_or_empty_hooks_dir_runs_normally() {
  db=$(new_db)
  bucket=$(new_bucket)

  # The image's own /hooks is empty.
  bk_backup empty "$db" "$bucket" -e S3_PREFIX=empty
  assert_rc 0 "backup with the empty default hooks directory"
  assert_log_not_contains "Running script hook"
  assert_log_not_contains "ERROR"
  assert_s3_count "$bucket" "empty/" 1

  bk_backup missing "$db" "$bucket" -e S3_PREFIX=missing -e HOOKS_DIR=/does/not/exist
  assert_rc 0 "backup with a missing hooks directory"
  assert_log_not_contains "Running script hook"
  assert_log_not_contains "ERROR"
  assert_s3_count "$bucket" "missing/" 1
}

test_hookscripts_symlinks_inside_hooks_dir_run() {
  db=$(new_db)
  bucket=$(new_bucket)
  hooks_setup
  # Laid out like a Kubernetes ConfigMap volume: event -> ..data/event -> ..<ts>/event.
  ts="..2026_10_20_00_00_00.000000001"
  mkdir -p "$CASE_DIR/hooks/$ts"
  chmod 755 "$CASE_DIR/hooks/$ts"
  for ev in pre-backup post-backup; do
    printf '%s\n' "$_HS_RECORDER" >"$CASE_DIR/hooks/$ts/$ev"
    chmod 755 "$CASE_DIR/hooks/$ts/$ev"
    ln -s "..data/$ev" "$CASE_DIR/hooks/$ev"
  done
  ln -s "$ts" "$CASE_DIR/hooks/..data"

  bk_backup backup "$db" "$bucket" "${HOOK_MOUNTS[@]}"
  assert_rc 0 "backup with symlinked hooks inside HOOKS_DIR"
  assert_eq "$(hook_events)" "pre-backup post-backup" "hook events"
  _hs_assert_args post-backup
  _hs_assert_uid post-backup
  assert_s3_count "$bucket" "backup/" 1
}

# ---------------------------------------------------------------------------
# Failing hooks.

test_hookscripts_failing_pre_backup_uploads_nothing() {
  db=$(new_db)
  bucket=$(new_bucket)
  hooks_setup
  _hs_failing_hook pre-backup 3
  _hs_record post-backup backup-error

  bk_backup backup "$db" "$bucket" "${HOOK_MOUNTS[@]}"
  assert_rc_nonzero "backup with a failing pre-backup hook"
  assert_eq "$(hook_events)" "pre-backup backup-error" "hook events"
  _hs_assert_env backup-error HOOK_EXIT_CODE "$BK_RC"
  assert_log_not_contains "Creating dump of"
  assert_log_not_contains "SQL backup finished"
  assert_s3_count "$bucket" "" 0
}

test_hookscripts_failing_post_backup_fails_job() {
  db=$(new_db)
  bucket=$(new_bucket)
  hooks_setup
  _hs_record pre-backup backup-error
  _hs_failing_hook post-backup 4

  bk_backup backup "$db" "$bucket" "${HOOK_MOUNTS[@]}"
  assert_rc_nonzero "backup with a failing post-backup hook"
  assert_eq "$(hook_events)" "pre-backup post-backup backup-error" "hook events"
  _hs_assert_env backup-error HOOK_EXIT_CODE "$BK_RC"
  assert_log_contains "SQL backup finished"
  # The upload had already happened; the object stays.
  assert_s3_count "$bucket" "backup/" 1
}

test_hookscripts_failing_pre_restore_leaves_database_untouched() {
  db=$(new_db)
  bucket=$(new_bucket)
  key=$(_hs_backup_key "$db" "$bucket") || fail "could not make a backup to restore from"
  psql_exec "$db" "CREATE TABLE public.hs_marker (v text); INSERT INTO public.hs_marker VALUES ('kept')" \
    >/dev/null || fail "could not add marker table"
  db_fingerprint "$db" >"$CASE_DIR/before.txt" || fail "could not fingerprint $db"
  hooks_setup
  _hs_failing_hook pre-restore 3
  _hs_record post-restore restore-error

  bk_restore restore "$db" "$bucket" "$key" "${HOOK_MOUNTS[@]}" \
    -e DROP_DATABASE=yes -e CREATE_DATABASE=yes
  assert_rc_nonzero "restore with a failing pre-restore hook"
  assert_eq "$(hook_events)" "pre-restore restore-error" "hook events"
  _hs_assert_env restore-error HOOK_EXIT_CODE "$BK_RC"
  assert_log_not_contains "Downloading backup file"
  assert_log_not_contains "Dropping database"
  db_exists "$db" || fail "database $db was dropped"
  assert_eq "$(psql_exec "$db" "SELECT v FROM public.hs_marker")" kept "marker row"
  db_fingerprint "$db" >"$CASE_DIR/after.txt" || fail "could not fingerprint $db"
  diff -u "$CASE_DIR/before.txt" "$CASE_DIR/after.txt" >&2 || fail "database $db changed"
}

test_hookscripts_failing_post_restore_fails_job() {
  db=$(new_db)
  bucket=$(new_bucket)
  key=$(_hs_backup_key "$db" "$bucket") || fail "could not make a backup to restore from"
  hooks_setup
  _hs_record pre-restore restore-error
  _hs_failing_hook post-restore 5

  restored="${db}_restored"
  bk_restore restore "$restored" "$bucket" "$key" "${HOOK_MOUNTS[@]}" -e CREATE_DATABASE=yes
  assert_rc_nonzero "restore with a failing post-restore hook"
  assert_eq "$(hook_events)" "pre-restore post-restore restore-error" "hook events"
  _hs_assert_env restore-error HOOK_EXIT_CODE "$BK_RC"
  assert_log_contains "Database restore completed successfully"
  assert_same_data "$db" "$restored"
}

test_hookscripts_failing_error_hook_keeps_exit_code() {
  db=$(new_db)
  bucket=$(new_bucket)
  hooks_setup
  _hs_record pre-backup pre-restore
  _hs_failing_hook backup-error 9
  # Not executable, so the restore-error hook itself fails to run.
  printf '%s\n' "$_HS_RECORDER" >"$CASE_DIR/hooks/restore-error"
  chmod 644 "$CASE_DIR/hooks/restore-error"

  bk_backup backup "$db" "${CASE_SLUG}-missing" "${HOOK_MOUNTS[@]}"
  assert_rc 2 "backup to a missing bucket with a failing backup-error hook"
  assert_eq "$(hook_events)" "pre-backup backup-error" "backup hook events"
  assert_log_contains "ERROR: backup-error hook failed; keeping original exit code 2"

  rm -f "$CASE_DIR/hook-out/events"
  bk_restore restore "$db" "$bucket" "backup/missing.sql.gz" "${HOOK_MOUNTS[@]}"
  assert_rc 2 "restore of a missing object with a broken restore-error hook"
  assert_eq "$(hook_events)" "pre-restore" "restore hook events"
  assert_log_contains "ERROR: hook script for restore-error is not an executable regular file"
  assert_log_contains "ERROR: restore-error hook failed; keeping original exit code 2"
}

test_hookscripts_non_executable_hook_fails_closed() {
  db=$(new_db)
  bucket=$(new_bucket)
  hooks_setup
  _hs_record post-backup backup-error
  printf '%s\n' "$_HS_RECORDER" >"$CASE_DIR/hooks/pre-backup"
  chmod 644 "$CASE_DIR/hooks/pre-backup"

  bk_backup backup "$db" "$bucket" "${HOOK_MOUNTS[@]}"
  assert_rc_nonzero "backup with a non-executable pre-backup hook"
  assert_log_contains "ERROR: hook script for pre-backup is not an executable regular file"
  assert_log_not_contains "Creating dump of"
  assert_eq "$(hook_events)" "backup-error" "hook events"
  assert_s3_count "$bucket" "" 0
}

test_hookscripts_directory_hook_fails_closed() {
  db=$(new_db)
  bucket=$(new_bucket)
  hooks_setup
  _hs_record post-backup backup-error
  # A directory passes an executable-bit check, so only a regular-file check
  # keeps it from being taken for the pre-backup script.
  mkdir -p "$CASE_DIR/hooks/pre-backup"
  chmod 755 "$CASE_DIR/hooks/pre-backup"

  bk_backup backup "$db" "$bucket" "${HOOK_MOUNTS[@]}"
  assert_rc_nonzero "backup with a directory as the pre-backup hook"
  assert_log_contains "not an executable regular file"
  assert_eq "$(hook_events)" "backup-error" "hook events"
  _hs_assert_env backup-error HOOK_EXIT_CODE "$BK_RC"
  assert_s3_count "$bucket" "" 0
}

test_hookscripts_symlink_outside_hooks_dir_fails_closed() {
  db=$(new_db)
  bucket=$(new_bucket)
  hooks_setup
  _hs_record post-backup backup-error
  # /hooks-evil shares the /hooks prefix, so a naive prefix check would accept it.
  mkdir -p "$CASE_DIR/hooks-evil"
  printf '#!/bin/sh\necho evil >> /hook-out/evil\n' >"$CASE_DIR/hooks-evil/pre-backup"
  chmod 755 "$CASE_DIR/hooks-evil" "$CASE_DIR/hooks-evil/pre-backup"
  ln -s /hooks-evil/pre-backup "$CASE_DIR/hooks/pre-backup"

  bk_backup backup "$db" "$bucket" "${HOOK_MOUNTS[@]}" -v "$CASE_DIR/hooks-evil:/hooks-evil:ro"
  assert_rc_nonzero "backup with a pre-backup symlink outside HOOKS_DIR"
  assert_log_contains "ERROR: hook script for pre-backup is outside HOOKS_DIR"
  assert_file_absent "$CASE_DIR/hook-out/evil" "the out-of-tree script ran"
  assert_log_not_contains "Creating dump of"
  assert_eq "$(hook_events)" "backup-error" "hook events"
  assert_s3_count "$bucket" "" 0
}

test_hookscripts_failing_script_skips_url_and_fires_error_url() {
  db=$(new_db)
  bucket=$(new_bucket)
  hooks_setup
  _hs_failing_hook pre-backup 1
  _hs_record backup-error

  bk_backup backup "$db" "$bucket" "${HOOK_MOUNTS[@]}" -e HOOK_ALLOW_HTTP=yes \
    -e "HOOK_PRE_BACKUP_URL=$(hook_url http ok pre)" \
    -e "HOOK_POST_BACKUP_URL=$(hook_url http ok post)" \
    -e "HOOK_BACKUP_ERROR_URL=$(hook_url http ok error)"
  assert_rc_nonzero "backup with a failing pre-backup script"
  assert_eq "$(hook_events)" "pre-backup backup-error" "hook events"
  assert_log_not_contains "Running URL hook for pre-backup"
  _hs_assert_log_order "Running script hook for backup-error" "Running URL hook for backup-error"
  assert_eq "$(hook_requests)" "http GET /ok/$CASE_SLUG/error" "URL hook requests"
  assert_s3_count "$bucket" "" 0
}

# ---------------------------------------------------------------------------
# Validation, logging and isolation.

test_hookscripts_validation_errors_fire_no_hooks() {
  db=$(new_db)
  bucket=$(new_bucket)
  hooks_setup
  _hs_record $_HS_ALL_EVENTS

  bk_run nobucket "${HOOK_MOUNTS[@]}" -e "POSTGRES_DATABASE=$db"
  assert_rc 1 "backup without S3_BUCKET"
  assert_log_contains "You need to set the S3_BUCKET environment variable."
  assert_log_not_contains "Running script hook"

  bk_backup nosecret "$db" "$bucket" "${HOOK_MOUNTS[@]}" --unset S3_SECRET_ACCESS_KEY
  assert_rc 1 "backup with an access key but no secret"
  assert_log_contains "You need to set the S3_SECRET_ACCESS_KEY environment variable."
  assert_log_not_contains "Running script hook"

  bk_run nodb "${HOOK_MOUNTS[@]}" -e "S3_BUCKET=$bucket" -e BACKUP_FILE=backup/x.sql.gz
  assert_rc 1 "restore without POSTGRES_DATABASE"
  assert_log_contains "You need to set the POSTGRES_DATABASE environment variable."
  assert_log_not_contains "Running script hook"

  assert_eq "$(hook_events)" "" "hook events after validation errors"
  assert_s3_count "$bucket" "" 0
}

test_hookscripts_output_appears_in_container_log() {
  db=$(new_db)
  bucket=$(new_bucket)
  hooks_setup
  write_hook pre-restore '#!/bin/sh
echo "hs-stdout-marker from $1"
echo "hs-stderr-marker from $1" >&2'
  write_hook restore-error '#!/bin/sh
echo "hs-stdout-marker from $1 exit $HOOK_EXIT_CODE"
echo "hs-stderr-marker from $1" >&2'

  bk_restore restore "$db" "$bucket" "backup/missing.sql.gz" "${HOOK_MOUNTS[@]}"
  assert_rc 2 "restore of a missing object"
  assert_log_contains "hs-stdout-marker from pre-restore"
  assert_log_contains "hs-stderr-marker from pre-restore"
  assert_log_contains "hs-stdout-marker from restore-error exit 2"
  assert_log_contains "hs-stderr-marker from restore-error"
  _hs_assert_log_order "Running script hook for pre-restore" "hs-stdout-marker from pre-restore"
  _hs_assert_log_order "hs-stdout-marker from pre-restore" "Downloading backup file from S3"
}

test_hookscripts_single_file_mount_runs_unprivileged() {
  db=$(new_db)
  bucket=$(new_bucket)
  hooks_setup
  # The README's single-file mount, into the image's own root-owned /hooks.
  write_hook pre-backup '#!/bin/sh
echo "$1" >> /hook-out/events
id -u > /hook-out/uid
if touch /hooks/hs-planted 2>/dev/null; then echo writable; else echo not-writable; fi > /hook-out/hooks-dir
for f in /proc/[0-9]*/environ; do cat "$f" 2>/dev/null | tr "\0" "\n"; done > /hook-out/proc-environ'

  bk_backup backup "$db" "$bucket" -v "$CASE_DIR/hooks/pre-backup:/hooks/pre-backup:ro" \
    -v "$CASE_DIR/hook-out:/hook-out" -e "ENCRYPTION_PASSWORD=$_HS_ENC_PASSWORD"
  assert_rc 0 "backup with a single mounted hook file"
  assert_eq "$(hook_events)" "pre-backup" "hook events"
  assert_eq "$(cat "$CASE_DIR/hook-out/uid")" 1000 "hook uid"
  assert_eq "$(cat "$CASE_DIR/hook-out/hooks-dir")" not-writable "/hooks writable by the hook user"
  if docker diff "$BK_CTR" 2>/dev/null | grep -q '/hooks/hs-planted'; then
    fail "the hook planted a file in /hooks"
  fi
  # The hook can read its own environment but not that of the root processes.
  assert_file_contains "$CASE_DIR/hook-out/proc-environ" "HOOK_EVENT=pre-backup"
  for v in "$PG_PASSWORD" "$S3_SECRET" "$S3_KEY" "$_HS_ENC_PASSWORD"; do
    assert_file_not_contains "$CASE_DIR/hook-out/proc-environ" "$v" "hook read a secret from /proc"
  done
  assert_s3_count "$bucket" "backup/" 1
}
