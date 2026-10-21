# Helpers for the end-to-end suite. Sourced by run.sh; never run directly.
#
# Each test_* function runs in its own subshell with these set:
#   CASE_NAME  test function name
#   CASE_SLUG  short lowercase id, safe for bucket and container names
#   CASE_DIR   scratch directory for this case (logs, hook scripts, downloads)
#
# Infrastructure (started by run.sh) is reachable from the image under test as:
#   pg:5432          PostgreSQL, user postgres / $PG_PASSWORD, template db e2e_seed
#   minio:9000       MinIO over HTTP
#   minio-tls:9000   MinIO over HTTPS, certificate signed by $E2E_CERTS/ca.crt
#   hooks:8080/8443  URL hook receiver (HTTP / HTTPS, same CA)

PG_PASSWORD=e2e-pg-password
S3_KEY=e2eaccesskey
S3_SECRET=e2esecretkey123

# Environment every bk_run starts from. Drop entries per call with --unset NAME.
E2E_BASE_ENV=(
  "POSTGRES_HOST=pg"
  "POSTGRES_USER=postgres"
  "POSTGRES_PASSWORD=$PG_PASSWORD"
  "S3_ENDPOINT=http://minio:9000"
  "S3_ACCESS_KEY_ID=$S3_KEY"
  "S3_SECRET_ACCESS_KEY=$S3_SECRET"
)

# ---------------------------------------------------------------------------
# Outcome markers and assertions. An assertion failure ends the case.

# Marks the case as expected to fail (a known bug). If it passes, the run fails
# with XPASS so the marker gets removed once the bug is fixed. Call it just
# before the step that exposes the bug, after the setup: a failure before the
# call is then reported as FAIL rather than hidden as an expected failure.
xfail() {
  printf '%s\n' "$*" > "$CASE_DIR/.xfail"
}

skip() {
  printf '%s\n' "$*" > "$CASE_DIR/.skip"
  exit 0
}

show_last_log() {
  if [ -n "${BK_LOG:-}" ] && [ -f "$BK_LOG" ]; then
    echo "--- last 60 lines of $(basename "$BK_LOG") (exit ${BK_RC:-?}) ---" >&2
    tail -n 60 "$BK_LOG" >&2
    echo "---" >&2
  fi
}

fail() {
  printf 'ASSERTION FAILED: %s\n' "$*" >&2
  # Inside $(...) the exit only ends that subshell, so also record the
  # failure for run.sh. One recorded before xfail is called is a setup
  # failure and is reported as FAIL even if the case later calls xfail.
  if [ -n "${CASE_DIR:-}" ]; then
    printf '%s\n' "$*" >>"$CASE_DIR/.failed"
    [ -f "$CASE_DIR/.xfail" ] || printf '%s\n' "$*" >>"$CASE_DIR/.failed_before_xfail"
  fi
  show_last_log
  exit 1
}

note() {
  printf '# %s\n' "$*" >&2
}

assert_eq() {
  [ "$1" = "$2" ] || fail "${3:-values differ}: expected '$2', got '$1'"
}

assert_ne() {
  [ "$1" != "$2" ] || fail "${3:-values should differ}: both are '$1'"
}

assert_match() {
  printf '%s' "$1" | grep -Eq -- "$2" || fail "${3:-no match}: '$1' does not match /$2/"
}

# assert_rc <expected> [message] - checks the exit code of the last bk_run.
assert_rc() {
  [ "${BK_RC:-}" = "$1" ] || fail "${2:-unexpected exit code}: expected $1, got ${BK_RC:-unset}"
}

assert_rc_nonzero() {
  [ -n "${BK_RC:-}" ] && [ "$BK_RC" -ne 0 ] || fail "${1:-expected a non-zero exit code}: got ${BK_RC:-unset}"
}

# Fixed-string checks against the combined output of the last bk_run.
assert_log_contains() {
  grep -Fq -- "$1" "$BK_LOG" || fail "${2:-log is missing expected text}: '$1'"
}

