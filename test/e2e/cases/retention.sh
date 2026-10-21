# Retention (DELETE_OLDER_THAN in backup.sh): which objects a backup deletes
# once it has uploaded, and what happens when the threshold or S3 calls fail.

_RET_TS='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'

# ---------------------------------------------------------------------------
# Helpers.

# _ret_mark - prints a time (seconds since the epoch) later than every object
# uploaded so far. Once _ret_wait_past <mark> returns, objects uploaded from
# then on are newer, so DELETE_OLDER_THAN=@<mark> selects exactly the earlier
# ones. Two seconds of slack either side cover the one-second resolution of S3
# listings and small clock differences between the host and the Docker VM.
_ret_mark() {
  printf '%s\n' $(($(date +%s) + 2))
}

_ret_wait_past() {
  wait_for 30 _ret_now_at_least $(($1 + 2)) || fail "clock did not advance past $1"
}

_ret_now_at_least() {
  [ "$(date +%s)" -ge "$1" ]
}

# _ret_put_aged <bucket> <when> <key> [<when> <key>]... - uploads small objects
# in one container (one mc call per object is slow). <when> is "now", or a GNU
# date phrase such as "40 days ago" or "@<epoch>" for the object's
# LastModified: MinIO takes that from the X-Minio-Source-Mtime header its
# replication uses, and if a MinIO release ignores it the test is skipped.
_ret_put_aged() {
  _ra_bucket=$1
  shift
  docker run --rm --network "$E2E_NET" --label "e2e.run=$E2E_RUN_ID" --label "e2e.case=$CASE_SLUG" \
    -e "RA_AUTH=$S3_KEY:$S3_SECRET" -e "RA_BASE=http://minio:9000/$_ra_bucket" \
    --entrypoint sh "$E2E_IMAGE" -c '
      set -e
      put() {
        curl -fsS -o /dev/null --aws-sigv4 aws:amz:us-east-1:s3 --user "$RA_AUTH" -T /tmp/body "$@"
      }
      while [ $# -ge 2 ]; do
        url="$RA_BASE/$(python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "$2")"
        printf "object %s\n" "$2" > /tmp/body
        if [ "$1" = now ]; then
          put "$url"
        else
          at=$(date -u -d "$1" +%s)
          put -H "X-Minio-Source-Mtime: $(date -u -d "@$at" +%Y-%m-%dT%H:%M:%SZ)" "$url"
          want=$(date -u -d "@$at" "+%a, %d %b %Y %H:%M:%S GMT")
          curl -fsSI --aws-sigv4 aws:amz:us-east-1:s3 --user "$RA_AUTH" "$url" > /tmp/head
          got=$(tr -d "\r" < /tmp/head | sed -n "s/^[Ll]ast-[Mm]odified: //p")
          if [ "$got" != "$want" ]; then
            echo "$2 has Last-Modified \"$got\", not \"$want\"" >&2
            exit 3
          fi
        fi
        shift 2
      done
    ' sh "$@"
  case $? in
    0) ;;
    3) skip "MinIO ignored X-Minio-Source-Mtime, so objects cannot be backdated" ;;
    *) fail "could not upload objects to s3://$_ra_bucket" ;;
  esac
}

# _ret_put <bucket> <key>... - uploads small objects (LastModified now).
_ret_put() {
  _rp_bucket=$1
  shift
  _rp_args=()
  for _rp_key in "$@"; do
    _rp_args+=(now "$_rp_key")
  done
  _ret_put_aged "$_rp_bucket" "${_rp_args[@]}"
}

# _ret_list <bucket> - stores the bucket's keys in RET_KEYS, so that several
# checks share one listing.
_ret_list() {
  RET_KEYS=$(s3_keys "$1")
}

# Keys in RET_KEYS, quoted so that leading and trailing spaces show.
_ret_keys_shown() {
  printf '%s\n' "$RET_KEYS" | sed '/^$/d; s/.*/"&"/' | tr '\n' ' '
}

# _ret_kept <key>... / _ret_gone <key>... - checks keys against RET_KEYS.
_ret_kept() {
  for _rk_key in "$@"; do
    printf '%s\n' "$RET_KEYS" | grep -Fxq -- "$_rk_key" \
      || fail "\"$_rk_key\" should have been kept (have: $(_ret_keys_shown))"
  done
}

