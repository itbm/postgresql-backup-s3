# Encryption (ENCRYPTION_PASSWORD): encrypted backups in both formats, restore
# with the right, a wrong or no password, odd passwords and legacy (pre-PBKDF2) backups.

_ENC_PASSWORD='correct horse battery staple'
_ENC_WRONG_PASSWORD='incorrect horse battery staple'
_ENC_ODD_PASSWORD='-p@ss w0rd '"'single'"' "double" $HOME ${PATH} `id` \n \\ * %s ünïcødé 🔐 密码 '
_ENC_TS='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'

# _enc_sh <script> [args...] - runs a shell script in the image under test for
# its openssl, gzip and xxd, so the host needs nothing beyond Docker. Stdin and
# stdout are passed through. Passwords are passed as arguments, never pasted into
# the script.
_enc_sh() {
  _es_script=$1
  shift
  docker run --rm -i --network none --label "e2e.run=$E2E_RUN_ID" --entrypoint sh "$E2E_IMAGE" \
    -c "$_es_script" sh "$@"
}

# _enc_decrypt <in> <out> <password> - README's manual decrypt command.
_enc_decrypt() {
  _enc_sh 'export PW=$1; openssl enc -aes-256-cbc -d -pbkdf2 -iter 100000 -pass env:PW 2>/dev/null' \
    "$3" <"$1" >"$2"
}

# _enc_decrypt_legacy <in> <out> <password> - the pre-PBKDF2 key derivation.
_enc_decrypt_legacy() {
  _enc_sh 'export PW=$1; openssl enc -aes-256-cbc -d -pass env:PW 2>/dev/null' "$3" <"$1" >"$2"
}

_enc_assert_salted() {
  assert_eq "$(head -c 8 "$1")" "Salted__" "${2:-encrypted file should start with the OpenSSL salt header}"
}

# _enc_assert_gzip_has_line <file> <line> - the file is valid gzip and its
# content has that exact line.
_enc_assert_gzip_has_line() {
  _enc_sh 'gunzip -c >/tmp/plain && grep -Fxq -- "$1" /tmp/plain' "$2" <"$1" \
    || fail "${3:-expected a valid gzip file with the line} '$2' ($1)"
}

# _enc_legacy_encrypt <in> <out> <password> - encrypts as releases before PBKDF2
# did (openssl enc -aes-256-cbc -k: salted, one round of SHA-256). openssl leaves
# out the Salted__ header when given -S, so it is written here. The salt is the
# first of a fixed list for which restore.sh's PBKDF2 attempt fails, as it does
# for about 255 salts in 256; the other case has its own test.
_enc_legacy_encrypt() {
  _enc_sh '
    export PW=$1
    cat >/tmp/plain
    for salt in e2e1000000000000 e2e1000000000001 e2e1000000000002 e2e1000000000003; do
      { printf Salted__; printf %s "$salt" | xxd -r -p
        openssl enc -aes-256-cbc -S "$salt" -pass env:PW -in /tmp/plain 2>/dev/null; } >/tmp/enc || exit 1
      if ! openssl enc -aes-256-cbc -d -pbkdf2 -iter 100000 -pass env:PW -in /tmp/enc -out /dev/null 2>/dev/null; then
        cat /tmp/enc
        exit 0
      fi
    done
    exit 1' "$3" <"$1" >"$2" || fail "could not legacy-encrypt $1"
}

# _enc_pick_wrong_password <encrypted-file> - prints a wrong password that both
# of restore.sh's decrypt attempts reject. CBC without authentication accepts a
# wrong key about 1 time in 256, which would make a test against a backup with
# a random salt flaky; that case has its own tests.
_enc_pick_wrong_password() {
  _enc_sh '
    cat >/tmp/enc
    for pw in "wrong password 1" "wrong password 2" "wrong password 3" "wrong password 4"; do
      export PW="$pw"
      if ! openssl enc -aes-256-cbc -d -pbkdf2 -iter 100000 -pass env:PW -in /tmp/enc -out /dev/null 2>/dev/null &&
        ! openssl enc -aes-256-cbc -d -pass env:PW -in /tmp/enc -out /dev/null 2>/dev/null; then
        printf "%s\n" "$pw"
        exit 0
      fi
    done
    exit 1' <"$1"
}

