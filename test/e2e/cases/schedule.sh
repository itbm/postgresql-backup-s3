# Scheduled backups: SCHEDULE parsing, COMMAND_TIMEOUT, overlap protection,
# logging, hooks and shutdown of the go-cron runner (main.go, run.sh).

_SCHED_TS='^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\]'

_sched_running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$BK_CTR" 2>/dev/null)" = true ]
}

_sched_exited() {
  [ "$(docker inspect -f '{{.State.Running}}' "$BK_CTR" 2>/dev/null)" = false ]
}

# _sched_wait_exit <seconds> - waits for the detached container to exit, then
# refreshes BK_LOG and sets BK_RC.
_sched_wait_exit() {
  if ! wait_for "$1" _sched_exited; then
    bk_logs
    fail "container $BK_CTR still running after $1s"
  fi
  bk_logs
  BK_RC=$(docker inspect -f '{{.State.ExitCode}}' "$BK_CTR")
}

# _sched_log_count <text> - refreshes BK_LOG and prints how often text occurs.
_sched_log_count() {
  bk_logs
  grep -Fc -- "$1" "$BK_LOG" || true
}

_sched_log_has_at_least() {
  [ "$(_sched_log_count "$1")" -ge "$2" ]
}

_sched_assert_log_match() {
  grep -Eq -- "$1" "$BK_LOG" || fail "${2:-log has no line matching} /$1/"
}

# _sched_live_procs <command> - live (non-zombie) processes in BK_CTR running command.
_sched_live_procs() {
  docker exec "$BK_CTR" ps -o stat,args 2>/dev/null \
    | awk -v c="$1" '$1 !~ /^Z/ && $2 == c' | grep -c . || true
}

_sched_live_procs_at_most() {
  [ "$(_sched_live_procs "$1")" -le "$2" ]
}

# _sched_assert_no_overlap <trace-file> - lines "start ..." and "end ..." must alternate.
_sched_assert_no_overlap() {
  awk '$1 == "start" { if (open) bad = 1; open = 1 }
       $1 == "end" { if (!open) bad = 1; open = 0 }
       END { exit bad }' "$1" || fail "hook runs overlapped: $(tr '\n' ' ' <"$1")"
}

# _sched_lock_table <database> <table> - holds an ACCESS EXCLUSIVE lock from a
# separate session until the case ends, so pg_dump blocks on it.
_sched_lock_table() {
  _sl_app="e2e_lock_$(printf '%s' "$CASE_SLUG" | tr '-' '_')"
  trap _sched_unlock EXIT
  docker exec -d -e "PGAPPNAME=$_sl_app" "$E2E_PG_CTR" psql -X -q -U postgres -d "$1" \
    -c "BEGIN; LOCK TABLE $2 IN ACCESS EXCLUSIVE MODE; SELECT pg_sleep(300); COMMIT;" \
    || fail "could not start the locking session"
  wait_for 30 _sched_lock_held || fail "locking session did not take the lock"
}

_sched_lock_held() {
  [ "$(psql_exec postgres "SELECT count(*) FROM pg_locks l JOIN pg_stat_activity a USING (pid)
    WHERE a.application_name = '$_sl_app' AND l.mode = 'AccessExclusiveLock' AND l.granted")" -ge 1 ]
}