assert_log_not_contains() {
  if grep -Fq -- "$1" "$BK_LOG"; then
    fail "${2:-log contains unexpected text}: '$1'"
  fi
}

assert_file_contains() {
  [ -f "$1" ] || fail "file not found: $1"
  grep -Fq -- "$2" "$1" || fail "${3:-file is missing expected text}: '$2' not in $1"
}

assert_file_not_contains() {
  if [ -f "$1" ] && grep -Fq -- "$2" "$1"; then
    fail "${3:-file contains unexpected text}: '$2' in $1"
  fi
}

assert_file_exists() {
  [ -e "$1" ] || fail "${2:-expected file to exist}: $1"
}

assert_file_absent() {
  [ ! -e "$1" ] || fail "${2:-expected file to be absent}: $1"
}

# ---------------------------------------------------------------------------
# Running the image under test.

# bk_run <label> [--unset NAME]... [docker run options...] [-- command args...]
#
# Runs the image once on the test network with E2E_BASE_ENV plus the given
# options, and waits for it to exit. Sets:
#   BK_RC   exit code
#   BK_LOG  file with combined stdout and stderr
#   BK_CTR  container name; the container is kept until the case ends so
#           tests can inspect it (for example with `docker diff`)
bk_run() {
  _bk_prepare "$@"
  # shellcheck disable=SC2086
  $E2E_TIMEOUT docker run --name "$BK_CTR" "${_bk_args[@]}" >"$BK_LOG" 2>&1
  BK_RC=$?
}

# bk_start <label> [same options as bk_run] - starts the image detached (for
# SCHEDULE tests). Use bk_logs to refresh BK_LOG and bk_stop to stop it.
bk_start() {
  _bk_prepare "$@"
  BK_RC=
  docker run -d --name "$BK_CTR" "${_bk_args[@]}" >/dev/null 2>"$BK_LOG" \
    || fail "could not start container $BK_CTR"
}

bk_logs() {
  docker logs "$BK_CTR" >"$BK_LOG" 2>&1
}

# bk_stop [timeout-seconds] - stops the detached container, refreshes BK_LOG
# and sets BK_RC to its exit code.
bk_stop() {
  docker stop -t "${1:-10}" "$BK_CTR" >/dev/null 2>&1
  bk_logs
  BK_RC=$(docker inspect -f '{{.State.ExitCode}}' "$BK_CTR")
}

# bk_backup <label> <database> <bucket> [bk_run options...]
bk_backup() {
  _bk_label=$1 _bk_db=$2 _bk_bucket=$3
  shift 3
  bk_run "$_bk_label" -e "POSTGRES_DATABASE=$_bk_db" -e "S3_BUCKET=$_bk_bucket" "$@"
}

# bk_restore <label> <database> <bucket> <backup-key> [bk_run options...]
bk_restore() {
  _bk_label=$1 _bk_db=$2 _bk_bucket=$3 _bk_key=$4
  shift 4
  bk_run "$_bk_label" -e "POSTGRES_DATABASE=$_bk_db" -e "S3_BUCKET=$_bk_bucket" \
    -e "BACKUP_FILE=$_bk_key" "$@"
}

_bk_prepare() {
  _bk_label=$1
  shift
  BK_CTR="${E2E_RUN_ID}-${CASE_SLUG}-${_bk_label}"
  BK_LOG="$CASE_DIR/${_bk_label}.log"
  docker rm -f "$BK_CTR" >/dev/null 2>&1

  _bk_unset=" "
  _bk_opts=()
  _bk_cmd=()
  _bk_in_cmd=0
  while [ $# -gt 0 ]; do
    if [ "$_bk_in_cmd" = 1 ]; then
      _bk_cmd+=("$1")
      shift
      continue
    fi
    case $1 in
      --unset)
        _bk_unset="$_bk_unset$2 "
        shift 2
        ;;
      --)
        _bk_in_cmd=1
        shift
        ;;
      *)
        _bk_opts+=("$1")
        shift
        ;;
    esac
  done

  _bk_args=(--label "e2e.run=$E2E_RUN_ID" --label "e2e.case=$CASE_SLUG" --network "$E2E_NET")
  for _bk_kv in "${E2E_BASE_ENV[@]}"; do
    case "$_bk_unset" in
      *" ${_bk_kv%%=*} "*) continue ;;
    esac
    _bk_args+=(-e "$_bk_kv")
  done
  _bk_args+=(${_bk_opts[@]+"${_bk_opts[@]}"} "$E2E_IMAGE" ${_bk_cmd[@]+"${_bk_cmd[@]}"})
}