# Fixed restore input for the CBC padding tests. Their salts were found by
# brute force for exactly these bytes, so changing the SQL invalidates them.
_enc_fixture_sql() {
  printf '%s\n' \
    "CREATE TABLE enc_fixture (id integer PRIMARY KEY, note text);" \
    "INSERT INTO enc_fixture VALUES (1, 'alpha'), (2, 'beta'), (3, 'gamma');"
}

# _enc_fixture_backup <out> <password> <salt> [openssl options...] - the fixture
# SQL as gzip with a single stored block (the same bytes whatever gzip the image
# ships), encrypted with a fixed salt. Without options it uses the legacy key
# derivation; pass -pbkdf2 -iter 100000 for the current format.
_enc_fixture_backup() {
  _ef_out=$1
  shift
  _enc_fixture_sql | _enc_sh '
    cat >/tmp/sql
    n=$(wc -c </tmp/sql)
    byte() { printf "\\$(printf %03o "$1")"; }
    { printf "\037\213\010\000\000\000\000\000\000\377"
      byte 1
      byte $((n & 255)); byte $(((n >> 8) & 255))
      byte $(((n ^ 65535) & 255)); byte $((((n ^ 65535) >> 8) & 255))
      cat /tmp/sql
      gzip -c </tmp/sql | tail -c 8; } >/tmp/plain.gz
    export PW=$1
    salt=$2
    shift 2
    printf Salted__
    printf %s "$salt" | xxd -r -p
    openssl enc -aes-256-cbc -S "$salt" "$@" -pass env:PW -in /tmp/plain.gz 2>/dev/null' "$@" >"$_ef_out" \
    || fail "could not build the fixture backup"
}

_enc_fixture_rows() {
  psql_exec "$1" "SELECT string_agg(id || ':' || note, ',' ORDER BY id) FROM enc_fixture"
}

# Name for a database that does not exist yet.
_enc_new_db_name() {
  printf 't_%s%s' "$CASE_SLUG" "${1:+_$1}" | tr '-' '_' | cut -c1-63
}

_enc_assert_db_absent() {
  if db_exists "$1"; then
    fail "${2:-database should not exist}: $1"
  fi
}

# _enc_assert_unchanged <database> <fingerprint-file> - the database still matches
# a db_fingerprint taken earlier.
_enc_assert_unchanged() {
  db_fingerprint "$1" >"$CASE_DIR/fingerprint-after.txt" || fail "could not fingerprint $1"
  diff -u "$2" "$CASE_DIR/fingerprint-after.txt" >&2 || fail "database $1 was modified"
}

# ---------------------------------------------------------------------------
# Backups.

test_encryption_plain_backup_uploads_only_encrypted_object() {
  db=$(new_db)
  bucket=$(new_bucket)

  bk_backup backup "$db" "$bucket" -e "ENCRYPTION_PASSWORD=$_ENC_PASSWORD"
  assert_rc 0 "encrypted backup"
  assert_log_contains "Encrypting /tmp/dump.sql.gz"
  assert_log_contains "SQL backup finished"
  assert_log_not_contains "$_ENC_PASSWORD" "the password must not be logged"
  assert_eq "$(bk_tmp_leftovers)" "" "plaintext or encrypted dump left in /tmp after backup"

  # Exactly one object in the whole bucket: no plaintext copy next to it.
  key=$(s3_single_key "$bucket" "")
  assert_match "$key" "^backup/${db}_${_ENC_TS}\.sql\.gz\.enc$" "encrypted backup key"

  s3_get "$bucket" "$key" "$CASE_DIR/backup.enc"
  _enc_assert_salted "$CASE_DIR/backup.enc"
  _enc_decrypt "$CASE_DIR/backup.enc" "$CASE_DIR/backup.sql.gz" "$_ENC_PASSWORD" \
    || fail "README's manual decrypt command failed on the backup"
  _enc_assert_gzip_has_line "$CASE_DIR/backup.sql.gz" "-- PostgreSQL database dump complete" \
    "decrypted backup should be a complete gzipped SQL dump"
}