_ret_gone() {
  for _rg_key in "$@"; do
    if printf '%s\n' "$RET_KEYS" | grep -Fxq -- "$_rg_key"; then
      fail "\"$_rg_key\" should have been deleted (have: $(_ret_keys_shown))"
    fi
  done
}

# _ret_count <n> - RET_KEYS has exactly n keys.
_ret_count() {
  assert_eq "$(printf '%s\n' "$RET_KEYS" | grep -c .)" "$1" "objects in the bucket ($(_ret_keys_shown))"
}

# _ret_new_backup <prefix> <database> [suffix-regex] - prints the one key in
# RET_KEYS that is a backup of database under prefix, or fails.
_ret_new_backup() {
  _rn_keys=$(printf '%s\n' "$RET_KEYS" | grep -E "^$1/$2_${_RET_TS}${3:-\\.sql\\.gz}\$")
  [ "$(printf '%s' "$_rn_keys" | grep -c .)" = 1 ] \
    || fail "expected one backup of $2 under $1/ (have: $(_ret_keys_shown))"
  printf '%s\n' "$_rn_keys"
}

# _ret_s3_user <tag> <bucket> <bucket-actions> <object-actions> - creates a
# MinIO user that may only do the given actions (quoted JSON strings, such as
# '"s3:ListBucket"') on the bucket and on its objects, and sets RET_USER_ENV
# to the bk_run options that use it.
_ret_s3_user() {
  _ru_name="ret$(printf '%s' "$CASE_SLUG-$1" | cksum | cut -d' ' -f1)"
  _ru_secret="$_ru_name-secret"
  mc_cli admin user add e2e "$_ru_name" "$_ru_secret" >/dev/null || fail "could not create MinIO user $_ru_name"
  printf '{"Version":"2012-10-17","Statement":[%s,%s]}' \
    "{\"Effect\":\"Allow\",\"Action\":[$3],\"Resource\":[\"arn:aws:s3:::$2\"]}" \
    "{\"Effect\":\"Allow\",\"Action\":[$4],\"Resource\":[\"arn:aws:s3:::$2/*\"]}" \
    | mc_cli admin policy create e2e "$_ru_name" /dev/stdin >/dev/null || fail "could not create policy $_ru_name"
  mc_cli admin policy attach e2e "$_ru_name" --user "$_ru_name" >/dev/null || fail "could not attach policy $_ru_name"
  RET_USER_ENV=(--unset S3_ACCESS_KEY_ID --unset S3_SECRET_ACCESS_KEY
    -e "S3_ACCESS_KEY_ID=$_ru_name" -e "S3_SECRET_ACCESS_KEY=$_ru_secret")
}

# _ret_hook_env <event> <name> - value of name in the environment a hook saw.
_ret_hook_env() {
  [ -f "$CASE_DIR/hook-out/$1.env" ] || fail "the $1 hook did not run"
  sed -n "s/^$2=//p" "$CASE_DIR/hook-out/$1.env"
}

_ret_log_has() {
  bk_logs
  grep -Fq -- "$1" "$BK_LOG"
}

# ---------------------------------------------------------------------------
# What is deleted and what is kept.

test_retention_deletes_old_objects_and_keeps_new_backup() {
  bucket=$(new_bucket) || exit 1
  _ret_put "$bucket" backup/old-1.sql.gz backup/old-2.sql.gz
  uploaded=$(date +%s)
  db=$(new_db) || exit 1
  # The post-backup hook lists the prefix, to show retention has finished by then.
  mc_cli anonymous set download "e2e/$bucket" >/dev/null || fail "could not allow anonymous listing"
  hooks_setup
  write_hook post-backup '#!/bin/sh
curl -fsS "$S3_ENDPOINT/$S3_BUCKET?list-type=2&prefix=$S3_PREFIX/" > /hook-out/listing'
  # The threshold is taken after the upload: the old objects are then at
  # least 9 - 5 = 4 seconds older than it, and the new backup is newer
  # unless the end of the upload and the threshold are 4 seconds apart.
  wait_for 30 _ret_now_at_least $((uploaded + 9)) || fail "clock did not advance"

  bk_backup backup "$db" "$bucket" -e "DELETE_OLDER_THAN=5 seconds ago" "${HOOK_MOUNTS[@]}"
  assert_rc 0 "backup with DELETE_OLDER_THAN"
  assert_log_contains "Checking for files older than 5 seconds ago"
  assert_log_contains "DELETING old-1.sql.gz"
  assert_log_contains "DELETING old-2.sql.gz"
  assert_log_contains "SQL backup finished"
  _ret_list "$bucket"
  _ret_gone backup/old-1.sql.gz backup/old-2.sql.gz
  new=$(_ret_new_backup backup "$db") || exit 1
  _ret_count 1
  assert_file_contains "$CASE_DIR/hook-out/listing" "<Key>$new</Key>" "listing taken by the post-backup hook"
  assert_file_not_contains "$CASE_DIR/hook-out/listing" "<Key>backup/old-" "old objects still listed when post-backup ran"
  assert_eq "$(bk_tmp_leftovers)" "" "temporary files (the S3 listing) left in /tmp"
}

