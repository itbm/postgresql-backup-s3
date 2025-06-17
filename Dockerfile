FROM alpine:3.22 AS build

WORKDIR /app

RUN apk update \
	&& apk upgrade \
	&& apk add go

COPY main.go /app/main.go

RUN go mod init github.com/guy1998/postgresql-backup-s3 \
	&& go get github.com/robfig/cron/v3 \
	&& go build -o out/go-cron

FROM alpine:3.22
LABEL maintainer="guy1998"

RUN apk update \
	&& apk upgrade \
	&& apk add coreutils postgresql17-client aws-cli openssl pigz \
	&& rm -rf /var/cache/apk/*

COPY --from=build /app/out/go-cron /usr/local/bin/go-cron

ENV POSTGRES_DATABASE **None**
ENV POSTGRES_HOST **None**
ENV POSTGRES_PORT 5432
ENV POSTGRES_USER **None**
ENV POSTGRES_PASSWORD **None**
ENV POSTGRES_EXTRA_OPTS ''
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
ENV TABLES **None**

ADD run.sh run.sh
ADD backup.sh backup.sh
ADD restore.sh restore.sh

CMD ["sh", "run.sh"]
