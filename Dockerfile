FROM alpine:3.24 AS build

WORKDIR /app

RUN apk update \
	&& apk upgrade \
	&& apk add go

COPY main.go /app/main.go

RUN go mod init github.com/itbm/postgresql-backup-s3 \
	&& go get github.com/robfig/cron/v3 \
	&& go build -o out/go-cron

FROM alpine:3.24
LABEL maintainer="ITBM"

RUN apk update \
	&& apk upgrade \
	&& apk add coreutils postgresql18-client aws-cli openssl pigz curl su-exec \
	&& adduser -D -H -s /sbin/nologin hook \
	&& mkdir -p /hooks \
	&& chown root:root /hooks \
	&& chmod 755 /hooks \
	&& rm -rf /var/cache/apk/*

COPY --from=build /app/out/go-cron /usr/local/bin/go-cron

ENV POSTGRES_DATABASE **None**
ENV POSTGRES_HOST **None**
ENV POSTGRES_PORT 5432
ENV POSTGRES_USER **None**
ENV POSTGRES_PASSWORD **None**
ENV POSTGRES_EXTRA_OPTS ''
ENV POSTGRES_EXTRA_DUMP_OPTS ''
ENV S3_ACCESS_KEY_ID **None**
ENV S3_SECRET_ACCESS_KEY **None**
ENV S3_BUCKET **None**
ENV S3_REGION us-west-1
ENV S3_PREFIX 'backup'
ENV S3_ENDPOINT **None**
ENV S3_S3V4 no
ENV SCHEDULE **None**
ENV ENCRYPTION_PASSWORD **None**
ENV DELETE_OLDER_THAN **None**
ENV BACKUP_FILE **None**
ENV CREATE_DATABASE no
ENV DROP_DATABASE no
ENV USE_CUSTOM_FORMAT no
ENV COMPRESSION_CMD 'gzip'
ENV DECOMPRESSION_CMD 'gunzip -c'
ENV PARALLEL_JOBS 1
ENV COMMAND_TIMEOUT **None**
ENV HOOKS_DIR /hooks
ENV HOOK_PRE_BACKUP_URL **None**
ENV HOOK_POST_BACKUP_URL **None**
ENV HOOK_BACKUP_ERROR_URL **None**
ENV HOOK_PRE_RESTORE_URL **None**
ENV HOOK_POST_RESTORE_URL **None**
ENV HOOK_RESTORE_ERROR_URL **None**
ENV HOOK_ALLOW_HTTP no
ENV HOOK_INHERIT_ENV no

ADD run.sh run.sh
ADD backup.sh backup.sh
ADD restore.sh restore.sh
ADD hooks.sh hooks.sh

CMD ["sh", "run.sh"]
