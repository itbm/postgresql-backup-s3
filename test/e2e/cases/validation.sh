# Input validation, run.sh dispatch, blank ("") values of the documented
# variables, README.md/Dockerfile consistency and what the image contains.

# Must match the variables README.md marks as required (checked below).
_VAL_REQUIRED="S3_BUCKET POSTGRES_DATABASE POSTGRES_HOST POSTGRES_USER POSTGRES_PASSWORD"
_VAL_EVENTS="pre-backup post-backup backup-error pre-restore post-restore restore-error"
_VAL_TS='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'
_VAL_ROOT="$E2E_DIR/../.."

# ---------------------------------------------------------------------------
# Helpers.

# _val_begin - call first in tests that clone the seed (after xfail). Databases
# recorded with _val_db or _val_track are dropped when the case ends, so a full
# run does not keep growing the server's data volume. E2E_KEEP=1 keeps them.
_val_begin() {
  : >"$CASE_DIR/val-dbs"
  [ "${E2E_KEEP:-0}" = 1 ] || trap _val_end EXIT
}

_val_end() {
  # fd 3, because psql_exec (docker exec -i) would swallow the rest of stdin.
  while IFS= read -r _ve_db <&3; do
    [ -z "$_ve_db" ] || drop_db "$_ve_db" </dev/null >/dev/null 2>&1
  done 3<"$CASE_DIR/val-dbs"
}

_val_track() {
  printf '%s\n' "$@" >>"$CASE_DIR/val-dbs"
}

# _val_db [suffix] - new_db, recorded for dropping. Use as db=$(_val_db) || exit 1.
_val_db() {
  _vd_name=$(new_db "$@") || exit 1
  _val_track "$_vd_name"
  printf '%s\n' "$_vd_name"
}

_val_label() {
  printf '%s' "$1" | tr 'A-Z_' 'a-z-'
}

# _val_without <variable> <database> <bucket> - sets VAL_ARGS to bk_run options
# for a complete configuration that lacks only the given required variable.
_val_without() {
  VAL_ARGS=()
  [ "$1" = POSTGRES_DATABASE ] || VAL_ARGS+=(-e "POSTGRES_DATABASE=$2")
  [ "$1" = S3_BUCKET ] || VAL_ARGS+=(-e "S3_BUCKET=$3")
  case $1 in
    POSTGRES_DATABASE | S3_BUCKET) ;;
    *) VAL_ARGS+=(--unset "$1") ;;
  esac
}

# _val_hooks_all - a recording script and an http URL hook for every event.
# Sets VAL_HOOK_ARGS to the bk_run options that enable them.
_val_hooks_all() {
  hooks_setup
  VAL_HOOK_ARGS=(${HOOK_MOUNTS[@]+"${HOOK_MOUNTS[@]}"} -e HOOK_ALLOW_HTTP=yes)
  for _vh_event in $_VAL_EVENTS; do
    write_hook "$_vh_event"
    VAL_HOOK_ARGS+=(-e "HOOK_$(printf '%s' "$_vh_event" | tr 'a-z-' 'A-Z_')_URL=$(hook_url http ok "$_vh_event")")
  done
}

# Events of the URL hooks the receiver saw for this case, in order.
_val_url_events() {
  hook_requests | awk '{ n = split($3, p, "/"); print p[n] }' | tr '\n' ' ' | sed 's/ *$//'
}

_val_assert_no_hooks() {
  assert_eq "$(hook_events)" "" "hook scripts that ran ($1)"
  assert_eq "$(_val_url_events)" "" "URL hooks requested ($1)"
}

# _val_snapshot <database> <file> - the database's OID (changes if it is dropped
# and recreated) and a fingerprint of its contents.
_val_snapshot() {
  {
    psql_exec postgres "SELECT oid FROM pg_database WHERE datname = '$1'" &&
      db_fingerprint "$1"
  } >"$2" || fail "could not snapshot database $1"
}

_val_assert_unchanged() {
  _val_snapshot "$1" "$2.after"
  diff -u "$2" "$2.after" >"$2.diff" || {
    head -n 20 "$2.diff" >&2
    fail "${3:-database $1 changed}"
  }
}

_val_exited() {
  [ "$(docker inspect -f '{{.State.Running}}' "$BK_CTR" 2>/dev/null)" = false ]
}

# _val_wait_exit <seconds> - waits for the bk_start container to exit, then
# refreshes BK_LOG and sets BK_RC.
_val_wait_exit() {
  if ! wait_for "$1" _val_exited; then
    bk_logs
    fail "container $BK_CTR still running after $1s"
  fi
  bk_logs
  BK_RC=$(docker inspect -f '{{.State.ExitCode}}' "$BK_CTR")
}

# _val_sql <container> <port> <database> <sql> - psql against a start_postgres server.
_val_sql() {
  docker exec -i "$1" psql -X -q -p "$2" -U postgres -d "$3" -At -v ON_ERROR_STOP=1 -c "$4"
}

