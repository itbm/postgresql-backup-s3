test_tmp_s3_extra_opts_backup_and_restore() {
  db=$(new_db) || exit 1
  bucket=$(new_bucket) || exit 1

  bk_backup backup "$db" "$bucket" -e "S3_EXTRA_OPTS=--metadata e2efoo=e2ebar"
  assert_rc 0 "backup with S3_EXTRA_OPTS"
  key=$(s3_single_key "$bucket" backup/) || exit 1
  meta=$(mc_cli stat --json "e2e/$bucket/$key")
  assert_match "$meta" '[Ee]2efoo"?:"?e2ebar' "metadata from S3_EXTRA_OPTS missing: $meta"

  bk_restore restore "${db}_copy" "$bucket" "$key" -e CREATE_DATABASE=yes -e "S3_EXTRA_OPTS=--no-progress"
  assert_rc 0 "restore with S3_EXTRA_OPTS"
  assert_same_data "$db" "${db}_copy"

  bk_backup badbackup "$db" "$bucket" -e "S3_EXTRA_OPTS=--no-such-option"
  assert_rc_nonzero "control: bad S3_EXTRA_OPTS must fail backup"
  bk_restore badrestore "${db}_copy2" "$bucket" "$key" -e CREATE_DATABASE=yes -e "S3_EXTRA_OPTS=--no-such-option"
  assert_rc_nonzero "control: bad S3_EXTRA_OPTS must fail restore"
}