test_retention_keeps_objects_newer_than_threshold() {
  bucket=$(new_bucket) || exit 1
  _ret_put "$bucket" backup/before.sql.gz
  cutoff=$(_ret_mark)
  db=$(new_db) || exit 1
  _ret_wait_past "$cutoff"
  _ret_put "$bucket" backup/after.sql.gz backup/after.txt

  bk_backup backup "$db" "$bucket" -e "DELETE_OLDER_THAN=@$cutoff"
  assert_rc 0 "backup with DELETE_OLDER_THAN=@<epoch>"
  assert_log_contains "DELETING before.sql.gz"
  assert_log_contains "after.sql.gz not older than @$cutoff"
  assert_log_contains "after.txt not older than @$cutoff"
  assert_log_not_contains "DELETING after"
  _ret_list "$bucket"
  _ret_gone backup/before.sql.gz
  _ret_kept backup/after.sql.gz backup/after.txt
  _ret_new_backup backup "$db" >/dev/null || exit 1
  _ret_count 3
}

# The README's example, with objects backdated by days.
test_retention_days_ago_as_documented() {
  bucket=$(new_bucket) || exit 1
  db=$(new_db) || exit 1
  _ret_put_aged "$bucket" "45 days ago" backup/45-days.sql.gz "31 days ago" backup/31-days.sql.gz \
    "29 days ago" backup/29-days.sql.gz "1 hour ago" backup/1-hour.sql.gz

  bk_backup backup "$db" "$bucket" -e "DELETE_OLDER_THAN=30 days ago"
  assert_rc 0 "backup with DELETE_OLDER_THAN='30 days ago'"
  assert_log_contains "DELETING 45-days.sql.gz"
  assert_log_contains "DELETING 31-days.sql.gz"
  assert_log_contains "29-days.sql.gz not older than 30 days ago"
  assert_log_contains "1-hour.sql.gz not older than 30 days ago"
  _ret_list "$bucket"
  _ret_gone backup/45-days.sql.gz backup/31-days.sql.gz
  _ret_kept backup/29-days.sql.gz backup/1-hour.sql.gz
  _ret_new_backup backup "$db" >/dev/null || exit 1
  _ret_count 3
}

# DELETE_OLDER_THAN has no default: without it nothing is deleted, however old.
test_retention_off_by_default() {
  bucket=$(new_bucket) || exit 1
  db=$(new_db) || exit 1
  _ret_put_aged "$bucket" "400 days ago" backup/400-days.sql.gz "1 day ago" backup/1-day.sql.gz

  bk_backup backup "$db" "$bucket"
  assert_rc 0 "backup without DELETE_OLDER_THAN"
  assert_log_not_contains "Checking for files older than"
  assert_log_not_contains "DELETING"
  _ret_list "$bucket"
  _ret_kept backup/400-days.sql.gz backup/1-day.sql.gz
  _ret_new_backup backup "$db" >/dev/null || exit 1
  _ret_count 3
}

