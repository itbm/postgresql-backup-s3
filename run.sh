#! /bin/sh

set -e

# Trust extra CAs dropped into Alpine's standard directory (must be named *.crt).
if ls /usr/local/share/ca-certificates/*.crt >/dev/null 2>&1; then
  update-ca-certificates
  export AWS_CA_BUNDLE="${AWS_CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}"
fi

# S3_CA_BUNDLE wins over the auto system path; existing AWS_CA_BUNDLE is honoured otherwise.
if [ -n "${S3_CA_BUNDLE}" ] && [ "${S3_CA_BUNDLE}" != "**None**" ]; then
  export AWS_CA_BUNDLE="${S3_CA_BUNDLE}"
fi

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