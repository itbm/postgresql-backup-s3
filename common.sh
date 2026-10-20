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

# --- Run report and result line ---
# Each run records its phases, such as dump and upload, in two places: the
# report file that go-cron in the -otel image names in PGBACKUP_TELEMETRY_FILE,
# and the pgbackup-result line printed to stderr at exit. Neither may change
# the script's exit code, so every helper here returns 0.

PHASE_NAME=""
PHASE_START_NS=""
RUN_START_NS=""
RESULT_PHASES=""
RESULT_FAILED_PHASE=""
RESULT_SIZE_BYTES=""
RESULT_RETENTION_DELETED=""
RESULT_RETENTION_KEPT=""
RESULT_FILE=""
# Hooks see BACKUP_SIZE_BYTES only once backup.sh has uploaded a backup.
unset BACKUP_SIZE_BYTES

# now_ns prints the Unix time in nanoseconds. A date without %N, such as an
# older BusyBox date, gives one-second precision.
now_ns() {
  _now=$(date +%s%N 2>/dev/null) || _now=""
  case "$_now" in
    ''|*[!0-9]*) _now="" ;;
  esac
  if [ "${#_now}" -le 10 ]; then
    _now=$(date +%s 2>/dev/null) || _now=""
    case "$_now" in
      ''|*[!0-9]*) _now=0 ;;
      *) _now="${_now}000000000" ;;
    esac
  fi
  printf '%s\n' "$_now"
}

# format_duration START_NS END_NS prints the time between them in seconds with
# three decimals.
format_duration() {
  _fd_ms=0
  case "$1" in
    ''|*[!0-9]*) ;;
    *)
      case "$2" in
        ''|*[!0-9]*) ;;
        *) _fd_ms=$(( ($2 - $1) / 1000000 )) ;;
      esac
      ;;
  esac
  if [ "$_fd_ms" -lt 0 ]; then
    _fd_ms=0
  fi
  printf '%d.%03d' "$((_fd_ms / 1000))" "$((_fd_ms % 1000))"
}

# report_write appends a record to the report file. The file must already
# exist and must not be a symbolic link; errors are ignored.
report_write() {
  if [ -n "$PGBACKUP_TELEMETRY_FILE" ] && [ -f "$PGBACKUP_TELEMETRY_FILE" ] && [ ! -h "$PGBACKUP_TELEMETRY_FILE" ]; then
    { printf '%s\n' "$1" >> "$PGBACKUP_TELEMETRY_FILE"; } 2>/dev/null || :
  fi
  return 0
}

# phase_begin NAME starts a phase, first ending any open phase as a success.
phase_begin() {
  phase_end 0
  PHASE_NAME=$1
  PHASE_START_NS=$(now_ns)
  report_write "begin $PHASE_NAME $PHASE_START_NS"
}

# phase_end [STATUS] ends the open phase, if any, with an exit status
# (default 0).
phase_end() {
  if [ -z "$PHASE_NAME" ]; then
    return 0
  fi
  _pe_name=$PHASE_NAME
  _pe_status=${1:-0}
  _pe_end=$(now_ns)
  PHASE_NAME=""
  report_write "end $_pe_name $_pe_end $_pe_status"
  _pe_key=$(printf '%s' "$_pe_name" | tr '-' '_') || _pe_key=$_pe_name
  RESULT_PHASES="$RESULT_PHASES ${_pe_key}_s=$(format_duration "$PHASE_START_NS" "$_pe_end")"
  if [ "$_pe_status" != 0 ] && [ -z "$RESULT_FAILED_PHASE" ]; then
    RESULT_FAILED_PHASE=$_pe_name
  fi
  return 0
}

# report_set KEY VALUE records a fact about the run, such as the backup size.
report_set() {
  _rs_value=$(printf '%s' "$2" | tr -d '\r\n') || _rs_value=""
  report_write "set $1 $_rs_value"
  case "$1" in
    backup.size_bytes) RESULT_SIZE_BYTES=$_rs_value ;;
    retention.deleted) RESULT_RETENTION_DELETED=$_rs_value ;;
    retention.kept) RESULT_RETENTION_KEPT=$_rs_value ;;
    s3.key) RESULT_FILE=$_rs_value ;;
  esac
  return 0
}

# logfmt_value prints a value for the result line, in double quotes when it
# contains a space, a double quote, an equals sign, a backslash or a control
# character. Line breaks are removed.
logfmt_value() {
  _lv=$(printf '%s' "$1" | tr -d '\r\n') || _lv=""
  case "$_lv" in
    '')
      printf '""'
      ;;
    *' '*|*'"'*|*'='*|*\\*|*[[:cntrl:]]*)
      _lv=$(printf '%s' "$_lv" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g') || _lv=""
      printf '"%s"' "$_lv"
      ;;
    *)
      printf '%s' "$_lv"
      ;;
  esac
}

# print_result_line OPERATION EXIT_CODE prints the pgbackup-result line to
# stderr.
print_result_line() {
  case "$2" in
    0) _pr_outcome=success ;;
    130|143) _pr_outcome=cancelled ;;
    *) _pr_outcome=failure ;;
  esac
  _pr_line="pgbackup-result operation=$1 outcome=$_pr_outcome exit_code=$2"
  _pr_line="$_pr_line database=$(logfmt_value "$POSTGRES_DATABASE")"
  _pr_line="$_pr_line duration_s=$(format_duration "$RUN_START_NS" "$(now_ns)")$RESULT_PHASES"
  if [ -n "$RESULT_FAILED_PHASE" ]; then
    _pr_line="$_pr_line failed_phase=$RESULT_FAILED_PHASE"
  fi
  if [ -n "$RESULT_SIZE_BYTES" ]; then
    _pr_line="$_pr_line size_bytes=$(logfmt_value "$RESULT_SIZE_BYTES")"
  fi
  if [ -n "$RESULT_RETENTION_DELETED" ]; then
    _pr_line="$_pr_line retention_deleted=$(logfmt_value "$RESULT_RETENTION_DELETED")"
  fi
  if [ -n "$RESULT_RETENTION_KEPT" ]; then
    _pr_line="$_pr_line retention_kept=$(logfmt_value "$RESULT_RETENTION_KEPT")"
  fi
  if [ -n "$RESULT_FILE" ]; then
    _pr_line="$_pr_line file=$(logfmt_value "$RESULT_FILE")"
  fi
  printf '%s\n' "$_pr_line" >&2 || :
  return 0
}
