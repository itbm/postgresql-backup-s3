#! /bin/sh

set -e

. "$(dirname "$0")/common.sh"

# Trust extra CAs dropped into Alpine's standard directory (must be named *.crt).
if ls /usr/local/share/ca-certificates/*.crt >/dev/null 2>&1; then
  update-ca-certificates >/dev/null
  export AWS_CA_BUNDLE="${AWS_CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}"
fi

# S3_CA_BUNDLE wins over the auto system path; existing AWS_CA_BUNDLE is honoured otherwise.
if has_value "${S3_CA_BUNDLE}"; then
  export AWS_CA_BUNDLE="${S3_CA_BUNDLE}"
fi

if [ "${S3_S3V4}" = "yes" ]; then
    aws configure set default.s3.signature_version s3v4
fi

# go-cron runs each job in its own process group and forwards stop signals to
# the whole group, so pg_dump, psql and aws stop too and cleanup runs.
if has_value "${BACKUP_FILE}"; then
  exec go-cron --once /bin/sh restore.sh
elif ! has_value "${SCHEDULE}"; then
  exec go-cron --once /bin/sh backup.sh
elif [ "${BACKUP_ON_START}" = "yes" ]; then
  exec go-cron --run-on-start "$SCHEDULE" /bin/sh backup.sh
else
  exec go-cron "$SCHEDULE" /bin/sh backup.sh
fi
