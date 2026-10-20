#! /bin/sh
# Tests for hooks.sh and backup/restore hook points.
# Run from anywhere: sh test/hooks_test.sh

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
# Shell used to run backup.sh/restore.sh; the image uses BusyBox sh.
SCRIPT_SHELL=${SCRIPT_SHELL:-bash}
export HOOK_DROP_PRIVS=no
export HOOK_ALLOW_HTTP=no
export HOOK_INHERIT_ENV=no

. "$ROOT/hooks.sh"

PASS=0
FAIL=0

pass() {
  PASS=$((PASS + 1))
}

fail() {
  FAIL=$((FAIL + 1))
  echo "FAIL: $*" >&2
}

assert_eq() {
  if [ "$1" = "$2" ]; then
    pass
  else
    fail "$3: expected '$2' got '$1'"
  fi
}

assert_ok() {
  if "$@"; then
    pass
  else
    fail "expected success: $*"
  fi
}

assert_fail() {
  if "$@"; then
    fail "expected failure: $*"
  else
    pass
  fi
}

url_reason() {
  hook_url_is_allowed "$1" || true
}

assert_url_allowed() {
  if hook_url_is_allowed "$1" >/dev/null; then
    pass
  else
    fail "URL should be allowed: $1 ($(url_reason "$1"))"
  fi
}

assert_url_denied() {
  _want=$2
  _got=$(hook_url_is_allowed "$1" 2>/dev/null) && {
    fail "URL should be denied: $1"
    return
  }
  if [ -n "$_want" ] && [ "$_got" != "$_want" ]; then
    fail "URL $1: expected reason '$_want' got '$_got'"
  else
    pass
  fi
}

# --- URL validation ---

assert_url_allowed "https://hc-ping.com/uuid"
assert_url_allowed "https://example.com:8443/ping"
assert_url_allowed "https://checks.example.org/start"

assert_url_denied "http://hc-ping.com/uuid" "http-not-allowed"
assert_url_denied "file:///etc/passwd" "scheme"
assert_url_denied "https://127.0.0.1/ping" "blocked-host"
assert_url_denied "https://127.0.0.1:443/ping" "blocked-host"
assert_url_denied "https://localhost/ping" "blocked-host"
assert_url_denied "https://LOCALHOST/ping" "blocked-host"
assert_url_denied "https://169.254.169.254/latest/meta-data/" "blocked-host"
assert_url_denied "https://metadata.google.internal/" "blocked-host"
assert_url_denied "https://[::1]/ping" "blocked-host"
assert_url_denied "https://user:pass@example.com/ping" "userinfo"
assert_url_denied "$(printf 'https://example.com/pi\nng')" "whitespace"
assert_url_denied "https://example.com/ping extra" "whitespace"
assert_url_denied "" "empty"
assert_url_denied "**None**" "empty"

HOOK_ALLOW_HTTP=yes
assert_url_allowed "http://hc-ping.com/uuid"
assert_url_denied "http://127.0.0.1/ping" "blocked-host"
HOOK_ALLOW_HTTP=no

assert_fail hook_event_allowed "../post-backup"
assert_fail hook_event_allowed "post-backup/../pre-backup"
assert_fail hook_event_allowed "post backup"
assert_ok hook_event_allowed post-backup
assert_ok hook_event_allowed backup-error
assert_ok hook_event_allowed pre-restore

# --- Script path / env scrubbing ---

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
HOOKS_DIR="$WORKDIR/hooks"
mkdir -p "$HOOKS_DIR"

# Invalid event names never run, even if a matching file exists.
printf '#!/bin/sh\necho RAN >> "%s/evil.log"\n' "$WORKDIR" > "$HOOKS_DIR/../post-backup"
chmod +x "$WORKDIR/post-backup" 2>/dev/null || true
assert_fail run_hooks "../post-backup"
if [ -f "$WORKDIR/evil.log" ]; then
  fail "path traversal event ran a script"
else
  pass
fi

# Symlink pointing outside HOOKS_DIR is rejected.
printf '#!/bin/sh\necho OUTSIDE\n' > "$WORKDIR/outside.sh"
chmod +x "$WORKDIR/outside.sh"
ln -s "$WORKDIR/outside.sh" "$HOOKS_DIR/post-backup"
assert_fail hook_run_script post-backup
rm -f "$HOOKS_DIR/post-backup"

# Non-executable file fails closed.
printf '#!/bin/sh\nexit 0\n' > "$HOOKS_DIR/post-backup"
chmod a-x "$HOOKS_DIR/post-backup"
assert_fail hook_run_script post-backup

# Env allowlist: secrets must not leak; metadata may.
ENV_FILE="$WORKDIR/hook.env"
EVENT_FILE="$WORKDIR/hook.events"
cat > "$HOOKS_DIR/post-backup" <<EOF
#! /bin/sh
env | sort > "$ENV_FILE"
echo "\$1" >> "$EVENT_FILE"
EOF
chmod +x "$HOOKS_DIR/post-backup"

export POSTGRES_PASSWORD=supersecret
export PGPASSWORD=supersecret
export ENCRYPTION_PASSWORD=enc-secret
export S3_SECRET_ACCESS_KEY=s3secret
export S3_ACCESS_KEY_ID=s3id
export AWS_SECRET_ACCESS_KEY=awssecret
export AWS_ACCESS_KEY_ID=awsid
export AWS_SESSION_TOKEN=session
export AWS_WEB_IDENTITY_TOKEN_FILE=/run/secrets/token
export POSTGRES_DATABASE=appdb
export POSTGRES_HOST=db.internal
export POSTGRES_PORT=5432
export POSTGRES_USER=app
export S3_BUCKET=backups
export S3_PREFIX=backup
export S3_REGION=eu-west-1
export BACKUP_DEST_FILE=appdb.dump
export BACKUP_S3_URI=s3://backups/backup/appdb.dump

assert_ok hook_run_script post-backup
assert_eq "$(cat "$EVENT_FILE")" "post-backup" "script event argument"

if grep -E 'supersecret|enc-secret|s3secret|awssecret|session|AWS_WEB_IDENTITY|AWS_ACCESS_KEY_ID|S3_ACCESS_KEY_ID|S3_SECRET|POSTGRES_PASSWORD|PGPASSWORD|ENCRYPTION_PASSWORD' "$ENV_FILE" >/dev/null; then
  fail "secret leaked into hook environment:"
  cat "$ENV_FILE" >&2
else
  pass
fi

if grep -q '^POSTGRES_DATABASE=appdb$' "$ENV_FILE" && grep -q '^BACKUP_S3_URI=s3://backups/backup/appdb.dump$' "$ENV_FILE"; then
  pass
else
  fail "allowlisted metadata missing from hook env"
  cat "$ENV_FILE" >&2
fi

if grep -q '^HOOK_EVENT=post-backup$' "$ENV_FILE"; then
  pass
else
  fail "HOOK_EVENT missing"
fi

# Inherit opt-out does pass secrets.
HOOK_INHERIT_ENV=yes
INHERIT_ENV="$WORKDIR/inherit.env"
cat > "$HOOKS_DIR/pre-backup" <<EOF
#! /bin/sh
env | sort > "$INHERIT_ENV"
EOF
chmod +x "$HOOKS_DIR/pre-backup"
assert_ok hook_run_script pre-backup
if grep -q 'POSTGRES_PASSWORD=supersecret' "$INHERIT_ENV"; then
  pass
else
  fail "HOOK_INHERIT_ENV=yes should pass POSTGRES_PASSWORD"
fi
HOOK_INHERIT_ENV=no

# Error hook receives HOOK_EXIT_CODE.
cat > "$HOOKS_DIR/backup-error" <<EOF
#! /bin/sh
env | sort > "$WORKDIR/error.env"
EOF
chmod +x "$HOOKS_DIR/backup-error"
# shellcheck disable=SC2034 # read by hooks.sh
HOOK_EXIT_CODE=7
assert_ok hook_run_script backup-error
if grep -q '^HOOK_EXIT_CODE=7$' "$WORKDIR/error.env"; then
  pass