# "Older than" is strict: an object from the threshold's own second is kept.
test_retention_threshold_is_exclusive() {
  bucket=$(new_bucket) || exit 1
  db=$(new_db) || exit 1
  at=$(($(date +%s) - 10 * 86400))
  _ret_put_aged "$bucket" "@$((at - 1))" backup/second-before.sql.gz "@$at" backup/same-second.sql.gz \
    "@$((at + 1))" backup/second-after.sql.gz

  bk_backup backup "$db" "$bucket" -e "DELETE_OLDER_THAN=@$at"
  assert_rc 0 "backup with DELETE_OLDER_THAN=@<epoch>"
  _ret_list "$bucket"
  _ret_gone backup/second-before.sql.gz
  _ret_kept backup/same-second.sql.gz backup/second-after.sql.gz
}

# Only objects directly in S3_PREFIX/ are candidates: not sub-prefixes (listed
# as PRE), not other prefixes, even ones that start with the same text.
test_retention_only_touches_objects_directly_in_prefix() {
  bucket=$(new_bucket) || exit 1
  others="backup/nested/old.sql.gz backup/nested/deeper/old.sql.gz backup-archive/old.sql.gz
    backups/old.sql.gz backupold.sql.gz old.sql.gz archive/backup/old.sql.gz"
  # shellcheck disable=SC2086
  _ret_put "$bucket" backup/old.sql.gz $others
  cutoff=$(_ret_mark)
  db=$(new_db) || exit 1
  _ret_wait_past "$cutoff"

  bk_backup backup "$db" "$bucket" -e "DELETE_OLDER_THAN=@$cutoff"
  assert_rc 0 "backup with DELETE_OLDER_THAN"
  assert_log_contains "DELETING old.sql.gz"
  assert_log_not_contains "nested" "retention looked into the nested/ sub-prefix"
  _ret_list "$bucket"
  _ret_gone backup/old.sql.gz
  # shellcheck disable=SC2086
  _ret_kept $others
  _ret_new_backup backup "$db" >/dev/null || exit 1
  _ret_count 8
}

# README: "this will delete all files in the S3_PREFIX path, not just those
# created by this script."
test_retention_deletes_any_file_in_prefix() {
  bucket=$(new_bucket) || exit 1
  # PREPROD_...: a name that merely contains PRE is a file, not a sub-prefix.
  _ret_put "$bucket" backup/README.txt backup/.keep backup/otherdb_2020-01-01T00:00:00Z.dump.enc \
    backup/PREPROD_2020-01-01T00:00:00Z.sql.gz
  cutoff=$(_ret_mark)
  db=$(new_db) || exit 1
  _ret_wait_past "$cutoff"

  bk_backup backup "$db" "$bucket" -e "DELETE_OLDER_THAN=@$cutoff"
  assert_rc 0 "backup with DELETE_OLDER_THAN"
  assert_log_contains "DELETING README.txt"
  assert_log_contains "DELETING .keep"
  assert_log_contains "DELETING otherdb_2020-01-01T00:00:00Z.dump.enc"
  assert_log_contains "DELETING PREPROD_2020-01-01T00:00:00Z.sql.gz"
  _ret_list "$bucket"
  _ret_gone backup/README.txt backup/.keep backup/otherdb_2020-01-01T00:00:00Z.dump.enc \
    backup/PREPROD_2020-01-01T00:00:00Z.sql.gz
  _ret_new_backup backup "$db" >/dev/null || exit 1
  _ret_count 1
}

# A newer key that is the old one without its backslash must survive.
test_retention_deletes_keys_with_spaces_or_backslashes() {
  bucket=$(new_bucket) || exit 1
  _ret_put "$bucket" "backup/old file.sql.gz" "backup/my db_2020-01-01T00:00:00Z.sql.gz" \
    'backup/back\slash.sql.gz'
  cutoff=$(_ret_mark)
  db=$(new_db) || exit 1
  _ret_wait_past "$cutoff"
  _ret_put "$bucket" "backup/new file.sql.gz" backup/backslash.sql.gz

  bk_backup backup "$db" "$bucket" -e "DELETE_OLDER_THAN=@$cutoff"
  assert_rc 0 "backup with DELETE_OLDER_THAN"
  assert_log_contains "DELETING old file.sql.gz"
  assert_log_contains "DELETING my db_2020-01-01T00:00:00Z.sql.gz"
  assert_log_contains 'DELETING back\slash.sql.gz'
  assert_log_contains "new file.sql.gz not older than @$cutoff"
  _ret_list "$bucket"
  _ret_gone "backup/old file.sql.gz" "backup/my db_2020-01-01T00:00:00Z.sql.gz" 'backup/back\slash.sql.gz'
  _ret_kept "backup/new file.sql.gz" backup/backslash.sql.gz
  _ret_new_backup backup "$db" >/dev/null || exit 1
  _ret_count 3
}

