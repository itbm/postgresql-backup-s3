#! /bin/sh
# Shared validation and setup for backup.sh and restore.sh. Sourced, not executed.
# Variables set here (AWS_ARGS, S3_BASE_URI, ...) are used by the scripts that source this file.
# shellcheck disable=SC2034

# A value is set when it is non-empty and not the **None** placeholder.
has_value() {
  [ -n "$1" ] && [ "$1" != "**None**" ]
}

die() {
  echo "$*"
  exit 1
}

quote_ident() {
  printf '"%s"' "$(printf '%s' "$1" | sed 's/"/""/g')"
}

quote_literal() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"
}

is_positive_int() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -gt 0 ]
}

# file_env VAR loads VAR from the file named by VAR_FILE (Docker and Kubernetes
# secrets). Setting both VAR and VAR_FILE is an error.
file_env() {
  _fe_var=$1
  _fe_val=""
  _fe_file=""
  eval "_fe_val=\${$_fe_var:-}"
  eval "_fe_file=\${${_fe_var}_FILE:-}"
  if ! has_value "$_fe_file"; then
    return 0
  fi
  if has_value "$_fe_val"; then
    die "Both ${_fe_var} and ${_fe_var}_FILE are set; use only one."
  fi
  if [ ! -r "$_fe_file" ]; then
    die "Cannot read ${_fe_var}_FILE: ${_fe_file}"
  fi
  # Command substitution drops trailing newlines, which secret files often have.
  _fe_val=$(cat "$_fe_file")
  eval "$_fe_var=\$_fe_val"
  export "${_fe_var?}"
}

load_secret_files() {
  for _secret in POSTGRES_USER POSTGRES_PASSWORD S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY ENCRYPTION_PASSWORD; do
    file_env "$_secret"
  done
}

validate_common_env() {
  load_secret_files

  has_value "${S3_BUCKET}" || die "You need to set the S3_BUCKET environment variable."
  has_value "${POSTGRES_DATABASE}" || die "You need to set the POSTGRES_DATABASE environment variable."

  if ! has_value "${POSTGRES_HOST}"; then
    if [ -n "${POSTGRES_PORT_5432_TCP_ADDR}" ]; then
      POSTGRES_HOST=$POSTGRES_PORT_5432_TCP_ADDR
      POSTGRES_PORT=$POSTGRES_PORT_5432_TCP_PORT
    else
      die "You need to set the POSTGRES_HOST environment variable."
    fi
  fi
  if ! has_value "${POSTGRES_PORT}"; then
    POSTGRES_PORT=5432
  fi

  has_value "${POSTGRES_USER}" || die "You need to set the POSTGRES_USER environment variable."
  has_value "${POSTGRES_PASSWORD}" || die "You need to set the POSTGRES_PASSWORD environment variable or link to a container named POSTGRES."

  if has_value "${S3_ACCESS_KEY_ID}"; then
    has_value "${S3_SECRET_ACCESS_KEY}" || die "You need to set the S3_SECRET_ACCESS_KEY environment variable."
    export AWS_ACCESS_KEY_ID=$S3_ACCESS_KEY_ID
    export AWS_SECRET_ACCESS_KEY=$S3_SECRET_ACCESS_KEY
  elif has_value "${S3_SECRET_ACCESS_KEY}"; then
    die "You need to set the S3_ACCESS_KEY_ID environment variable."
  fi
}

setup_aws() {
  AWS_ARGS=""
  if has_value "${S3_ENDPOINT}"; then
    AWS_ARGS="--endpoint-url ${S3_ENDPOINT}"
  fi
  if [ "${S3_SSL_VERIFY}" = "no" ]; then
    AWS_ARGS="$AWS_ARGS --no-verify-ssl"
  fi

  # Avoid AWS CLI v2 default checksum behaviour that breaks many S3-compatible
  # endpoints and some streaming uploads (XAmzContentSHA256Mismatch).
  export AWS_REQUEST_CHECKSUM_CALCULATION="${AWS_REQUEST_CHECKSUM_CALCULATION:-when_required}"
  export AWS_RESPONSE_CHECKSUM_VALIDATION="${AWS_RESPONSE_CHECKSUM_VALIDATION:-when_required}"

  if has_value "${S3_REGION}"; then
    export AWS_DEFAULT_REGION=$S3_REGION
  fi

  # Strip leading and trailing slashes so an empty or slashed prefix never
  # produces keys such as s3://bucket//file.
  S3_PREFIX_PATH=""
  if has_value "${S3_PREFIX}"; then
    S3_PREFIX_PATH=$(printf '%s' "$S3_PREFIX" | sed -e 's#^/*##' -e 's#/*$##')
  fi
  if [ -n "$S3_PREFIX_PATH" ]; then
    S3_BASE_URI="s3://${S3_BUCKET}/${S3_PREFIX_PATH}/"
  else
    S3_BASE_URI="s3://${S3_BUCKET}/"
  fi
}

setup_postgres() {
  export PGPASSWORD=$POSTGRES_PASSWORD
  POSTGRES_HOST_OPTS="-h $POSTGRES_HOST -p $POSTGRES_PORT -U $POSTGRES_USER $POSTGRES_EXTRA_OPTS"
}

make_work_dir() {
  WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pgbackup.XXXXXX")
}

remove_work_dir() {
  if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
    rm -rf "$WORK_DIR"
  fi
  WORK_DIR=""
}
