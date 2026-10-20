# GOCRON_VARIANT selects the go-cron build: "default", or "otel" for the
# OpenTelemetry image published as <version>-otel.
ARG GOCRON_VARIANT=default

# go-cron is cross-compiled on the build machine's platform, so arm64 images
# do not compile under emulation.
FROM --platform=$BUILDPLATFORM alpine:3.24 AS build

WORKDIR /src

RUN apk update \
	&& apk upgrade \
	&& apk add go

COPY go.mod go.sum ./
RUN go mod download
COPY main.go ./
COPY internal ./internal

FROM build AS gocron-default
ARG TARGETOS
ARG TARGETARCH
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags="-s -w" -o /out/go-cron .

FROM build AS gocron-otel
COPY otel/go.mod otel/go.sum ./otel/
RUN cd otel && go mod download
COPY otel ./otel
ARG TARGETOS
ARG TARGETARCH
ARG VERSION=dev
RUN cd otel \
	&& CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags="-s -w -X main.version=$VERSION" -o /out/go-cron .

FROM gocron-${GOCRON_VARIANT} AS gocron

FROM alpine:3.24
LABEL maintainer="ITBM"

RUN apk update \
	&& apk upgrade \
	&& apk add coreutils postgresql18-client aws-cli openssl pigz ca-certificates curl su-exec tzdata \
	&& adduser -D -H -s /sbin/nologin hook \
	&& mkdir -p /hooks \
	&& chown root:root /hooks \
	&& chmod 755 /hooks \
	&& rm -rf /var/cache/apk/*

COPY --from=gocron /out/go-cron /usr/local/bin/go-cron

ENV POSTGRES_DATABASE=**None** \
	POSTGRES_HOST=**None** \
	POSTGRES_PORT=5432 \
	POSTGRES_USER=**None** \
	POSTGRES_PASSWORD=**None** \
	POSTGRES_EXTRA_OPTS='' \
	POSTGRES_EXTRA_DUMP_OPTS='' \
	S3_ACCESS_KEY_ID=**None** \
	S3_SECRET_ACCESS_KEY=**None** \
	S3_BUCKET=**None** \
	S3_REGION=us-west-1 \
	S3_PREFIX='backup' \
	S3_ENDPOINT=**None** \
	S3_CA_BUNDLE=**None** \
	S3_SSL_VERIFY=yes \
	S3_S3V4=no \
	S3_STORAGE_CLASS=**None** \
	S3_SSE=**None** \
	S3_SSE_KMS_KEY_ID=**None** \
	SCHEDULE=**None** \
	BACKUP_ON_START=no \
	ENCRYPTION_PASSWORD=**None** \
	DELETE_OLDER_THAN=**None** \
	DELETE_MATCH_DATABASE=no \
	BACKUP_FILE=**None** \
	CREATE_DATABASE=no \
	DROP_DATABASE=no \
	RESTORE_ON_ERROR_STOP=**None** \
	USE_CUSTOM_FORMAT=no \
	COMPRESSION_CMD='gzip' \
	DECOMPRESSION_CMD='gunzip -c' \
	PARALLEL_JOBS=1 \
	COMMAND_TIMEOUT=**None** \
	HOOKS_DIR=/hooks \
	HOOK_PRE_BACKUP_URL=**None** \
	HOOK_POST_BACKUP_URL=**None** \
	HOOK_BACKUP_ERROR_URL=**None** \
	HOOK_PRE_RESTORE_URL=**None** \
	HOOK_POST_RESTORE_URL=**None** \
	HOOK_RESTORE_ERROR_URL=**None** \
	HOOK_ALLOW_HTTP=no \
	HOOK_INHERIT_ENV=no

WORKDIR /

COPY run.sh backup.sh restore.sh common.sh hooks.sh /

CMD ["sh", "run.sh"]