# Lists files the last container added or changed under /tmp (temp-file leaks).
bk_tmp_leftovers() {
  docker diff "$BK_CTR" 2>/dev/null | awk '$1 != "D" && $2 ~ "^/tmp/." { print $2 }'
}

# wait_for <seconds> <command...> - polls once a second until the command succeeds.
wait_for() {
  _wf_end=$((SECONDS + $1))
  shift
  until "$@"; do
    [ "$SECONDS" -lt "$_wf_end" ] || return 1
    sleep 1
  done
}

# ---------------------------------------------------------------------------
# S3 (MinIO) helpers, via the MinIO client. Aliases: e2e (HTTP), tls (HTTPS).

mc_cli() {
  docker run --rm -i --network "$E2E_NET" --label "e2e.run=$E2E_RUN_ID" \
    -e "MC_HOST_e2e=http://${S3_KEY}:${S3_SECRET}@minio:9000" \
    -e "MC_HOST_tls=https://${S3_KEY}:${S3_SECRET}@minio-tls:9000" \
    -e "SSL_CERT_FILE=/e2e-ca.crt" -v "$E2E_CERTS/ca.crt:/e2e-ca.crt:ro" \
    "$E2E_MC_IMAGE" --quiet --no-color "$@"
}

# Bucket named after the case (pass a suffix for extra buckets). Prints the name.
new_bucket() {
  _nb_name=$CASE_SLUG${1:+-$1}
  mc_cli mb --ignore-existing "${S3_ALIAS:-e2e}/$_nb_name" >/dev/null || fail "could not create bucket $_nb_name"
  printf '%s\n' "$_nb_name"
}

# s3_keys <bucket> [prefix] - object keys in the bucket that start with prefix.
s3_keys() {
  mc_cli find "${S3_ALIAS:-e2e}/$1" 2>/dev/null \
    | sed "s#^${S3_ALIAS:-e2e}/$1/##" \
    | awk -v p="${2:-}" 'index($0, p) == 1' \
    | LC_ALL=C sort
}

s3_count() {
  s3_keys "$@" | grep -c . || true
}

# s3_has_at_least <bucket> <prefix> <n> - for use with wait_for.
s3_has_at_least() {
  [ "$(s3_count "$1" "$2")" -ge "$3" ]
}

s3_get() {
  mc_cli cat "${S3_ALIAS:-e2e}/$1/$2" >"$3" || fail "could not download s3://$1/$2"
}

s3_put() {
  mc_cli pipe "${S3_ALIAS:-e2e}/$1/$2" <"$3" >/dev/null || fail "could not upload s3://$1/$2"
}

s3_put_string() {
  printf '%s' "$3" | mc_cli pipe "${S3_ALIAS:-e2e}/$1/$2" >/dev/null || fail "could not upload s3://$1/$2"
}

assert_s3_exists() {
  s3_keys "$1" | grep -Fxq -- "$2" || fail "${3:-object missing}: s3://$1/$2 (have: $(s3_keys "$1" | tr '\n' ' '))"
}

assert_s3_absent() {
  if s3_keys "$1" | grep -Fxq -- "$2"; then
    fail "${3:-object should not exist}: s3://$1/$2"
  fi
}

# assert_s3_count <bucket> <prefix> <n>
assert_s3_count() {
  _ac_n=$(s3_count "$1" "$2")
  [ "$_ac_n" = "$3" ] || fail "${4:-object count}: expected $3 under s3://$1/$2, got $_ac_n ($(s3_keys "$1" "$2" | tr '\n' ' '))"
}

