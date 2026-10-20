# S3 options against MinIO: S3_BUCKET with a sub-path, S3_PREFIX, S3_REGION,
# S3_S3V4, credentials (S3_* and the default AWS chain), S3_ENDPOINT, checksum
# settings and multipart uploads.

_S3_TS_RE='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'

# ---------------------------------------------------------------------------
# Helpers.

# _s3_mark_db <database> - adds a marker table, so a restore that replaced the
# database (even with identical data) is noticed by _s3_assert_marker.
_s3_mark_db() {
  psql_exec "$1" "CREATE TABLE public.s3_untouched_marker (v text); INSERT INTO public.s3_untouched_marker VALUES ('still here')" >/dev/null \
    || fail "could not add a marker to $1"
}

_s3_assert_marker() {
  assert_eq "$(psql_exec "$1" "SELECT v FROM public.s3_untouched_marker" 2>/dev/null)" "still here" \
    "${2:-database $1 was replaced or changed}"
}

# _s3_env_value <env-file> <name> - value of name in a file written by `env`.
_s3_env_value() {
  [ -f "$1" ] || fail "hook environment file not found: $1"
  sed -n "s/^$2=//p" "$1"
}

# _s3_object_stat <bucket> <key> - prints "<size> <etag>" of an object.
_s3_object_stat() {
  _so_json=$(mc_cli stat --json "e2e/$1/$2") || fail "could not stat s3://$1/$2"
  _so_size=$(printf '%s' "$_so_json" | sed -n 's/.*"size":\([0-9][0-9]*\).*/\1/p' | head -n 1)
  _so_etag=$(printf '%s' "$_so_json" | sed -n 's/.*"etag":"\([^"]*\)".*/\1/p' | head -n 1)
  printf '%s %s\n' "$_so_size" "$_so_etag"
}

# _s3_cutoff_mark - prints a time (seconds since the epoch) later than every
# object uploaded so far. Once _s3_cutoff_wait <cutoff> returns, objects
# uploaded afterwards are newer, so DELETE_OLDER_THAN=@<cutoff> must delete
# exactly the earlier ones. Two seconds of slack either side cover the
# one-second resolution of S3 listings and small clock differences between the
# host and the Docker VM (Docker Desktop).
_s3_cutoff_mark() {
  printf '%s\n' $(($(date +%s) + 2))
}

_s3_cutoff_wait() {
  wait_for 15 _s3_now_at_least $(($1 + 2)) || fail "clock did not advance"
}

# _s3_cutoff - both of the above. Use as cutoff=$(_s3_cutoff) || exit 1.
_s3_cutoff() {
  _sc_at=$(_s3_cutoff_mark)
  _s3_cutoff_wait "$_sc_at"
  printf '%s\n' "$_sc_at"
}

_s3_now_at_least() {
  [ "$(date +%s)" -ge "$1" ]
}

# --- MinIO request trace ----------------------------------------------------
#
# The AWS CLI hides some settings from S3 (it follows region redirects, for
# example), and MinIO quietly turns a key such as "/x" or "a//x" into "x" or
# rejects it, so a few tests read the requests MinIO received instead:
# `mc admin trace --verbose` prints each request with its headers.

# _s3_trace_start <bucket> - starts tracing (until the case ends).
_s3_trace_start() {
  _S3_TRACE_BUCKET=$1
  _S3_TRACE_CTR="${E2E_RUN_ID}-${CASE_SLUG}-trace"
  _S3_TRACE_N=0
  docker run -d --name "$_S3_TRACE_CTR" --label "e2e.run=$E2E_RUN_ID" --label "e2e.case=$CASE_SLUG" \
    --network "$E2E_NET" -e "MC_HOST_e2e=http://${S3_KEY}:${S3_SECRET}@minio:9000" \
    "$E2E_MC_IMAGE" --no-color admin trace --verbose e2e >/dev/null \
    || fail "could not start the MinIO trace"
  _s3_trace_sync
}

# _s3_trace_sync - makes a marker request and waits until the trace shows it,
# so every request made before the call is in the trace, then writes one line
# per traced request to CASE_DIR/trace.txt:
#   <method> <path> <aws-cli|other> <signing-region> <checksum-algorithm|-> <checksum-mode|->
_s3_trace_sync() {
  _S3_TRACE_N=$((_S3_TRACE_N + 1))
  _S3_TRACE_MARK="s3-trace-mark-$_S3_TRACE_N"
  wait_for 30 _s3_trace_has_mark || fail "the MinIO trace never showed marker request $_S3_TRACE_MARK"
  docker logs "$_S3_TRACE_CTR" 2>/dev/null | _s3_trace_summary >"$CASE_DIR/trace.txt"
}

_s3_trace_has_mark() {
  mc_cli stat "e2e/$_S3_TRACE_BUCKET/$_S3_TRACE_MARK" >/dev/null 2>&1
  docker logs "$_S3_TRACE_CTR" 2>/dev/null | grep -Fq "$_S3_TRACE_MARK"
}

