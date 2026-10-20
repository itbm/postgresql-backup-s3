#! /bin/sh

set -e
set -o pipefail

>&2 echo "-----"

. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/hooks.sh"

validate_common_env

if ! has_value "${BACKUP_FILE}"; then
  echo "You need to set the BACKUP_FILE environment variable with the backup filename to restore."
  echo "Use S3_PREFIX/filename format. Example: backup/database_0000-00-00T00:00:00Z.sql.gz"
  exit 1
fi

if has_value "${PARALLEL_JOBS}"; then
  is_positive_int "$PARALLEL_JOBS" || die "PARALLEL_JOBS must be a positive integer, got: ${PARALLEL_JOBS}"
else
  PARALLEL_JOBS=1
fi

# Stop plain-SQL restores at the first error so a partial restore is never
# reported as a success. pg_dumpall output routinely hits harmless errors
# (for example "role already exists"), so it stays permissive unless asked.
if has_value "${RESTORE_ON_ERROR_STOP}"; then
  case "$RESTORE_ON_ERROR_STOP" in
    yes|no) ;;
    *) die "RESTORE_ON_ERROR_STOP must be yes or no, got: ${RESTORE_ON_ERROR_STOP}" ;;
  esac
elif [ "${POSTGRES_DATABASE}" = "all" ]; then
  RESTORE_ON_ERROR_STOP=no
else
  RESTORE_ON_ERROR_STOP=yes
fi

setup_aws
setup_postgres
POSTGRES_DATABASE_IDENT=$(quote_ident "$POSTGRES_DATABASE")
POSTGRES_DATABASE_LITERAL=$(quote_literal "$POSTGRES_DATABASE")
POSTGRES_DATABASE_CONNINFO=$(conninfo_dbname "$POSTGRES_DATABASE")

PSQL_RESTORE_OPTS=""
if [ "$RESTORE_ON_ERROR_STOP" = "yes" ]; then
  PSQL_RESTORE_OPTS="-v ON_ERROR_STOP=1"
fi

# Runs a single admin statement against the postgres database and fails on error.
psql_admin() {
  psql $POSTGRES_HOST_OPTS -d postgres -v ON_ERROR_STOP=1 -Atq -c "$1"
}

# pg_dump 17 and later put "SET transaction_timeout = 0;" in the header of every
# plain dump, and PostgreSQL 16 and older reject it, which stops a restore with
# ON_ERROR_STOP. Drops that line where pg_dump writes it, right after its other
# timeout settings in each database's header, so table data and function bodies
# are never changed.
strip_transaction_timeout() {
  awk '
    $0 == "SET transaction_timeout = 0;" && p1 == "SET idle_in_transaction_session_timeout = 0;" &&
      p2 == "SET lock_timeout = 0;" && p3 == "SET statement_timeout = 0;" { next }
    { print; p3 = p2; p2 = p1; p1 = $0 }
  '
}

# Prints the server_version_num of the server, connecting to database $1.
# Expanded output (psql -x in POSTGRES_EXTRA_OPTS) prints it as "name|value".
server_version_num() {
  _version=$(psql $POSTGRES_HOST_OPTS -d "$1" -Atq -c "SHOW server_version_num")
  printf '%s\n' "${_version##*|}"
}

# Writes the plain SQL backup to stdout, ready for psql on a server whose
# server_version_num is $1.
plain_sql() {
  if is_positive_int "$1" && [ "$1" -lt 170000 ]; then
    $DECOMPRESSION_CMD "$DOWNLOAD_PATH" | strip_transaction_timeout
  else
    $DECOMPRESSION_CMD "$DOWNLOAD_PATH"
  fi
}

# Sets BACKUP_FILE to the newest <POSTGRES_DATABASE>_<timestamp> backup in S3_PREFIX.
resolve_latest_backup() {
  echo "Finding the latest backup of ${POSTGRES_DATABASE} in ${S3_BASE_URI}"
  aws $AWS_ARGS s3 ls "$S3_BASE_URI" > "$WORK_DIR/s3-listing" || exit 2
  latest=""
  while IFS= read -r line; do
    parse_s3_ls_line "$line" || continue
    name=$S3_LS_NAME
    is_database_backup "$name" || continue
    echo "$name" >> "$WORK_DIR/candidates"
  done < "$WORK_DIR/s3-listing"
  # UTC ISO 8601 timestamps sort chronologically as strings.
  if [ -f "$WORK_DIR/candidates" ]; then
    latest=$(sort "$WORK_DIR/candidates" | tail -n 1)
  fi
  if [ -z "$latest" ]; then
    echo "ERROR: No backups of ${POSTGRES_DATABASE} found in ${S3_BASE_URI}"
    exit 1
  fi
  BACKUP_FILE="${S3_PREFIX_PATH:+${S3_PREFIX_PATH}/}${latest}"
  export BACKUP_FILE
  echo "Latest backup is ${BACKUP_FILE}"
}