# _val_put_aged <bucket> <key> <when> - uploads a small object whose
# LastModified is <when> (a GNU date phrase). MinIO takes it from the
# X-Minio-Source-Mtime header its replication uses; if a MinIO release ignores
# it, the test is skipped.
_val_put_aged() {
  docker run --rm --network "$E2E_NET" --label "e2e.run=$E2E_RUN_ID" --label "e2e.case=$CASE_SLUG" \
    -e "VA_AUTH=$S3_KEY:$S3_SECRET" -e "VA_URL=http://minio:9000/$1/$2" -e "VA_WHEN=$3" \
    --entrypoint sh "$E2E_IMAGE" -c '
      set -e
      sig="--aws-sigv4 aws:amz:us-east-1:s3"
      echo "old object" >/tmp/body
      curl -fsS -o /dev/null $sig --user "$VA_AUTH" -T /tmp/body \
        -H "X-Minio-Source-Mtime: $(date -u -d "$VA_WHEN" +%Y-%m-%dT%H:%M:%SZ)" "$VA_URL"
      want=$(date -u -d "$VA_WHEN" "+%a, %d %b %Y %H:%M:%S GMT")
      got=$(curl -fsSI $sig --user "$VA_AUTH" "$VA_URL" | tr -d "\r" | sed -n "s/^[Ll]ast-[Mm]odified: //p")
      [ "$got" = "$want" ] || exit 3
    '
  case $? in
    0) ;;
    3) skip "MinIO ignored X-Minio-Source-Mtime, so objects cannot be backdated" ;;
    *) fail "could not upload s3://$1/$2" ;;
  esac
}

# _val_probe <key> - values printed as key=value by the last bk_run.
_val_probe() {
  sed -n "s/^$1=//p" "$BK_LOG"
}

# Strips blanks, one level of quotes or backticks, and treats **None** as empty.
_val_norm() {
  printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    -e "s/^'\\(.*\\)'\$/\\1/" -e 's/^"\(.*\)"$/\1/' -e 's/^`\(.*\)`$/\1/' -e 's/^\*\*None\*\*$//'
}

# NAME|default for every ENV instruction in the Dockerfile.
_val_dockerfile_env() {
  awk '$1 == "ENV" {
    line = $0
    sub(/^ENV[ \t]+/, "", line)
    if (match(line, /^[A-Za-z_][A-Za-z0-9_]*=/)) {
      name = substr(line, 1, RLENGTH - 1); value = substr(line, RLENGTH + 1)
    } else {
      name = line; sub(/[ \t].*$/, "", name)
      value = line; sub(/^[^ \t]+[ \t]*/, "", value)
    }
    print name "|" value
  }' "$_VAL_ROOT/Dockerfile"
}

# NAME|default|required for every row of README.md's "Environment variables" table.
_val_readme_env() {
  awk -F'|' '
    /^## Environment variables/ { on = 1; next }
    on && /^#/ { exit }
    on && /^\|/ {
      if (++rows <= 2) next
      for (i = 2; i <= 4; i++) gsub(/^[ \t]+|[ \t]+$/, "", $i)
      print $2 "|" $3 "|" $4
    }' "$_VAL_ROOT/README.md"
}

# ---------------------------------------------------------------------------
# Documentation and image.

test_validation_docs_env_table_matches_dockerfile() {
  _val_dockerfile_env >"$CASE_DIR/dockerfile-env"
  _val_readme_env >"$CASE_DIR/readme-env"
  [ "$(grep -c . "$CASE_DIR/dockerfile-env")" -ge 10 ] || fail "parsed too few ENV lines from the Dockerfile"
  [ "$(grep -c . "$CASE_DIR/readme-env")" -ge 10 ] || fail "parsed too few rows from README.md's table"

  cut -d'|' -f1 "$CASE_DIR/dockerfile-env" | LC_ALL=C sort >"$CASE_DIR/dockerfile-names"
  cut -d'|' -f1 "$CASE_DIR/readme-env" | LC_ALL=C sort >"$CASE_DIR/readme-names"
  assert_eq "$(uniq -d "$CASE_DIR/dockerfile-names" | tr '\n' ' ')" "" "variables set twice in the Dockerfile"
  assert_eq "$(uniq -d "$CASE_DIR/readme-names" | tr '\n' ' ')" "" "variables listed twice in README.md"
  assert_eq "$(LC_ALL=C comm -23 "$CASE_DIR/dockerfile-names" "$CASE_DIR/readme-names" | tr '\n' ' ')" "" \
    "Dockerfile ENV variables missing from README.md's table"
  assert_eq "$(LC_ALL=C comm -13 "$CASE_DIR/dockerfile-names" "$CASE_DIR/readme-names" | tr '\n' ' ')" "" \
    "README.md table rows with no ENV in the Dockerfile"

  mismatches=""
  while IFS='|' read -r name value; do
    want=$(_val_norm "$value")
    got=$(_val_norm "$(awk -F'|' -v n="$name" '$1 == n { print $2; exit }' "$CASE_DIR/readme-env")")
    [ "$got" = "$want" ] || mismatches="$mismatches $name (README.md '$got', Dockerfile '$want');"
  done <"$CASE_DIR/dockerfile-env"
  assert_eq "$mismatches" "" "README.md defaults that differ from the Dockerfile"

  required=$(awk -F'|' '$3 == "Y" { print $1 }' "$CASE_DIR/readme-env" | LC_ALL=C sort | tr '\n' ' ')
  assert_eq "$required" "$(printf '%s\n' $_VAL_REQUIRED | LC_ALL=C sort | tr '\n' ' ')" \
    "variables README.md marks as required (keep _VAL_REQUIRED in step)"
  assert_eq "$(awk -F'|' '$1 == "BACKUP_FILE" { print $3 }' "$CASE_DIR/readme-env")" "Y*" "BACKUP_FILE's required column"

  # Variables used in README.md's examples must exist.
  {
    grep -oE -- '-e [A-Z][A-Z0-9_]*=' "$_VAL_ROOT/README.md" | sed 's/^-e //; s/=$//'
    sed -n 's/^ *- name: \([A-Z][A-Z0-9_]*\) *$/\1/p' "$_VAL_ROOT/README.md"
  } | LC_ALL=C sort -u >"$CASE_DIR/example-names"
  [ -s "$CASE_DIR/example-names" ] || fail "found no variables in README.md's examples"
  assert_eq "$(LC_ALL=C comm -23 "$CASE_DIR/example-names" "$CASE_DIR/dockerfile-names" | tr '\n' ' ')" "" \
    "variables in README.md's examples that the image does not define"
}

