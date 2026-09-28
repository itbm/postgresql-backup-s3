#! /bin/sh
# Tests for hooks.sh and backup/restore hook points.
# Run from anywhere: sh test/hooks_test.sh

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
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
cat > "$FAKE_BIN/curl" <<EOF
#! /bin/sh
printf '%s\n' "\$*" >> "$CURL_LOG"
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

# --- backup.sh / restore.sh hook points with fake tools ---

write_fakes() {
  cat > "$FAKE_BIN/pg_dump" <<'EOF'
#! /bin/sh
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
  src=\$1
  dest=\$2
  if [ -f "\$src" ]; then
    rel=\${dest#s3://}
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
  exit 0
fi
if [ "\$cmd" = rm ]; then
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
    cd "$ROOT"
    PATH="$FAKE_BIN:$PATH"
    common_env
    export HOOK_DROP_PRIVS=no HOOK_INHERIT_ENV=no
    for _kv in "$@"; do
      export "$_kv"
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
printf '#! /bin/sh\necho GOCRON "$1"\n' > "$FAKE_BIN/go-cron"
printf '#! /bin/sh\nexit 0\n' > "$FAKE_BIN/update-ca-certificates"
chmod +x "$FAKE_BIN/go-cron" "$FAKE_BIN/update-ca-certificates"
run_entry() {
  (
    cd "$RUN_DIR"
    PATH="$FAKE_BIN:$PATH"
    export BACKUP_FILE="$1" SCHEDULE="$2" S3_S3V4=no S3_CA_BUNDLE=
    sh "$ROOT/run.sh"
  ) 2>&1
}
assert_eq "$(run_entry '' '')" "BACKUP" "run.sh empty SCHEDULE"
assert_eq "$(run_entry '**None**' '@daily')" "GOCRON @daily" "run.sh with SCHEDULE"
assert_eq "$(run_entry 'backup/x.sql.gz' '@daily')" "RESTORE" "run.sh with BACKUP_FILE"
unset TMPDIR

echo "Passed: $PASS  Failed: $FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