# s3_single_key <bucket> <prefix> - prints the only key under prefix, or fails.
s3_single_key() {
  _sk_keys=$(s3_keys "$1" "$2")
  _sk_n=$(printf '%s' "$_sk_keys" | grep -c . || true)
  [ "$_sk_n" = 1 ] || fail "expected exactly one object under s3://$1/$2, got $_sk_n: $(printf '%s' "$_sk_keys" | tr '\n' ' ')"
  printf '%s\n' "$_sk_keys"
}

# ---------------------------------------------------------------------------
# PostgreSQL helpers. PG_CTR overrides the target container (default: pg).

sql_ident() {
  printf '"%s"' "$(printf '%s' "$1" | sed 's/"/""/g')"
}

# db_conninfo <database> - a connection string naming the database, so a name
# that starts with "-" or contains "=" is not read as an option or as a
# connection string.
db_conninfo() {
  printf "dbname='%s'" "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/\\\\'/g")"
}

# psql_exec <database> <sql> - prints unaligned, tuples-only output. Reads
# nothing from stdin, so it is safe inside `while read` loops.
psql_exec() {
  docker exec -i "${PG_CTR:-$E2E_PG_CTR}" psql -X -q -U postgres -d "$(db_conninfo "$1")" -At -v ON_ERROR_STOP=1 \
    -c "$2" </dev/null
}

# When a case ends, run.sh drops the databases on the shared server whose
# names start with the case's new_db prefix (t_<slug>), plus any listed in
# CASE_DIR/.dbs, so disk use does not grow with every case.
_record_db() {
  if [ "${PG_CTR:-$E2E_PG_CTR}" = "$E2E_PG_CTR" ]; then
    printf '%s\n' "$1" >>"$CASE_DIR/.dbs"
  fi
}

db_exists() {
  [ "$(psql_exec postgres "SELECT count(*) FROM pg_database WHERE datname = '$(printf '%s' "$1" | sed "s/'/''/g")'")" = 1 ]
}

# new_db [suffix] - creates a database cloned from the seed and prints its name.
new_db() {
  _nd_name=$(printf 't_%s%s' "$CASE_SLUG" "${1:+_$1}" | tr '-' '_' | cut -c1-63)
  psql_exec postgres "CREATE DATABASE $(sql_ident "$_nd_name") TEMPLATE e2e_seed" >/dev/null \
    || fail "could not create database $_nd_name"
  printf '%s\n' "$_nd_name"
}

# new_db_named <name> - same as new_db but with an exact (possibly odd) name.
new_db_named() {
  psql_exec postgres "CREATE DATABASE $(sql_ident "$1") TEMPLATE e2e_seed" >/dev/null \
    || fail "could not create database $1"
  _record_db "$1"
}

drop_db() {
  psql_exec postgres "DROP DATABASE IF EXISTS $(sql_ident "$1") WITH (FORCE)" >/dev/null
}

# db_fingerprint <database> - one line per object; see fixtures/fingerprint.sql.
db_fingerprint() {
  docker exec -i "${PG_CTR:-$E2E_PG_CTR}" psql -X -q -U postgres -d "$(db_conninfo "$1")" -At -v ON_ERROR_STOP=1 -f - \
    <"$E2E_DIR/fixtures/fingerprint.sql"
}

# assert_same_data <source-db> <restored-db> [restored-container]
assert_same_data() {
  db_fingerprint "$1" >"$CASE_DIR/fingerprint-src.txt" || fail "could not fingerprint $1"
  PG_CTR=${3:-${PG_CTR:-$E2E_PG_CTR}} db_fingerprint "$2" >"$CASE_DIR/fingerprint-dst.txt" \
    || fail "could not fingerprint $2"
  [ -s "$CASE_DIR/fingerprint-src.txt" ] || fail "empty fingerprint for $1"
  if ! diff -u "$CASE_DIR/fingerprint-src.txt" "$CASE_DIR/fingerprint-dst.txt" >"$CASE_DIR/fingerprint.diff"; then
    head -n 40 "$CASE_DIR/fingerprint.diff" >&2
    fail "restored database $2 differs from $1"
  fi
}

