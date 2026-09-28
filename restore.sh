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

PSQL_RESTORE_OPTS=""
if [ "$RESTORE_ON_ERROR_STOP" = "yes" ]; then
  PSQL_RESTORE_OPTS="-v ON_ERROR_STOP=1"
fi

# Runs a single admin statement against the postgres database and fails on error.
psql_admin() {
  psql $POSTGRES_HOST_OPTS -d postgres -v ON_ERROR_STOP=1 -Atq -c "$1"
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

LOCAL_FILE=$(basename "$BACKUP_FILE")
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
    if ! openssl enc -aes-256-cbc -d -pbkdf2 -iter 100000 -in "$ENCRYPTED_PATH" -out "$DECRYPTED_PATH" -pass env:ENCRYPTION_PASSWORD 2>/dev/null; then
      if ! openssl enc -aes-256-cbc -d -in "$ENCRYPTED_PATH" -out "$DECRYPTED_PATH" -pass env:ENCRYPTION_PASSWORD; then
        echo "Error decrypting backup file. Check your encryption password."
        exit 1
      fi
      echo "WARNING: Decrypted legacy OpenSSL backup (non-PBKDF2). Re-backup to upgrade encryption."
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
      $DECOMPRESSION_CMD "$DOWNLOAD_PATH" | psql $POSTGRES_HOST_OPTS $PSQL_RESTORE_OPTS -d postgres
    else
      echo "Restoring database ${POSTGRES_DATABASE}"
      $DECOMPRESSION_CMD "$DOWNLOAD_PATH" | psql $POSTGRES_HOST_OPTS $PSQL_RESTORE_OPTS -d "$POSTGRES_DATABASE"
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
      pg_restore -j "$PARALLEL_JOBS" $POSTGRES_HOST_OPTS -d "$POSTGRES_DATABASE" "$DOWNLOAD_PATH"
    else
      pg_restore $POSTGRES_HOST_OPTS -d "$POSTGRES_DATABASE" "$DOWNLOAD_PATH"
    fi
    ;;
esac

echo "Database restore completed successfully"

run_hooks post-restore

>&2 echo "-----"