test_validation_image_contents() {
  assert_eq "$(docker image inspect -f '{{json .Config.Cmd}}' "$E2E_IMAGE")" '["sh","run.sh"]' "image CMD"
  assert_eq "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$E2E_IMAGE")" "null" "image ENTRYPOINT"

  bk_run probe -- sh -c '
    [ -f run.sh ] && echo "cmd_dir=$(pwd)"
    for b in pg_dump psql pg_restore pg_dumpall; do echo "client=$($b --version)"; done
    for b in aws openssl pigz curl su-exec go-cron gzip gunzip; do
      command -v "$b" >/dev/null && echo "tool=$b"
    done
    date -d "30 days ago" +%s >/dev/null 2>&1 && echo "gnu_date=yes"
    echo "alpine=$(cat /etc/alpine-release)"
    echo "hook_ids=$(id -u hook) $(id -g hook) $(id -G hook)"
    echo "su_exec_uid=$(su-exec hook id -u)"
    echo "hooks_dir=$(stat -c "%U:%G %a" /hooks)"
    for f in /hooks/probe /run.sh /backup.sh /restore.sh /hooks.sh; do
      su-exec hook sh -c ": >> $f" 2>/dev/null && echo "hook_writes=$f"
    done
    echo "go_cron=$(go-cron 2>&1 | head -n 1)"
  '
  assert_rc 0 "image probe"

  assert_eq "$(_val_probe cmd_dir)" "/" "working directory holding run.sh"

  readme_pg=$(sed -n 's/.*ships the PostgreSQL \([0-9][0-9]*\) client.*/\1/p' "$_VAL_ROOT/README.md" | head -n 1)
  assert_eq "$readme_pg" 18 "PostgreSQL client major version README.md states"
  for b in pg_dump psql pg_restore pg_dumpall; do
    assert_match "$(_val_probe client | grep "^$b ")" "^$b \(PostgreSQL\) 18(\.[0-9]+)+$" "$b version"
  done
  for b in aws openssl pigz curl su-exec go-cron gzip gunzip; do
    assert_eq "$(_val_probe tool | grep -Fx -- "$b")" "$b" "$b on PATH"
  done
  assert_eq "$(_val_probe gnu_date)" yes "GNU date, which DELETE_OLDER_THAN phrases such as '30 days ago' need"
  assert_match "$(_val_probe go_cron)" "^Usage: go-cron " "go-cron runs"
  readme_alpine=$(sed -n 's/.*based on Alpine \([0-9][0-9.]*[0-9]\).*/\1/p' "$_VAL_ROOT/README.md" | head -n 1)
  [ -n "$readme_alpine" ] || fail "README.md does not say which Alpine release the image is based on"
  case "$(_val_probe alpine)" in
    "$readme_alpine" | "$readme_alpine".*) ;;
    *) fail "image is Alpine $(_val_probe alpine), README.md says $readme_alpine" ;;
  esac

  set -- $(_val_probe hook_ids)
  [ $# -ge 3 ] || fail "no hook user: '$(_val_probe hook_ids)'"
  hook_uid=$1 hook_gid=$2
  shift 2
  [ "$hook_uid" -ne 0 ] && [ "$hook_gid" -ne 0 ] || fail "hook user is uid $hook_uid gid $hook_gid"
  for g in "$@"; do
    case $g in 0 | 10) fail "hook user is in group $g (root or wheel)" ;; esac
  done
  # Also fails if the container does not start as root, as hooks need.
  assert_eq "$(_val_probe su_exec_uid)" "$hook_uid" "uid after su-exec hook"
  assert_eq "$(_val_probe hooks_dir)" "root:root 755" "owner and mode of /hooks"
  assert_eq "$(_val_probe hook_writes | tr '\n' ' ')" "" "paths the hook user can write"
}

# ---------------------------------------------------------------------------
# Required variables. Validation runs before hooks are armed, so a rejected run
# must not fire any hook, including the *-error ones (README.md, "Lifecycle hooks").

