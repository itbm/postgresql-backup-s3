# --- build stage ---
FROM alpine:3.22 AS build
WORKDIR /app
RUN apk add --no-cache go
COPY main.go /app/main.go
RUN go mod init github.com/itbm/postgresql-backup-s3 \
 && go get github.com/robfig/cron/v3 \
 && go build -o out/go-cron

# --- final stage: always track the latest Bitnami Postgres ---
FROM bitnami/postgresql:latest
LABEL maintainer="TechCrazi"

# Become root only for installs/file copies
USER root

# 1) Install minimal utilities in a cross-distro way
#    (handles apt / tdnf / dnf|yum / apk)
RUN set -euo pipefail; \
  need_pkgs="ca-certificates curl unzip openssl coreutils pigz"; \
  if command -v apt-get >/dev/null 2>&1; then \
    apt-get update && apt-get install -y --no-install-recommends $need_pkgs && rm -rf /var/lib/apt/lists/*; \
  elif command -v tdnf >/dev/null 2>&1; then \
    tdnf -y --refresh install $need_pkgs || tdnf -y install $need_pkgs; \
    (update-ca-trust || update-ca-certificates || true); \
  elif command -v microdnf >/dev/null 2>&1; then \
    microdnf -y install $need_pkgs || true; \
  elif command -v dnf >/dev/null 2>&1; then \
    dnf -y install $need_pkgs || true; \
  elif command -v yum >/dev/null 2>&1; then \
    yum -y install $need_pkgs || true; \
  elif command -v apk >/dev/null 2>&1; then \
    apk add --no-cache $need_pkgs; \
  else \
    echo "No supported package manager found in base image" >&2; exit 1; \
  fi

# 2) Install AWS CLI v2 from Amazon (works on any base)
RUN set -euo pipefail; \
  arch="$(uname -m)"; \
  case "$arch" in \
    x86_64|amd64)  AWSCLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" ;; \
    aarch64|arm64) AWSCLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" ;; \
    *) echo "Unsupported arch: $arch" >&2; exit 1 ;; \
  esac; \
  curl -sSL "$AWSCLI_URL" -o /tmp/awscliv2.zip; \
  unzip -q /tmp/awscliv2.zip -d /tmp; \
  /tmp/aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli; \
  rm -rf /tmp/aws /tmp/awscliv2.zip; \
  aws --version

# Ensure PG tools are on PATH (Bitnami keeps them here)
ENV PATH="/opt/bitnami/postgresql/bin:${PATH}"

# Copy your binary & scripts
COPY --from=build /app/out/go-cron /usr/local/bin/go-cron
COPY backup.sh /usr/local/bin/backup.sh
COPY restore.sh /usr/local/bin/restore.sh
COPY run.sh    /usr/local/bin/run.sh
RUN chmod +x /usr/local/bin/go-cron /usr/local/bin/*.sh

# Drop back to Bitnami's non-root user (UID 1001)
USER 1001

# Environment (override at runtime; avoid baking secrets)
ENV POSTGRES_DATABASE=**None** \
    POSTGRES_HOST=**None** \
    POSTGRES_PORT=5432 \
    POSTGRES_USER=**None** \
    POSTGRES_PASSWORD=**None** \
    POSTGRES_EXTRA_OPTS='' \
    S3_ACCESS_KEY_ID=**None** \
    S3_SECRET_ACCESS_KEY=**None** \
    S3_BUCKET=**None** \
    S3_REGION=us-west-1 \
    S3_PREFIX='backup' \
    S3_ENDPOINT=**None** \
    S3_S3V4=no \
    SCHEDULE=**None** \
    ENCRYPTION_PASSWORD=**None** \
    DELETE_OLDER_THAN=**None** \
    BACKUP_FILE=**None** \
    CREATE_DATABASE=no \
    DROP_DATABASE=no \
    USE_CUSTOM_FORMAT=no \
    COMPRESSION_CMD='gzip' \
    DECOMPRESSION_CMD='gunzip -c' \
    PARALLEL_JOBS=1

CMD ["/usr/local/bin/run.sh"]
