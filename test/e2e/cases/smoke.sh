# Smoke test: the documented "Basic Usage" backup and restore commands, end to
# end, with default settings. If this fails, start here.

test_smoke_default_backup_then_restore() {
  db=$(new_db)
  bucket=$(new_bucket)

  bk_backup backup "$db" "$bucket"
  assert_rc 0 "default backup"
  assert_log_contains "Creating dump of $db database from pg..."
  assert_log_contains "SQL backup finished"

  key=$(s3_single_key "$bucket" "backup/")
  assert_match "$key" "^backup/${db}_[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\.sql\.gz$" "backup key"
  assert_eq "$(bk_tmp_leftovers)" "" "temporary files left in /tmp after backup"

  restored="${db}_restored"
  bk_restore restore "$restored" "$bucket" "$key" -e CREATE_DATABASE=yes
  assert_rc 0 "restore into a new database"
  assert_log_contains "Database restore completed successfully"
  assert_same_data "$db" "$restored"
  assert_eq "$(bk_tmp_leftovers)" "" "temporary files left in /tmp after restore"
}