# Each old key differs from a newer one only in its whitespace.
test_retention_keys_differing_only_in_whitespace() {
  bucket=$(new_bucket) || exit 1
  tab=$'\t'
  _ret_put "$bucket" "backup/ lead.sql.gz" "backup/two  spaces.sql.gz" "backup/tab${tab}x.sql.gz" "backup/trail.sql.gz "
  cutoff=$(_ret_mark)
  db=$(new_db) || exit 1
  _ret_wait_past "$cutoff"
  _ret_put "$bucket" backup/lead.sql.gz "backup/two spaces.sql.gz" "backup/tab x.sql.gz" backup/trail.sql.gz

  xfail "retention rebuilds each key from 'aws s3 ls' with awk field splitting, which drops leading and trailing spaces and turns tabs and runs of spaces into one space: the old key stays and a newer object with the rebuilt name is deleted instead"
  bk_backup backup "$db" "$bucket" -e "DELETE_OLDER_THAN=@$cutoff"
  assert_rc 0 "backup with DELETE_OLDER_THAN"
  _ret_list "$bucket"
  _ret_kept backup/lead.sql.gz "backup/two spaces.sql.gz" "backup/tab x.sql.gz" backup/trail.sql.gz
  _ret_gone "backup/ lead.sql.gz" "backup/two  spaces.sql.gz" "backup/tab${tab}x.sql.gz" "backup/trail.sql.gz "
}

test_retention_deletes_file_whose_name_contains_pre() {
  bucket=$(new_bucket) || exit 1
  _ret_put "$bucket" "backup/release PRE 1.sql.gz"
  cutoff=$(_ret_mark)
  db=$(new_db) || exit 1
  _ret_wait_past "$cutoff"

  xfail "retention skips every 'aws s3 ls' line containing ' PRE ' to ignore sub-prefixes, so an old file whose name contains ' PRE ' is never deleted"
  bk_backup backup "$db" "$bucket" -e "DELETE_OLDER_THAN=@$cutoff"
  assert_rc 0 "backup with DELETE_OLDER_THAN"
  _ret_list "$bucket"
  _ret_gone "backup/release PRE 1.sql.gz"
}

test_retention_custom_nested_prefix() {
  bucket=$(new_bucket) || exit 1
  prefix=team/prod/db1
  others="team/prod/db1/nested/old.sql.gz team/prod/db10/old.sql.gz team/prod/old.sql.gz backup/old.sql.gz"
  # shellcheck disable=SC2086
  _ret_put "$bucket" "$prefix/old.sql.gz" "$prefix/old.dump.enc" $others
  cutoff=$(_ret_mark)
  db=$(new_db) || exit 1
  _ret_wait_past "$cutoff"

  bk_backup backup "$db" "$bucket" -e "S3_PREFIX=$prefix" -e USE_CUSTOM_FORMAT=yes \
    -e ENCRYPTION_PASSWORD=retention-secret -e "DELETE_OLDER_THAN=@$cutoff"
  assert_rc 0 "backup with retention under $prefix"
  assert_log_contains "DELETING old.sql.gz"
  assert_log_contains "DELETING old.dump.enc"
  _ret_list "$bucket"
  _ret_gone "$prefix/old.sql.gz" "$prefix/old.dump.enc"
  # shellcheck disable=SC2086
  _ret_kept $others
  _ret_new_backup "$prefix" "$db" '\.dump\.enc' >/dev/null || exit 1
  _ret_count 5
}