_s3_trace_summary() {
  awk '
    { sub(/^[^ ]+:[0-9]+ /, "") }
    /^\[REQUEST / { req = 1; first = 1; ua = "other"; rg = "-"; ck = "-"; cm = "-"; next }
    /^\[RESPONSE\]/ { if (req) print m, p, ua, rg, ck, cm; req = 0; next }
    !req { next }
    first { m = $1; p = $2; first = 0; next }
    { h = tolower($1) }
    h == "user-agent:" && $2 ~ /^aws-cli\// { ua = "aws-cli" }
    h == "authorization:" && match($0, /Credential=[^,]*/) {
      if (split(substr($0, RSTART, RLENGTH), c, "/") >= 3) rg = c[3]
    }
    h ~ /^x-amz-checksum-(crc|sha)[a-z0-9]*:$/ { ck = substr(h, 16, length(h) - 16) }
    h == "x-amz-checksum-mode:" { cm = $2 }
  '
}

# _s3_trace_cli <bucket> [method] - traced AWS CLI requests for the bucket.
# The method LIST picks the GET requests that list objects; GET the others.
_s3_trace_cli() {
  awk -v b="/$1" -v m="${2:-}" '
    $3 != "aws-cli" { next }
    !($2 == b || index($2, b "/") == 1 || index($2, b "?") == 1) { next }
    { lst = ($1 == "GET" && $2 ~ /[?&]list-type=/) }
    m == "" || (m == "LIST" && lst) || (m != "LIST" && $1 == m && !lst)
  ' "$CASE_DIR/trace.txt"
}

# _s3_assert_cli_requests <bucket> <method> <what> - at least one such request.
_s3_assert_cli_requests() {
  [ -n "$(_s3_trace_cli "$1" "$2")" ] \
    || fail "$3: the trace shows no AWS CLI $2 request for bucket $1 (trace.txt has $(grep -c . "$CASE_DIR/trace.txt") requests; has the 'mc admin trace' format changed?)"
}

# _s3_assert_cli_keys <bucket> <method> <key-start> <what> - there is such a
# request, and each names an object key that starts with key-start (as sent,
# so URL-encoded), which rules out the extra slashes MinIO would hide.
_s3_assert_cli_keys() {
  _s3_assert_cli_requests "$1" "$2" "$4"
  _sck_bad=$(_s3_trace_cli "$1" "$2" | awk -v p="/$1/$3" 'index($2, p) != 1 { print $2 }')
  [ -z "$_sck_bad" ] || fail "$4: AWS CLI $2 requests for keys that do not start with '$3': $(printf '%s' "$_sck_bad" | tr '\n' ' ')"
}

# _s3_assert_signed_for <bucket> <region> <what> - every traced AWS CLI request
# for the bucket was signed (SigV4 credential scope) for region.
_s3_assert_signed_for() {
  _sa_bad=$(_s3_trace_cli "$1" | awk -v r="$2" '$4 != r')
  [ -z "$_sa_bad" ] || fail "$3: AWS CLI requests not signed for region $2: $(printf '%s' "$_sa_bad" | tr '\n' ';')"
}

# ---------------------------------------------------------------------------
# S3_BUCKET. README.md calls it "Your AWS S3 bucket path", so a sub-path is
# part of it: everything goes under <bucket>/<sub>/ and BACKUP_FILE is
# relative to it.

test_s3_bucket_with_sub_path_backup_retention_and_restore() {
  db=$(new_db) || exit 1
  bucket=$(new_bucket) || exit 1
  s3_put_string "$bucket" sub/backup/old.sql.gz "old backup"
  s3_put_string "$bucket" backup/keep.sql.gz "old object outside the sub-path"
  cutoff=$(_s3_cutoff) || exit 1
  hooks_setup
  write_hook post-backup

  bk_backup backup "$db" "$bucket/sub" -e "DELETE_OLDER_THAN=@$cutoff" "${HOOK_MOUNTS[@]}"
  assert_rc 0 "backup with S3_BUCKET=$bucket/sub and DELETE_OLDER_THAN"
  assert_s3_absent "$bucket" sub/backup/old.sql.gz "old backup under sub/backup/ was not deleted"
  assert_s3_exists "$bucket" backup/keep.sql.gz "retention deleted an object outside the sub-path"
  key=$(s3_single_key "$bucket" sub/) || exit 1
  assert_match "$key" "^sub/backup/${db}_${_S3_TS_RE}\.sql\.gz\$" "key under the bucket's sub-path"
  assert_eq "$(_s3_env_value "$CASE_DIR/hook-out/post-backup.env" BACKUP_S3_URI)" "s3://$bucket/$key" \
    "BACKUP_S3_URI with a bucket sub-path"

  restored="${db}_copy"
  bk_restore restore "$restored" "$bucket/sub" "${key#sub/}" -e CREATE_DATABASE=yes
  assert_rc 0 "restore with S3_BUCKET=$bucket/sub and BACKUP_FILE=${key#sub/}"
  assert_same_data "$db" "$restored"
}

# ---------------------------------------------------------------------------
# S3_PREFIX.

test_s3_prefix_nested_backup_and_restore() {
  db=$(new_db) || exit 1
  bucket=$(new_bucket) || exit 1

  bk_backup backup "$db" "$bucket" -e S3_PREFIX=prod/db1
  assert_rc 0 "backup with S3_PREFIX=prod/db1"
  key=$(s3_single_key "$bucket" "") || exit 1
  assert_match "$key" "^prod/db1/${db}_${_S3_TS_RE}\.sql\.gz\$" "key under the nested prefix"

  # BACKUP_FILE is the full key; S3_PREFIX (left at its default here) plays no part.
  restored="${db}_copy"
  bk_restore restore "$restored" "$bucket" "$key" -e CREATE_DATABASE=yes
  assert_rc 0 "restore from the nested prefix"
  assert_log_contains "Downloading backup file from S3: s3://$bucket/$key"
  assert_same_data "$db" "$restored"
}

# A trailing or a leading slash in S3_PREFIX ('backups/', '/backups') is a
# plausible setting; either way the key must be backups/<file>, never
# backups//<file> or /backups/<file>.

test_s3_prefix_trailing_slash_uploads_to_single_slash_key() {
  db=$(new_db) || exit 1
  bucket=$(new_bucket) || exit 1
  hooks_setup
  write_hook post-backup
  _s3_trace_start "$bucket"

  xfail "S3_PREFIX=backups/ uploads to s3://<bucket>/backups//<file>: MinIO rejects that key (XMinioInvalidObjectName) and the backup exits 2, AWS S3 would store a key containing '//'"
  bk_backup backup "$db" "$bucket" -e S3_PREFIX=backups/ "${HOOK_MOUNTS[@]}"
  assert_rc 0 "backup with S3_PREFIX=backups/"
  key=$(s3_single_key "$bucket" "") || exit 1
  assert_match "$key" "^backups/${db}_${_S3_TS_RE}\.sql\.gz\$" "key with S3_PREFIX=backups/"
  _s3_trace_sync
  _s3_assert_cli_keys "$bucket" PUT "backups/${db}_" "upload with S3_PREFIX=backups/"
  assert_eq "$(_s3_env_value "$CASE_DIR/hook-out/post-backup.env" BACKUP_S3_URI)" "s3://$bucket/$key" \
    "BACKUP_S3_URI with S3_PREFIX=backups/"
}

test_s3_prefix_trailing_slash_retention_deletes_old_backups() {
  db=$(new_db) || exit 1
  bucket=$(new_bucket) || exit 1
  s3_put_string "$bucket" backups/old.sql.gz "old backup"
  cutoff=$(_s3_cutoff) || exit 1
  _s3_trace_start "$bucket"

  xfail "S3_PREFIX=backups/ uploads to s3://<bucket>/backups//<file>, which MinIO rejects (XMinioInvalidObjectName), so the backup exits 2 before retention; retention would list and delete under backups// too"
  bk_backup backup "$db" "$bucket" -e S3_PREFIX=backups/ -e "DELETE_OLDER_THAN=@$cutoff"
  assert_rc 0 "backup with S3_PREFIX=backups/ and DELETE_OLDER_THAN"
  assert_s3_absent "$bucket" backups/old.sql.gz "old backup under backups/ was not deleted"
  new=$(s3_single_key "$bucket" "") || exit 1
  assert_match "$new" "^backups/${db}_${_S3_TS_RE}\.sql\.gz\$" "the new backup is the only object left"
  _s3_trace_sync
  _s3_assert_cli_keys "$bucket" DELETE backups/old.sql.gz "retention delete with S3_PREFIX=backups/"
}

test_s3_prefix_trailing_slash_backup_restores() {
  db=$(new_db) || exit 1
  bucket=$(new_bucket) || exit 1

  xfail "S3_PREFIX=backups/ uploads to s3://<bucket>/backups//<file>, which MinIO rejects (XMinioInvalidObjectName), so the backup exits 2 and there is nothing to restore"
  bk_backup backup "$db" "$bucket" -e S3_PREFIX=backups/
  assert_rc 0 "backup with S3_PREFIX=backups/"
  key=$(s3_single_key "$bucket" "") || exit 1
  assert_match "$key" "^backups/${db}_${_S3_TS_RE}\.sql\.gz\$" "key with S3_PREFIX=backups/"

  restored="${db}_copy"
  bk_restore restore "$restored" "$bucket" "$key" -e CREATE_DATABASE=yes -e S3_PREFIX=backups/
  assert_rc 0 "restore of a backup taken with S3_PREFIX=backups/"
  assert_same_data "$db" "$restored"
}

test_s3_prefix_leading_slash_uploads_to_single_slash_key() {
  db=$(new_db) || exit 1
  bucket=$(new_bucket) || exit 1
  hooks_setup
  write_hook post-backup
  _s3_trace_start "$bucket"

  bk_backup backup "$db" "$bucket" -e S3_PREFIX=/backups "${HOOK_MOUNTS[@]}"
  assert_rc 0 "backup with S3_PREFIX=/backups"
  key=$(s3_single_key "$bucket" "") || exit 1
  assert_match "$key" "^backups/${db}_${_S3_TS_RE}\.sql\.gz\$" "key with S3_PREFIX=/backups"
  _s3_trace_sync
  xfail "S3_PREFIX=/backups uploads to s3://<bucket>//backups/<file>, which on AWS S3 is a key starting with '/' (MinIO hides it by normalising the key); BACKUP_S3_URI has the same '//'"
  _s3_assert_cli_keys "$bucket" PUT "backups/${db}_" "upload with S3_PREFIX=/backups"
  assert_eq "$(_s3_env_value "$CASE_DIR/hook-out/post-backup.env" BACKUP_S3_URI)" "s3://$bucket/$key" \
    "BACKUP_S3_URI with S3_PREFIX=/backups"
}

test_s3_prefix_leading_slash_retention_deletes_old_backups() {
  db=$(new_db) || exit 1
  bucket=$(new_bucket) || exit 1
  s3_put_string "$bucket" backups/old.sql.gz "old backup"
  cutoff=$(_s3_cutoff) || exit 1
  _s3_trace_start "$bucket"

  xfail "with S3_PREFIX=/backups the retention listing is 'aws s3 ls s3://<bucket>//backups/', which matches nothing, so the backup exits 2 after uploading and nothing is deleted"
  bk_backup backup "$db" "$bucket" -e S3_PREFIX=/backups -e "DELETE_OLDER_THAN=@$cutoff"
  assert_rc 0 "backup with S3_PREFIX=/backups and DELETE_OLDER_THAN"
  assert_s3_absent "$bucket" backups/old.sql.gz "old backup under backups/ was not deleted"
  new=$(s3_single_key "$bucket" "") || exit 1
  assert_match "$new" "^backups/${db}_${_S3_TS_RE}\.sql\.gz\$" "the new backup is the only object left"
  _s3_trace_sync
  _s3_assert_cli_keys "$bucket" DELETE backups/old.sql.gz "retention delete with S3_PREFIX=/backups"
}

# Restores by the key the bucket lists. That works against MinIO, which stored
# the upload as backups/<file>; see the upload test above for AWS S3.
test_s3_prefix_leading_slash_backup_restores() {
  db=$(new_db) || exit 1
  bucket=$(new_bucket) || exit 1

  bk_backup backup "$db" "$bucket" -e S3_PREFIX=/backups
  assert_rc 0 "backup with S3_PREFIX=/backups"
  key=$(s3_single_key "$bucket" "") || exit 1
  assert_match "$key" "^backups/${db}_${_S3_TS_RE}\.sql\.gz\$" "key with S3_PREFIX=/backups"

  restored="${db}_copy"
  bk_restore restore "$restored" "$bucket" "$key" -e CREATE_DATABASE=yes -e S3_PREFIX=/backups
  assert_rc 0 "restore of a backup taken with S3_PREFIX=/backups"
  assert_same_data "$db" "$restored"
}

test_s3_prefix_empty_uploads_without_leading_slash() {
  db=$(new_db) || exit 1
  bucket=$(new_bucket) || exit 1
  hooks_setup
  write_hook post-backup
  _s3_trace_start "$bucket"

  bk_backup backup "$db" "$bucket" -e S3_PREFIX= "${HOOK_MOUNTS[@]}"
  assert_rc 0 "backup with an empty S3_PREFIX"
  key=$(s3_single_key "$bucket" "") || exit 1
  assert_match "$key" "^${db}_${_S3_TS_RE}\.sql\.gz\$" "key with an empty prefix"
  _s3_trace_sync
  xfail "an empty S3_PREFIX uploads to s3://<bucket>//<file>, which on AWS S3 is a key starting with '/' (MinIO hides it by normalising the key); BACKUP_S3_URI has the same '//'"
  _s3_assert_cli_keys "$bucket" PUT "${db}_" "upload with an empty S3_PREFIX"
  assert_eq "$(_s3_env_value "$CASE_DIR/hook-out/post-backup.env" BACKUP_S3_URI)" "s3://$bucket/$key" \
    "BACKUP_S3_URI with an empty prefix"
}

test_s3_prefix_empty_backup_restores() {
  db=$(new_db) || exit 1
  bucket=$(new_bucket) || exit 1

  bk_backup backup "$db" "$bucket" -e S3_PREFIX=
  assert_rc 0 "backup with an empty S3_PREFIX"
  key=$(s3_single_key "$bucket" "") || exit 1
  assert_match "$key" "^${db}_${_S3_TS_RE}\.sql\.gz\$" "key with an empty prefix"

  restored="${db}_copy"
  bk_restore restore "$restored" "$bucket" "$key" -e CREATE_DATABASE=yes -e S3_PREFIX=
  assert_rc 0 "restore of a backup taken with an empty prefix"
  assert_same_data "$db" "$restored"
}

test_s3_prefix_empty_retention_deletes_old_backups() {
  db=$(new_db) || exit 1
  bucket=$(new_bucket) || exit 1
  bk_backup first "$db" "$bucket" -e S3_PREFIX=
  assert_rc 0 "first backup with an empty S3_PREFIX"
  old=$(s3_single_key "$bucket" "") || exit 1
  assert_match "$old" "^${db}_${_S3_TS_RE}\.sql\.gz\$" "key with an empty prefix"
  cutoff=$(_s3_cutoff) || exit 1
  _s3_trace_start "$bucket"

  xfail "with an empty S3_PREFIX the retention listing is 'aws s3 ls s3://<bucket>//', which matches nothing, so the backup exits 2 after uploading and nothing is deleted"
  bk_backup second "$db" "$bucket" -e S3_PREFIX= -e "DELETE_OLDER_THAN=@$cutoff"
  assert_rc 0 "backup with an empty S3_PREFIX and DELETE_OLDER_THAN"
  assert_log_contains "SQL backup finished"
  assert_s3_absent "$bucket" "$old" "old backup was not deleted"
  assert_s3_count "$bucket" "" 1 "objects left after retention"
  _s3_trace_sync
  _s3_assert_cli_keys "$bucket" DELETE "${db}_" "retention delete with an empty S3_PREFIX"
}

# ---------------------------------------------------------------------------
# S3_REGION. Checked in the SigV4 credential scope of the requests MinIO sees.

test_s3_region_default_signs_requests_for_us_west_1() {
  db=$(new_db) || exit 1
  bucket=$(new_bucket) || exit 1
  _s3_trace_start "$bucket"

  bk_backup backup "$db" "$bucket"
  assert_rc 0 "backup with the default region"

  _s3_trace_sync
  _s3_assert_cli_requests "$bucket" PUT "backup upload"
  _s3_assert_signed_for "$bucket" us-west-1 "default S3_REGION"
}

test_s3_region_custom_signs_backup_retention_and_restore() {
  db=$(new_db) || exit 1
  bucket=$(new_bucket) || exit 1
  s3_put_string "$bucket" backup/old.sql.gz "old backup"
  cutoff=$(_s3_cutoff) || exit 1
  _s3_trace_start "$bucket"

  bk_backup backup "$db" "$bucket" -e S3_REGION=eu-central-1 -e "DELETE_OLDER_THAN=@$cutoff"
  assert_rc 0 "backup with S3_REGION=eu-central-1 and DELETE_OLDER_THAN"
  assert_s3_absent "$bucket" backup/old.sql.gz "old backup was not deleted"
  key=$(s3_single_key "$bucket" backup/) || exit 1
  restored="${db}_copy"
  bk_restore restore "$restored" "$bucket" "$key" -e CREATE_DATABASE=yes -e S3_REGION=eu-central-1
  assert_rc 0 "restore with S3_REGION=eu-central-1"
  assert_same_data "$db" "$restored"

  _s3_trace_sync
  _s3_assert_cli_requests "$bucket" PUT "backup upload"
  _s3_assert_cli_requests "$bucket" LIST "retention listing"
  _s3_assert_cli_requests "$bucket" DELETE "retention delete"
  _s3_assert_cli_requests "$bucket" GET "restore download"
  _s3_assert_signed_for "$bucket" eu-central-1 "S3_REGION=eu-central-1"
}

# ---------------------------------------------------------------------------
# S3_S3V4.

test_s3_s3v4_yes_writes_signature_version() {
  db=$(new_db) || exit 1
  bucket=$(new_bucket) || exit 1

  bk_backup backup "$db" "$bucket" -e S3_S3V4=yes
  assert_rc 0 "backup with S3_S3V4=yes"
  docker cp "$BK_CTR:/root/.aws/config" "$CASE_DIR/aws-config" >/dev/null 2>&1 \
    || fail "S3_S3V4=yes did not write /root/.aws/config"
  assert_file_contains "$CASE_DIR/aws-config" "signature_version = s3v4"
  # And the AWS CLI reads it as the default profile's S3 setting.
  got=$(docker run --rm -v "$CASE_DIR/aws-config:/root/.aws/config:ro" --entrypoint aws "$E2E_IMAGE" \
    configure get default.s3.signature_version 2>&1)
  assert_eq "$got" "s3v4" "default.s3.signature_version as the AWS CLI reads it"

  key=$(s3_single_key "$bucket" backup/) || exit 1
  restored="${db}_copy"
  bk_restore restore "$restored" "$bucket" "$key" -e CREATE_DATABASE=yes -e S3_S3V4=yes
  assert_rc 0 "restore with S3_S3V4=yes"
  assert_same_data "$db" "$restored"
  docker cp "$BK_CTR:/root/.aws/config" "$CASE_DIR/aws-config-restore" >/dev/null 2>&1 \
    || fail "S3_S3V4=yes did not write /root/.aws/config for a restore"
  assert_file_contains "$CASE_DIR/aws-config-restore" "signature_version = s3v4"
}

test_s3_s3v4_default_writes_no_aws_config() {
  db=$(new_db) || exit 1
  bucket=$(new_bucket) || exit 1

  bk_backup backup "$db" "$bucket"
  assert_rc 0 "backup with the default S3_S3V4"
  if docker cp "$BK_CTR:/root/.aws/config" "$CASE_DIR/aws-config" >/dev/null 2>&1; then
    fail "the default S3_S3V4=no wrote /root/.aws/config: $(cat "$CASE_DIR/aws-config")"
  fi
}

# ---------------------------------------------------------------------------
# Credentials. Half a key pair is rejected before anything runs; validation.sh
# covers that.

test_s3_credentials_from_aws_environment() {
  db=$(new_db) || exit 1
  bucket=$(new_bucket) || exit 1
  creds=(--unset S3_ACCESS_KEY_ID --unset S3_SECRET_ACCESS_KEY
    -e "AWS_ACCESS_KEY_ID=$S3_KEY" -e "AWS_SECRET_ACCESS_KEY=$S3_SECRET")

  bk_backup backup "$db" "$bucket" "${creds[@]}"
  assert_rc 0 "backup with AWS_* credentials only"
  key=$(s3_single_key "$bucket" backup/) || exit 1

  restored="${db}_copy"
  bk_restore restore "$restored" "$bucket" "$key" -e CREATE_DATABASE=yes "${creds[@]}"
  assert_rc 0 "restore with AWS_* credentials only"
  assert_same_data "$db" "$restored"
}

# The README's Kubernetes example sets every variable, empty ones included.
test_s3_credentials_empty_s3_values_use_aws_environment() {
  db=$(new_db) || exit 1
  bucket=$(new_bucket) || exit 1
  creds=(--unset S3_ACCESS_KEY_ID --unset S3_SECRET_ACCESS_KEY -e S3_ACCESS_KEY_ID= -e S3_SECRET_ACCESS_KEY=
    -e "AWS_ACCESS_KEY_ID=$S3_KEY" -e "AWS_SECRET_ACCESS_KEY=$S3_SECRET")

  bk_backup backup "$db" "$bucket" "${creds[@]}"
  assert_rc 0 "backup with empty S3_* credentials and AWS_* set"
  key=$(s3_single_key "$bucket" backup/) || exit 1

  restored="${db}_copy"
  bk_restore restore "$restored" "$bucket" "$key" -e CREATE_DATABASE=yes "${creds[@]}"
  assert_rc 0 "restore with empty S3_* credentials and AWS_* set"
  assert_same_data "$db" "$restored"
}

test_s3_credentials_from_shared_credentials_file() {
  db=$(new_db) || exit 1
  bucket=$(new_bucket) || exit 1
  printf '[default]\naws_access_key_id = %s\naws_secret_access_key = %s\n' "$S3_KEY" "$S3_SECRET" \
    >"$CASE_DIR/credentials"
  chmod 644 "$CASE_DIR/credentials"
  creds=(--unset S3_ACCESS_KEY_ID --unset S3_SECRET_ACCESS_KEY
    -v "$CASE_DIR/credentials:/root/.aws/credentials:ro")

  bk_backup backup "$db" "$bucket" "${creds[@]}"
  assert_rc 0 "backup with a mounted ~/.aws/credentials"
  key=$(s3_single_key "$bucket" backup/) || exit 1

  restored="${db}_copy"
  bk_restore restore "$restored" "$bucket" "$key" -e CREATE_DATABASE=yes "${creds[@]}"
  assert_rc 0 "restore with a mounted ~/.aws/credentials"
  assert_same_data "$db" "$restored"
}

test_s3_credentials_named_profile_in_custom_file() {
  db=$(new_db) || exit 1
  bucket=$(new_bucket) || exit 1
  printf '[default]\naws_access_key_id = wrongkey\naws_secret_access_key = wrongsecret\n\n[e2e-backup]\naws_access_key_id = %s\naws_secret_access_key = %s\n' \
    "$S3_KEY" "$S3_SECRET" >"$CASE_DIR/credentials"
  chmod 644 "$CASE_DIR/credentials"

  bk_backup backup "$db" "$bucket" --unset S3_ACCESS_KEY_ID --unset S3_SECRET_ACCESS_KEY \
    -v "$CASE_DIR/credentials:/etc/e2e-aws/credentials:ro" \
    -e AWS_SHARED_CREDENTIALS_FILE=/etc/e2e-aws/credentials -e AWS_PROFILE=e2e-backup
  assert_rc 0 "backup with AWS_PROFILE and AWS_SHARED_CREDENTIALS_FILE"
  assert_s3_count "$bucket" backup/ 1
}

# Temporary credentials (what IAM roles, IRSA and SSO hand out) come with a
# session token; MinIO's STS issues real ones.
test_s3_credentials_temporary_with_session_token() {
  db=$(new_db) || exit 1
  bucket=$(new_bucket) || exit 1
  temp=$(docker run --rm --network "$E2E_NET" --label "e2e.run=$E2E_RUN_ID" --label "e2e.case=$CASE_SLUG" \
    -e "AWS_ACCESS_KEY_ID=$S3_KEY" -e "AWS_SECRET_ACCESS_KEY=$S3_SECRET" -e AWS_DEFAULT_REGION=us-east-1 \
    --entrypoint aws "$E2E_IMAGE" --endpoint-url http://minio:9000 sts assume-role \
    --role-arn arn:aws:iam::123456789012:role/e2e --role-session-name "$CASE_SLUG" --duration-seconds 900 \
    --output text --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]') \
    || fail "could not get temporary credentials from MinIO STS"
  read -r temp_key temp_secret temp_token <<EOF
$temp
EOF
  [ -n "$temp_token" ] || fail "MinIO STS returned no session token: $temp"
  creds=(--unset S3_ACCESS_KEY_ID --unset S3_SECRET_ACCESS_KEY -e "AWS_ACCESS_KEY_ID=$temp_key"
    -e "AWS_SECRET_ACCESS_KEY=$temp_secret" -e "AWS_SESSION_TOKEN=$temp_token")

  bk_backup backup "$db" "$bucket" "${creds[@]}"
  assert_rc 0 "backup with temporary credentials"
  assert_log_not_contains "$temp_token" "the session token appears in the log"
  key=$(s3_single_key "$bucket" backup/) || exit 1

  restored="${db}_copy"
  bk_restore restore "$restored" "$bucket" "$key" -e CREATE_DATABASE=yes "${creds[@]}"
  assert_rc 0 "restore with temporary credentials"
  assert_log_not_contains "$temp_token" "the session token appears in the log"
  assert_same_data "$db" "$restored"
}

test_s3_credentials_s3_vars_take_precedence() {
  db=$(new_db) || exit 1
  bucket=$(new_bucket) || exit 1
  printf '[default]\naws_access_key_id = filekey\naws_secret_access_key = filesecret\n' >"$CASE_DIR/credentials"
  chmod 644 "$CASE_DIR/credentials"
  # Right S3_* (from the base environment), wrong AWS_* and a wrong credentials file.
  wrong=(-e AWS_ACCESS_KEY_ID=envkey -e AWS_SECRET_ACCESS_KEY=envsecret
    -v "$CASE_DIR/credentials:/root/.aws/credentials:ro")

  bk_backup backup "$db" "$bucket" "${wrong[@]}"
  assert_rc 0 "backup with right S3_* and wrong AWS_* credentials"
  key=$(s3_single_key "$bucket" backup/) || exit 1

  restored="${db}_copy"
  bk_restore restore "$restored" "$bucket" "$key" -e CREATE_DATABASE=yes "${wrong[@]}"
  assert_rc 0 "restore with right S3_* and wrong AWS_* credentials"
  assert_same_data "$db" "$restored"
}

test_s3_credentials_wrong_exit_2_and_change_nothing() {
  db=$(new_db) || exit 1
  bucket=$(new_bucket) || exit 1
  bk_backup good "$db" "$bucket"
  assert_rc 0 "backup with the right credentials"
  key=$(s3_single_key "$bucket" backup/) || exit 1
  _s3_mark_db "$db"
  wrong_secret="wrong-secret-$CASE_SLUG"

  bk_backup wrong-secret "$db" "$bucket" -e "S3_SECRET_ACCESS_KEY=$wrong_secret"
  assert_rc 2 "backup with a wrong secret key"
  assert_log_contains "SignatureDoesNotMatch"
  assert_log_not_contains "SQL backup finished"
  assert_log_not_contains "$wrong_secret" "the secret key appears in the log"
  assert_eq "$(bk_tmp_leftovers)" "" "temporary files left in /tmp after a refused upload"

  bk_backup wrong-key "$db" "$bucket" -e S3_ACCESS_KEY_ID=no-such-access-key
  assert_rc 2 "backup with an unknown access key"
  assert_log_contains "InvalidAccessKeyId"
  assert_log_not_contains "SQL backup finished"
  assert_s3_count "$bucket" "" 1 "objects after refused uploads"

  bk_restore restore "$db" "$bucket" "$key" -e "S3_SECRET_ACCESS_KEY=$wrong_secret" \
    -e DROP_DATABASE=yes -e CREATE_DATABASE=yes
  assert_rc 2 "restore with a wrong secret key"
  # The download starts with a HEAD request, whose 403 carries no error code.
  assert_log_contains "Forbidden"
  assert_log_not_contains "$wrong_secret" "the secret key appears in the restore log"
  assert_log_not_contains "Dropping database"
  assert_log_not_contains "Database restore completed successfully"
  _s3_assert_marker "$db" "a restore with wrong credentials touched the database"
  assert_eq "$(bk_tmp_leftovers)" "" "temporary files left in /tmp after a refused download"
}

test_s3_credentials_none_found_exit_2() {
  db=$(new_db) || exit 1
  bucket=$(new_bucket) || exit 1

  # No credentials anywhere; the metadata service is off so the lookup cannot
  # reach whatever cloud the runner is on.
  bk_backup backup "$db" "$bucket" --unset S3_ACCESS_KEY_ID --unset S3_SECRET_ACCESS_KEY \
    -e AWS_EC2_METADATA_DISABLED=true
  assert_rc 2 "backup without any credentials"
  assert_log_contains "Unable to locate credentials"
  assert_log_not_contains "SQL backup finished"
  assert_s3_count "$bucket" "" 0 "objects uploaded without credentials"
  assert_eq "$(bk_tmp_leftovers)" "" "temporary files left in /tmp"
}

# ---------------------------------------------------------------------------
# Bucket and endpoint. An empty S3_ENDPOINT is covered by validation.sh.

test_s3_missing_bucket_exit_2() {
  db=$(new_db) || exit 1
  missing="$CASE_SLUG-missing"

  bk_backup backup "$db" "$missing"
  assert_rc 2 "backup to a missing bucket"
  assert_log_contains "NoSuchBucket"
  assert_log_not_contains "SQL backup finished"
  if mc_cli ls "e2e/$missing" >/dev/null 2>&1; then
    fail "the failed backup created bucket $missing"
  fi

  _s3_mark_db "$db"
  bk_restore restore "$db" "$missing" "backup/${db}_2024-01-01T00:00:00Z.sql.gz" \
    -e DROP_DATABASE=yes -e CREATE_DATABASE=yes
  assert_rc 2 "restore from a missing bucket"
  assert_log_not_contains "Dropping database"
  _s3_assert_marker "$db" "a restore from a missing bucket touched the database"
}

test_s3_endpoint_unresolvable_fails_fast() {
  db=$(new_db) || exit 1
  bucket=$(new_bucket) || exit 1
  # .invalid never resolves (RFC 6761).
  endpoint="http://$CASE_SLUG.invalid:9000"

  started=$SECONDS
  bk_backup backup "$db" "$bucket" -e "S3_ENDPOINT=$endpoint"
  took=$((SECONDS - started))
  assert_rc_nonzero "backup to an endpoint that does not resolve"
  assert_log_contains "Could not connect to the endpoint URL"
  assert_log_not_contains "SQL backup finished"
  assert_eq "$(bk_tmp_leftovers)" "" "temporary files left in /tmp"
  # Generous for slow runners; a hang would run into bk_run's own timeout.
  [ "$took" -lt 60 ] || fail "backup to an unresolvable endpoint took ${took}s"

  _s3_mark_db "$db"
  started=$SECONDS
  bk_restore restore "$db" "$bucket" "backup/${db}_2024-01-01T00:00:00Z.sql.gz" -e "S3_ENDPOINT=$endpoint" \
    -e DROP_DATABASE=yes -e CREATE_DATABASE=yes
  took=$((SECONDS - started))
  assert_rc_nonzero "restore from an endpoint that does not resolve"
  assert_log_contains "Could not connect to the endpoint URL"
  _s3_assert_marker "$db" "a restore from an unreachable endpoint touched the database"
  [ "$took" -lt 60 ] || fail "restore from an unresolvable endpoint took ${took}s"
}

test_s3_endpoint_from_aws_endpoint_url_when_unset() {
  db=$(new_db) || exit 1
  bucket=$(new_bucket) || exit 1
  endpoint=(--unset S3_ENDPOINT -e AWS_ENDPOINT_URL=http://minio:9000)

  bk_backup backup "$db" "$bucket" "${endpoint[@]}"
  assert_rc 0 "backup with S3_ENDPOINT unset and AWS_ENDPOINT_URL set"
  key=$(s3_single_key "$bucket" backup/) || exit 1

  restored="${db}_copy"
  bk_restore restore "$restored" "$bucket" "$key" -e CREATE_DATABASE=yes "${endpoint[@]}"
  assert_rc 0 "restore with S3_ENDPOINT unset and AWS_ENDPOINT_URL set"
  assert_same_data "$db" "$restored"
}

# ---------------------------------------------------------------------------
# AWS_REQUEST_CHECKSUM_CALCULATION / AWS_RESPONSE_CHECKSUM_VALIDATION. Hooks
# with HOOK_INHERIT_ENV=yes show the values; the trace shows their effect.

test_s3_checksum_settings_default_to_when_required() {
  db=$(new_db) || exit 1
  bucket=$(new_bucket) || exit 1
  hooks_setup
  write_hook pre-backup
  write_hook pre-restore
  _s3_trace_start "$bucket"

  bk_backup backup "$db" "$bucket" -e HOOK_INHERIT_ENV=yes "${HOOK_MOUNTS[@]}"
  assert_rc 0 "backup with the default checksum settings"
  key=$(s3_single_key "$bucket" backup/) || exit 1
  restored="${db}_copy"
  bk_restore restore "$restored" "$bucket" "$key" -e CREATE_DATABASE=yes -e HOOK_INHERIT_ENV=yes "${HOOK_MOUNTS[@]}"
  assert_rc 0 "restore with the default checksum settings"
  assert_same_data "$db" "$restored"

  for ev in pre-backup pre-restore; do
    env_file="$CASE_DIR/hook-out/$ev.env"
    assert_eq "$(_s3_env_value "$env_file" AWS_REQUEST_CHECKSUM_CALCULATION)" when_required "AWS_REQUEST_CHECKSUM_CALCULATION ($ev)"
    assert_eq "$(_s3_env_value "$env_file" AWS_RESPONSE_CHECKSUM_VALIDATION)" when_required "AWS_RESPONSE_CHECKSUM_VALIDATION ($ev)"
  done

  _s3_trace_sync
  _s3_assert_cli_requests "$bucket" PUT "backup upload"
  _s3_assert_cli_requests "$bucket" GET "restore download"
  assert_eq "$(_s3_trace_cli "$bucket" PUT | awk '$5 != "-"')" "" "upload sent a checksum although none is required"
  assert_eq "$(_s3_trace_cli "$bucket" GET | awk '$6 != "-"')" "" "download asked for checksum validation although none is required"
}

test_s3_checksum_settings_set_by_user_are_kept() {
  db=$(new_db) || exit 1
  bucket=$(new_bucket) || exit 1
  hooks_setup
  write_hook pre-backup
  write_hook pre-restore
  _s3_trace_start "$bucket"
  settings=(-e AWS_REQUEST_CHECKSUM_CALCULATION=when_supported -e AWS_RESPONSE_CHECKSUM_VALIDATION=when_supported
    -e HOOK_INHERIT_ENV=yes "${HOOK_MOUNTS[@]}")

  bk_backup backup "$db" "$bucket" "${settings[@]}"
  assert_rc 0 "backup with checksums when_supported"
  key=$(s3_single_key "$bucket" backup/) || exit 1
  restored="${db}_copy"
  bk_restore restore "$restored" "$bucket" "$key" -e CREATE_DATABASE=yes "${settings[@]}"
  assert_rc 0 "restore with checksums when_supported"
  assert_same_data "$db" "$restored"

  for ev in pre-backup pre-restore; do
    env_file="$CASE_DIR/hook-out/$ev.env"
    assert_eq "$(_s3_env_value "$env_file" AWS_REQUEST_CHECKSUM_CALCULATION)" when_supported "AWS_REQUEST_CHECKSUM_CALCULATION ($ev)"
    assert_eq "$(_s3_env_value "$env_file" AWS_RESPONSE_CHECKSUM_VALIDATION)" when_supported "AWS_RESPONSE_CHECKSUM_VALIDATION ($ev)"
  done

  _s3_trace_sync
  _s3_assert_cli_requests "$bucket" PUT "backup upload"
  _s3_assert_cli_requests "$bucket" GET "restore download"
  assert_eq "$(_s3_trace_cli "$bucket" PUT | awk '$5 == "-"')" "" "upload without a checksum although when_supported was set"
  assert_eq "$(_s3_trace_cli "$bucket" GET | awk '$6 != "ENABLED"')" "" "download without checksum validation although when_supported was set"
}

# ---------------------------------------------------------------------------
# Multipart upload and download.

test_s3_multipart_large_backup_round_trip() {
  db=$(new_db) || exit 1
  bucket=$(new_bucket) || exit 1
  # 16 MB of random bytes; pg_dump writes bytea as hex, which gzip only halves,
  # so the backup ends up around 20 MB: well over the AWS CLI's 8 MB threshold.
  psql_exec "$db" "CREATE TABLE public.s3_blobs (id integer PRIMARY KEY, data bytea NOT NULL);
    INSERT INTO public.s3_blobs
    SELECT i, (SELECT decode(string_agg(md5(i::text || ':' || j::text || ':' || random()::text), ''), 'hex')
               FROM generate_series(1, 65536) AS j)
    FROM generate_series(1, 16) AS i" >/dev/null || fail "could not load random data"

  bk_backup backup "$db" "$bucket"
  assert_rc 0 "backup of a large database"
  key=$(s3_single_key "$bucket" backup/) || exit 1
  read -r size etag <<EOF
$(_s3_object_stat "$bucket" "$key")
EOF
  [ "${size:-0}" -gt $((8 * 1024 * 1024)) ] || fail "backup is ${size:-?} bytes, not over the 8 MiB multipart threshold"
  # A multipart object's ETag ends in -<number of parts>.
  assert_match "$etag" '-([2-9]|[1-9][0-9]+)$' "ETag of the backup (multipart upload)"

  restored="${db}_copy"
  bk_restore restore "$restored" "$bucket" "$key" -e CREATE_DATABASE=yes
  assert_rc 0 "restore of a large backup"
  assert_same_data "$db" "$restored"
  assert_eq "$(psql_exec "$restored" "SELECT sum(length(data)) FROM public.s3_blobs")" $((16 * 1024 * 1024)) \
    "restored random data size"
  assert_eq "$(bk_tmp_leftovers)" "" "temporary files left in /tmp after restore"
}

# ---------------------------------------------------------------------------
# Keys with spaces.

test_s3_key_with_spaces_backup_restore_and_retention() {
  bucket=$(new_bucket) || exit 1
  # Starts with the case's new_db prefix, so run.sh also drops "$name copy".
  name="$(printf 't_%s' "$CASE_SLUG" | tr '-' '_') with space"
  new_db_named "$name"
  prefix="nightly backups/db 1"

  bk_backup first "$name" "$bucket" -e "S3_PREFIX=$prefix"
  assert_rc 0 "backup of '$name' under '$prefix'"
  old=$(s3_single_key "$bucket" "$prefix/") || exit 1
  assert_match "$old" "^${prefix}/${name}_${_S3_TS_RE}\.sql\.gz\$" "key with spaces"
  cutoff=$(_s3_cutoff_mark)

  restored="$name copy"
  bk_restore restore "$restored" "$bucket" "$old" -e CREATE_DATABASE=yes
  assert_rc 0 "restore from a key with spaces"
  assert_same_data "$name" "$restored"

  _s3_cutoff_wait "$cutoff"
  bk_backup second "$name" "$bucket" -e "S3_PREFIX=$prefix" -e "DELETE_OLDER_THAN=@$cutoff"
  assert_rc 0 "backup with retention under '$prefix'"
  assert_log_contains "DELETING ${old#"$prefix/"}"
  assert_s3_absent "$bucket" "$old" "old backup with spaces in its key was not deleted"
  new=$(s3_single_key "$bucket" "$prefix/") || exit 1
  assert_ne "$new" "$old" "the new backup is kept"
}