else
  fail "HOOK_EXIT_CODE not passed to error hook"
  cat "$WORKDIR/error.env" >&2
fi

# Failed error hook does not change run_error_hooks status.
cat > "$HOOKS_DIR/restore-error" <<EOF
#! /bin/sh
exit 42
EOF
chmod +x "$HOOKS_DIR/restore-error"
assert_ok run_error_hooks restore-error 9

# --- URL hook uses curl argv, not shell; rejected URLs never invoke curl ---

FAKE_BIN="$WORKDIR/bin"
mkdir -p "$FAKE_BIN"
CURL_LOG="$WORKDIR/curl.log"
CURL_ENV="$WORKDIR/curl.env"
cat > "$FAKE_BIN/curl" <<EOF
#! /bin/sh
printf '%s\n' "\$*" >> "$CURL_LOG"
env | sort > "$CURL_ENV"
exit 0
EOF
chmod +x "$FAKE_BIN/curl"
PATH="$FAKE_BIN:$PATH"
export PATH

rm -f "$CURL_LOG"
HOOK_POST_BACKUP_URL="https://127.0.0.1/secret-uuid"
assert_fail hook_run_url post-backup
if [ -f "$CURL_LOG" ]; then
  fail "curl invoked for blocked URL"
else
  pass
fi

HOOK_POST_BACKUP_URL="https://hc-ping.com/secret-uuid"
assert_ok hook_run_url post-backup
if grep -q -- '--proto =https' "$CURL_LOG" && grep -q -- '--max-redirs 0' "$CURL_LOG" && grep -q -- '-- https://hc-ping.com/secret-uuid' "$CURL_LOG"; then
  pass
else
  fail "curl argv missing expected flags:"
  cat "$CURL_LOG" >&2
fi
# -q must come first for curl to skip .curlrc.
case "$(tail -n 1 "$CURL_LOG")" in
  "-q "*) pass ;;
  *) fail "curl argv does not start with -q: $(tail -n 1 "$CURL_LOG")" ;;
esac

# curl sees only PATH, HOME and proxy/CA settings, never secrets.
if grep -E 'supersecret|enc-secret|s3secret|awssecret|session|PGPASSWORD|POSTGRES_PASSWORD|AWS_SECRET_ACCESS_KEY|AWS_ACCESS_KEY_ID|AWS_WEB_IDENTITY|POSTGRES_DATABASE' "$CURL_ENV" >/dev/null; then
  fail "URL hook curl saw secrets or other variables:"
  cat "$CURL_ENV" >&2
else
  pass
fi
assert_eq "$(grep '^HOME=' "$CURL_ENV")" "HOME=/tmp" "URL hook HOME"
assert_eq "$(grep '^PATH=' "$CURL_ENV")" "PATH=$PATH" "URL hook PATH passed through"

rm -f "$CURL_ENV"
if (
  export HTTPS_PROXY=http://proxy.example:3128 no_proxy=.internal SSL_CERT_FILE=/etc/ssl/custom.pem
  hook_run_url post-backup
); then
  pass
else
  fail "URL hook with proxy settings failed"
fi
if grep -q '^HTTPS_PROXY=http://proxy.example:3128$' "$CURL_ENV" && grep -q '^no_proxy=.internal$' "$CURL_ENV" && grep -q '^SSL_CERT_FILE=/etc/ssl/custom.pem$' "$CURL_ENV"; then
  pass
else
  fail "URL hook did not pass proxy and CA settings:"
  cat "$CURL_ENV" >&2
fi

# With privilege dropping, env -i runs before su-exec, so the process that
# switches to the hook user never sees secrets. The fake su-exec sets HOME as
# the real one does.
SU_BIN="$WORKDIR/subin"
mkdir -p "$SU_BIN"
cat > "$SU_BIN/su-exec" <<EOF
#! /bin/sh
env | sort >> "$WORKDIR/su-exec.env"
printf '%s\n' "\$1" >> "$WORKDIR/su-exec.user"
shift
HOME=/home/hook
export HOME
exec "\$@"
EOF
printf '#! /bin/sh\nexit 0\n' > "$SU_BIN/id"
chmod +x "$SU_BIN/su-exec" "$SU_BIN/id"

rm -f "$WORKDIR/su-exec.env" "$WORKDIR/su-exec.user" "$CURL_ENV"
if (
  PATH="$SU_BIN:$PATH"
  HOOK_DROP_PRIVS=yes
  hook_run_url post-backup
); then
  pass
else
  fail "URL hook with HOOK_DROP_PRIVS=yes failed"
fi
assert_eq "$(cat "$WORKDIR/su-exec.user" 2>/dev/null)" "hook" "URL hook runs as the hook user"
if [ -f "$WORKDIR/su-exec.env" ] && ! grep -E 'supersecret|awssecret|PGPASSWORD|AWS_SECRET_ACCESS_KEY' "$WORKDIR/su-exec.env" >/dev/null; then
  pass
else
  fail "su-exec for the URL hook saw secrets (env -i must come first):"
  cat "$WORKDIR/su-exec.env" >&2
fi
assert_eq "$(grep '^HOME=' "$CURL_ENV" 2>/dev/null)" "HOME=/tmp" "URL hook HOME after su-exec"

SU_HOOK_ENV="$WORKDIR/su-hook.env"
printf '#! /bin/sh\nenv | sort > "%s"\n' "$SU_HOOK_ENV" > "$HOOKS_DIR/post-backup"
chmod +x "$HOOKS_DIR/post-backup"
rm -f "$WORKDIR/su-exec.env" "$WORKDIR/su-exec.user"
if (
  PATH="$SU_BIN:$PATH"
  HOOK_DROP_PRIVS=yes
  hook_run_script post-backup
); then
  pass
else
  fail "script hook with HOOK_DROP_PRIVS=yes failed"
fi
assert_eq "$(cat "$WORKDIR/su-exec.user" 2>/dev/null)" "hook" "script hook runs as the hook user"
if [ -f "$WORKDIR/su-exec.env" ] && ! grep -E 'supersecret|awssecret|PGPASSWORD|AWS_SECRET_ACCESS_KEY' "$WORKDIR/su-exec.env" "$SU_HOOK_ENV" >/dev/null; then
  pass
else
  fail "su-exec or the script hook saw secrets:"
  cat "$WORKDIR/su-exec.env" "$SU_HOOK_ENV" >&2
fi
if grep -q '^HOME=/tmp$' "$SU_HOOK_ENV" && grep -q '^POSTGRES_DATABASE=appdb$' "$SU_HOOK_ENV" && grep -q '^PATH=/usr/local/bin:/usr/bin:/bin$' "$SU_HOOK_ENV"; then
  pass
else
  fail "script hook environment after su-exec:"
  cat "$SU_HOOK_ENV" >&2
fi

# HOOK_INHERIT_ENV=yes still passes the full environment through su-exec.
rm -f "$SU_HOOK_ENV"
if (
  PATH="$SU_BIN:$PATH"
  HOOK_DROP_PRIVS=yes
  HOOK_INHERIT_ENV=yes
  hook_run_script post-backup
); then
  pass
else
  fail "inheriting script hook with HOOK_DROP_PRIVS=yes failed"
fi
if grep -q '^POSTGRES_PASSWORD=supersecret$' "$SU_HOOK_ENV"; then
  pass
else
  fail "HOOK_INHERIT_ENV=yes with su-exec should pass POSTGRES_PASSWORD"
fi
rm -f "$HOOKS_DIR/post-backup"

# --- backup.sh / restore.sh hook points with fake tools ---

