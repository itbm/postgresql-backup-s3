#! /bin/sh
# Lifecycle hooks for backup/restore. Sourced by backup.sh and restore.sh.
# Do not execute operator-supplied strings as a shell.

hook_has_value() {
  [ -n "$1" ] && [ "$1" != "**None**" ]
}

hook_event_allowed() {
  case "$1" in
    pre-backup|post-backup|backup-error|pre-restore|post-restore|restore-error)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

hook_url_for_event() {
  case "$1" in
    pre-backup) printf '%s' "${HOOK_PRE_BACKUP_URL}" ;;
    post-backup) printf '%s' "${HOOK_POST_BACKUP_URL}" ;;
    backup-error) printf '%s' "${HOOK_BACKUP_ERROR_URL}" ;;
    pre-restore) printf '%s' "${HOOK_PRE_RESTORE_URL}" ;;
    post-restore) printf '%s' "${HOOK_POST_RESTORE_URL}" ;;
    restore-error) printf '%s' "${HOOK_RESTORE_ERROR_URL}" ;;
    *) return 1 ;;
  esac
}

hook_strip_port() {
  # $1 = host[:port] that is not an unbracketed IPv6 address
  case "$1" in
    *:*)
      printf '%s' "${1%:*}"
      ;;
    *)
      printf '%s' "$1"
      ;;
  esac
}

hook_url_host() {
  _hook_url=$1
  _hook_rest=${_hook_url#*://}
  _hook_authority=${_hook_rest%%[/?#]*}
  case "$_hook_authority" in
    \[*)
      _hook_host=${_hook_authority#\[}
      _hook_host=${_hook_host%%]*}
      printf '%s' "$_hook_host"
      ;;
    *)
      hook_strip_port "$_hook_authority"
      ;;
  esac
}

hook_url_has_userinfo() {
  _hook_url=$1
  _hook_rest=${_hook_url#*://}
  _hook_authority=${_hook_rest%%[/?#]*}
  case "$_hook_authority" in
    *@*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

hook_host_is_blocked() {
  _hook_host=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  _hook_host=${_hook_host%.}

  case "$_hook_host" in
    localhost|localhost.*|metadata.google.internal|*.metadata.google.internal)
      return 0
      ;;
    127.*|169.254.*|0.0.0.0)
      return 0
      ;;
    ::1|0:0:0:0:0:0:0:1)
      return 0
      ;;
    ::ffff:127.*|::ffff:169.254.*|0:0:0:0:0:ffff:127.*|0:0:0:0:0:ffff:169.254.*)
      return 0
      ;;
    fe80:*|fd00:ec2:*)
      return 0
      ;;
  esac
  return 1
}

# Prints a short reason to stdout and returns 1 when the URL is not allowed.
hook_url_is_allowed() {
  _hook_url=$1

  if ! hook_has_value "$_hook_url"; then
    printf '%s\n' "empty"
    return 1
  fi

  _hook_stripped=$(printf '%s' "$_hook_url" | tr -d '\n\r\t ')
  if [ "$_hook_stripped" != "$_hook_url" ]; then
    printf '%s\n' "whitespace"
    return 1
  fi

  case "$_hook_url" in
    https://*)
      ;;
    http://*)
      if [ "${HOOK_ALLOW_HTTP}" != "yes" ]; then
        printf '%s\n' "http-not-allowed"
        return 1
      fi
      ;;
    *)
      printf '%s\n' "scheme"
      return 1
      ;;
  esac

  if hook_url_has_userinfo "$_hook_url"; then
    printf '%s\n' "userinfo"
    return 1
  fi

  _hook_host=$(hook_url_host "$_hook_url")
  if [ -z "$_hook_host" ]; then
    printf '%s\n' "host"
    return 1
  fi

  if hook_host_is_blocked "$_hook_host"; then
    printf '%s\n' "blocked-host"
    return 1
  fi

  return 0
}

hook_run_as_hook() {
  if [ "${HOOK_DROP_PRIVS:-yes}" = "no" ]; then
    "$@"
    return $?
  fi

  if ! command -v su-exec >/dev/null 2>&1; then
    echo "ERROR: su-exec is required to run hooks" >&2
    return 1
  fi
  if ! id -u hook >/dev/null 2>&1; then
    echo "ERROR: hook user is required to run hooks" >&2
    return 1
  fi
  su-exec hook "$@"
}