test_encryption_custom_format_round_trip_with_parallel_jobs() {
  db=$(new_db)
  bucket=$(new_bucket)

  bk_backup backup "$db" "$bucket" -e USE_CUSTOM_FORMAT=yes -e "ENCRYPTION_PASSWORD=$_ENC_PASSWORD"
  assert_rc 0 "encrypted custom format backup"
  assert_log_contains "Encrypting /tmp/dump.dump"
  assert_eq "$(bk_tmp_leftovers)" "" "plaintext or encrypted dump left in /tmp after backup"
  key=$(s3_single_key "$bucket" "")
  assert_match "$key" "^backup/${db}_${_ENC_TS}\.dump\.enc$" "encrypted custom format key"

  s3_get "$bucket" "$key" "$CASE_DIR/backup.enc"
  _enc_assert_salted "$CASE_DIR/backup.enc"
  _enc_decrypt "$CASE_DIR/backup.enc" "$CASE_DIR/backup.dump" "$_ENC_PASSWORD" \
    || fail "README's manual decrypt command failed on the custom format backup"
  assert_eq "$(head -c 5 "$CASE_DIR/backup.dump")" "PGDMP" "decrypted file should be a pg_dump archive"

  for jobs in 1 4; do
    target="${db}_j$jobs"
    bk_restore "restore-j$jobs" "$target" "$bucket" "$key" -e "ENCRYPTION_PASSWORD=$_ENC_PASSWORD" \
      -e CREATE_DATABASE=yes -e "PARALLEL_JOBS=$jobs"
    assert_rc 0 "restore of the encrypted custom format backup with PARALLEL_JOBS=$jobs"
    assert_log_contains "Decrypting backup file"
    assert_log_contains "Restoring database $target from custom format"
    if [ "$jobs" -gt 1 ]; then
      assert_log_contains "Using parallel restore with $jobs jobs"
    else
      assert_log_not_contains "Using parallel restore"
    fi
    assert_log_not_contains "WARNING: Decrypted legacy"
    assert_same_data "$db" "$target"
    assert_eq "$(bk_tmp_leftovers)" "" "temporary files left in /tmp after restore (PARALLEL_JOBS=$jobs)"
  done
}

test_encryption_failure_uploads_nothing() {
  db=$(new_db)
  bucket=$(new_bucket)
  # A read-only directory where openssl wants to write the encrypted file.
  mkdir -p "$CASE_DIR/blocker"

  bk_backup backup "$db" "$bucket" -e "ENCRYPTION_PASSWORD=$_ENC_PASSWORD" \
    -v "$CASE_DIR/blocker:/tmp/dump.sql.gz.enc:ro"
  assert_rc 1 "backup whose encryption fails"
  assert_log_contains "Error encrypting /tmp/dump.sql.gz"
  assert_log_not_contains "Uploading dump"
  assert_log_not_contains "SQL backup finished"
  assert_s3_count "$bucket" "" 0 "nothing should be uploaded when encryption fails"
  assert_eq "$(bk_tmp_leftovers | grep -vFx /tmp/dump.sql.gz.enc)" "" "plaintext dump left in /tmp after a failed encryption"
}

# ---------------------------------------------------------------------------
# Restores.

test_encryption_restore_with_right_password() {
  db=$(new_db)
  bucket=$(new_bucket)
  bk_backup backup "$db" "$bucket" -e "ENCRYPTION_PASSWORD=$_ENC_PASSWORD"
  assert_rc 0 "encrypted backup"
  key=$(s3_single_key "$bucket" backup/)

  restored="${db}_restored"
  bk_restore restore "$restored" "$bucket" "$key" -e "ENCRYPTION_PASSWORD=$_ENC_PASSWORD" -e CREATE_DATABASE=yes
  assert_rc 0 "restore of an encrypted backup"
  assert_log_contains "Decrypting backup file"
  assert_log_not_contains "WARNING: Decrypted legacy"
  assert_log_contains "Database restore completed successfully"
  assert_log_contains "Cleaning up temporary files"
  assert_log_not_contains "$_ENC_PASSWORD" "the password must not be logged"
  assert_same_data "$db" "$restored"
  assert_eq "$(bk_tmp_leftovers)" "" "encrypted or decrypted file left in /tmp after restore"
}