write_fakes() {
  cat > "$FAKE_BIN/pg_dump" <<'EOF'
#! /bin/sh
if [ -n "${FAKE_PGPASS_LOG:-}" ]; then
  printf 'PGPASSWORD=%s\nARGS=%s\n' "$PGPASSWORD" "$*" > "$FAKE_PGPASS_LOG"
fi
if [ "${FAKE_DUMP_EMPTY:-no}" = yes ]; then
  exit 0
fi
if [ "${FAKE_DUMP_TERM_PARENT:-no}" = yes ]; then
  # Stop the script mid-dump, as docker stop or go-cron would.
  kill -TERM "$PPID"
fi
echo "SELECT 1;"
exit 0
EOF
  cat > "$FAKE_BIN/pg_dumpall" <<'EOF'
#! /bin/sh
echo "SELECT 1;"
exit 0
EOF
  cat > "$FAKE_BIN/pg_restore" <<'EOF'
#! /bin/sh
case " $* " in
  *" --list "*)
    if [ "${FAKE_RESTORE_LIST_FAIL:-no}" = yes ]; then
      exit 1
    fi
    ;;
esac
exit 0
EOF
  cat > "$FAKE_BIN/psql" <<EOF
#! /bin/sh
printf '%s\n' "\$*" >> "$WORKDIR/psql.log"
case " \$* " in
  *" -c "*)
    case "\$*" in
      *server_version_num*) echo "\${FAKE_PG_VERSION:-180000}" ;;
      *"FROM pg_database"*) if [ "\${FAKE_DB_EXISTS:-no}" = yes ]; then echo 1; fi ;;
      *"DROP DATABASE"*) if [ "\${FAKE_DROP_FAIL:-no}" = yes ]; then exit 1; fi ;;
    esac
    exit 0
    ;;
esac
cat > "$WORKDIR/psql.stdin"
exit "\${FAKE_PSQL_EXIT:-0}"
EOF
  cat > "$FAKE_BIN/aws" <<EOF
#! /bin/sh
printf '%s\n' "\$*" >> "$WORKDIR/aws.log"
cmd=""
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = s3 ]; then
    shift
    cmd=\$1
    shift
    break
  fi
  shift