_sched_unlock() {
  psql_exec postgres "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
    WHERE application_name = '$_sl_app'" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------

test_schedule_every_runs_repeatedly() {
  db=$(new_db)
  bucket=$(new_bucket)

  bk_start cron -e "POSTGRES_DATABASE=$db" -e "S3_BUCKET=$bucket" -e "SCHEDULE=@every 2s"
  wait_for 90 s3_has_at_least "$bucket" backup/ 3 || { bk_logs; fail "fewer than 3 scheduled backups after 90s"; }
  wait_for 30 _sched_log_has_at_least "Command finished successfully" 3 \
    || fail "fewer than 3 runs reported success"
  _sched_running || fail "scheduled container is no longer running"

  _sched_assert_log_match "$_SCHED_TS INFO: Cron job scheduled: @every 2s\$"
  _sched_assert_log_match "$_SCHED_TS INFO: Command to run: /bin/sh backup.sh\$"
  _sched_assert_log_match "$_SCHED_TS INFO: Command timeout: disabled\$"
  _sched_assert_log_match "$_SCHED_TS INFO: Executing command: "
  _sched_assert_log_match "$_SCHED_TS STDERR: -----\$"
  _sched_assert_log_match "$_SCHED_TS STDOUT: Creating dump of $db database from pg\.\.\.\$"
  _sched_assert_log_match "$_SCHED_TS STDOUT: SQL backup finished\$"
  _sched_assert_log_match "$_SCHED_TS INFO: Command finished successfully\$"
  assert_log_not_contains "Command finished with error"

  for key in $(s3_keys "$bucket" backup/); do
    assert_match "$key" "^backup/${db}_[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\.sql\.gz$" "scheduled backup key"
  done
  key=$(s3_keys "$bucket" backup/ | tail -n 1)
  bk_stop

  restored="${db}_restored"
  bk_restore restore "$restored" "$bucket" "$key" -e CREATE_DATABASE=yes
  assert_rc 0 "restore of the newest scheduled backup"
  assert_same_data "$db" "$restored"
}

test_schedule_cron_expressions_accepted() {
  db=$(new_db)
  bucket=$(new_bucket)

  exprs=("*/5 * * * *" "0 3 * * 1-5" "@daily" "@hourly" "@weekly" "@midnight" "@every 1h30m")
  ctrs=()
  logs=()
  i=0
  for expr in "${exprs[@]}"; do
    bk_start "expr$i" -e "POSTGRES_DATABASE=$db" -e "S3_BUCKET=$bucket" -e "SCHEDULE=$expr"
    ctrs+=("$BK_CTR")
    logs+=("$BK_LOG")
    i=$((i + 1))
  done

  i=0
  for expr in "${exprs[@]}"; do
    BK_CTR=${ctrs[$i]} BK_LOG=${logs[$i]}
    wait_for 30 _sched_log_has_at_least "INFO: Cron job scheduled: $expr" 1 \
      || fail "SCHEDULE '$expr' was not scheduled"
    i=$((i + 1))
  done

  # Give a container that would exit after scheduling the chance to do so.
  sleep 2
  i=0
  for expr in "${exprs[@]}"; do
    BK_CTR=${ctrs[$i]} BK_LOG=${logs[$i]}
    bk_logs
    _sched_running || fail "container for SCHEDULE '$expr' stopped"
    assert_log_not_contains "Invalid schedule format"
    i=$((i + 1))
  done
}

test_schedule_invalid_schedule_exits() {
  exprs=("not a schedule" "0 */5 * * * *" "@every nonsense" "@every" "61 * * * *" "* * * *")
  ctrs=()
  logs=()
  i=0
  for expr in "${exprs[@]}"; do
    bk_start "bad$i" -e "POSTGRES_DATABASE=unused" -e "S3_BUCKET=unused" -e "SCHEDULE=$expr"
    ctrs+=("$BK_CTR")
    logs+=("$BK_LOG")
    i=$((i + 1))
  done

  i=0
  for expr in "${exprs[@]}"; do
    BK_CTR=${ctrs[$i]} BK_LOG=${logs[$i]}
    _sched_wait_exit 30
    assert_rc 1 "SCHEDULE '$expr'"
    _sched_assert_log_match "$_SCHED_TS ERROR: Invalid schedule format: "
    assert_log_not_contains "Cron job scheduled"
    assert_log_not_contains "Executing command"
    i=$((i + 1))
  done
}

test_schedule_command_timeout_parsing() {
  # label, COMMAND_TIMEOUT ("-" leaves it at the image default), expected text
  set -- \
    default - "INFO: Command timeout: disabled" \
    zero 0 "INFO: Command timeout: disabled" \
    empty "" "INFO: Command timeout: disabled" \
    hours 2h "INFO: Command timeout: 2h0m0s" \
    seconds 90s "INFO: Command timeout: 1m30s" \
    word abc 'ERROR: invalid COMMAND_TIMEOUT "abc"' \
    negative -5s 'ERROR: invalid COMMAND_TIMEOUT "-5s"' \
    nounit 10 'ERROR: invalid COMMAND_TIMEOUT "10"'
  cases=("$@")

  ctrs=()
  logs=()
  i=0
  while [ "$i" -lt ${#cases[@]} ]; do
    label=${cases[$i]} value=${cases[$((i + 1))]}
    if [ "$value" = - ]; then
      bk_start "$label" -e "POSTGRES_DATABASE=unused" -e "S3_BUCKET=unused" -e "SCHEDULE=@daily"
    else
      bk_start "$label" -e "POSTGRES_DATABASE=unused" -e "S3_BUCKET=unused" -e "SCHEDULE=@daily" \
        -e "COMMAND_TIMEOUT=$value"
    fi
    ctrs+=("$BK_CTR")
    logs+=("$BK_LOG")
    i=$((i + 3))
  done

  i=0
  n=0
  while [ "$i" -lt ${#cases[@]} ]; do
    label=${cases[$i]} value=${cases[$((i + 1))]} expected=${cases[$((i + 2))]}
    BK_CTR=${ctrs[$n]} BK_LOG=${logs[$n]}
    case $expected in
      ERROR:*)
        _sched_wait_exit 30
        assert_rc 1 "COMMAND_TIMEOUT='$value'"
        _sched_assert_log_match "$_SCHED_TS ERROR: invalid COMMAND_TIMEOUT "
        assert_log_contains "$expected"
        assert_log_not_contains "Cron job scheduled"
        ;;
      *)
        wait_for 30 _sched_log_has_at_least "$expected" 1 \
          || fail "COMMAND_TIMEOUT='$value' ($label): expected '$expected'"
        _sched_running || fail "container for COMMAND_TIMEOUT='$value' stopped"
        assert_log_contains "INFO: Cron job scheduled: @daily"
        ;;
    esac
    i=$((i + 3))
    n=$((n + 1))
  done
}

test_schedule_command_timeout_stops_long_run() {
  db=$(new_db)
  bucket=$(new_bucket)
  hooks_setup
  # The hook is slow while /hook-out/slow exists, so the test can end the slow phase.
  write_hook pre-backup '#!/bin/sh
echo "start $$" >> /hook-out/trace
if [ -e /hook-out/slow ]; then sleep 6; fi
echo "end $$" >> /hook-out/trace'
  touch "$CASE_DIR/hook-out/slow"

  bk_start cron -e "POSTGRES_DATABASE=$db" -e "S3_BUCKET=$bucket" -e "SCHEDULE=@every 2s" \
    -e COMMAND_TIMEOUT=3s "${HOOK_MOUNTS[@]}"
  wait_for 60 _sched_log_has_at_least "Command timed out after 3s" 2 \
    || fail "slow runs were not timed out"
  assert_log_contains "INFO: Command timeout: 3s"
  _sched_assert_log_match "$_SCHED_TS ERROR: Command timed out after 3s\$"
  assert_log_not_contains "Command finished successfully"
  assert_log_not_contains "Creating dump of"
  assert_s3_count "$bucket" "" 0 "timed-out runs must not upload"
  _sched_running || fail "container stopped after a timed-out run"

  # Later runs that finish in time succeed.
  rm -f "$CASE_DIR/hook-out/slow"
  wait_for 60 s3_has_at_least "$bucket" backup/ 1 || { bk_logs; fail "no backup after the slow phase ended"; }
  wait_for 30 _sched_log_has_at_least "Command finished successfully" 1 \
    || fail "no successful run after the slow phase ended"
}

# COMMAND_TIMEOUT kills only the direct child (/bin/sh backup.sh). Anything it
# started (pg_dump, gzip, aws, hook scripts) is re-parented to go-cron and keeps
# running, so a hung pg_dump survives every timeout and the next run starts
# another one beside it.
test_schedule_timeout_kills_child_processes() {
  xfail "COMMAND_TIMEOUT kills only /bin/sh backup.sh; its pg_dump keeps running and timed-out runs pile up"
  db=$(new_db)
  bucket=$(new_bucket)
  _sched_lock_table "$db" app.users

  bk_start cron -e "POSTGRES_DATABASE=$db" -e "S3_BUCKET=$bucket" -e "SCHEDULE=@every 2s" \
    -e COMMAND_TIMEOUT=3s
  wait_for 60 _sched_log_has_at_least "Command timed out after 3s" 2 \
    || fail "runs blocked on the lock were not timed out"

  # At most the current run's pg_dump may be alive; allow a moment for a
  # graceful (SIGTERM, then SIGKILL) implementation to finish the job.
  if ! wait_for 10 _sched_live_procs_at_most pg_dump 1; then
    note "processes in $BK_CTR:"
    docker exec "$BK_CTR" ps -o pid,ppid,stat,args | sed 's/^/# /' >&2
    note "pg_dump sessions on $db: $(psql_exec postgres "SELECT count(*) FROM pg_stat_activity
      WHERE datname = '$db' AND application_name = 'pg_dump'")"
    fail "$(_sched_live_procs pg_dump) pg_dump processes alive after two timed-out runs"
  fi
  assert_s3_count "$bucket" "" 0 "runs blocked on the lock must not upload"
}

test_schedule_overlapping_run_is_skipped() {
  db=$(new_db)
  bucket=$(new_bucket)
  hooks_setup
  write_hook pre-backup '#!/bin/sh
echo "start $$" >> /hook-out/trace
sleep 5
echo "end $$" >> /hook-out/trace'

  bk_start cron -e "POSTGRES_DATABASE=$db" -e "S3_BUCKET=$bucket" -e "SCHEDULE=@every 2s" "${HOOK_MOUNTS[@]}"
  wait_for 60 s3_has_at_least "$bucket" backup/ 1 || { bk_logs; fail "no scheduled backup after 60s"; }
  wait_for 60 _sched_log_has_at_least "Previous command still running; skipping this run" 2 \
    || fail "overlapping ticks were not skipped"
  wait_for 30 _sched_log_has_at_least "Executing command" 2 || fail "no second run after the skips"

  _sched_assert_log_match "$_SCHED_TS WARN: Previous command still running; skipping this run\$"
  _sched_assert_no_overlap "$CASE_DIR/hook-out/trace"
  assert_log_not_contains "Command finished with error"
}

test_schedule_failed_run_keeps_scheduling() {
  db=$(new_db)
  late_bucket="$CASE_SLUG-late"
  hooks_setup
  write_hook backup-error

  # The bucket does not exist yet, so every run fails at the upload.
  bk_start cron -e "POSTGRES_DATABASE=$db" -e "S3_BUCKET=$late_bucket" -e "SCHEDULE=@every 2s" \
    "${HOOK_MOUNTS[@]}"
  wait_for 60 _sched_log_has_at_least "Command finished with error" 2 \
    || fail "failing runs were not reported"
  _sched_assert_log_match "$_SCHED_TS ERROR: Command finished with error: exit status [1-9][0-9]*\$"
  _sched_running || fail "container stopped after a failed run"
  assert_log_not_contains "Command finished successfully"
  wait_for 30 _sched_backup_errors_at_least 2 || fail "backup-error hook did not run for each failed run (events: $(hook_events))"

  new_bucket late >/dev/null
  wait_for 60 s3_has_at_least "$late_bucket" backup/ 1 || { bk_logs; fail "no backup once the bucket existed"; }
  wait_for 30 _sched_log_has_at_least "Command finished successfully" 1 \
    || fail "no successful run once the bucket existed"
}

_sched_backup_errors_at_least() {
  [ "$(grep -c '^backup-error$' "$CASE_DIR/hook-out/events" 2>/dev/null || true)" -ge "$1" ]
}

test_schedule_docker_stop_is_prompt() {
  db=$(new_db)
  bucket=$(new_bucket)

  bk_start idle -e "POSTGRES_DATABASE=$db" -e "S3_BUCKET=$bucket" -e "SCHEDULE=@daily"
  wait_for 30 _sched_log_has_at_least "Cron job scheduled" 1 || fail "idle container did not schedule"
  started=$SECONDS
  bk_stop 30
  took=$((SECONDS - started))
  [ "$took" -lt 10 ] || fail "docker stop of an idle scheduled container took ${took}s"
  _sched_exited || fail "idle container still running after docker stop"

  # Stopping in the middle of a run is just as prompt.
  hooks_setup
  write_hook pre-backup '#!/bin/sh
echo "start $$" >> /hook-out/trace
sleep 60'
  bk_start busy -e "POSTGRES_DATABASE=$db" -e "S3_BUCKET=$bucket" -e "SCHEDULE=@every 2s" "${HOOK_MOUNTS[@]}"
  wait_for 30 test -s "$CASE_DIR/hook-out/trace" || fail "scheduled run did not start"
  started=$SECONDS
  bk_stop 30
  took=$((SECONDS - started))
  [ "$took" -lt 10 ] || fail "docker stop during a scheduled run took ${took}s"
  _sched_exited || fail "busy container still running after docker stop"
}

test_schedule_hooks_run_on_every_run() {
  db=$(new_db)
  bucket=$(new_bucket)
  hooks_setup
  write_hook pre-backup
  write_hook post-backup '#!/bin/sh
echo "$1" >> /hook-out/events
echo "$BACKUP_DEST_FILE" >> /hook-out/dest'

  bk_start cron -e "POSTGRES_DATABASE=$db" -e "S3_BUCKET=$bucket" -e "SCHEDULE=@every 2s" \
    -e HOOK_ALLOW_HTTP=yes -e "HOOK_POST_BACKUP_URL=$(hook_url http ok post)" "${HOOK_MOUNTS[@]}"
  wait_for 90 _sched_dest_lines_at_least 3 || { bk_logs; fail "post-backup hook ran fewer than 3 times"; }
  wait_for 30 _sched_hook_requests_at_least 3 || fail "post-backup URL requested fewer than 3 times"
  bk_stop

  # Strict pre/post alternation, possibly ending with a run cut short by the stop.
  assert_match "$(hook_events)" '^(pre-backup post-backup )+(pre-backup( post-backup)?)?$' "hook order"
  dup=$(sort "$CASE_DIR/hook-out/dest" | uniq -d)
  assert_eq "$dup" "" "post-backup saw the same BACKUP_DEST_FILE twice"
  while IFS= read -r dest; do
    assert_s3_exists "$bucket" "backup/$dest" "BACKUP_DEST_FILE of a scheduled run"
  done <"$CASE_DIR/hook-out/dest"
  assert_eq "$(hook_requests | sort -u)" "http GET /ok/$CASE_SLUG/post" "URL hook requests"
}

_sched_dest_lines_at_least() {
  [ "$(grep -c . "$CASE_DIR/hook-out/dest" 2>/dev/null || true)" -ge "$1" ]
}

_sched_hook_requests_at_least() {
  [ "$(hook_requests | grep -c . || true)" -ge "$1" ]
}

test_schedule_backup_file_restores_once() {
  db=$(new_db)
  bucket=$(new_bucket)
  bk_backup seed "$db" "$bucket"
  assert_rc 0 "seed backup"
  key=$(s3_single_key "$bucket" backup/)

  restored="${db}_restored"
  bk_start restore -e "POSTGRES_DATABASE=$restored" -e "S3_BUCKET=$bucket" -e "BACKUP_FILE=$key" \
    -e CREATE_DATABASE=yes -e "SCHEDULE=@every 2s"
  _sched_wait_exit 120
  assert_rc 0 "restore with SCHEDULE set"
  assert_log_contains "Database restore completed successfully"
  assert_log_not_contains "Cron job scheduled"
  assert_eq "$(grep -c 'Downloading backup file' "$BK_LOG")" 1 "number of restores"
  assert_s3_count "$bucket" backup/ 1 "restore with SCHEDULE must not take backups"
  assert_same_data "$db" "$restored"
}

# go-cron reads each output stream with a bufio.Scanner and its default 64 KiB
# line limit. On a longer line the reader gives up, the pipe fills and the
# backup blocks for ever, so every later tick is skipped. aws s3 cp prints its
# progress as one CR-separated line, which passes 64 KiB on uploads of roughly
# 500 MB; the hook below prints the same kind of line.
test_schedule_long_output_line_does_not_hang() {
  xfail "a scheduled run whose output has a line over 64 KiB (aws progress on a ~500 MB upload) hangs for ever"
  db=$(new_db)
  bucket=$(new_bucket)
  hooks_setup
  write_hook pre-backup '#!/bin/sh
awk '\''BEGIN { for (i = 1; i <= 2500; i++) printf "Completed %d.0 KiB/600.0 MiB (150.0 MiB/s) with 1 file(s) remaining\r", i * 256; print "" }'\'''

  bk_start cron -e "POSTGRES_DATABASE=$db" -e "S3_BUCKET=$bucket" -e "SCHEDULE=@every 2s" "${HOOK_MOUNTS[@]}"
  wait_for 30 s3_has_at_least "$bucket" backup/ 1 || { bk_logs; fail "no backup within 30s; the run is stuck"; }
  wait_for 30 _sched_log_has_at_least "Command finished successfully" 1 || fail "run never finished"
}

# go-cron calls cmd.Wait() while its reader goroutines may still be draining the
# pipes; Wait closes them, so the tail of a run's output is dropped and
# "Error reading output: read |0: file already closed" is logged instead.
test_schedule_output_is_logged_completely() {
  xfail "the end of a scheduled run's output is lost (cmd.Wait closes the pipes before they are drained)"
  db=$(new_db)
  bucket=$(new_bucket)
  hooks_setup
  write_hook post-backup '#!/bin/sh
yes x | head -n 40000
echo end-of-post-backup-output'

  bk_start cron -e "POSTGRES_DATABASE=$db" -e "S3_BUCKET=$bucket" -e "SCHEDULE=@every 2s" "${HOOK_MOUNTS[@]}"
  wait_for 90 _sched_log_has_at_least "Command finished successfully" 2 || fail "fewer than 2 runs finished"
  finished=$(grep -Fc "Command finished successfully" "$BK_LOG")
  markers=$(grep -Fc "STDOUT: end-of-post-backup-output" "$BK_LOG" || true)
  [ "$markers" -ge "$finished" ] \
    || fail "$finished runs finished but only $markers logged their last output line"
  assert_log_not_contains "Error reading output"
}