hook_run_script() {
  _hook_event=$1

  if ! hook_event_allowed "$_hook_event"; then
    echo "ERROR: invalid hook event" >&2
    return 1
  fi

  _hook_dir=${HOOKS_DIR:-/hooks}
  _hook_script="${_hook_dir%/}/$_hook_event"

  if [ ! -e "$_hook_script" ]; then
    return 0
  fi

  if [ ! -d "$_hook_dir" ]; then
    echo "ERROR: HOOKS_DIR is not a directory" >&2
    return 1
  fi

  if ! _hook_dir_real=$(realpath "$_hook_dir") || ! _hook_script_real=$(realpath "$_hook_script"); then
    echo "ERROR: cannot resolve hook script path for ${_hook_event}" >&2
    return 1
  fi

  case "$_hook_script_real" in
    "$_hook_dir_real"/*)
      ;;
    *)
      echo "ERROR: hook script for ${_hook_event} is outside HOOKS_DIR" >&2
      return 1
      ;;
  esac

  if [ ! -f "$_hook_script_real" ] || [ ! -x "$_hook_script_real" ]; then
    echo "ERROR: hook script for ${_hook_event} is not an executable regular file" >&2
    return 1
  fi

  echo "Running script hook for ${_hook_event}"

  if [ "${HOOK_INHERIT_ENV}" = "yes" ]; then
    hook_run_as_hook "$_hook_script_real" "$_hook_event"
    return $?
  fi

  # env -i allowlist: never pass passwords, AWS keys, or IRSA/web-identity files.
  set -- env -i \
    "PATH=/usr/local/bin:/usr/bin:/bin" \
    "HOME=/tmp" \
    "HOOK_EVENT=${_hook_event}"

  if hook_has_value "$TZ"; then
    set -- "$@" "TZ=$TZ"
  fi
  if hook_has_value "$POSTGRES_DATABASE"; then
    set -- "$@" "POSTGRES_DATABASE=$POSTGRES_DATABASE"
  fi
  if hook_has_value "$POSTGRES_HOST"; then
    set -- "$@" "POSTGRES_HOST=$POSTGRES_HOST"
  fi
  if hook_has_value "$POSTGRES_PORT"; then
    set -- "$@" "POSTGRES_PORT=$POSTGRES_PORT"
  fi
  if hook_has_value "$POSTGRES_USER"; then
    set -- "$@" "POSTGRES_USER=$POSTGRES_USER"
  fi
  if hook_has_value "$S3_BUCKET"; then
    set -- "$@" "S3_BUCKET=$S3_BUCKET"
  fi
  if hook_has_value "$S3_PREFIX"; then
    set -- "$@" "S3_PREFIX=$S3_PREFIX"
  fi
  if hook_has_value "$S3_REGION"; then
    set -- "$@" "S3_REGION=$S3_REGION"
  fi
  if hook_has_value "$S3_ENDPOINT"; then
    set -- "$@" "S3_ENDPOINT=$S3_ENDPOINT"
  fi
  if hook_has_value "$BACKUP_DEST_FILE"; then
    set -- "$@" "BACKUP_DEST_FILE=$BACKUP_DEST_FILE"
  fi
  if hook_has_value "$BACKUP_S3_URI"; then
    set -- "$@" "BACKUP_S3_URI=$BACKUP_S3_URI"
  fi
  if hook_has_value "$BACKUP_FILE"; then
    set -- "$@" "BACKUP_FILE=$BACKUP_FILE"
  fi
  case "$_hook_event" in
    *-error)
      if [ -n "$HOOK_EXIT_CODE" ]; then
        set -- "$@" "HOOK_EXIT_CODE=$HOOK_EXIT_CODE"
      fi
      ;;
  esac

  set -- "$@" "$_hook_script_real" "$_hook_event"
  hook_run_as_hook "$@"
}

hook_run_url() {
  _hook_event=$1

  if ! hook_event_allowed "$_hook_event"; then
    echo "ERROR: invalid hook event" >&2
    return 1
  fi

  _hook_url=$(hook_url_for_event "$_hook_event")
  if ! hook_has_value "$_hook_url"; then
    return 0
  fi

  _hook_reason=$(hook_url_is_allowed "$_hook_url") || {
    echo "ERROR: hook URL for ${_hook_event} is not allowed (${_hook_reason})" >&2
    return 1
  }

  _hook_proto='=https'
  if [ "${HOOK_ALLOW_HTTP}" = "yes" ]; then
    _hook_proto='=https,http'
  fi

  echo "Running URL hook for ${_hook_event}"

  if ! hook_run_as_hook curl -fsS --retry 3 --max-time 30 --proto "$_hook_proto" --max-redirs 0 -- "$_hook_url" >/dev/null 2>/dev/null; then
    echo "ERROR: URL hook for ${_hook_event} failed" >&2
    return 1
  fi
}

run_hooks() {
  _hook_event=$1
  if ! hook_event_allowed "$_hook_event"; then
    echo "ERROR: invalid hook event" >&2
    return 1
  fi
  hook_run_script "$_hook_event" || return 1
  hook_run_url "$_hook_event" || return 1
}

run_error_hooks() {
  _hook_event=$1
  HOOK_EXIT_CODE=$2
  if ! run_hooks "$_hook_event"; then
    echo "ERROR: ${_hook_event} hook failed; keeping original exit code ${HOOK_EXIT_CODE}" >&2
  fi
  return 0
}