done
if [ "\$cmd" = cp ]; then
  # Options such as --storage-class come first; the last two arguments are the paths.
  src=""
  dest=""
  for a in "\$@"; do
    src=\$dest
    dest=\$a
  done
  if [ -f "\$src" ]; then
    if [ "\${FAKE_UPLOAD_FAIL:-no}" = yes ]; then
      exit 1
    fi
    rel=\${dest#s3://}
    basename "\$dest" > "$WORKDIR/last-upload"
    mkdir -p "$WORKDIR/s3/\$(dirname "\$rel")"
    cp "\$src" "$WORKDIR/s3/\$rel"
    exit 0
  fi
  rel=\${src#s3://}
  cp "$WORKDIR/s3/\$rel" "\$dest"
  exit 0
fi
if [ "\$cmd" = ls ]; then
  cat "$WORKDIR/s3-ls.txt" 2>/dev/null
  if [ "\${FAKE_LS_INCLUDE_UPLOAD:-no}" = yes ]; then
    echo "2000-01-01 00:00:00 10 \$(cat "$WORKDIR/last-upload")"
  fi
  exit 0
fi
if [ "\$cmd" = rm ]; then
  if [ "\${FAKE_RM_FAIL:-no}" = yes ]; then
    exit 1
  fi
  printf '%s\n' "\$1" >> "$WORKDIR/aws-rm.log"
  exit 0
fi
exit 1
EOF
  chmod +x "$FAKE_BIN/pg_dump" "$FAKE_BIN/pg_dumpall" "$FAKE_BIN/pg_restore" "$FAKE_BIN/psql" "$FAKE_BIN/aws"
}

write_fakes

common_env() {
  export S3_BUCKET=test-bucket
  export S3_PREFIX=backup
  export S3_REGION=us-east-1
  export S3_ENDPOINT="**None**"
  export S3_ACCESS_KEY_ID="**None**"
  export S3_SECRET_ACCESS_KEY="**None**"
  export POSTGRES_DATABASE=appdb
  export POSTGRES_HOST=db.example
  export POSTGRES_PORT=5432
  export POSTGRES_USER=app
  export POSTGRES_PASSWORD=supersecret
  export ENCRYPTION_PASSWORD="**None**"
  export DELETE_OLDER_THAN="**None**"
  export USE_CUSTOM_FORMAT=no
  export COMPRESSION_CMD=gzip
  export DECOMPRESSION_CMD="gunzip -c"
  export CREATE_DATABASE=no
  export DROP_DATABASE=no
  export PARALLEL_JOBS=1
  export BACKUP_FILE="**None**"
  export HOOKS_DIR="$HOOKS_DIR"
  export HOOK_PRE_BACKUP_URL="**None**"
  export HOOK_POST_BACKUP_URL="**None**"
  export HOOK_BACKUP_ERROR_URL="**None**"
  export HOOK_PRE_RESTORE_URL="**None**"
  export HOOK_POST_RESTORE_URL="**None**"
  export HOOK_RESTORE_ERROR_URL="**None**"
}

rm -f "$HOOKS_DIR"/*
BACKUP_EVENTS="$WORKDIR/backup.events"
for ev in pre-backup post-backup backup-error; do
  cat > "$HOOKS_DIR/$ev" <<EOF
#! /bin/sh
echo "\$1" >> "$BACKUP_EVENTS"
env | sort > "$WORKDIR/\$1.env"
EOF
  chmod +x "$HOOKS_DIR/$ev"
done

common_env
if (
  cd "$ROOT"
  PATH="$FAKE_BIN:$PATH"
  export PATH HOOK_DROP_PRIVS=no HOOK_INHERIT_ENV=no
  $SCRIPT_SHELL "$ROOT/backup.sh"
); then
  pass
else
  fail "backup.sh should succeed with fakes"
fi

assert_eq "$(tr '\n' ' ' < "$BACKUP_EVENTS" | sed 's/ *$//')" "pre-backup post-backup" "backup hook order"

if grep -q 'POSTGRES_PASSWORD=supersecret' "$WORKDIR/post-backup.env"; then
  fail "backup post-backup hook leaked POSTGRES_PASSWORD"
else
  pass
fi

if grep -q '^BACKUP_DEST_FILE=' "$WORKDIR/post-backup.env" && grep -q '^BACKUP_S3_URI=s3://test-bucket/backup/' "$WORKDIR/post-backup.env"; then
  pass
else
  fail "post-backup missing BACKUP_DEST_FILE / BACKUP_S3_URI"
  cat "$WORKDIR/post-backup.env" >&2
fi

# Validation failure must not fire backup-error.
rm -f "$BACKUP_EVENTS"
if (
  cd "$ROOT"
  PATH="$FAKE_BIN:$PATH"
  common_env
  export S3_BUCKET="**None**" HOOK_DROP_PRIVS=no
  $SCRIPT_SHELL "$ROOT/backup.sh"
); then
  fail "backup.sh should fail without S3_BUCKET"
else
  pass
fi
if [ -f "$BACKUP_EVENTS" ]; then
  fail "validation failure fired hooks: $(cat "$BACKUP_EVENTS")"
else
  pass
fi

# Dump failure fires pre-backup then backup-error, not post-backup.
cat > "$FAKE_BIN/pg_dump" <<'EOF'
#! /bin/sh
echo "dump failed" >&2
exit 1
EOF
chmod +x "$FAKE_BIN/pg_dump"
rm -f "$BACKUP_EVENTS"
if (
  cd "$ROOT"
  PATH="$FAKE_BIN:$PATH"
  common_env
  export HOOK_DROP_PRIVS=no
  $SCRIPT_SHELL "$ROOT/backup.sh"
); then
  fail "backup.sh should fail when pg_dump fails"
else
  pass
fi
assert_eq "$(tr '\n' ' ' < "$BACKUP_EVENTS" | sed 's/ *$//')" "pre-backup backup-error" "backup error hook order"
write_fakes

# Restore hooks.
RESTORE_EVENTS="$WORKDIR/restore.events"
for ev in pre-restore post-restore restore-error; do
  cat > "$HOOKS_DIR/$ev" <<EOF
#! /bin/sh
echo "\$1" >> "$RESTORE_EVENTS"
EOF
  chmod +x "$HOOKS_DIR/$ev"
done

mkdir -p "$WORKDIR/s3/test-bucket/backup"
printf 'SELECT 1;\n' | gzip > "$WORKDIR/s3/test-bucket/backup/appdb.sql.gz"

if (
  cd "$ROOT"
  PATH="$FAKE_BIN:$PATH"
  common_env
  export BACKUP_FILE=backup/appdb.sql.gz HOOK_DROP_PRIVS=no
  $SCRIPT_SHELL "$ROOT/restore.sh"
); then
  pass
else
  fail "restore.sh should succeed with fakes"
fi
assert_eq "$(tr '\n' ' ' < "$RESTORE_EVENTS" | sed 's/ *$//')" "pre-restore post-restore" "restore hook order"

rm -f "$RESTORE_EVENTS"
if (
  cd "$ROOT"
  PATH="$FAKE_BIN:$PATH"
  common_env
  export BACKUP_FILE="**None**" HOOK_DROP_PRIVS=no
  $SCRIPT_SHELL "$ROOT/restore.sh"
); then
  fail "restore.sh should fail without BACKUP_FILE"
else
  pass
fi
if [ -f "$RESTORE_EVENTS" ]; then
  fail "restore validation fired hooks: $(cat "$RESTORE_EVENTS")"
else
  pass
fi

# --- Phase 1 regression tests: env handling, S3 keys, restore safety ---

rm -f "$HOOKS_DIR"/*
export TMPDIR="$WORKDIR/tmp"
mkdir -p "$TMPDIR"

# run_script <script> [VAR=value ...] runs a script with the common env plus overrides.
run_script() {
  _script=$1
  shift
  (
    cd "$ROOT" || exit 1
    PATH="$FAKE_BIN:$PATH"
    common_env
    export HOOK_DROP_PRIVS=no HOOK_INHERIT_ENV=no
    for _kv in "$@"; do
      export "${_kv?}"
    done
    $SCRIPT_SHELL "$ROOT/$_script"
  ) > "$WORKDIR/last.out" 2>&1
}

reset_logs() {
  rm -rf "$WORKDIR/aws.log" "$WORKDIR/aws-rm.log" "$WORKDIR/psql.log" "$WORKDIR/psql.stdin" "$WORKDIR/s3-ls.txt" "$WORKDIR/s3/test-bucket"
}

last_upload_key() {
  grep -E '(^| )s3 cp ' "$WORKDIR/aws.log" | tail -n 1 | awk '{print $NF}'
}

# Empty strings (as in the Kubernetes example) are treated as unset.
reset_logs
printf '2000-01-01 00:00:00 10 appdb_old.sql.gz\n' > "$WORKDIR/s3-ls.txt"
if run_script backup.sh S3_ENDPOINT= DELETE_OLDER_THAN= ENCRYPTION_PASSWORD=; then
  pass
else
  fail "backup.sh with empty optional vars should succeed"
  cat "$WORKDIR/last.out" >&2
fi
if grep -q -- '--endpoint-url' "$WORKDIR/aws.log"; then
  fail "empty S3_ENDPOINT produced --endpoint-url"
else
  pass
fi
if [ -f "$WORKDIR/aws-rm.log" ] || grep -qE '(^| )s3 ls ' "$WORKDIR/aws.log"; then
  fail "empty DELETE_OLDER_THAN triggered retention"
else
  pass
fi
case "$(last_upload_key)" in
  *.enc) fail "empty ENCRYPTION_PASSWORD encrypted the backup" ;;
  *) pass ;;
esac

# Empty required variables are rejected.
reset_logs
assert_fail run_script backup.sh S3_BUCKET=
assert_fail run_script backup.sh POSTGRES_PASSWORD=

# Empty S3_PREFIX does not produce a double slash; slashes are normalised.
reset_logs
assert_ok run_script backup.sh S3_PREFIX=
case "$(last_upload_key)" in
  s3://test-bucket/appdb_*.sql.gz) pass ;;
  *) fail "empty S3_PREFIX key: $(last_upload_key)" ;;
esac
reset_logs
assert_ok run_script backup.sh S3_PREFIX=/nested/path/
case "$(last_upload_key)" in
  s3://test-bucket/nested/path/appdb_*.sql.gz) pass ;;
  *) fail "slashed S3_PREFIX key: $(last_upload_key)" ;;
esac

# Invalid DELETE_OLDER_THAN fails before any dump or upload.
reset_logs
assert_fail run_script backup.sh "DELETE_OLDER_THAN=not a date at all"
if [ -f "$WORKDIR/aws.log" ]; then
  fail "invalid DELETE_OLDER_THAN still uploaded"
else
  pass
fi

# Retention uses the normalised prefix.
reset_logs
printf '2000-01-01 00:00:00 10 appdb_old.sql.gz\n' > "$WORKDIR/s3-ls.txt"
assert_ok run_script backup.sh "DELETE_OLDER_THAN=30 days ago"
assert_eq "$(cat "$WORKDIR/aws-rm.log" 2>/dev/null)" "s3://test-bucket/backup/appdb_old.sql.gz" "retention delete key"

# Temporary files are removed after success and failure.
assert_eq "$(ls "$TMPDIR" | wc -l | tr -d ' ')" "0" "temp dir cleaned"

# Restore: plain SQL stops at the first error by default.
reset_logs
mkdir -p "$WORKDIR/s3/test-bucket/backup"
printf 'SELECT 1;\n' | gzip > "$WORKDIR/s3/test-bucket/backup/appdb.sql.gz"
assert_ok run_script restore.sh BACKUP_FILE=backup/appdb.sql.gz
if grep -q 'ON_ERROR_STOP=1 -d appdb' "$WORKDIR/psql.log"; then
  pass
else
  fail "restore psql missing ON_ERROR_STOP=1"
  cat "$WORKDIR/psql.log" >&2
fi

RESTORE_EVENTS="$WORKDIR/restore.events"
for ev in pre-restore post-restore restore-error; do
  printf '#! /bin/sh\necho "$1" >> "%s"\n' "$RESTORE_EVENTS" > "$HOOKS_DIR/$ev"
  chmod +x "$HOOKS_DIR/$ev"
done
rm -f "$RESTORE_EVENTS"
assert_fail run_script restore.sh BACKUP_FILE=backup/appdb.sql.gz FAKE_PSQL_EXIT=3
assert_eq "$(tr '\n' ' ' < "$RESTORE_EVENTS" | sed 's/ *$//')" "pre-restore restore-error" "failed psql restore fires restore-error"
rm -f "$HOOKS_DIR"/*

# RESTORE_ON_ERROR_STOP=no opts out; POSTGRES_DATABASE=all defaults to permissive.
reset_logs
mkdir -p "$WORKDIR/s3/test-bucket/backup"
printf 'SELECT 1;\n' | gzip > "$WORKDIR/s3/test-bucket/backup/appdb.sql.gz"
assert_ok run_script restore.sh BACKUP_FILE=backup/appdb.sql.gz RESTORE_ON_ERROR_STOP=no
assert_ok run_script restore.sh BACKUP_FILE=backup/appdb.sql.gz POSTGRES_DATABASE=all
if grep -v ' -c ' "$WORKDIR/psql.log" | grep -q 'ON_ERROR_STOP'; then
  fail "ON_ERROR_STOP set despite opt-out / all"
else
  pass
fi
assert_fail run_script restore.sh BACKUP_FILE=backup/appdb.sql.gz RESTORE_ON_ERROR_STOP=maybe

# A failed DROP DATABASE fails the restore instead of restoring into the old database.
reset_logs
mkdir -p "$WORKDIR/s3/test-bucket/backup"
printf 'SELECT 1;\n' | gzip > "$WORKDIR/s3/test-bucket/backup/appdb.sql.gz"
assert_fail run_script restore.sh BACKUP_FILE=backup/appdb.sql.gz DROP_DATABASE=yes FAKE_DROP_FAIL=yes
if [ -f "$WORKDIR/psql.stdin" ]; then
  fail "restore ran after failed DROP DATABASE"
else
  pass
fi

# DROP uses WITH (FORCE) on PostgreSQL 13+ and plain DROP before that.
reset_logs
mkdir -p "$WORKDIR/s3/test-bucket/backup"
printf 'SELECT 1;\n' | gzip > "$WORKDIR/s3/test-bucket/backup/appdb.sql.gz"
assert_ok run_script restore.sh BACKUP_FILE=backup/appdb.sql.gz DROP_DATABASE=yes
if grep -q 'DROP DATABASE IF EXISTS "appdb" WITH (FORCE);' "$WORKDIR/psql.log"; then pass; else fail "missing DROP WITH (FORCE)"; fi
assert_ok run_script restore.sh BACKUP_FILE=backup/appdb.sql.gz DROP_DATABASE=yes FAKE_PG_VERSION=120005
if grep -q 'DROP DATABASE IF EXISTS "appdb";' "$WORKDIR/psql.log"; then pass; else fail "missing plain DROP for PostgreSQL 12"; fi

# CREATE_DATABASE only creates a missing database.
reset_logs
mkdir -p "$WORKDIR/s3/test-bucket/backup"
printf 'SELECT 1;\n' | gzip > "$WORKDIR/s3/test-bucket/backup/appdb.sql.gz"
assert_ok run_script restore.sh BACKUP_FILE=backup/appdb.sql.gz CREATE_DATABASE=yes FAKE_DB_EXISTS=yes
if grep -q 'CREATE DATABASE' "$WORKDIR/psql.log"; then fail "CREATE DATABASE run for existing database"; else pass; fi
assert_ok run_script restore.sh BACKUP_FILE=backup/appdb.sql.gz CREATE_DATABASE=yes
if grep -q 'CREATE DATABASE "appdb";' "$WORKDIR/psql.log"; then pass; else fail "CREATE DATABASE not run for missing database"; fi

# Invalid PARALLEL_JOBS is rejected up front.
assert_fail run_script restore.sh BACKUP_FILE=backup/appdb.sql.gz PARALLEL_JOBS=abc

# Unsupported formats are rejected before the database is dropped.
reset_logs
mkdir -p "$WORKDIR/s3/test-bucket/backup"
printf 'x' > "$WORKDIR/s3/test-bucket/backup/appdb.tar"
assert_fail run_script restore.sh BACKUP_FILE=backup/appdb.tar DROP_DATABASE=yes
if grep -q 'DROP' "$WORKDIR/psql.log" 2>/dev/null; then fail "dropped database before rejecting format"; else pass; fi

assert_eq "$(ls "$TMPDIR" | wc -l | tr -d ' ')" "0" "temp dir cleaned after restores"

# run.sh: empty SCHEDULE runs a one-off backup instead of go-cron.
RUN_DIR="$WORKDIR/run"
mkdir -p "$RUN_DIR"
printf 'echo BACKUP\n' > "$RUN_DIR/backup.sh"
printf 'echo RESTORE\n' > "$RUN_DIR/restore.sh"
printf '#! /bin/sh\necho GOCRON "$@"\n' > "$FAKE_BIN/go-cron"
printf '#! /bin/sh\nexit 0\n' > "$FAKE_BIN/update-ca-certificates"
chmod +x "$FAKE_BIN/go-cron" "$FAKE_BIN/update-ca-certificates"
run_entry() {
  (
    cd "$RUN_DIR" || exit 1
    PATH="$FAKE_BIN:$PATH"
    export BACKUP_FILE="$1" SCHEDULE="$2" S3_S3V4=no S3_CA_BUNDLE=
    sh "$ROOT/run.sh"
  ) 2>&1
}
assert_eq "$(run_entry '' '')" "GOCRON --once /bin/sh backup.sh" "run.sh empty SCHEDULE"
assert_eq "$(run_entry '**None**' '@daily')" "GOCRON @daily /bin/sh backup.sh" "run.sh with SCHEDULE"
assert_eq "$(run_entry 'backup/x.sql.gz' '@daily')" "GOCRON --once /bin/sh restore.sh" "run.sh with BACKUP_FILE"
unset TMPDIR

# --- Phase 2: retention options and dump verification ---

export TMPDIR="$WORKDIR/tmp"

write_old_listing() {
  cat > "$WORKDIR/s3-ls.txt" <<LS
                           PRE nested/
2000-01-01 00:00:00         10 appdb_2000-01-01T00:00:00Z.sql.gz
2000-01-01 00:00:00         10 otherdb_2000-01-01T00:00:00Z.sql.gz
2000-01-01 00:00:00         10 notes with spaces.txt
2999-01-01 00:00:00         10 appdb_2999-01-01T00:00:00Z.sql.gz
LS
}

# Default retention keeps the current behaviour: every old file in the prefix is deleted.
reset_logs
write_old_listing
assert_ok run_script backup.sh "DELETE_OLDER_THAN=30 days ago"
assert_eq "$(sort "$WORKDIR/aws-rm.log" | tr '\n' '|')" "s3://test-bucket/backup/appdb_2000-01-01T00:00:00Z.sql.gz|s3://test-bucket/backup/notes with spaces.txt|s3://test-bucket/backup/otherdb_2000-01-01T00:00:00Z.sql.gz|" "default retention deletes all old files"
if grep -q 'Retention: deleted 3 file(s), kept 1 newer file(s)' "$WORKDIR/last.out"; then pass; else fail "retention summary missing"; fi

# DELETE_MATCH_DATABASE=yes only deletes this database's backups.
reset_logs
write_old_listing
assert_ok run_script backup.sh "DELETE_OLDER_THAN=30 days ago" DELETE_MATCH_DATABASE=yes
assert_eq "$(cat "$WORKDIR/aws-rm.log")" "s3://test-bucket/backup/appdb_2000-01-01T00:00:00Z.sql.gz" "DELETE_MATCH_DATABASE=yes deletes only matching files"

# The backup uploaded by this run is never deleted, even if its listed time is old.
reset_logs
assert_ok run_script backup.sh "DELETE_OLDER_THAN=30 days ago" FAKE_LS_INCLUDE_UPLOAD=yes
if [ -f "$WORKDIR/aws-rm.log" ]; then
  fail "retention deleted the backup it just uploaded: $(cat "$WORKDIR/aws-rm.log")"
else
  pass
fi

# A failed delete fails the backup.
reset_logs
write_old_listing
assert_fail run_script backup.sh "DELETE_OLDER_THAN=30 days ago" FAKE_RM_FAIL=yes

# An empty dump is never uploaded.
reset_logs
assert_fail run_script backup.sh USE_CUSTOM_FORMAT=yes FAKE_DUMP_EMPTY=yes
if [ -f "$WORKDIR/aws.log" ]; then fail "empty dump was uploaded"; else pass; fi

# A custom-format dump that pg_restore cannot read is never uploaded.
reset_logs
assert_fail run_script backup.sh USE_CUSTOM_FORMAT=yes FAKE_RESTORE_LIST_FAIL=yes
if [ -f "$WORKDIR/aws.log" ]; then fail "unreadable custom dump was uploaded"; else pass; fi
reset_logs
assert_ok run_script backup.sh USE_CUSTOM_FORMAT=yes

# A corrupt gzip stream is never uploaded.
GZ_BIN="$WORKDIR/gzbin"
mkdir -p "$GZ_BIN"
REAL_GZIP=$(command -v gzip)
cat > "$GZ_BIN/gzip" <<GZ
#! /bin/sh
if [ "\$1" = -t ]; then
  exec "$REAL_GZIP" "\$@"
fi
cat >/dev/null
printf 'not gzip data'
GZ
chmod +x "$GZ_BIN/gzip"
reset_logs
assert_fail run_script backup.sh "PATH=$GZ_BIN:$FAKE_BIN:$PATH"
if [ -f "$WORKDIR/aws.log" ]; then fail "corrupt gzip dump was uploaded"; else pass; fi

# Other compressors are not checked with gzip -t.
reset_logs
assert_ok run_script backup.sh COMPRESSION_CMD=cat

assert_eq "$(ls "$TMPDIR" | wc -l | tr -d ' ')" "0" "temp dir cleaned after phase 2 tests"
unset TMPDIR

# --- Phase 3: secrets from files, restore latest, upload options, BACKUP_ON_START ---

export TMPDIR="$WORKDIR/tmp"
SECRETS="$WORKDIR/secrets"
mkdir -p "$SECRETS"
printf 'filepass\n' > "$SECRETS/pgpass"
printf 'fileuser\n' > "$SECRETS/pguser"
printf 'encpass\n' > "$SECRETS/encpass"

# *_FILE secrets are loaded, with the trailing newline removed.
reset_logs
assert_ok run_script backup.sh POSTGRES_PASSWORD='**None**' "POSTGRES_PASSWORD_FILE=$SECRETS/pgpass" POSTGRES_USER= "POSTGRES_USER_FILE=$SECRETS/pguser" "FAKE_PGPASS_LOG=$WORKDIR/pgpass.log"
if grep -q '^PGPASSWORD=filepass$' "$WORKDIR/pgpass.log" && grep -q '^ARGS=.* -U fileuser ' "$WORKDIR/pgpass.log"; then
  pass
else
  fail "POSTGRES_PASSWORD_FILE/POSTGRES_USER_FILE not used: $(cat "$WORKDIR/pgpass.log")"
fi

# Setting both a variable and its _FILE form is rejected, as is an unreadable file.
assert_fail run_script backup.sh "POSTGRES_PASSWORD_FILE=$SECRETS/pgpass"
assert_fail run_script backup.sh POSTGRES_PASSWORD= "POSTGRES_PASSWORD_FILE=$SECRETS/missing"

# ENCRYPTION_PASSWORD_FILE encrypts with the file's password.
reset_logs
assert_ok run_script backup.sh "ENCRYPTION_PASSWORD_FILE=$SECRETS/encpass"
ENC_KEY=$(last_upload_key)
ENC_OBJ="$WORKDIR/s3/${ENC_KEY#s3://}"
case "$ENC_KEY" in
  *.sql.gz.enc) pass ;;
  *) fail "ENCRYPTION_PASSWORD_FILE did not encrypt: $ENC_KEY" ;;
esac
if openssl enc -aes-256-cbc -d -pbkdf2 -iter 100000 -in "$ENC_OBJ" -pass pass:encpass 2>/dev/null | gunzip -c | grep -q 'SELECT 1;'; then
  pass
else
  fail "backup not decryptable with the password from ENCRYPTION_PASSWORD_FILE"
fi

# BACKUP_FILE=latest restores the newest matching backup.
reset_logs
mkdir -p "$WORKDIR/s3/test-bucket/backup"
cat > "$WORKDIR/s3-ls.txt" <<LS
                           PRE nested/
2030-01-01 00:00:00         10 appdb_2024-01-01T00:00:00Z.sql.gz
2020-01-01 00:00:00         10 appdb_2025-06-01T12:00:00Z.dump
2020-01-01 00:00:00         10 appdb_2025-01-01T00:00:00Z.sql.gz.enc
2020-01-01 00:00:00         10 appdb_archive_2026-01-01T00:00:00Z.sql.gz
2020-01-01 00:00:00         10 otherdb_2026-01-01T00:00:00Z.sql.gz
2020-01-01 00:00:00         10 appdb_notes.txt
LS
printf 'custom' > "$WORKDIR/s3/test-bucket/backup/appdb_2025-06-01T12:00:00Z.dump"
PRE_RESTORE_ENV="$WORKDIR/pre-restore.env"
printf '#! /bin/sh\nenv > "%s"\n' "$PRE_RESTORE_ENV" > "$HOOKS_DIR/pre-restore"
chmod +x "$HOOKS_DIR/pre-restore"
assert_ok run_script restore.sh BACKUP_FILE=latest
if grep -q 's3 cp s3://test-bucket/backup/appdb_2025-06-01T12:00:00Z.dump ' "$WORKDIR/aws.log"; then
  pass
else
  fail "BACKUP_FILE=latest picked the wrong file:"
  cat "$WORKDIR/aws.log" "$WORKDIR/last.out" >&2
fi
if grep -q '^BACKUP_FILE=backup/appdb_2025-06-01T12:00:00Z.dump$' "$PRE_RESTORE_ENV"; then
  pass
else
  fail "pre-restore hook did not see the resolved BACKUP_FILE"
fi
rm -f "$HOOKS_DIR"/*

# BACKUP_FILE=latest with an empty prefix and with no matching backups.
reset_logs
mkdir -p "$WORKDIR/s3/test-bucket"
printf '2020-01-01 00:00:00         10 appdb_2025-06-01T12:00:00Z.dump\n' > "$WORKDIR/s3-ls.txt"
printf 'custom' > "$WORKDIR/s3/test-bucket/appdb_2025-06-01T12:00:00Z.dump"
assert_ok run_script restore.sh BACKUP_FILE=latest S3_PREFIX=
if grep -q 's3 cp s3://test-bucket/appdb_2025-06-01T12:00:00Z.dump ' "$WORKDIR/aws.log"; then pass; else fail "latest with empty prefix"; fi
reset_logs
printf '2020-01-01 00:00:00         10 otherdb_2025-06-01T12:00:00Z.dump\n' > "$WORKDIR/s3-ls.txt"
assert_fail run_script restore.sh BACKUP_FILE=latest
if grep -q 'No backups of appdb found' "$WORKDIR/last.out"; then pass; else fail "missing no-backups message"; fi

# Upload options are passed to the upload only.
reset_logs
assert_ok run_script backup.sh S3_STORAGE_CLASS=STANDARD_IA S3_SSE=aws:kms S3_SSE_KMS_KEY_ID=alias/backups
if grep -qE '(^| )s3 cp --storage-class STANDARD_IA --sse aws:kms --sse-kms-key-id alias/backups ' "$WORKDIR/aws.log"; then
  pass
else
  fail "upload options missing: $(cat "$WORKDIR/aws.log")"
fi
case "$(last_upload_key)" in
  s3://test-bucket/backup/appdb_*.sql.gz) pass ;;
  *) fail "upload key with options: $(last_upload_key)" ;;
esac
assert_fail run_script backup.sh S3_SSE=rot13
assert_fail run_script backup.sh S3_SSE_KMS_KEY_ID=alias/backups

# BACKUP_ON_START asks go-cron to run a backup before the first scheduled run.
assert_eq "$(BACKUP_ON_START=yes run_entry '**None**' '@daily')" "GOCRON --run-on-start @daily /bin/sh backup.sh" "BACKUP_ON_START=yes"
assert_eq "$(BACKUP_ON_START=no run_entry '**None**' '@daily')" "GOCRON @daily /bin/sh backup.sh" "BACKUP_ON_START=no"

assert_eq "$(ls "$TMPDIR" | wc -l | tr -d ' ')" "0" "temp dir cleaned after phase 3 tests"
unset TMPDIR

# --- Phase 4: result line, report file and hook environment ---

export TMPDIR="$WORKDIR/tmp"
REPORT="$WORKDIR/report"

# result_line prints the last run's pgbackup-result line with durations
# replaced by D, backup timestamps by TS and the size by N.
result_line() {
  grep '^pgbackup-result ' "$WORKDIR/last.out" | sed -E \
    -e 's/=[0-9]+\.[0-9]{3}( |$)/=D\1/g' \
    -e 's/_[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z/_TS/g' \
    -e 's/ size_bytes=[0-9]+/ size_bytes=N/'
}

# report_records prints a report file on one line, with timestamps replaced
# by T, backup timestamps by TS and the size by N.
report_records() {
  sed -E \
    -e 's/^(begin|end) ([a-z-]+) [0-9]{19}( |$)/\1 \2 T\3/' \
    -e 's/_[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z/_TS/g' \
    -e 's/^set backup\.size_bytes [0-9]+$/set backup.size_bytes N/' \
    "$1" | tr '\n' '|'
}

uploaded_size() {
  wc -c < "$WORKDIR/s3/$(last_upload_key | sed 's#^s3://##')" | tr -d ' '
}

# Helpers: logfmt quoting, durations and the nanosecond clock fallback.
logfmt() {
  (
    . "$ROOT/common.sh"
    logfmt_value "$1"
  )
}
assert_eq "$(logfmt appdb)" "appdb" "logfmt plain value"
assert_eq "$(logfmt 'my db')" '"my db"' "logfmt value with a space"
assert_eq "$(logfmt 'say "hi"')" '"say \"hi\""' "logfmt value with quotes"
assert_eq "$(logfmt 'a\b')" '"a\\b"' "logfmt value with a backslash"
assert_eq "$(logfmt 'k=v')" '"k=v"' "logfmt value with an equals sign"
assert_eq "$(logfmt "$(printf 'a\tb')")" "$(printf '"a\tb"')" "logfmt value with a tab"
assert_eq "$(logfmt "$(printf 'a\nb\r')")" "ab" "logfmt value with line breaks"
assert_eq "$(. "$ROOT/common.sh"; format_duration 1000000000 2234567890)" "1.234" "format_duration"
assert_eq "$(. "$ROOT/common.sh"; format_duration 2000000000 1000000000)" "0.000" "format_duration never negative"
DATE_BIN="$WORKDIR/datebin"
mkdir -p "$DATE_BIN"
cat > "$DATE_BIN/date" <<'EOF'
#! /bin/sh
case "$1" in
  +%s%N) echo "1700000000%N" ;;
  +%s) echo "1700000000" ;;
esac
EOF
chmod +x "$DATE_BIN/date"
assert_eq "$(PATH="$DATE_BIN:$PATH"; . "$ROOT/common.sh"; now_ns)" "1700000000000000000" "now_ns without %N"

# A successful backup prints the result line with every phase and records
# the phases and facts in the report file. (An absolute date also works with
# BusyBox date.)
reset_logs
write_old_listing
: > "$REPORT"
assert_ok run_script backup.sh "DELETE_OLDER_THAN=2001-01-01 00:00:00" "PGBACKUP_TELEMETRY_FILE=$REPORT"
SIZE=$(uploaded_size)
assert_eq "$(result_line)" "pgbackup-result operation=backup outcome=success exit_code=0 database=appdb duration_s=D pre_backup_s=D dump_s=D verify_s=D upload_s=D retention_s=D post_backup_s=D size_bytes=N retention_deleted=3 retention_kept=1 file=backup/appdb_TS.sql.gz" "backup result line"
if grep -q "^pgbackup-result .* size_bytes=$SIZE " "$WORKDIR/last.out"; then pass; else fail "result line size_bytes is not $SIZE"; fi
assert_eq "$(report_records "$REPORT")" "begin pre-backup T|end pre-backup T 0|begin dump T|set dump.format plain|set compression gzip|end dump T 0|begin verify T|end verify T 0|set encrypted no|set s3.key backup/appdb_TS.sql.gz|begin upload T|end upload T 0|set backup.size_bytes N|begin retention T|end retention T 0|set retention.deleted 3|set retention.kept 1|begin post-backup T|end post-backup T 0|" "backup report records"
if grep -q "^set backup.size_bytes $SIZE\$" "$REPORT"; then pass; else fail "report size is not $SIZE"; fi
# Timestamps are in nanoseconds and never go backwards.
if awk '$1 == "begin" || $1 == "end" { if (length($3) != 19 || $3 < prev) bad = 1; prev = $3 } END { exit bad }' "$REPORT"; then
  pass
else
  fail "report timestamps:"
  cat "$REPORT" >&2
fi

# Custom format and encryption are reported.
reset_logs
: > "$REPORT"
assert_ok run_script backup.sh USE_CUSTOM_FORMAT=yes ENCRYPTION_PASSWORD=encpass "PGBACKUP_TELEMETRY_FILE=$REPORT"
assert_eq "$(report_records "$REPORT")" "begin pre-backup T|end pre-backup T 0|begin dump T|set dump.format custom|end dump T 0|begin verify T|end verify T 0|set encrypted yes|begin encrypt T|end encrypt T 0|set s3.key backup/appdb_TS.dump.enc|begin upload T|end upload T 0|set backup.size_bytes N|begin post-backup T|end post-backup T 0|" "custom encrypted backup report records"
assert_eq "$(result_line)" "pgbackup-result operation=backup outcome=success exit_code=0 database=appdb duration_s=D pre_backup_s=D dump_s=D verify_s=D encrypt_s=D upload_s=D post_backup_s=D size_bytes=N file=backup/appdb_TS.dump.enc" "custom encrypted backup result line"

# The result line goes to stderr only; stdout is unchanged.
reset_logs
(
  cd "$ROOT" || exit 1
  PATH="$FAKE_BIN:$PATH"
  common_env
  $SCRIPT_SHELL "$ROOT/backup.sh"
) > "$WORKDIR/stdout" 2> "$WORKDIR/stderr"
if grep -q '^pgbackup-result ' "$WORKDIR/stderr" && ! grep -q 'pgbackup-result' "$WORKDIR/stdout"; then
  pass
else
  fail "result line must go to stderr only"
fi

# A failed upload exits 2, names the phase and reports no size.
reset_logs
: > "$REPORT"
run_script backup.sh FAKE_UPLOAD_FAIL=yes "PGBACKUP_TELEMETRY_FILE=$REPORT"
assert_eq "$?" "2" "backup exit code on upload failure"
assert_eq "$(result_line)" "pgbackup-result operation=backup outcome=failure exit_code=2 database=appdb duration_s=D pre_backup_s=D dump_s=D verify_s=D upload_s=D backup_error_s=D failed_phase=upload file=backup/appdb_TS.sql.gz" "backup result line on upload failure"
assert_eq "$(report_records "$REPORT")" "begin pre-backup T|end pre-backup T 0|begin dump T|set dump.format plain|set compression gzip|end dump T 0|begin verify T|end verify T 0|set encrypted no|set s3.key backup/appdb_TS.sql.gz|begin upload T|end upload T 2|begin backup-error T|end backup-error T 0|" "report records on upload failure"

# Stopping the script mid-dump ends the open phase with the exit code.
reset_logs
: > "$REPORT"
run_script backup.sh FAKE_DUMP_TERM_PARENT=yes "PGBACKUP_TELEMETRY_FILE=$REPORT"
assert_eq "$?" "143" "backup exit code when stopped"
assert_eq "$(result_line)" "pgbackup-result operation=backup outcome=cancelled exit_code=143 database=appdb duration_s=D pre_backup_s=D dump_s=D backup_error_s=D failed_phase=dump" "backup result line when stopped"
assert_eq "$(report_records "$REPORT")" "begin pre-backup T|end pre-backup T 0|begin dump T|set dump.format plain|set compression gzip|end dump T 143|begin backup-error T|end backup-error T 0|" "report records when stopped"

# A stop signal during the error hooks must not cut the EXIT trap short:
# the exit code and result line stay, and the error-hook phase records it.
TERM_HOOKS="$WORKDIR/hooks-term"
mkdir -p "$TERM_HOOKS"
for _ev in backup-error restore-error; do
  printf '#! /bin/sh\nkill -TERM "$PPID"\n' > "$TERM_HOOKS/$_ev"
  chmod +x "$TERM_HOOKS/$_ev"
done
reset_logs
: > "$REPORT"
run_script backup.sh FAKE_UPLOAD_FAIL=yes "HOOKS_DIR=$TERM_HOOKS" "PGBACKUP_TELEMETRY_FILE=$REPORT"
assert_eq "$?" "2" "backup exit code when stopped during error hooks"
assert_eq "$(result_line)" "pgbackup-result operation=backup outcome=failure exit_code=2 database=appdb duration_s=D pre_backup_s=D dump_s=D verify_s=D upload_s=D backup_error_s=D failed_phase=upload file=backup/appdb_TS.sql.gz" "backup result line when stopped during error hooks"
assert_eq "$(report_records "$REPORT" | sed 's/.*|begin backup-error/begin backup-error/')" "begin backup-error T|end backup-error T 143|" "error-hook phase records the stop signal"
reset_logs
mkdir -p "$WORKDIR/s3/test-bucket/backup"
printf 'SELECT 1;\n' | gzip > "$WORKDIR/s3/test-bucket/backup/appdb.sql.gz"
run_script restore.sh BACKUP_FILE=backup/appdb.sql.gz FAKE_PSQL_EXIT=3 "HOOKS_DIR=$TERM_HOOKS"
assert_eq "$?" "3" "restore exit code when stopped during error hooks"
if grep -q '^pgbackup-result operation=restore outcome=failure exit_code=3 ' "$WORKDIR/last.out"; then
  pass
else
  fail "restore result line missing when stopped during error hooks"
fi

# Restore: result line and report records, with drop and create.
reset_logs
mkdir -p "$WORKDIR/s3/test-bucket/backup"
printf 'SELECT 1;\n' | gzip > "$WORKDIR/s3/test-bucket/backup/appdb.sql.gz"
: > "$REPORT"
assert_ok run_script restore.sh BACKUP_FILE=backup/appdb.sql.gz DROP_DATABASE=yes CREATE_DATABASE=yes "PGBACKUP_TELEMETRY_FILE=$REPORT"
assert_eq "$(result_line)" "pgbackup-result operation=restore outcome=success exit_code=0 database=appdb duration_s=D pre_restore_s=D download_s=D drop_s=D create_s=D restore_s=D post_restore_s=D file=backup/appdb.sql.gz" "restore result line"
assert_eq "$(report_records "$REPORT")" "begin pre-restore T|end pre-restore T 0|set s3.key backup/appdb.sql.gz|begin download T|end download T 0|set encrypted no|set dump.format plain|begin drop T|end drop T 0|begin create T|end create T 0|begin restore T|end restore T 0|begin post-restore T|end post-restore T 0|" "restore report records"

# Restore of the latest encrypted backup reports the resolved key.
reset_logs
mkdir -p "$WORKDIR/s3/test-bucket/backup"
printf '2020-01-01 00:00:00         10 appdb_2025-01-01T00:00:00Z.sql.gz.enc\n' > "$WORKDIR/s3-ls.txt"
printf 'SELECT 1;\n' | gzip | openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt -pass pass:encpass > "$WORKDIR/s3/test-bucket/backup/appdb_2025-01-01T00:00:00Z.sql.gz.enc"
: > "$REPORT"
assert_ok run_script restore.sh BACKUP_FILE=latest ENCRYPTION_PASSWORD=encpass "PGBACKUP_TELEMETRY_FILE=$REPORT"
assert_eq "$(result_line)" "pgbackup-result operation=restore outcome=success exit_code=0 database=appdb duration_s=D resolve_s=D pre_restore_s=D download_s=D decrypt_s=D restore_s=D post_restore_s=D file=backup/appdb_TS.sql.gz.enc" "restore latest result line"
assert_eq "$(report_records "$REPORT")" "begin resolve T|end resolve T 0|begin pre-restore T|end pre-restore T 0|set s3.key backup/appdb_TS.sql.gz.enc|begin download T|end download T 0|set encrypted yes|begin decrypt T|end decrypt T 0|set dump.format plain|begin restore T|end restore T 0|begin post-restore T|end post-restore T 0|" "restore latest report records"

# A failed restore keeps its exit code and names the phase.
reset_logs
mkdir -p "$WORKDIR/s3/test-bucket/backup"
printf 'SELECT 1;\n' | gzip > "$WORKDIR/s3/test-bucket/backup/appdb.sql.gz"
run_script restore.sh BACKUP_FILE=backup/appdb.sql.gz FAKE_PSQL_EXIT=3
assert_eq "$?" "3" "restore exit code on failure"
assert_eq "$(result_line)" "pgbackup-result operation=restore outcome=failure exit_code=3 database=appdb duration_s=D pre_restore_s=D download_s=D restore_s=D restore_error_s=D failed_phase=restore file=backup/appdb.sql.gz" "restore result line on failure"

# Validation errors happen before the EXIT trap and print no result line.
assert_fail run_script restore.sh BACKUP_FILE="**None**"
assert_eq "$(result_line)" "" "no restore result line for validation errors"
assert_fail run_script backup.sh S3_BUCKET=
assert_eq "$(result_line)" "" "no backup result line for validation errors"

# The report file is written only when it exists and is not a symbolic link.
reset_logs
: > "$WORKDIR/report-target"
ln -s "$WORKDIR/report-target" "$WORKDIR/report-link"
assert_ok run_script backup.sh "PGBACKUP_TELEMETRY_FILE=$WORKDIR/report-link"
if [ -s "$WORKDIR/report-target" ]; then fail "report written through a symbolic link"; else pass; fi
assert_ok run_script backup.sh "PGBACKUP_TELEMETRY_FILE=$WORKDIR/missing-report"
if [ -e "$WORKDIR/missing-report" ]; then fail "missing report file was created"; else pass; fi
mkdir -p "$WORKDIR/report-dir"
assert_ok run_script backup.sh "PGBACKUP_TELEMETRY_FILE=$WORKDIR/report-dir"
assert_eq "$(ls -A "$WORKDIR/report-dir")" "" "report directory untouched"
assert_ok run_script backup.sh PGBACKUP_TELEMETRY_FILE=
if [ -n "$(result_line)" ]; then pass; else fail "result line missing without a report file"; fi
# A report file that cannot be written neither fails the run nor adds output.
if [ -f /proc/version ]; then
  assert_ok run_script backup.sh PGBACKUP_TELEMETRY_FILE=/proc/version
  if grep -qi 'error' "$WORKDIR/last.out"; then
    fail "report write error was printed:"
    cat "$WORKDIR/last.out" >&2
  else
    pass
  fi
fi

# Script hooks receive the trace context, and the backup size after the upload.
for ev in pre-backup post-backup; do
  printf '#! /bin/sh\nenv | sort > "%s/%s.env"\n' "$WORKDIR" "$ev" > "$HOOKS_DIR/$ev"
  chmod +x "$HOOKS_DIR/$ev"
done
rm -f "$WORKDIR/pre-backup.env" "$WORKDIR/post-backup.env"
reset_logs
TP=00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
assert_ok run_script backup.sh "TRACEPARENT=$TP" TRACESTATE=vendor=opaque BACKUP_SIZE_BYTES=999
SIZE=$(uploaded_size)
if grep -q "^TRACEPARENT=$TP\$" "$WORKDIR/post-backup.env" && grep -q '^TRACESTATE=vendor=opaque$' "$WORKDIR/post-backup.env" && grep -q "^BACKUP_SIZE_BYTES=$SIZE\$" "$WORKDIR/post-backup.env"; then
  pass
else
  fail "post-backup hook missing TRACEPARENT, TRACESTATE or BACKUP_SIZE_BYTES=$SIZE:"
  cat "$WORKDIR/post-backup.env" >&2
fi
# Before the upload the size is unknown, even when the container sets it.
if grep -q "^TRACEPARENT=$TP\$" "$WORKDIR/pre-backup.env" && ! grep -q '^BACKUP_SIZE_BYTES=' "$WORKDIR/pre-backup.env"; then
  pass
else
  fail "pre-backup hook environment:"
  cat "$WORKDIR/pre-backup.env" >&2
fi
rm -f "$HOOKS_DIR"/*

# A database name with a space is quoted in the result line.
reset_logs
assert_ok run_script backup.sh "POSTGRES_DATABASE=my db"
assert_eq "$(result_line)" 'pgbackup-result operation=backup outcome=success exit_code=0 database="my db" duration_s=D pre_backup_s=D dump_s=D verify_s=D upload_s=D post_backup_s=D size_bytes=N file="backup/my db_TS.sql.gz"' "result line quotes a database name with a space"

assert_eq "$(ls "$TMPDIR" | wc -l | tr -d ' ')" "0" "temp dir cleaned after phase 4 tests"
unset TMPDIR

echo "Passed: $PASS  Failed: $FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