# aws s3 ls prints local time and backup.sh parses it as local time, so both
# must follow TZ. <E2E>-14 is POSIX for 14 hours ahead of UTC all year.
test_retention_honours_tz() {
  bucket=$(new_bucket) || exit 1
  _ret_put "$bucket" backup/before.sql.gz
  cutoff=$(_ret_mark)
  db=$(new_db) || exit 1
  _ret_wait_past "$cutoff"
  _ret_put "$bucket" backup/after.sql.gz

  bk_backup backup "$db" "$bucket" -e "TZ=<E2E>-14" -e "DELETE_OLDER_THAN=@$cutoff"
  assert_rc 0 "backup with TZ=<E2E>-14 and DELETE_OLDER_THAN"
  _ret_list "$bucket"
  _ret_gone backup/before.sql.gz
  _ret_kept backup/after.sql.gz
  _ret_new_backup backup "$db" >/dev/null || exit 1
}

# Restores often share the backup container's environment; they must not
# apply retention.
test_retention_not_applied_by_restore() {
  bucket=$(new_bucket) || exit 1
  db=$(new_db) || exit 1
  bk_backup backup "$db" "$bucket"
  assert_rc 0 "backup"
  key=$(s3_single_key "$bucket" backup/) || exit 1
  _ret_put "$bucket" backup/old.sql.gz
  cutoff=$(_ret_mark)
  _ret_wait_past "$cutoff"

  bk_restore restore "${db}_restored" "$bucket" "$key" -e CREATE_DATABASE=yes -e "DELETE_OLDER_THAN=@$cutoff"
  assert_rc 0 "restore with DELETE_OLDER_THAN set"
  assert_log_not_contains "Checking for files older than"
  assert_log_not_contains "DELETING"
  _ret_list "$bucket"
  _ret_kept "$key" backup/old.sql.gz
  _ret_count 2
}

test_retention_runs_on_every_scheduled_backup() {
  bucket=$(new_bucket) || exit 1
  db=$(new_db) || exit 1

  # Each run's threshold is 3 s before its own upload, so a run deletes the
  # backup from two runs (12 s) back for sure, and usually the previous one.
  bk_start sched -e "POSTGRES_DATABASE=$db" -e "S3_BUCKET=$bucket" -e "SCHEDULE=@every 6s" \
    -e "DELETE_OLDER_THAN=3 seconds ago"
  wait_for 90 _ret_log_has "delete: s3://$bucket/backup/${db}_" \
    || fail "no scheduled run deleted an earlier backup"
  bk_stop
  deleted=$(sed -n "s#.*delete: s3://$bucket/\\(backup/${db}_[^ ]*\\.sql\\.gz\\).*#\\1#p" "$BK_LOG" | head -n 1)
  assert_match "$deleted" "^backup/${db}_${_RET_TS}\\.sql\\.gz\$" "deleted key"
  [ "$(grep -Fc "Checking for files older than 3 seconds ago" "$BK_LOG")" -ge 2 ] \
    || fail "retention did not run on every scheduled backup"
  _ret_list "$bucket"
  _ret_gone "$deleted"
  [ "$(printf '%s\n' "$RET_KEYS" | grep -c "^backup/${db}_")" -ge 1 ] \
    || fail "scheduled retention left no backup (have: $(_ret_keys_shown))"
}

# ---------------------------------------------------------------------------
# Failures.

test_retention_does_not_run_when_backup_fails() {
  bucket=$(new_bucket) || exit 1
  _ret_put "$bucket" backup/old.sql.gz
  cutoff=$(_ret_mark)
  db=$(new_db) || exit 1
  # May list and delete, so retention would succeed if it ran, but not upload.
  _ret_s3_user noput "$bucket" '"s3:ListBucket"' '"s3:GetObject","s3:DeleteObject"'
  _ret_wait_past "$cutoff"

  bk_backup dump-fails "${db}_missing" "$bucket" -e "DELETE_OLDER_THAN=@$cutoff"
  assert_rc_nonzero "backup of a database that does not exist"
  assert_log_not_contains "Checking for files older than" "retention ran after the dump failed"

  bk_backup upload-fails "$db" "$bucket" "${RET_USER_ENV[@]}" -e "DELETE_OLDER_THAN=@$cutoff"
  assert_rc_nonzero "backup whose upload is denied"
  assert_log_contains "Uploading dump to $bucket"
  assert_log_not_contains "Checking for files older than" "retention ran after the upload failed"
  assert_log_not_contains "DELETING"

  _ret_list "$bucket"
  _ret_kept backup/old.sql.gz
  _ret_count 1
}

