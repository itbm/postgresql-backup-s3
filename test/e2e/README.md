# End-to-end tests

These tests build the image and run it, as a user would, against real services on a private Docker network:

| Service     | Image                                      | Reached by the image as                  |
|-------------|--------------------------------------------|------------------------------------------|
| PostgreSQL  | `postgres:18-alpine` (matches the client)  | `pg:5432`                                |
| MinIO       | `cgr.dev/chainguard/minio:latest`          | `http://minio:9000`                      |
| MinIO (TLS) | same, with a throwaway CA                  | `https://minio-tls:9000`                 |
| Hook receiver | `python:3.14-alpine` running `hook_server.py` | `http://hooks:8080`, `https://hooks:8443` |

MinIO stopped publishing its own images to Docker Hub and Quay in 2025, so the suite uses Chainguard's free MinIO build.

## Running

You need bash and Docker. Nothing else is installed on the host.

```sh
# Everything (builds the image first)
test/e2e/run.sh

# Only tests whose names match a regex
test/e2e/run.sh 'restore|encryption'

# Only some case files, reusing an image you already built
E2E_BUILD=0 E2E_IMAGE=postgres-backup-s3:e2e E2E_CASES="backup.sh restore.sh" test/e2e/run.sh

# List the tests without running anything
E2E_LIST=1 test/e2e/run.sh
```

Each run uses its own network and container names, so two runs can share one Docker daemon. Everything is removed afterwards, including each case's databases as soon as the case ends. `E2E_KEEP=1` keeps it all for debugging; remove it afterwards with `docker rm -f -v $(docker ps -aq --filter label=e2e.run=<id>)` (the `-v` also removes PostgreSQL's data volumes) and `docker network rm <id>-net`. `E2E_VERBOSE=1` prints the output of passing tests too. The header of `run.sh` lists every setting, including how to test against another PostgreSQL server version (`E2E_POSTGRES_IMAGE`).

The output has one line per test: `ok`, `FAIL`, `xfail` (a known product bug, see below), `XPASS` or `skip`. The run fails on any `FAIL` or `XPASS`. A failing test prints its own output and the tail of the container log.

## Layout

- `run.sh`: builds the image, starts the services, loads the seed data, runs the tests and cleans up.
- `lib.sh`: helpers for running the image and checking S3, PostgreSQL and hooks. Read its comments before writing a test.
- `cases/*.sh`: the tests, one file per feature area. Every `test_*` function is a test.
- `fixtures/seed.sql`: the `e2e_seed` template database. It has awkward data on purpose: unicode, NULLs, bytea, JSON, arrays, partitions, a materialised view, a trigger, a sequence and a large object.
- `fixtures/fingerprint.sql`: prints one line per object with a checksum of its contents. `assert_same_data` compares two databases with it to prove a restore is exact.
- `hook_server.py`: records URL hook requests. The first path segment chooses the reply (`ok` 200, `fail` 403, `error500` 500, `redirect` 302).

## Writing a test

```sh
test_restore_custom_format_parallel() {
  db=$(new_db)            # fresh copy of the seed database
  bucket=$(new_bucket)    # fresh bucket

  bk_backup backup "$db" "$bucket" -e USE_CUSTOM_FORMAT=yes
  assert_rc 0
  key=$(s3_single_key "$bucket" backup/)

  bk_restore restore "${db}_copy" "$bucket" "$key" -e CREATE_DATABASE=yes -e PARALLEL_JOBS=4
  assert_rc 0
  assert_log_contains "Using parallel restore with 4 jobs"
  assert_same_data "$db" "${db}_copy"
}
```

- Each test runs in its own subshell and gets its own database and bucket. Don't rely on other tests or on their order.
- `bk_run` and its wrappers start from a working configuration (`E2E_BASE_ENV` in `lib.sh`). Add `-e NAME=value` to override a variable, and `--unset NAME` to leave it at the image default.
- Assert what a user would see: the exit code, the log, the objects in S3 and the data in PostgreSQL.
- Assert outcomes rather than implementation details: check S3 contents, exit codes and data, and match only the parts of log lines that a user would rely on. A temporary file path or the exact wording of an internal message should not decide whether a test passes.
- Poll with `wait_for` rather than sleeping a fixed time.

## Known bugs

If a test exposes a product bug that is not fixed yet, write the test for the correct behaviour and call `xfail "short reason"` just before the step that exposes the bug, after the setup. The run reports it as `xfail` and stays green, while a failure during setup still shows as `FAIL`. Once the bug is fixed, the test passes and the run fails with `XPASS` until the marker is removed.