test_validation_backup_rejects_missing_required_variables() {
  _val_begin
  db=$(_val_db) || exit 1
  bucket=$(new_bucket) || exit 1
  _val_hooks_all

  for var in $_VAL_REQUIRED; do
    _val_without "$var" "$db" "$bucket"
    bk_run "no-$(_val_label "$var")" "${VAL_ARGS[@]}" "${VAL_HOOK_ARGS[@]}"
    assert_rc 1 "backup without $var"
    assert_log_contains "You need to set the $var environment variable"
    assert_log_not_contains "Creating dump of" "dump started without $var"
    assert_log_not_contains "hook for" "hook ran without $var"
  done
  _val_assert_no_hooks "after rejected backups"
  assert_s3_count "$bucket" "" 0 "objects uploaded by rejected backups"

  # Control: the same hooks fire once nothing is missing.
  bk_backup control "$db" "$bucket" "${VAL_HOOK_ARGS[@]}"
  assert_rc 0 "backup with every required variable"
  assert_eq "$(hook_events)" "pre-backup post-backup" "hook scripts of the control backup"
  assert_eq "$(_val_url_events)" "pre-backup post-backup" "URL hooks of the control backup"
  s3_single_key "$bucket" backup/ >/dev/null || exit 1
}

test_validation_restore_rejects_missing_required_variables() {
  _val_begin
  db=$(_val_db) || exit 1
  bucket=$(new_bucket) || exit 1
  bk_backup backup "$db" "$bucket"
  assert_rc 0 "backup to restore from"
  key=$(s3_single_key "$bucket" backup/) || exit 1
  _val_snapshot "$db" "$CASE_DIR/before"
  _val_hooks_all

  # DROP and CREATE would replace the database if a rejected restore went ahead.
  for var in $_VAL_REQUIRED; do
    _val_without "$var" "$db" "$bucket"
    bk_run "no-$(_val_label "$var")" "${VAL_ARGS[@]}" -e "BACKUP_FILE=$key" \
      -e DROP_DATABASE=yes -e CREATE_DATABASE=yes "${VAL_HOOK_ARGS[@]}"
    assert_rc 1 "restore without $var"
    assert_log_contains "You need to set the $var environment variable"
    assert_log_not_contains "Downloading backup file" "download started without $var"
    assert_log_not_contains "Creating dump of" "a restore without $var ran a backup"
    assert_log_not_contains "hook for" "hook ran without $var"
  done
  _val_assert_no_hooks "after rejected restores"
  _val_assert_unchanged "$db" "$CASE_DIR/before" "a rejected restore changed $db"
  assert_s3_count "$bucket" "" 1 "objects after rejected restores"

  restored="${db}_copy"
  _val_track "$restored"
  bk_restore control "$restored" "$bucket" "$key" -e CREATE_DATABASE=yes "${VAL_HOOK_ARGS[@]}"
  assert_rc 0 "restore with every required variable"
  assert_eq "$(hook_events)" "pre-restore post-restore" "hook scripts of the control restore"
  assert_eq "$(_val_url_events)" "pre-restore post-restore" "URL hooks of the control restore"
  assert_same_data "$db" "$restored"
}

test_validation_restore_script_requires_backup_file() {
  _val_begin
  db=$(_val_db) || exit 1
  bucket=$(new_bucket) || exit 1
  _val_hooks_all

  bk_run direct -e "POSTGRES_DATABASE=$db" -e "S3_BUCKET=$bucket" -e DROP_DATABASE=yes \
    "${VAL_HOOK_ARGS[@]}" -- sh restore.sh
  assert_rc 1 "restore.sh without BACKUP_FILE"
  assert_log_contains "You need to set the BACKUP_FILE environment variable with the backup filename to restore."
  assert_log_contains "Use S3_PREFIX/filename format. Example: backup/database_0000-00-00T00:00:00Z.sql.gz"
  assert_log_not_contains "Downloading backup file"
  assert_log_not_contains "Dropping database"
  _val_assert_no_hooks "restore.sh without BACKUP_FILE"
  db_exists "$db" || fail "restore.sh without BACKUP_FILE dropped $db"
}

# run.sh treats an empty BACKUP_FILE as unset; restore.sh should too.
test_validation_restore_script_rejects_empty_backup_file() {
  xfail "restore.sh only rejects BACKUP_FILE=**None**: an empty value downloads s3://<bucket>/, drops the database when DROP_DATABASE=yes, then fails with 'Unsupported backup format'"
  _val_begin
  db=$(_val_db) || exit 1
  bucket=$(new_bucket) || exit 1
  _val_hooks_all

  bk_run direct -e "POSTGRES_DATABASE=$db" -e "S3_BUCKET=$bucket" -e BACKUP_FILE= -e DROP_DATABASE=yes \
    "${VAL_HOOK_ARGS[@]}" -- sh restore.sh
  db_exists "$db" || fail "restore.sh with an empty BACKUP_FILE dropped $db"
  assert_rc 1 "restore.sh with an empty BACKUP_FILE"
  assert_log_contains "You need to set the BACKUP_FILE environment variable with the backup filename to restore."
  assert_log_not_contains "Downloading backup file"
  _val_assert_no_hooks "restore.sh with an empty BACKUP_FILE"
}

