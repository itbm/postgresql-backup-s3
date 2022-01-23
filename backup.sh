#! /bin/sh
source common.sh

echo "Creating dump of ${POSTGRES_DATABASE} database from ${POSTGRES_HOST}..."

SRC_FILE=dump.sql.gz
DEST_FILE=${POSTGRES_DATABASE}_$(date +"%Y-%m-%dT%H:%M:%SZ").sql.gz

if [ "${POSTGRES_DATABASE}" == "all" ]; then
  pg_dumpall $POSTGRES_HOST_OPTS | gzip > $SRC_FILE
else
  pg_dump $POSTGRES_HOST_OPTS $POSTGRES_DATABASE | gzip > $SRC_FILE
fi


if [ "${ENCRYPTION_PASSWORD}" != "**None**" ]; then
  >&2 echo "Encrypting ${SRC_FILE}"
  openssl enc -aes-256-cbc -in $SRC_FILE -out ${SRC_FILE}.enc -pbkdf2 -k $ENCRYPTION_PASSWORD
  if [ $? != 0 ]; then
    >&2 echo "Error encrypting ${SRC_FILE}"
  fi
  rm $SRC_FILE
  SRC_FILE="${SRC_FILE}.enc"
  DEST_FILE="${DEST_FILE}.enc"
fi

echo "Uploading ${DEST_FILE} to S3 ($S3_BUCKET)"

cat $SRC_FILE | aws $AWS_ARGS s3 cp - s3://$S3_BUCKET/$S3_PREFIX/$DEST_FILE || exit 2

if [ "${DELETE_OLDER_THAN}" != "**None**" ]; then
  >&2 echo "Checking for files older than ${DELETE_OLDER_THAN}"
  aws $AWS_ARGS s3 ls s3://$S3_BUCKET/$S3_PREFIX/ | grep " PRE " -v | while read -r line;
    do
      fileName=`echo $line|awk {'print $4'}`
      created=`echo $line|awk {'print $1" "$2'}`
      created=`date -d "$created" +%s`
      older_than=`date -d "$DELETE_OLDER_THAN" +%s`
      if [ $created -lt $older_than ]
        then
          if [ $fileName != "" ]
            then
              >&2 echo "DELETING ${fileName}"
              aws $AWS_ARGS s3 rm s3://$S3_BUCKET/$S3_PREFIX/$fileName
          fi
      else
          >&2 echo "${fileName} not older than ${DELETE_OLDER_THAN}"
      fi
    done;
fi

echo "SQL backup finished"

>&2 echo "-----"
