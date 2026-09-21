#! /bin/sh

set -e
set -o pipefail

>&2 echo "-----"

quote_ident() {
  printf '"%s"' "$(printf '%s' "$1" | sed 's/"/""/g')"
}

has_value() {
  [ -n "$1" ] && [ "$1" != "**None**" ]
}

. "$(dirname "$0")/hooks.sh"

cleanup() {
  if [ -n "$ENCRYPTED_PATH" ] || [ -n "$DECRYPTED_PATH" ] || [ -n "$DOWNLOAD_PATH" ]; then
    echo "Cleaning up temporary files"
  fi
  if [ -n "$ENCRYPTED_PATH" ]; then
    rm -f "$ENCRYPTED_PATH"
  fi
  if [ -n "$DECRYPTED_PATH" ]; then
    rm -f "$DECRYPTED_PATH"
  fi
  if [ -n "$DOWNLOAD_PATH" ]; then
    rm -f "$DOWNLOAD_PATH"
  fi
}

if [ "${S3_BUCKET}" = "**None**" ]; then
  echo "You need to set the S3_BUCKET environment variable."
  exit 1
fi

if [ "${POSTGRES_DATABASE}" = "**None**" ]; then
  echo "You need to set the POSTGRES_DATABASE environment variable."
  exit 1
fi

if [ "${POSTGRES_HOST}" = "**None**" ]; then
  if [ -n "${POSTGRES_PORT_5432_TCP_ADDR}" ]; then
    POSTGRES_HOST=$POSTGRES_PORT_5432_TCP_ADDR
    POSTGRES_PORT=$POSTGRES_PORT_5432_TCP_PORT
  else
    echo "You need to set the POSTGRES_HOST environment variable."
    exit 1
  fi
fi

if [ "${POSTGRES_USER}" = "**None**" ]; then
  echo "You need to set the POSTGRES_USER environment variable."
  exit 1
fi

if [ "${POSTGRES_PASSWORD}" = "**None**" ]; then
  echo "You need to set the POSTGRES_PASSWORD environment variable or link to a container named POSTGRES."
  exit 1
fi

if has_value "${S3_ACCESS_KEY_ID}"; then
  if ! has_value "${S3_SECRET_ACCESS_KEY}"; then
    echo "You need to set the S3_SECRET_ACCESS_KEY environment variable."
    exit 1
  fi
  export AWS_ACCESS_KEY_ID=$S3_ACCESS_KEY_ID
  export AWS_SECRET_ACCESS_KEY=$S3_SECRET_ACCESS_KEY
elif has_value "${S3_SECRET_ACCESS_KEY}"; then
  echo "You need to set the S3_ACCESS_KEY_ID environment variable."
  exit 1
fi

if [ "${S3_ENDPOINT}" = "**None**" ]; then
  AWS_ARGS=""
else
  AWS_ARGS="--endpoint-url ${S3_ENDPOINT}"
fi

if [ "${BACKUP_FILE}" = "**None**" ]; then
  echo "You need to set the BACKUP_FILE environment variable with the backup filename to restore."
  echo "Use S3_PREFIX/filename format. Example: backup/database_0000-00-00T00:00:00Z.sql.gz"
  exit 1
fi

# Avoid AWS CLI v2 default checksum behaviour that breaks many S3-compatible
# endpoints and some streaming uploads (XAmzContentSHA256Mismatch).
export AWS_REQUEST_CHECKSUM_CALCULATION="${AWS_REQUEST_CHECKSUM_CALCULATION:-when_required}"
export AWS_RESPONSE_CHECKSUM_VALIDATION="${AWS_RESPONSE_CHECKSUM_VALIDATION:-when_required}"

export AWS_DEFAULT_REGION=$S3_REGION

export PGPASSWORD=$POSTGRES_PASSWORD
POSTGRES_HOST_OPTS="-h $POSTGRES_HOST -p $POSTGRES_PORT -U $POSTGRES_USER $POSTGRES_EXTRA_OPTS"
POSTGRES_DATABASE_IDENT=$(quote_ident "$POSTGRES_DATABASE")