test_validation_s3_key_pair_must_be_complete() {
  _val_begin
  db=$(_val_db) || exit 1
  bucket=$(new_bucket) || exit 1
  _val_hooks_all

  bk_backup key-only "$db" "$bucket" --unset S3_SECRET_ACCESS_KEY "${VAL_HOOK_ARGS[@]}"
  assert_rc 1 "backup with S3_ACCESS_KEY_ID only"
  assert_log_contains "You need to set the S3_SECRET_ACCESS_KEY environment variable."
  bk_backup key-blank-secret "$db" "$bucket" --unset S3_SECRET_ACCESS_KEY -e S3_SECRET_ACCESS_KEY= \
    "${VAL_HOOK_ARGS[@]}"
  assert_rc 1 "backup with S3_ACCESS_KEY_ID and an empty S3_SECRET_ACCESS_KEY"
  assert_log_contains "You need to set the S3_SECRET_ACCESS_KEY environment variable."
  bk_backup secret-only "$db" "$bucket" --unset S3_ACCESS_KEY_ID "${VAL_HOOK_ARGS[@]}"
  assert_rc 1 "backup with S3_SECRET_ACCESS_KEY only"
  assert_log_contains "You need to set the S3_ACCESS_KEY_ID environment variable."
  bk_backup blank-key-secret "$db" "$bucket" --unset S3_ACCESS_KEY_ID -e S3_ACCESS_KEY_ID= \
    "${VAL_HOOK_ARGS[@]}"
  assert_rc 1 "backup with an empty S3_ACCESS_KEY_ID and S3_SECRET_ACCESS_KEY"
  assert_log_contains "You need to set the S3_ACCESS_KEY_ID environment variable."

  bk_restore restore-key-only "$db" "$bucket" backup/any.sql.gz --unset S3_SECRET_ACCESS_KEY \
    -e DROP_DATABASE=yes "${VAL_HOOK_ARGS[@]}"
  assert_rc 1 "restore with S3_ACCESS_KEY_ID only"
  assert_log_contains "You need to set the S3_SECRET_ACCESS_KEY environment variable."
  assert_log_not_contains "Downloading backup file"
  bk_restore restore-secret-only "$db" "$bucket" backup/any.sql.gz --unset S3_ACCESS_KEY_ID \
    -e DROP_DATABASE=yes "${VAL_HOOK_ARGS[@]}"
  assert_rc 1 "restore with S3_SECRET_ACCESS_KEY only"
  assert_log_contains "You need to set the S3_ACCESS_KEY_ID environment variable."
  assert_log_not_contains "Downloading backup file"

  _val_assert_no_hooks "after half key pairs"
  assert_s3_count "$bucket" "" 0 "objects uploaded with half a key pair"
  db_exists "$db" || fail "a rejected restore dropped $db"

  bk_backup control "$db" "$bucket" "${VAL_HOOK_ARGS[@]}"
  assert_rc 0 "backup with both keys"
  assert_eq "$(hook_events)" "pre-backup post-backup" "hook scripts of the control backup"
  assert_eq "$(_val_url_events)" "pre-backup post-backup" "URL hooks of the control backup"
}

# Legacy Docker links: without POSTGRES_HOST, backup.sh and restore.sh take the
# host and port from POSTGRES_PORT_5432_TCP_ADDR and POSTGRES_PORT_5432_TCP_PORT.
test_validation_docker_link_variables_supply_host_and_port() {
  ctr=$(start_postgres vallink 5433) || exit 1
  _val_sql "$ctr" 5433 postgres "CREATE DATABASE link_db" >/dev/null || fail "could not create link_db"
  _val_sql "$ctr" 5433 link_db "CREATE TABLE link_marker (v text); INSERT INTO link_marker VALUES ('reached-through-link')" \
    >/dev/null || fail "could not fill link_db"
  bucket=$(new_bucket) || exit 1
  # A link aliased "postgres" also sets POSTGRES_PORT to a URL, which must not be used as the port.
  link=(--unset POSTGRES_HOST -e POSTGRES_PORT=tcp://vallink:5433 -e POSTGRES_PORT_5432_TCP=tcp://vallink:5433
    -e POSTGRES_PORT_5432_TCP_ADDR=vallink -e POSTGRES_PORT_5432_TCP_PORT=5433 -e POSTGRES_PORT_5432_TCP_PROTO=tcp)

  bk_backup backup link_db "$bucket" "${link[@]}"
  assert_rc 0 "backup through link variables"
  assert_log_contains "Creating dump of link_db database from vallink..."
  key=$(s3_single_key "$bucket" backup/) || exit 1
  assert_match "$key" "^backup/link_db_${_VAL_TS}\.sql\.gz$" "backup key"

  bk_restore restore link_copy "$bucket" "$key" "${link[@]}" -e CREATE_DATABASE=yes
  assert_rc 0 "restore through link variables"
  assert_log_contains "Restoring database link_copy on vallink"
  assert_eq "$(_val_sql "$ctr" 5433 link_copy "SELECT v FROM link_marker")" "reached-through-link" \
    "restored marker on the linked server"
}

# ---------------------------------------------------------------------------
# run.sh dispatch.

test_validation_dispatch_backs_up_once_without_backup_file() {
  _val_begin
  db=$(_val_db) || exit 1

  for variant in unset blank; do
    bucket=$(new_bucket "$variant") || exit 1
    if [ "$variant" = unset ]; then
      bk_backup "$variant" "$db" "$bucket"
    else
      bk_backup "$variant" "$db" "$bucket" -e BACKUP_FILE=
    fi
    assert_rc 0 "run with BACKUP_FILE $variant and no SCHEDULE"
    assert_log_contains "SQL backup finished"
    assert_log_not_contains "Downloading backup file"
    assert_log_not_contains "Cron job scheduled"
    key=$(s3_single_key "$bucket" "") || exit 1
    assert_match "$key" "^backup/${db}_${_VAL_TS}\.sql\.gz$" "backup key with BACKUP_FILE $variant"
  done
}

