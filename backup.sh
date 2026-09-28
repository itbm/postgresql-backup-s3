#! /bin/sh

set -e
set -o pipefail

>&2 echo "-----"

. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/hooks.sh"

set_backup_uri() {
  BACKUP_DEST_FILE=$DEST_FILE
  BACKUP_S3_URI="${S3_BASE_URI}${DEST_FILE}"
  export BACKUP_DEST_FILE BACKUP_S3_URI
}

validate_common_env

if has_value "${DELETE_OLDER_THAN}"; then
  if ! older_than=$(date -d "$DELETE_OLDER_THAN" +%s 2>/dev/null); then
    die "DELETE_OLDER_THAN is not a valid date expression: ${DELETE_OLDER_THAN}"
  fi
fi

setup_aws
setup_postgres
POSTGRES_DUMP_OPTS="$POSTGRES_EXTRA_DUMP_OPTS"

backup_on_exit() {
  rc=$?
  trap - EXIT
  set +e
  remove_work_dir
  if [ "$rc" -ne 0 ]; then
    run_error_hooks backup-error "$rc"
  fi
  exit "$rc"
}
trap backup_on_exit EXIT
# Turn SIGTERM/SIGINT into a normal exit so the EXIT trap cleans up and fires error hooks.
trap 'exit 143' TERM
trap 'exit 130' INT

make_work_dir

run_hooks pre-backup

echo "Creating dump of ${POSTGRES_DATABASE} database from ${POSTGRES_HOST}..."

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

if [ "$USE_CUSTOM_FORMAT" = "yes" ]; then
  SRC_FILE="$WORK_DIR/dump.dump"
  DEST_FILE="${POSTGRES_DATABASE}_${TIMESTAMP}.dump"
  set_backup_uri

  if [ "${POSTGRES_DATABASE}" = "all" ]; then
    echo "ERROR: Custom format (-Fc) is not supported with pg_dumpall."
    exit 1
  else
    pg_dump -Fc $POSTGRES_HOST_OPTS $POSTGRES_DUMP_OPTS "$POSTGRES_DATABASE" > "$SRC_FILE"
  fi
else
  SRC_FILE="$WORK_DIR/dump.sql.gz"
  DEST_FILE="${POSTGRES_DATABASE}_${TIMESTAMP}.sql.gz"
  set_backup_uri

  if [ "${POSTGRES_DATABASE}" = "all" ]; then
    pg_dumpall $POSTGRES_HOST_OPTS $POSTGRES_DUMP_OPTS | $COMPRESSION_CMD > "$SRC_FILE"
  else
    pg_dump $POSTGRES_HOST_OPTS $POSTGRES_DUMP_OPTS "$POSTGRES_DATABASE" | $COMPRESSION_CMD > "$SRC_FILE"
  fi
fi

if has_value "${ENCRYPTION_PASSWORD}"; then
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

aws $AWS_ARGS s3 cp "$SRC_FILE" "$BACKUP_S3_URI" || exit 2
rm -f "$SRC_FILE"

if has_value "${DELETE_OLDER_THAN}"; then
  >&2 echo "Checking for files older than ${DELETE_OLDER_THAN}"
  listing_file="$WORK_DIR/s3-listing"
  aws $AWS_ARGS s3 ls "$S3_BASE_URI" > "$listing_file" || exit 2
  while IFS= read -r line
    do
      [ -n "$line" ] || continue
      case "$line" in
        *' PRE '*) continue ;;
      esac
      fileName=$(echo "$line" | awk '{ $1=$2=$3=""; sub(/^ +/, ""); print }')
      created=$(echo "$line" | awk '{print $1" "$2}')
      created=$(date -d "$created" +%s)
      if [ "$created" -lt "$older_than" ]
        then
          if [ -n "$fileName" ]
            then
              >&2 echo "DELETING ${fileName}"
              aws $AWS_ARGS s3 rm "${S3_BASE_URI}${fileName}"
          fi
      else
          >&2 echo "${fileName} not older than ${DELETE_OLDER_THAN}"
      fi
    done < "$listing_file"
fi

echo "SQL backup finished"

run_hooks post-backup

>&2 echo "-----"