LOCAL_FILE=$(basename "$BACKUP_FILE")
DOWNLOAD_PATH="/tmp/$LOCAL_FILE"
ENCRYPTED_PATH=""
DECRYPTED_PATH=""

restore_on_exit() {
  rc=$?
  trap - EXIT
  set +e
  cleanup
  if [ "$rc" -ne 0 ]; then
    run_error_hooks restore-error "$rc"
  fi
  exit "$rc"
}
trap restore_on_exit EXIT

run_hooks pre-restore

echo "Downloading backup file from S3: s3://${S3_BUCKET}/${BACKUP_FILE}"
aws $AWS_ARGS s3 cp "s3://${S3_BUCKET}/${BACKUP_FILE}" "$DOWNLOAD_PATH" || exit 2

case "$LOCAL_FILE" in
  *.enc)
    if [ "${ENCRYPTION_PASSWORD}" = "**None**" ]; then
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
    DOWNLOAD_PATH=$DECRYPTED_PATH
    ;;
esac

echo "Restoring database ${POSTGRES_DATABASE} on ${POSTGRES_HOST}"

if [ "${DROP_DATABASE}" = "yes" ]; then
  if [ "${POSTGRES_DATABASE}" = "all" ]; then
    echo "Cannot drop all databases. Please specify a single database to drop."
    exit 1
  fi
  echo "Dropping database ${POSTGRES_DATABASE}"
  if ! psql $POSTGRES_HOST_OPTS -d postgres -c "DROP DATABASE IF EXISTS ${POSTGRES_DATABASE_IDENT} WITH (FORCE);" > /dev/null 2>&1; then
    if ! psql $POSTGRES_HOST_OPTS -d postgres -c "DROP DATABASE IF EXISTS ${POSTGRES_DATABASE_IDENT};" > /dev/null 2>&1; then
      echo "WARNING: Failed to drop database ${POSTGRES_DATABASE}."
    fi
  fi
fi

if [ "${CREATE_DATABASE}" = "yes" ]; then
  if [ "${POSTGRES_DATABASE}" = "all" ]; then
    echo "Cannot create all databases. Please specify a single database to create."
    exit 1
  fi
  echo "Creating database ${POSTGRES_DATABASE}"
  if ! psql $POSTGRES_HOST_OPTS -d postgres -c "CREATE DATABASE ${POSTGRES_DATABASE_IDENT};" > /dev/null 2>&1; then
    echo "WARNING: Failed to create database ${POSTGRES_DATABASE}. It might already exist."
  fi
fi

case "$DOWNLOAD_PATH" in
  *.sql.gz)
    if [ "${POSTGRES_DATABASE}" = "all" ]; then
      echo "Restoring all databases"
      $DECOMPRESSION_CMD "$DOWNLOAD_PATH" | psql $POSTGRES_HOST_OPTS -d postgres
    else
      echo "Restoring database ${POSTGRES_DATABASE}"
      $DECOMPRESSION_CMD "$DOWNLOAD_PATH" | psql $POSTGRES_HOST_OPTS -d "$POSTGRES_DATABASE"
    fi
    ;;
  *.dump)
    if [ "${POSTGRES_DATABASE}" = "all" ]; then
      echo "ERROR: Custom format backup cannot be used to restore all databases."
      exit 1
    else
      echo "Restoring database ${POSTGRES_DATABASE} from custom format"
      if [ "$PARALLEL_JOBS" -gt 1 ]; then
        echo "Using parallel restore with $PARALLEL_JOBS jobs"
        pg_restore -j "$PARALLEL_JOBS" $POSTGRES_HOST_OPTS -d "$POSTGRES_DATABASE" "$DOWNLOAD_PATH"
      else
        pg_restore $POSTGRES_HOST_OPTS -d "$POSTGRES_DATABASE" "$DOWNLOAD_PATH"
      fi
    fi
    ;;
  *)
    echo "ERROR: Unsupported backup format. Expected *.sql.gz or *.dump file."
    exit 1
    ;;
esac

echo "Database restore completed successfully"

run_hooks post-restore

>&2 echo "-----"