# AES-CBC has no integrity check, so a wrong password or key derivation
# decrypts without an error about 1 time in 256 and gives garbage. Accepts a
# decrypted file only if it reads as a backup, and keeps the reason if not.
decrypted_backup_readable() {
  case "$DECRYPTED_PATH" in
    *.dump) pg_restore --list "$DECRYPTED_PATH" >/dev/null 2> "$WORK_DIR/decrypt-check.err" ;;
    *.sql.gz) $DECOMPRESSION_CMD "$DECRYPTED_PATH" >/dev/null 2> "$WORK_DIR/decrypt-check.err" ;;
    # Any other name is rejected as an unsupported format after decryption.
    *) return 0 ;;
  esac
}

# Runs pg_restore with the given arguments. pg_restore 17 and later set
# transaction_timeout on each connection, which PostgreSQL 16 and older reject;
# pg_restore carries on and exits 1 at the end. A restore whose only errors are
# that setting succeeded, unless pg_restore stopped at the first one
# (--single-transaction), in which case it does not report errors as ignored.
run_pg_restore() {
  _rc=0
  # Show pg_restore's messages as they come and keep a copy to check.
  { { pg_restore "$@" 2>&1 1>&3 | tee "$WORK_DIR/pg_restore.err" >&2; } 3>&1; } || _rc=$?
  if [ "$_rc" -ne 1 ]; then
    return "$_rc"
  fi
  _errors=$(grep -c '^pg_restore: error: ' "$WORK_DIR/pg_restore.err" || true)
  _timeouts=$(grep -c '^Command was: SET transaction_timeout = 0;$' "$WORK_DIR/pg_restore.err" || true)
  if [ "$_timeouts" -gt 0 ] && [ "$_errors" -eq "$_timeouts" ] \
    && grep -q '^pg_restore: warning: errors ignored on restore: ' "$WORK_DIR/pg_restore.err"; then
    echo "Ignored ${_errors} error(s) from SET transaction_timeout, which this PostgreSQL server does not support"
    return 0
  fi
  return "$_rc"
}

restore_on_exit() {
  rc=$?
  trap - EXIT
  set +e
  if [ -n "$WORK_DIR" ]; then
    echo "Cleaning up temporary files"
  fi
  remove_work_dir
  if [ "$rc" -ne 0 ]; then
    run_error_hooks restore-error "$rc"
  fi
  exit "$rc"
}
trap restore_on_exit EXIT
# Turn SIGTERM/SIGINT into a normal exit so the EXIT trap cleans up and fires error hooks.
trap 'exit 143' TERM
trap 'exit 130' INT

make_work_dir

if [ "$BACKUP_FILE" = "latest" ]; then
  resolve_latest_backup
fi

# Not basename, which would read a name starting with "-" as options.
LOCAL_FILE=${BACKUP_FILE##*/}
DOWNLOAD_PATH="$WORK_DIR/$LOCAL_FILE"

run_hooks pre-restore

echo "Downloading backup file from S3: s3://${S3_BUCKET}/${BACKUP_FILE}"
aws $AWS_ARGS s3 cp "s3://${S3_BUCKET}/${BACKUP_FILE}" "$DOWNLOAD_PATH" || exit 2

case "$LOCAL_FILE" in
  *.enc)
    if ! has_value "${ENCRYPTION_PASSWORD}"; then
      echo "Backup file is encrypted. You need to set the ENCRYPTION_PASSWORD environment variable."
      exit 1
    fi

    echo "Decrypting backup file"
    ENCRYPTED_PATH="$DOWNLOAD_PATH"
    DECRYPTED_PATH="${DOWNLOAD_PATH%.enc}"
    # Prefer PBKDF2 (current format); fall back to legacy OpenSSL key derivation.
    if openssl enc -aes-256-cbc -d -pbkdf2 -iter 100000 -in "$ENCRYPTED_PATH" -out "$DECRYPTED_PATH" -pass env:ENCRYPTION_PASSWORD 2>/dev/null \
      && decrypted_backup_readable; then
      :
    elif openssl enc -aes-256-cbc -d -in "$ENCRYPTED_PATH" -out "$DECRYPTED_PATH" -pass env:ENCRYPTION_PASSWORD \
      && decrypted_backup_readable; then
      echo "WARNING: Decrypted legacy OpenSSL backup (non-PBKDF2). Re-backup to upgrade encryption."
    else
      echo "Error decrypting backup file. Check your encryption password."
      if [ -s "$WORK_DIR/decrypt-check.err" ]; then
        echo "A decryption passed OpenSSL's check but is not a readable backup:"
        cat "$WORK_DIR/decrypt-check.err"
      fi
      exit 1
    fi
    rm -f "$ENCRYPTED_PATH"
    DOWNLOAD_PATH=$DECRYPTED_PATH
    ;;
