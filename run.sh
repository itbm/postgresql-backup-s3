#! /bin/sh

set -e

if [ "${S3_S3V4}" = "yes" ]; then
    aws configure set default.s3.signature_version s3v4
fi

if [ "${BACKUP_FILE}" != "" ] && [ "${BACKUP_FILE}" != "**None**" ]; then
  sh restore.sh
elif [ "${SCHEDULE}" = "**None**" ]; then
  sh backup.sh
else
  exec go-cron "$SCHEDULE" /bin/sh backup.sh
fi