test_encryption_wrong_password_changes_nothing() {
  db=$(new_db)
  bucket=$(new_bucket)
  bk_backup backup "$db" "$bucket" -e "ENCRYPTION_PASSWORD=$_ENC_PASSWORD"
  assert_rc 0 "encrypted backup"
  key=$(s3_single_key "$bucket" backup/)
  s3_get "$bucket" "$key" "$CASE_DIR/backup.enc"
  wrong=$(_enc_pick_wrong_password "$CASE_DIR/backup.enc") || fail "no candidate wrong password is rejected"
  psql_exec "$db" "CREATE TABLE app.enc_marker (id integer); INSERT INTO app.enc_marker VALUES (7)" >/dev/null \
    || fail "could not modify $db"
  db_fingerprint "$db" >"$CASE_DIR/before.txt" || fail "could not fingerprint $db"

  bk_restore existing "$db" "$bucket" "$key" -e "ENCRYPTION_PASSWORD=$wrong" \
    -e DROP_DATABASE=yes -e CREATE_DATABASE=yes
  assert_rc 1 "restore with a wrong password"
  assert_log_contains "Decrypting backup file"
  assert_log_contains "Error decrypting backup file. Check your encryption password."
  assert_log_not_contains "Dropping database"
  assert_log_not_contains "Database restore completed successfully"
  _enc_assert_unchanged "$db" "$CASE_DIR/before.txt"
  assert_eq "$(bk_tmp_leftovers)" "" "decrypted or encrypted file left in /tmp after a wrong password"

  target=$(_enc_new_db_name new)
  bk_restore new "$target" "$bucket" "$key" -e "ENCRYPTION_PASSWORD=$wrong" -e CREATE_DATABASE=yes
  assert_rc 1 "restore into a new database with a wrong password"
  assert_log_contains "Error decrypting backup file. Check your encryption password."
  _enc_assert_db_absent "$target" "no database should be created after a wrong password"
  assert_eq "$(bk_tmp_leftovers)" "" "decrypted or encrypted file left in /tmp after a wrong password"
}

test_encryption_restore_without_password_fails() {
  db=$(new_db)
  bucket=$(new_bucket)
  bk_backup backup "$db" "$bucket" -e "ENCRYPTION_PASSWORD=$_ENC_PASSWORD"
  assert_rc 0 "encrypted backup"
  key=$(s3_single_key "$bucket" backup/)
  psql_exec "$db" "CREATE TABLE app.enc_marker (id integer)" >/dev/null || fail "could not modify $db"
  db_fingerprint "$db" >"$CASE_DIR/before.txt" || fail "could not fingerprint $db"

  bk_restore restore "$db" "$bucket" "$key" -e DROP_DATABASE=yes -e CREATE_DATABASE=yes
  assert_rc 1 "restore of an encrypted backup without ENCRYPTION_PASSWORD"
  assert_log_contains "Backup file is encrypted. You need to set the ENCRYPTION_PASSWORD environment variable."
  assert_log_not_contains "Decrypting backup file"
  assert_log_not_contains "Dropping database"
  _enc_assert_unchanged "$db" "$CASE_DIR/before.txt"
  assert_eq "$(bk_tmp_leftovers)" "" "downloaded file left in /tmp"
}

test_encryption_unencrypted_backup_restores_with_password_set() {
  db=$(new_db)
  bucket=$(new_bucket)
  bk_backup backup "$db" "$bucket"
  assert_rc 0 "unencrypted backup"
  key=$(s3_single_key "$bucket" backup/)
  assert_match "$key" '\.sql\.gz$' "unencrypted backup key"

  restored="${db}_restored"
  bk_restore restore "$restored" "$bucket" "$key" -e "ENCRYPTION_PASSWORD=$_ENC_PASSWORD" -e CREATE_DATABASE=yes
  assert_rc 0 "restore of an unencrypted backup with ENCRYPTION_PASSWORD set"
  assert_log_not_contains "Decrypting backup file"
  assert_log_contains "Database restore completed successfully"
  assert_same_data "$db" "$restored"
  assert_eq "$(bk_tmp_leftovers)" "" "downloaded file left in /tmp after restore"
}