test_validation_dispatch_backup_file_wins_over_schedule() {
  _val_begin
  db=$(_val_db) || exit 1
  bucket=$(new_bucket) || exit 1
  bk_backup backup "$db" "$bucket"
  assert_rc 0 "backup to restore from"
  key=$(s3_single_key "$bucket" backup/) || exit 1

  restored="${db}_copy"
  _val_track "$restored"
  bk_start restore -e "POSTGRES_DATABASE=$restored" -e "S3_BUCKET=$bucket" -e "BACKUP_FILE=$key" \
    -e CREATE_DATABASE=yes -e "SCHEDULE=@every 1s"
  _val_wait_exit 120
  assert_rc 0 "restore with SCHEDULE also set"
  assert_log_contains "Database restore completed successfully"
  assert_log_not_contains "Cron job scheduled"
  assert_log_not_contains "Creating dump of"
  assert_s3_count "$bucket" "" 1 "objects after a restore with SCHEDULE set"
  assert_same_data "$db" "$restored"
}

# ---------------------------------------------------------------------------
# Blank values. Kubernetes manifests often set value: "" (README.md's example
# does so for several optional variables); a blank optional variable should
# behave as if it were unset.

test_validation_empty_optional_values_behave_like_defaults() {
  _val_begin
  db=$(_val_db) || exit 1
  bucket=$(new_bucket) || exit 1
  hooks_setup
  for event in pre-backup post-backup pre-restore post-restore; do
    write_hook "$event"
  done
  blanks=(-e POSTGRES_EXTRA_OPTS= -e S3_CA_BUNDLE= -e S3_S3V4= -e COMMAND_TIMEOUT= -e HOOKS_DIR=
    -e HOOK_ALLOW_HTTP= -e HOOK_INHERIT_ENV= -e USE_CUSTOM_FORMAT= -e CREATE_DATABASE= -e DROP_DATABASE=
    -e PARALLEL_JOBS=)
  for event in $_VAL_EVENTS; do
    blanks+=(-e "HOOK_$(printf '%s' "$event" | tr 'a-z-' 'A-Z_')_URL=")
  done

  bk_backup backup "$db" "$bucket" "${HOOK_MOUNTS[@]}" "${blanks[@]}" -e POSTGRES_EXTRA_DUMP_OPTS= -e BACKUP_FILE=
  assert_rc 0 "backup with blank optional variables"
  assert_log_not_contains "URL hook"
  assert_log_not_contains "ERROR"
  key=$(s3_single_key "$bucket" "") || exit 1
  assert_match "$key" "^backup/${db}_${_VAL_TS}\.sql\.gz$" "backup key (plain format, default prefix)"
  if docker cp "$BK_CTR:/root/.aws/config" "$CASE_DIR/aws-config" >/dev/null 2>&1; then
    fail "an empty S3_S3V4 wrote /root/.aws/config: $(cat "$CASE_DIR/aws-config")"
  fi
  # HOOKS_DIR="" still finds /hooks; HOOK_INHERIT_ENV="" keeps the scrubbed environment.
  assert_eq "$(hook_events)" "pre-backup post-backup" "hook scripts with an empty HOOKS_DIR"
  assert_file_contains "$CASE_DIR/hook-out/pre-backup.env" "HOOK_EVENT=pre-backup"
  assert_file_not_contains "$CASE_DIR/hook-out/pre-backup.env" "POSTGRES_PASSWORD=" "password passed to a hook"
  assert_file_not_contains "$CASE_DIR/hook-out/pre-backup.env" "S3_SECRET_ACCESS_KEY=" "S3 secret passed to a hook"

  restored="${db}_copy"
  _val_track "$restored"
  psql_exec postgres "CREATE DATABASE $(sql_ident "$restored")" >/dev/null || fail "could not create $restored"
  bk_restore restore "$restored" "$bucket" "$key" "${HOOK_MOUNTS[@]}" "${blanks[@]}"
  assert_rc 0 "restore with blank optional variables"
  assert_log_not_contains "Dropping database"
  assert_log_not_contains "Creating database"
  assert_eq "$(hook_events)" "pre-backup post-backup pre-restore post-restore" "hook scripts after the restore"
  assert_same_data "$db" "$restored"

  # CREATE_DATABASE="" means no: a missing database is not created.
  missing="${db}_missing"
  _val_track "$missing"
  bk_restore missing "$missing" "$bucket" "$key" -e CREATE_DATABASE=
  assert_rc_nonzero "restore into a missing database with an empty CREATE_DATABASE"
  assert_log_not_contains "Creating database"
  if db_exists "$missing"; then
    fail "an empty CREATE_DATABASE created $missing"
  fi
}

test_validation_empty_parallel_jobs_restores_without_jobs() {
  _val_begin
  db=$(_val_db) || exit 1
  bucket=$(new_bucket) || exit 1
  bk_backup backup "$db" "$bucket" -e USE_CUSTOM_FORMAT=yes
  assert_rc 0 "custom format backup"
  key=$(s3_single_key "$bucket" backup/) || exit 1

  restored="${db}_copy"
  _val_track "$restored"
  bk_restore restore "$restored" "$bucket" "$key" -e CREATE_DATABASE=yes -e PARALLEL_JOBS=
  assert_rc 0 "custom format restore with an empty PARALLEL_JOBS"
  assert_log_contains "Restoring database $restored from custom format"
  assert_log_not_contains "Using parallel restore"
  assert_same_data "$db" "$restored"
}

