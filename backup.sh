#! /bin/sh

set -e
set -o pipefail

>&2 echo "-----"

has_value() {
  [ -n "$1" ] && [ "$1" != "**None**" ]
}

. "$(dirname "$0")/hooks.sh"

set_backup_uri() {
  BACKUP_DEST_FILE=$DEST_FILE
  BACKUP_S3_URI="s3://${S3_BUCKET}/${S3_PREFIX}/${DEST_FILE}"
  export BACKUP_DEST_FILE BACKUP_S3_URI
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

if [ "${S3_SSL_VERIFY}" = "no" ]; then
  AWS_ARGS="$AWS_ARGS --no-verify-ssl"
fi

# Avoid AWS CLI v2 default checksum behaviour that breaks many S3-compatible
# endpoints and some streaming uploads (XAmzContentSHA256Mismatch).
export AWS_REQUEST_CHECKSUM_CALCULATION="${AWS_REQUEST_CHECKSUM_CALCULATION:-when_required}"
export AWS_RESPONSE_CHECKSUM_VALIDATION="${AWS_RESPONSE_CHECKSUM_VALIDATION:-when_required}"

export AWS_DEFAULT_REGION=$S3_REGION

export PGPASSWORD=$POSTGRES_PASSWORD
POSTGRES_HOST_OPTS="-h $POSTGRES_HOST -p $POSTGRES_PORT -U $POSTGRES_USER $POSTGRES_EXTRA_OPTS"
POSTGRES_DUMP_OPTS="$POSTGRES_EXTRA_DUMP_OPTS"

cleanup_src() {
  if [ -n "$SRC_FILE" ]; then
    rm -f "$SRC_FILE"
  fi
  rm -f /tmp/s3-listing
}

backup_on_exit() {
  rc=$?
  trap - EXIT
  set +e
  cleanup_src
  if [ "$rc" -ne 0 ]; then
    run_error_hooks backup-error "$rc"
  fi
  exit "$rc"
}
trap backup_on_exit EXIT

run_hooks pre-backup

echo "Creating dump of ${POSTGRES_DATABASE} database from ${POSTGRES_HOST}..."

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

if [ "$USE_CUSTOM_FORMAT" = "yes" ]; then
  SRC_FILE=/tmp/dump.dump
  DEST_FILE="${POSTGRES_DATABASE}_${TIMESTAMP}.dump"
  set_backup_uri
  rm -f "$SRC_FILE"

  if [ "${POSTGRES_DATABASE}" = "all" ]; then
    echo "ERROR: Custom format (-Fc) is not supported with pg_dumpall."
    exit 1
  else
    pg_dump -Fc $POSTGRES_HOST_OPTS $POSTGRES_DUMP_OPTS "$POSTGRES_DATABASE" > "$SRC_FILE"
  fi
else
  SRC_FILE=/tmp/dump.sql.gz
  DEST_FILE="${POSTGRES_DATABASE}_${TIMESTAMP}.sql.gz"
  set_backup_uri
  rm -f "$SRC_FILE"

  if [ "${POSTGRES_DATABASE}" = "all" ]; then
    pg_dumpall $POSTGRES_HOST_OPTS $POSTGRES_DUMP_OPTS | $COMPRESSION_CMD > "$SRC_FILE"
  else
    pg_dump $POSTGRES_HOST_OPTS $POSTGRES_DUMP_OPTS "$POSTGRES_DATABASE" | $COMPRESSION_CMD > "$SRC_FILE"
  fi
fi

if [ "${ENCRYPTION_PASSWORD}" != "**None**" ]; then
  >&2 echo "Encrypting ${SRC_FILE}"
  if ! openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt -in "$SRC_FILE" -out "${SRC_FILE}.enc" -pass env:ENCRYPTION_PASSWORD; then
    >&2 echo "Error encrypting ${SRC_FILE}"
    exit 1
  fi
  rm -f "$SRC_FILE"
  SRC_FILE="${SRC_FILE}.enc"
  DEST_FILE="${DEST_FILE}.enc"
  set_backup_uri
fi

echo "Uploading dump to $S3_BUCKET"

aws $AWS_ARGS s3 cp "$SRC_FILE" "s3://${S3_BUCKET}/${S3_PREFIX}/${DEST_FILE}" || exit 2
rm -f "$SRC_FILE"
SRC_FILE=""

if [ "${DELETE_OLDER_THAN}" != "**None**" ]; then
  >&2 echo "Checking for files older than ${DELETE_OLDER_THAN}"
  older_than=`date -d "$DELETE_OLDER_THAN" +%s`
  listing_file=/tmp/s3-listing
  aws $AWS_ARGS s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/" > "$listing_file" || exit 2
  while IFS= read -r line
    do
      [ -n "$line" ] || continue
      case "$line" in
        *' PRE '*) continue ;;
      esac
      fileName=`echo "$line" | awk '{ $1=$2=$3=""; sub(/^ +/, ""); print }'`
      created=`echo "$line" | awk '{print $1" "$2}'`
      created=`date -d "$created" +%s`
      if [ "$created" -lt "$older_than" ]
        then
          if [ -n "$fileName" ]
            then
              >&2 echo "DELETING ${fileName}"
              aws $AWS_ARGS s3 rm "s3://${S3_BUCKET}/${S3_PREFIX}/${fileName}"
          fi
      else
          >&2 echo "${fileName} not older than ${DELETE_OLDER_THAN}"
      fi
    done < "$listing_file"
  rm -f "$listing_file"
fi

echo "SQL backup finished"

run_hooks post-backup

>&2 echo "-----"