test_encryption_password_with_special_characters() {
  db=$(new_db)
  bucket=$(new_bucket)

  bk_backup backup "$db" "$bucket" -e "ENCRYPTION_PASSWORD=$_ENC_ODD_PASSWORD"
  assert_rc 0 "backup with an awkward password"
  assert_log_not_contains "$_ENC_ODD_PASSWORD" "the password must not be logged"
  key=$(s3_single_key "$bucket" "")
  assert_match "$key" '\.sql\.gz\.enc$' "encrypted backup key"

  # The password must be used byte for byte, not shell-expanded or split.
  s3_get "$bucket" "$key" "$CASE_DIR/backup.enc"
  _enc_decrypt "$CASE_DIR/backup.enc" "$CASE_DIR/backup.sql.gz" "$_ENC_ODD_PASSWORD" \
    || fail "manual decrypt with the exact password failed"
  _enc_assert_gzip_has_line "$CASE_DIR/backup.sql.gz" "-- PostgreSQL database dump complete"

  restored="${db}_restored"
  bk_restore restore "$restored" "$bucket" "$key" -e "ENCRYPTION_PASSWORD=$_ENC_ODD_PASSWORD" -e CREATE_DATABASE=yes
  assert_rc 0 "restore with an awkward password"
  assert_log_not_contains "WARNING: Decrypted legacy"
  assert_log_not_contains "$_ENC_ODD_PASSWORD" "the password must not be logged"
  assert_same_data "$db" "$restored"
}

# ---------------------------------------------------------------------------
# Legacy backups, as releases before PBKDF2 wrote them: openssl enc -aes-256-cbc
# -k "$ENCRYPTION_PASSWORD". Every release used Alpine 3.9 or later, so OpenSSL
# 1.1 or later and its SHA-256 default digest.

test_encryption_legacy_backups_restore_with_warning() {
  db=$(new_db)
  bucket=$(new_bucket)

  for format in plain custom; do
    if [ "$format" = custom ]; then
      bk_backup "backup-$format" "$db" "$bucket" -e "S3_PREFIX=$format" -e USE_CUSTOM_FORMAT=yes
      ext=dump
    else
      bk_backup "backup-$format" "$db" "$bucket" -e "S3_PREFIX=$format"
      ext=sql.gz
    fi
    assert_rc 0 "unencrypted $format backup"
    s3_get "$bucket" "$(s3_single_key "$bucket" "$format/")" "$CASE_DIR/$format.plain"
    _enc_legacy_encrypt "$CASE_DIR/$format.plain" "$CASE_DIR/$format.enc" "$_ENC_PASSWORD"
    _enc_assert_salted "$CASE_DIR/$format.enc"
    key="legacy/${db}_2020-01-01T00:00:00Z.$ext.enc"
    s3_put "$bucket" "$key" "$CASE_DIR/$format.enc"

    restored="${db}_$format"
    bk_restore "restore-$format" "$restored" "$bucket" "$key" -e "ENCRYPTION_PASSWORD=$_ENC_PASSWORD" \
      -e CREATE_DATABASE=yes
    assert_rc 0 "restore of a legacy $format backup"
    assert_log_contains "Decrypting backup file"
    assert_log_contains "WARNING: Decrypted legacy OpenSSL backup (non-PBKDF2). Re-backup to upgrade encryption."
    assert_log_contains "Database restore completed successfully"
    assert_same_data "$db" "$restored"
    assert_eq "$(bk_tmp_leftovers)" "" "temporary files left in /tmp after a legacy $format restore"
  done
}

# Control for the misread test below: the same fixture with an ordinary salt.
test_encryption_legacy_fixture_restores_with_ordinary_salt() {
  bucket=$(new_bucket)
  target=$(_enc_new_db_name)
  _enc_fixture_backup "$CASE_DIR/legacy.enc" "$_ENC_PASSWORD" e2e0000000000000
  s3_put "$bucket" backup/legacy.sql.gz.enc "$CASE_DIR/legacy.enc"

  bk_restore restore "$target" "$bucket" backup/legacy.sql.gz.enc -e "ENCRYPTION_PASSWORD=$_ENC_PASSWORD" \
    -e CREATE_DATABASE=yes
  assert_rc 0 "restore of the legacy fixture"
  assert_log_contains "WARNING: Decrypted legacy OpenSSL backup (non-PBKDF2)"
  assert_eq "$(_enc_fixture_rows "$target")" "1:alpha,2:beta,3:gamma" "restored fixture rows"
}