test_validation_empty_hook_allow_http_keeps_http_blocked() {
  _val_begin
  db=$(_val_db) || exit 1
  bucket=$(new_bucket) || exit 1

  bk_backup backup "$db" "$bucket" -e HOOK_ALLOW_HTTP= -e "HOOK_PRE_BACKUP_URL=$(hook_url http ok pre-backup)"
  assert_rc_nonzero "backup with an http hook URL and an empty HOOK_ALLOW_HTTP"
  assert_log_contains "ERROR: hook URL for pre-backup is not allowed (http-not-allowed)"
  assert_eq "$(_val_url_events)" "" "URL hooks requested"
  assert_s3_count "$bucket" "" 0 "objects uploaded"
}

# Nothing in these runs trusts the e2e CA, so every upload must be refused.
test_validation_empty_tls_options_keep_certificate_checks() {
  _val_begin
  db=$(_val_db) || exit 1
  bucket=$(S3_ALIAS=tls new_bucket) || exit 1

  for var in S3_SSL_VERIFY S3_CA_BUNDLE; do
    bk_backup "$(_val_label "$var")" "$db" "$bucket" --unset S3_ENDPOINT \
      -e S3_ENDPOINT=https://minio-tls:9000 -e "$var="
    assert_rc 2 "backup to an untrusted TLS endpoint with an empty $var"
    assert_log_contains "CERTIFICATE_VERIFY_FAILED"
  done
  assert_eq "$(S3_ALIAS=tls s3_count "$bucket" "")" 0 "objects uploaded without a trusted certificate"
}

# README.md offers AWS_CA_BUNDLE as an alternative to S3_CA_BUNDLE. Set but
# empty, the AWS CLI stops verifying certificates altogether.
test_validation_empty_aws_ca_bundle_keeps_certificate_checks() {
  xfail "an empty AWS_CA_BUNDLE is passed to the AWS CLI, which then skips certificate verification (InsecureRequestWarning) although S3_SSL_VERIFY is yes, so the backup goes to an untrusted endpoint"
  _val_begin
  db=$(_val_db) || exit 1
  bucket=$(S3_ALIAS=tls new_bucket) || exit 1

  bk_backup backup "$db" "$bucket" --unset S3_ENDPOINT -e S3_ENDPOINT=https://minio-tls:9000 -e AWS_CA_BUNDLE=
  assert_eq "$(S3_ALIAS=tls s3_count "$bucket" "")" 0 "objects uploaded without a trusted certificate"
  assert_rc 2 "backup to an untrusted TLS endpoint with an empty AWS_CA_BUNDLE"
  assert_log_contains "CERTIFICATE_VERIFY_FAILED"
}

test_validation_empty_schedule_runs_one_backup() {
  xfail "an empty SCHEDULE (as in README.md's Kubernetes example) is passed to go-cron, which exits 1 with 'Invalid schedule format: empty spec string' and no backup"
  _val_begin
  db=$(_val_db) || exit 1
  bucket=$(new_bucket) || exit 1

  bk_start run -e "POSTGRES_DATABASE=$db" -e "S3_BUCKET=$bucket" -e SCHEDULE=
  _val_wait_exit 120
  assert_rc 0 "run with an empty SCHEDULE"
  assert_log_contains "SQL backup finished"
  key=$(s3_single_key "$bucket" "") || exit 1
  assert_match "$key" "^backup/${db}_${_VAL_TS}\.sql\.gz$" "backup key"
}

test_validation_empty_postgres_port_uses_default() {
  xfail "an empty POSTGRES_PORT (as in README.md's Kubernetes example) leaves a bare '-p' that takes '-U' as the port, so pg_dump fails with 'too many command-line arguments'"
  _val_begin
  db=$(_val_db) || exit 1
  bucket=$(new_bucket) || exit 1

  bk_backup backup "$db" "$bucket" -e POSTGRES_PORT=
  assert_rc 0 "backup with an empty POSTGRES_PORT"
  key=$(s3_single_key "$bucket" backup/) || exit 1
  restored="${db}_copy"
  _val_track "$restored"
  bk_restore restore "$restored" "$bucket" "$key" -e CREATE_DATABASE=yes -e POSTGRES_PORT=
  assert_rc 0 "restore with an empty POSTGRES_PORT"
  assert_same_data "$db" "$restored"
}

test_validation_empty_s3_endpoint_same_as_unset() {
  xfail "an empty S3_ENDPOINT (as in README.md's Kubernetes example) becomes a bare '--endpoint-url' that takes 's3' as the URL, so every aws call fails with \"Found invalid choice 'cp'\" and the backup exits 2"
  _val_begin
  db=$(_val_db) || exit 1
  bucket=$(new_bucket) || exit 1

  # AWS_ENDPOINT_URL stands in for AWS's own endpoint, which the suite cannot reach.
  bk_backup backup "$db" "$bucket" --unset S3_ENDPOINT -e S3_ENDPOINT= -e AWS_ENDPOINT_URL=http://minio:9000
  assert_rc 0 "backup with an empty S3_ENDPOINT"
  s3_single_key "$bucket" backup/ >/dev/null || exit 1
}

