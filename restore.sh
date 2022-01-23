#! /bin/sh
source common.sh

echo "Retstoring database ${POSTGRES_DATABASE} to ${POSTGRES_HOST} ..."

echo "Finding latest backup ... "

LATEST_BACKUP=$(aws $AWS_ARGS s3 ls s3://$S3_BUCKET/$S3_PREFIX/ | sort | tail -n 1 | awk '{ print $4 }')

echo "Fetching ${LATEST_BACKUP} from S3"

if [ "${ENCRYPTION_PASSWORD}" != "**None**" ]; then
    aws $AWS_ARGS s3 cp s3://$S3_BUCKET/$S3_PREFIX/${LATEST_BACKUP} dump.sql.gz.enc
    >&2 echo "Decrypting dump.sql.gz.enc"
    openssl enc -aes-256-cbc -in dump.sql.gz.enc -out dump.sql.gz -pbkdf2 -d -k $ENCRYPTION_PASSWORD
    rm dump.sql.gz.enc
else
    aws $AWS_ARGS s3 cp s3://$S3_BUCKET/$S3_PREFIX/${LATEST_BACKUP} dump.sql.gz
fi

gzip -f -d dump.sql.gz

if [ "${DROP_PUBLIC}" == "yes" ]; then
	echo "Recreating the public schema"
	psql $POSTGRES_HOST_OPTS -d $POSTGRES_DATABASE -c "drop schema public cascade; create schema public;"
fi

echo "Restoring ${LATEST_BACKUP}"

if [ "${POSTGRES_DATABASE}" == "all" ]; then
    (set -x; psql $POSTGRES_HOST_OPTS < dump.sql)
else
    (set -x; psql $POSTGRES_HOST_OPTS -d $POSTGRES_DATABASE < dump.sql)
fi

echo "Restore complete"

>&2 echo "-----"