esac

case "$DOWNLOAD_PATH" in
  *.sql.gz|*.dump) ;;
  *)
    echo "ERROR: Unsupported backup format. Expected *.sql.gz or *.dump file."
    exit 1
    ;;
esac

echo "Restoring database ${POSTGRES_DATABASE} on ${POSTGRES_HOST}"

if [ "${DROP_DATABASE}" = "yes" ]; then
  if [ "${POSTGRES_DATABASE}" = "all" ]; then
    echo "Cannot drop all databases. Please specify a single database to drop."
    exit 1
  fi
  echo "Dropping database ${POSTGRES_DATABASE}"
  server_version_num=$(psql_admin "SHOW server_version_num")
  if [ "$server_version_num" -ge 130000 ]; then
    drop_sql="DROP DATABASE IF EXISTS ${POSTGRES_DATABASE_IDENT} WITH (FORCE);"
  else
    drop_sql="DROP DATABASE IF EXISTS ${POSTGRES_DATABASE_IDENT};"
  fi
  if ! psql_admin "$drop_sql"; then
    echo "ERROR: Failed to drop database ${POSTGRES_DATABASE}."
    exit 1
  fi
fi

if [ "${CREATE_DATABASE}" = "yes" ]; then
  if [ "${POSTGRES_DATABASE}" = "all" ]; then
    echo "Cannot create all databases. Please specify a single database to create."
    exit 1
  fi
  db_exists=$(psql_admin "SELECT 1 FROM pg_database WHERE datname = ${POSTGRES_DATABASE_LITERAL}")
  if [ "$db_exists" = "1" ]; then
    echo "Database ${POSTGRES_DATABASE} already exists; not creating it"
  else
    echo "Creating database ${POSTGRES_DATABASE}"
    if ! psql_admin "CREATE DATABASE ${POSTGRES_DATABASE_IDENT};"; then
      echo "ERROR: Failed to create database ${POSTGRES_DATABASE}."
      exit 1
    fi
  fi
fi

case "$DOWNLOAD_PATH" in
  *.sql.gz)
    if [ "${POSTGRES_DATABASE}" = "all" ]; then
      echo "Restoring all databases"
      version=$(server_version_num postgres)
      plain_sql "$version" | psql $POSTGRES_HOST_OPTS $PSQL_RESTORE_OPTS -d postgres
    else
      echo "Restoring database ${POSTGRES_DATABASE}"
      version=$(server_version_num "$POSTGRES_DATABASE_CONNINFO")
      plain_sql "$version" | psql $POSTGRES_HOST_OPTS $PSQL_RESTORE_OPTS -d "$POSTGRES_DATABASE_CONNINFO"
    fi
    ;;
  *.dump)
    if [ "${POSTGRES_DATABASE}" = "all" ]; then
      echo "ERROR: Custom format backup cannot be used to restore all databases."
      exit 1
    fi
    echo "Restoring database ${POSTGRES_DATABASE} from custom format"
    if [ "$PARALLEL_JOBS" -gt 1 ]; then
      echo "Using parallel restore with $PARALLEL_JOBS jobs"
      run_pg_restore -j "$PARALLEL_JOBS" $POSTGRES_HOST_OPTS -d "$POSTGRES_DATABASE_CONNINFO" "$DOWNLOAD_PATH"
    else
      run_pg_restore $POSTGRES_HOST_OPTS -d "$POSTGRES_DATABASE_CONNINFO" "$DOWNLOAD_PATH"
    fi
    ;;
esac

echo "Database restore completed successfully"

run_hooks post-restore

>&2 echo "-----"