# Disabling retention or rejecting the value are both fine; deleting is not.
test_validation_empty_delete_older_than_deletes_nothing() {
  xfail "an empty DELETE_OLDER_THAN reaches 'date -d \"\"', which is midnight today, so every object in the prefix older than that is deleted"
  _val_begin
  db=$(_val_db) || exit 1
  bucket=$(new_bucket) || exit 1
  _val_put_aged "$bucket" backup/older.sql.gz "3 days ago"

  bk_backup backup "$db" "$bucket" -e DELETE_OLDER_THAN=
  assert_s3_exists "$bucket" backup/older.sql.gz "an empty DELETE_OLDER_THAN deleted an older object"
  assert_log_not_contains "DELETING"
}

# Treating the blank like unset (a plain backup) or rejecting it are both fine.
# An object that looks encrypted but needs no password to open is not.
test_validation_empty_encryption_password_never_used_as_key() {
  xfail "an empty ENCRYPTION_PASSWORD is used as the key: the backup is uploaded as .sql.gz.enc, encrypted with an empty password that anyone can supply"
  _val_begin
  db=$(_val_db) || exit 1
  bucket=$(new_bucket) || exit 1

  bk_backup backup "$db" "$bucket" -e ENCRYPTION_PASSWORD=
  assert_eq "$(s3_keys "$bucket" | grep '\.enc$')" "" "objects encrypted with an empty password"
  assert_log_not_contains "Encrypting "
  if [ "$BK_RC" = 0 ]; then
    key=$(s3_single_key "$bucket" backup/) || exit 1
    restored="${db}_copy"
    _val_track "$restored"
    bk_restore restore "$restored" "$bucket" "$key" -e CREATE_DATABASE=yes -e ENCRYPTION_PASSWORD=
    assert_rc 0 "restore with an empty ENCRYPTION_PASSWORD"
    assert_same_data "$db" "$restored"
  else
    assert_s3_count "$bucket" "" 0 "objects uploaded by a rejected backup"
  fi
}

test_validation_empty_compression_cmd_uses_gzip() {
  xfail "an empty COMPRESSION_CMD leaves 'pg_dump ... | > file', so pg_dump is killed by SIGPIPE and every plain backup exits 141"
  _val_begin
  db=$(_val_db) || exit 1
  bucket=$(new_bucket) || exit 1

  bk_backup backup "$db" "$bucket" -e COMPRESSION_CMD=
  assert_rc 0 "backup with an empty COMPRESSION_CMD"
  key=$(s3_single_key "$bucket" backup/) || exit 1
  restored="${db}_copy"
  _val_track "$restored"
  bk_restore restore "$restored" "$bucket" "$key" -e CREATE_DATABASE=yes
  assert_rc 0 "default restore of that backup"
  assert_same_data "$db" "$restored"
}

test_validation_empty_decompression_cmd_uses_gunzip() {
  xfail "an empty DECOMPRESSION_CMD makes restore.sh execute the downloaded file itself ('Permission denied', exit 126), so every plain restore fails"
  _val_begin
  db=$(_val_db) || exit 1
  bucket=$(new_bucket) || exit 1
  bk_backup backup "$db" "$bucket"
  assert_rc 0 "backup to restore from"
  key=$(s3_single_key "$bucket" backup/) || exit 1

  restored="${db}_copy"
  _val_track "$restored"
  bk_restore restore "$restored" "$bucket" "$key" -e CREATE_DATABASE=yes -e DECOMPRESSION_CMD=
  assert_rc 0 "restore with an empty DECOMPRESSION_CMD"
  assert_same_data "$db" "$restored"
}

# A blank required variable should be rejected like a missing one.
test_validation_empty_postgres_database_rejected_on_backup() {
  xfail "an empty POSTGRES_DATABASE passes validation (only **None** is checked), so pg_dump falls back to the database named after the user, uploads it as backup/_<timestamp>.sql.gz and exits 0"
  bucket=$(new_bucket) || exit 1

  bk_run backup -e "S3_BUCKET=$bucket" -e POSTGRES_DATABASE=
  assert_s3_count "$bucket" "" 0 "objects uploaded with an empty POSTGRES_DATABASE"
  assert_rc 1 "backup with an empty POSTGRES_DATABASE"
  assert_log_contains "You need to set the POSTGRES_DATABASE environment variable."
}

test_validation_empty_postgres_database_rejected_on_restore() {
  xfail "an empty POSTGRES_DATABASE passes restore validation and 'psql -d \"\"' connects to the database named after the user, so the backup is loaded into the postgres maintenance database and the run reports success"
  _val_begin
  # A server of its own, because the current behaviour writes into its postgres database.
  ctr=$(start_postgres valblank) || exit 1
  db=$(_val_db) || exit 1
  bucket=$(new_bucket) || exit 1
  bk_backup backup "$db" "$bucket"
  assert_rc 0 "backup to restore from"
  key=$(s3_single_key "$bucket" backup/) || exit 1

  bk_restore restore "" "$bucket" "$key" --unset POSTGRES_HOST -e POSTGRES_HOST=valblank -e CREATE_DATABASE=yes
  assert_eq "$(_val_sql "$ctr" 5432 postgres "SELECT count(*) FROM pg_namespace WHERE nspname = 'app'")" 0 \
    "backup restored into the postgres database"
  assert_rc 1 "restore with an empty POSTGRES_DATABASE"
  assert_log_contains "You need to set the POSTGRES_DATABASE environment variable."
  assert_log_not_contains "Downloading backup file"
}