# README: post-backup runs only when "dump, encrypt, upload, and optional
# retention delete all succeeded"; backup-error on any non-zero exit.
test_retention_delete_failure_fails_the_backup() {
  bucket=$(new_bucket) || exit 1
  _ret_put "$bucket" backup/old.sql.gz
  cutoff=$(_ret_mark)
  db=$(new_db) || exit 1
  _ret_s3_user nodelete "$bucket" '"s3:ListBucket"' '"s3:GetObject","s3:PutObject"'
  hooks_setup
  write_hook post-backup
  write_hook backup-error
  _ret_wait_past "$cutoff"

  bk_backup backup "$db" "$bucket" "${RET_USER_ENV[@]}" "${HOOK_MOUNTS[@]}" -e "DELETE_OLDER_THAN=@$cutoff"
  assert_rc_nonzero "backup whose retention may not delete"
  assert_log_contains "DELETING old.sql.gz"
  assert_log_not_contains "SQL backup finished"
  assert_eq "$(hook_events)" "backup-error" "hooks run"
  assert_eq "$(_ret_hook_env backup-error HOOK_EXIT_CODE)" "$BK_RC" "HOOK_EXIT_CODE"
  assert_eq "$(bk_tmp_leftovers)" "" "temporary files (the S3 listing) left in /tmp"
  _ret_list "$bucket"
  _ret_kept backup/old.sql.gz
  _ret_new_backup backup "$db" >/dev/null || exit 1
}

test_retention_listing_failure_fails_the_backup() {
  bucket=$(new_bucket) || exit 1
  db=$(new_db) || exit 1
  _ret_s3_user nolist "$bucket" '"s3:GetBucketLocation"' '"s3:PutObject"'
  hooks_setup
  write_hook post-backup
  write_hook backup-error

  bk_backup backup "$db" "$bucket" "${RET_USER_ENV[@]}" "${HOOK_MOUNTS[@]}" -e "DELETE_OLDER_THAN=1 day ago"
  assert_rc_nonzero "backup whose retention may not list the prefix"
  assert_log_contains "Checking for files older than 1 day ago"
  assert_log_not_contains "SQL backup finished"
  assert_eq "$(hook_events)" "backup-error" "hooks run"
  assert_eq "$(_ret_hook_env backup-error HOOK_EXIT_CODE)" "$BK_RC" "HOOK_EXIT_CODE"
  assert_eq "$(bk_tmp_leftovers)" "" "temporary files (the S3 listing) left in /tmp"
}

# ---------------------------------------------------------------------------
# Thresholds that are not a date in the past.

test_retention_invalid_threshold_deletes_nothing() {
  bucket=$(new_bucket) || exit 1
  _ret_put "$bucket" backup/old.sql.gz
  cutoff=$(_ret_mark)
  db=$(new_db) || exit 1
  hooks_setup
  write_hook post-backup
  # Old enough to be deleted if the value were read as "now".
  _ret_wait_past "$cutoff"

  bk_backup backup "$db" "$bucket" -e "DELETE_OLDER_THAN=not a date" "${HOOK_MOUNTS[@]}"
  assert_rc_nonzero "backup with DELETE_OLDER_THAN='not a date'"
  assert_log_contains "not a date"
  assert_log_not_contains "DELETING"
  assert_log_not_contains "SQL backup finished"
  assert_eq "$(hook_events)" "" "post-backup hook ran although DELETE_OLDER_THAN is invalid"
  _ret_list "$bucket"
  _ret_kept backup/old.sql.gz
}

# An empty DELETE_OLDER_THAN is covered by
# test_validation_empty_delete_older_than_deletes_nothing in validation.sh.

# "7 days" (without "ago") is 7 days in the future. Whether that is rejected or
# not, the backup just uploaded must survive.
test_retention_future_threshold_keeps_new_backup() {
  bucket=$(new_bucket) || exit 1
  db=$(new_db) || exit 1

  bk_backup backup "$db" "$bucket" -e "DELETE_OLDER_THAN=7 days"
  assert_log_not_contains "DELETING ${db}_" "retention deleted the backup it had just uploaded"
  if [ "$BK_RC" = 0 ]; then
    _ret_list "$bucket"
    _ret_new_backup backup "$db" >/dev/null || exit 1
  fi
}
