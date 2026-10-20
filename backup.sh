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

# compression_name prints the compressor's name: the base name of the first
# word of COMPRESSION_CMD.
compression_name() {
  set -- $COMPRESSION_CMD
  basename "$1"
}

verify_dump() {
  if [ ! -s "$SRC_FILE" ]; then
    echo "ERROR: The dump file is empty; not uploading it."
    exit 1
  fi
  if [ "$USE_CUSTOM_FORMAT" = "yes" ]; then
    if ! pg_restore --list "$SRC_FILE" >/dev/null; then
      echo "ERROR: The custom-format dump failed verification; not uploading it."
      exit 1
    fi
    return 0
  fi
  # Only gzip output can be checked; other compressors are uploaded as they are.
  case "$(compression_name)" in
    gzip|pigz)
      if ! gzip -t "$SRC_FILE"; then
        echo "ERROR: The compressed dump failed verification; not uploading it."
        exit 1
      fi
      ;;
  esac
}

validate_common_env

if has_value "${DELETE_OLDER_THAN}"; then
  if ! older_than=$(date -d "$DELETE_OLDER_THAN" +%s 2>/dev/null); then
    die "DELETE_OLDER_THAN is not a valid date expression: ${DELETE_OLDER_THAN}"
  fi
fi

UPLOAD_ARGS=""
if has_value "${S3_STORAGE_CLASS}"; then
  UPLOAD_ARGS="--storage-class ${S3_STORAGE_CLASS}"
fi
if has_value "${S3_SSE}"; then
  case "$S3_SSE" in
    AES256|aws:kms|aws:kms:dsse) ;;
    *) die "S3_SSE must be AES256, aws:kms or aws:kms:dsse, got: ${S3_SSE}" ;;
  esac
  UPLOAD_ARGS="$UPLOAD_ARGS --sse ${S3_SSE}"
fi
if has_value "${S3_SSE_KMS_KEY_ID}"; then
  case "${S3_SSE}" in
    aws:kms|aws:kms:dsse) ;;
    *) die "S3_SSE_KMS_KEY_ID requires S3_SSE=aws:kms or S3_SSE=aws:kms:dsse." ;;
  esac
  UPLOAD_ARGS="$UPLOAD_ARGS --sse-kms-key-id ${S3_SSE_KMS_KEY_ID}"
fi

setup_aws
setup_postgres
POSTGRES_DUMP_OPTS="$POSTGRES_EXTRA_DUMP_OPTS"

backup_on_exit() {
  rc=$?
  trap - EXIT
  set +e
  # A phase still open here was interrupted; it ends with the exit code.
  phase_end "$rc"
  remove_work_dir
  if [ "$rc" -ne 0 ]; then
    phase_begin backup-error
    run_error_hooks backup-error "$rc"
    phase_end 0
  fi
  print_result_line backup "$rc"
  exit "$rc"
}
RUN_START_NS=$(now_ns)
trap backup_on_exit EXIT
# Turn SIGTERM/SIGINT into a normal exit so the EXIT trap cleans up and fires error hooks.
trap 'exit 143' TERM
trap 'exit 130' INT

make_work_dir

phase_begin pre-backup
run_hooks pre-backup
phase_end

echo "Creating dump of ${POSTGRES_DATABASE} database from ${POSTGRES_HOST}..."

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

phase_begin dump
if [ "$USE_CUSTOM_FORMAT" = "yes" ]; then
  report_set dump.format custom
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
  report_set dump.format plain
  report_set compression "$(compression_name)"
  SRC_FILE="$WORK_DIR/dump.sql.gz"
  DEST_FILE="${POSTGRES_DATABASE}_${TIMESTAMP}.sql.gz"
  set_backup_uri

  if [ "${POSTGRES_DATABASE}" = "all" ]; then
    pg_dumpall $POSTGRES_HOST_OPTS $POSTGRES_DUMP_OPTS | $COMPRESSION_CMD > "$SRC_FILE"
  else
    pg_dump $POSTGRES_HOST_OPTS $POSTGRES_DUMP_OPTS "$POSTGRES_DATABASE" | $COMPRESSION_CMD > "$SRC_FILE"
  fi
fi
phase_end

phase_begin verify
verify_dump
phase_end

if has_value "${ENCRYPTION_PASSWORD}"; then
  report_set encrypted yes
  phase_begin encrypt
  >&2 echo "Encrypting ${SRC_FILE}"
  if ! openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt -in "$SRC_FILE" -out "${SRC_FILE}.enc" -pass env:ENCRYPTION_PASSWORD; then
    >&2 echo "Error encrypting ${SRC_FILE}"
    exit 1
  fi
  rm -f "$SRC_FILE"
  SRC_FILE="${SRC_FILE}.enc"
  DEST_FILE="${DEST_FILE}.enc"
  set_backup_uri
  phase_end
else
  report_set encrypted no
fi

echo "Uploading dump to $S3_BUCKET"

report_set s3.key "${S3_PREFIX_PATH:+${S3_PREFIX_PATH}/}${DEST_FILE}"
backup_size=$(wc -c 2>/dev/null < "$SRC_FILE" | tr -cd '0-9') || backup_size=""
phase_begin upload
aws $AWS_ARGS s3 cp $UPLOAD_ARGS "$SRC_FILE" "$BACKUP_S3_URI" || exit 2
phase_end
if [ -n "$backup_size" ]; then
  report_set backup.size_bytes "$backup_size"
  BACKUP_SIZE_BYTES=$backup_size
  export BACKUP_SIZE_BYTES
fi
rm -f "$SRC_FILE"

if has_value "${DELETE_OLDER_THAN}"; then
  phase_begin retention
  >&2 echo "Checking for files older than ${DELETE_OLDER_THAN}"
  listing_file="$WORK_DIR/s3-listing"
  aws $AWS_ARGS s3 ls "$S3_BASE_URI" > "$listing_file" || exit 2
  deleted=0
  kept=0
  while IFS= read -r line
    do
      [ -n "$line" ] || continue
      case "$line" in
        *' PRE '*) continue ;;
      esac
      fileName=$(echo "$line" | awk '{ $1=$2=$3=""; sub(/^ +/, ""); print }')
      [ -n "$fileName" ] || continue
      # Never delete the backup this run just uploaded.
      [ "$fileName" != "$DEST_FILE" ] || continue
      if [ "${DELETE_MATCH_DATABASE}" = "yes" ]; then
        case "$fileName" in
          "${POSTGRES_DATABASE}_"*) ;;
          *) continue ;;
        esac
      fi
      created=$(echo "$line" | awk '{print $1" "$2}')
      created=$(date -d "$created" +%s)
      if [ "$created" -lt "$older_than" ]; then
        >&2 echo "DELETING ${fileName}"
        if ! aws $AWS_ARGS s3 rm "${S3_BASE_URI}${fileName}"; then
          >&2 echo "ERROR: Failed to delete ${fileName}"
          exit 2
        fi
        deleted=$((deleted + 1))
      else
        >&2 echo "${fileName} not older than ${DELETE_OLDER_THAN}"
        kept=$((kept + 1))
      fi
    done < "$listing_file"
  >&2 echo "Retention: deleted ${deleted} file(s), kept ${kept} newer file(s)"
  phase_end
  report_set retention.deleted "$deleted"
  report_set retention.kept "$kept"
fi

echo "SQL backup finished"

phase_begin post-backup
run_hooks post-backup
phase_end

>&2 echo "-----"