test_encryption_legacy_backup_misread_as_pbkdf2() {
  xfail "restore.sh only falls back to the legacy key derivation when the PBKDF2 attempt fails, but about 1 legacy backup in 256 passes the CBC padding check with the PBKDF2 key and is restored as garbage"
  bucket=$(new_bucket)
  target=$(_enc_new_db_name)
  # Salt found by brute force: with it the PBKDF2 trial decrypt of this legacy
  # file passes the padding check and yields garbage.
  _enc_fixture_backup "$CASE_DIR/legacy.enc" "$_ENC_PASSWORD" e2e0000000000084
  _enc_decrypt "$CASE_DIR/legacy.enc" "$CASE_DIR/garbage" "$_ENC_PASSWORD" \
    || fail "precondition: the PBKDF2 trial decrypt of this fixture should pass the padding check"
  s3_put "$bucket" backup/legacy.sql.gz.enc "$CASE_DIR/legacy.enc"

  bk_restore restore "$target" "$bucket" backup/legacy.sql.gz.enc -e "ENCRYPTION_PASSWORD=$_ENC_PASSWORD" \
    -e CREATE_DATABASE=yes
  assert_rc 0 "restore of a legacy backup"
  assert_log_contains "WARNING: Decrypted legacy OpenSSL backup (non-PBKDF2)"
  assert_eq "$(_enc_fixture_rows "$target")" "1:alpha,2:beta,3:gamma" "restored fixture rows"
}

# ---------------------------------------------------------------------------
# A wrong password that slips through the CBC padding check (about 2 in 256).

test_encryption_wrong_password_passing_pbkdf2_padding_keeps_database() {
  xfail "a wrong password whose PBKDF2 decrypt passes the CBC padding check (about 1 in 256) is not detected, so DROP_DATABASE=yes drops the database before the restore fails"
  db=$(new_db)
  bucket=$(new_bucket)
  _enc_fixture_backup "$CASE_DIR/backup.enc" "$_ENC_PASSWORD" e2e0000000000212 -pbkdf2 -iter 100000
  _enc_decrypt "$CASE_DIR/backup.enc" "$CASE_DIR/garbage" "$_ENC_WRONG_PASSWORD" \
    || fail "precondition: the wrong password should pass the PBKDF2 padding check for this fixture"
  s3_put "$bucket" backup/fixture.sql.gz.enc "$CASE_DIR/backup.enc"

  bk_restore restore "$db" "$bucket" backup/fixture.sql.gz.enc -e "ENCRYPTION_PASSWORD=$_ENC_WRONG_PASSWORD" \
    -e DROP_DATABASE=yes -e CREATE_DATABASE=yes
  assert_rc 1 "restore with a wrong password"
  assert_same_data e2e_seed "$db"
  assert_log_contains "Error decrypting backup file. Check your encryption password."
  assert_log_not_contains "Dropping database"
}

test_encryption_wrong_password_passing_legacy_padding_keeps_database() {
  xfail "a wrong password whose legacy fallback decrypt passes the CBC padding check (about 1 in 256) is reported as a legacy backup, and DROP_DATABASE=yes drops the database before the restore fails"
  db=$(new_db)
  bucket=$(new_bucket)
  _enc_fixture_backup "$CASE_DIR/backup.enc" "$_ENC_PASSWORD" e2e00000000000cd -pbkdf2 -iter 100000
  if _enc_decrypt "$CASE_DIR/backup.enc" "$CASE_DIR/garbage" "$_ENC_WRONG_PASSWORD"; then
    fail "precondition: the wrong password should fail the PBKDF2 padding check for this fixture"
  fi
  _enc_decrypt_legacy "$CASE_DIR/backup.enc" "$CASE_DIR/garbage" "$_ENC_WRONG_PASSWORD" \
    || fail "precondition: the wrong password should pass the legacy padding check for this fixture"
  s3_put "$bucket" backup/fixture.sql.gz.enc "$CASE_DIR/backup.enc"

  bk_restore restore "$db" "$bucket" backup/fixture.sql.gz.enc -e "ENCRYPTION_PASSWORD=$_ENC_WRONG_PASSWORD" \
    -e DROP_DATABASE=yes -e CREATE_DATABASE=yes
  assert_rc 1 "restore with a wrong password"
  assert_same_data e2e_seed "$db"
  assert_log_contains "Error decrypting backup file. Check your encryption password."
  assert_log_not_contains "WARNING: Decrypted legacy"
  assert_log_not_contains "Dropping database"
}