# start_postgres <alias> [port] - starts an extra, case-scoped PostgreSQL server
# reachable as <alias>:<port> and prints its container name.
start_postgres() {
  _sp_alias=$1 _sp_port=${2:-5432}
  _sp_ctr="${E2E_RUN_ID}-${CASE_SLUG}-${_sp_alias}"
  docker run -d --name "$_sp_ctr" --label "e2e.run=$E2E_RUN_ID" --label "e2e.case=$CASE_SLUG" \
    --network "$E2E_NET" --network-alias "$_sp_alias" -e "POSTGRES_PASSWORD=$PG_PASSWORD" \
    "$E2E_POSTGRES_IMAGE" -c "port=$_sp_port" -c fsync=off -c full_page_writes=off >/dev/null \
    || fail "could not start postgres $_sp_alias"
  wait_for 60 docker exec "$_sp_ctr" psql -X -h 127.0.0.1 -p "$_sp_port" -U postgres -Atc 'SELECT 1' >/dev/null 2>&1 \
    || fail "postgres $_sp_alias did not become ready"
  printf '%s\n' "$_sp_ctr"
}

# ---------------------------------------------------------------------------
# Hooks.

# hooks_setup - creates CASE_DIR/hooks (mounted read-only at /hooks) and
# CASE_DIR/hook-out (writable by the unprivileged hook user at /hook-out), and
# sets HOOK_MOUNTS for bk_run.
hooks_setup() {
  mkdir -p "$CASE_DIR/hooks" "$CASE_DIR/hook-out"
  chmod 755 "$CASE_DIR/hooks"
  chmod 777 "$CASE_DIR/hook-out"
  HOOK_MOUNTS=(-v "$CASE_DIR/hooks:/hooks:ro" -v "$CASE_DIR/hook-out:/hook-out")
}

# write_hook <event> [script-body] - writes an executable hook script. The
# default body appends the event to /hook-out/events and saves its environment
# and uid to /hook-out/<event>.env and /hook-out/<event>.uid.
write_hook() {
  if [ $# -ge 2 ]; then
    printf '%s\n' "$2" >"$CASE_DIR/hooks/$1"
  else
    cat >"$CASE_DIR/hooks/$1" <<'EOF'
#!/bin/sh
echo "$1" >> /hook-out/events
env | sort > "/hook-out/$1.env"
id -u > "/hook-out/$1.uid"
EOF
  fi
  chmod 755 "$CASE_DIR/hooks/$1"
}

# hook_events - recorded script-hook events, space separated, in order.
hook_events() {
  if [ -f "$CASE_DIR/hook-out/events" ]; then
    tr '\n' ' ' <"$CASE_DIR/hook-out/events" | sed 's/ *$//'
  fi
}

# hook_url <http|https> <ok|fail|error500|redirect> <name> - URL on the hook
# receiver that is unique to this case.
hook_url() {
  if [ "$1" = https ]; then
    printf 'https://hooks:8443/%s/%s/%s\n' "$2" "$CASE_SLUG" "$3"
  else
    printf 'http://hooks:8080/%s/%s/%s\n' "$2" "$CASE_SLUG" "$3"
  fi
}

# hook_requests - requests the receiver logged for this case, one per line:
# "<scheme> <method> <path>".
hook_requests() {
  grep -F "/$CASE_SLUG/" "$E2E_WORK/hook-server/requests.log" 2>/dev/null || true
}

# hook_request_headers - one JSON object per request the receiver logged for
# this case: {"path": "...", "headers": {"Name": "value", ...}}.
hook_request_headers() {
  grep -F "/$CASE_SLUG/" "$E2E_WORK/hook-server/headers.log" 2>/dev/null || true
}

# Mount that makes the image trust the e2e CA through run.sh's
# /usr/local/share/ca-certificates path (needed for https hook URLs too).
e2e_ca_system_mount() {
  printf '%s\n' "$E2E_CERTS/ca.crt:/usr/local/share/ca-certificates/e2e-ca.crt:ro"
}
