#!/usr/bin/env bash
# End-to-end tests for the postgres-backup-s3 image.
#
# Builds the image, then starts PostgreSQL, MinIO (HTTP and HTTPS) and a URL
# hook receiver on a private Docker network and runs every test_* function in
# test/e2e/cases/*.sh against them. Needs only bash and Docker.
#
# Usage: test/e2e/run.sh [name-regex]
#
# Environment:
#   E2E_FILTER            regex of test names to run (same as the argument)
#   E2E_CASES             case files to load, e.g. "backup.sh restore.sh" (default: all)
#   E2E_IMAGE             image tag to test (default: postgres-backup-s3:e2e)
#   E2E_BUILD             1 to build E2E_IMAGE from this checkout first (default), 0 to skip
#   E2E_POSTGRES_IMAGE    PostgreSQL server image (default: postgres:18-alpine)
#   E2E_MINIO_IMAGE       MinIO server image (default: cgr.dev/chainguard/minio:latest)
#   E2E_MC_IMAGE          MinIO client image (default: cgr.dev/chainguard/minio-client:latest)
#   E2E_HOOK_SERVER_IMAGE Python image for the hook receiver (default: python:3.14-alpine)
#   E2E_ARTIFACTS         directory to copy logs of failed cases into
#   E2E_KEEP              1 to leave containers and the work directory behind
#   E2E_VERBOSE           1 to print the output of passing cases too
#   E2E_RUN_ID            prefix for container and network names (default: random)
#   E2E_LIST              1 to list the selected tests and exit

E2E_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$E2E_DIR/../.." && pwd)

E2E_IMAGE=${E2E_IMAGE:-postgres-backup-s3:e2e}
E2E_BUILD=${E2E_BUILD:-1}
E2E_POSTGRES_IMAGE=${E2E_POSTGRES_IMAGE:-postgres:18-alpine}
E2E_MINIO_IMAGE=${E2E_MINIO_IMAGE:-cgr.dev/chainguard/minio:latest}
E2E_MC_IMAGE=${E2E_MC_IMAGE:-cgr.dev/chainguard/minio-client:latest}
E2E_HOOK_SERVER_IMAGE=${E2E_HOOK_SERVER_IMAGE:-python:3.14-alpine}
E2E_FILTER=${1:-${E2E_FILTER:-}}
E2E_CASES=${E2E_CASES:-}
E2E_KEEP=${E2E_KEEP:-0}
E2E_VERBOSE=${E2E_VERBOSE:-0}
E2E_RUN_ID=${E2E_RUN_ID:-e2e$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')}
E2E_NET="${E2E_RUN_ID}-net"
E2E_PG_CTR="${E2E_RUN_ID}-pg"
E2E_TIMEOUT=
if command -v timeout >/dev/null 2>&1; then
  E2E_TIMEOUT="timeout ${E2E_RUN_TIMEOUT:-300}"
fi

export E2E_DIR E2E_IMAGE E2E_POSTGRES_IMAGE E2E_MC_IMAGE E2E_RUN_ID E2E_NET E2E_PG_CTR E2E_TIMEOUT

# shellcheck source=test/e2e/lib.sh
. "$E2E_DIR/lib.sh"

log() {
  printf '%s\n' "$*" >&2
}

die() {
  log "e2e: $*"
  exit 2
}

in_github() {
  [ "${GITHUB_ACTIONS:-}" = true ]
}

# ---------------------------------------------------------------------------
# Test discovery.

case_files=()
if [ -n "$E2E_CASES" ]; then
  for f in $E2E_CASES; do
    case_files+=("$E2E_DIR/cases/${f##*/}")
  done
else
  for f in "$E2E_DIR"/cases/*.sh; do
    [ -e "$f" ] && case_files+=("$f")
  done
fi
[ ${#case_files[@]} -gt 0 ] || die "no case files found"

tests=()
for f in "${case_files[@]}"; do
  [ -f "$f" ] || die "case file not found: $f"
  # shellcheck source=/dev/null
  . "$f"
  for t in $(grep -Eo '^test_[A-Za-z0-9_]+' "$f"); do
    if [ -z "$E2E_FILTER" ] || printf '%s' "$t" | grep -Eq -- "$E2E_FILTER"; then
      tests+=("$t")
    fi
  done
done
[ ${#tests[@]} -gt 0 ] || die "no tests match '${E2E_FILTER}'"

if [ "${E2E_LIST:-0}" = 1 ]; then
  printf '%s\n' "${tests[@]}"
  exit 0
fi

slugify() {
  _s=$(printf '%s' "${1#test_}" | tr '[:upper:]_' '[:lower:]-' | tr -cd 'a-z0-9-')
  if [ ${#_s} -gt 40 ]; then
    _h=$(printf '%s' "$1" | cksum | cut -c1-6)
    _s="$(printf '%s' "$_s" | cut -c1-33)-$_h"
  fi
  printf '%s' "$_s"
}

# ---------------------------------------------------------------------------
# Infrastructure.

E2E_WORK=$(mktemp -d "${TMPDIR:-/tmp}/pgbs3-e2e.XXXXXX") || die "mktemp failed"
chmod 755 "$E2E_WORK"
E2E_CERTS="$E2E_WORK/certs"
export E2E_WORK E2E_CERTS

cleanup() {
  status=$?
  trap - EXIT INT TERM
  if [ "$E2E_KEEP" = 1 ]; then
    log "e2e: kept containers (label e2e.run=$E2E_RUN_ID) and work dir $E2E_WORK"
    exit "$status"
  fi
  ids=$(docker ps -aq --filter "label=e2e.run=$E2E_RUN_ID")
  [ -z "$ids" ] || docker rm -f $ids >/dev/null 2>&1
  docker network rm "$E2E_NET" >/dev/null 2>&1
  # Containers write root-owned files into the work dir; remove them as root.
  docker run --rm -v "$E2E_WORK:/work" --entrypoint sh "$E2E_IMAGE" \
    -c 'rm -rf /work/* /work/.[!.]*' >/dev/null 2>&1
  rm -rf "$E2E_WORK" 2>/dev/null
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ "$E2E_BUILD" = 1 ]; then
  log "e2e: building $E2E_IMAGE"
  docker build -t "$E2E_IMAGE" "$ROOT" >"$E2E_WORK/build.log" 2>&1 || {
    tail -n 50 "$E2E_WORK/build.log" >&2
    die "image build failed"
  }
fi
docker image inspect "$E2E_IMAGE" >/dev/null 2>&1 || die "image $E2E_IMAGE not found"

log "e2e: starting infrastructure ($E2E_RUN_ID)"
docker network create --label "e2e.run=$E2E_RUN_ID" "$E2E_NET" >/dev/null || die "could not create network"

# A throwaway CA and one server certificate for minio-tls and hooks, made with
# the image's own openssl so the host needs nothing beyond Docker.
mkdir -p "$E2E_CERTS"
chmod 755 "$E2E_CERTS"
docker run --rm -v "$E2E_CERTS:/out" --entrypoint sh "$E2E_IMAGE" -c '
  set -e
  cd /out
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=postgres-backup-s3 e2e CA" \
    -keyout ca.key -out ca.crt 2>/dev/null
  openssl req -newkey rsa:2048 -nodes -subj "/CN=minio-tls" -keyout private.key -out server.csr 2>/dev/null
  printf "%s\n" "subjectAltName=DNS:minio-tls,DNS:hooks" "basicConstraints=CA:FALSE" \
    "keyUsage=digitalSignature,keyEncipherment" "extendedKeyUsage=serverAuth" > server.ext
  openssl x509 -req -days 2 -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -extfile server.ext -out public.crt 2>/dev/null
  # A second, unrelated CA for "wrong CA" tests.
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=unrelated CA" \
    -keyout other-ca.key -out other-ca.crt 2>/dev/null
  chmod 644 ./*
' || die "could not create certificates"

infra_run() {
  name=$1
  shift
  docker run -d --name "${E2E_RUN_ID}-$name" --label "e2e.run=$E2E_RUN_ID" \
    --network "$E2E_NET" --network-alias "$name" "$@" >/dev/null || die "could not start $name"
}

infra_run pg -e "POSTGRES_PASSWORD=$PG_PASSWORD" "$E2E_POSTGRES_IMAGE" \
  -c fsync=off -c full_page_writes=off -c synchronous_commit=off
infra_run minio -e "MINIO_ROOT_USER=$S3_KEY" -e "MINIO_ROOT_PASSWORD=$S3_SECRET" \
  "$E2E_MINIO_IMAGE" server /data
infra_run minio-tls -e "MINIO_ROOT_USER=$S3_KEY" -e "MINIO_ROOT_PASSWORD=$S3_SECRET" \
  -v "$E2E_CERTS:/certs:ro" "$E2E_MINIO_IMAGE" server /data --certs-dir /certs
mkdir -p "$E2E_WORK/hook-server"
chmod 777 "$E2E_WORK/hook-server"
infra_run hooks -v "$E2E_DIR/hook_server.py:/srv/hook_server.py:ro" -v "$E2E_CERTS:/certs:ro" \
  -v "$E2E_WORK/hook-server:/log" "$E2E_HOOK_SERVER_IMAGE" \
  python /srv/hook_server.py /log/requests.log /certs/public.crt /certs/private.key /log/ready

pg_ready() {
  docker exec "$E2E_PG_CTR" psql -X -h 127.0.0.1 -U postgres -Atc 'SELECT 1' >/dev/null 2>&1
}
minio_ready() {
  mc_cli ls e2e >/dev/null 2>&1 && mc_cli ls tls >/dev/null 2>&1
}
hooks_ready() {
  [ -f "$E2E_WORK/hook-server/ready" ]
}
wait_for 90 pg_ready || { docker logs "$E2E_PG_CTR" >&2; die "PostgreSQL did not start"; }
wait_for 90 minio_ready || { docker logs "${E2E_RUN_ID}-minio-tls" >&2; die "MinIO did not start"; }
wait_for 60 hooks_ready || { docker logs "${E2E_RUN_ID}-hooks" >&2; die "hook receiver did not start"; }

psql_exec postgres "CREATE DATABASE e2e_seed" >/dev/null || die "could not create seed database"
docker exec -i "$E2E_PG_CTR" psql -X -q -U postgres -d e2e_seed -v ON_ERROR_STOP=1 -f - \
  <"$E2E_DIR/fixtures/seed.sql" >/dev/null || die "could not load seed data"

log "e2e: $(docker exec "$E2E_PG_CTR" postgres --version), $(docker run --rm --entrypoint pg_dump "$E2E_IMAGE" --version)"
log "e2e: running ${#tests[@]} test(s)"

# ---------------------------------------------------------------------------
# Execution.

passed=0
failed=0
xfailed=0
skipped=0
failures=()
started=$SECONDS

for t in "${tests[@]}"; do
  slug=$(slugify "$t")
  dir="$E2E_WORK/cases/$slug"
  mkdir -p "$dir"
  chmod 755 "$dir"
  case_start=$SECONDS

  (
    CASE_NAME=$t
    CASE_SLUG=$slug
    CASE_DIR=$dir
    cd "$dir" || exit 1
    "$t"
  ) >"$dir/output.log" 2>&1
  rc=$?

  ids=$(docker ps -aq --filter "label=e2e.case=$slug" --filter "label=e2e.run=$E2E_RUN_ID")
  [ -z "$ids" ] || docker rm -f $ids >/dev/null 2>&1

  took="$((SECONDS - case_start))s"
  show=0
  if [ -f "$dir/.skip" ]; then
    result="skip"
    skipped=$((skipped + 1))
    detail=" ($(cat "$dir/.skip"))"
  elif [ -f "$dir/.xfail" ] && [ "$rc" -ne 0 ]; then
    result="xfail"
    xfailed=$((xfailed + 1))
    detail=" (known issue: $(cat "$dir/.xfail"))"
  elif [ -f "$dir/.xfail" ]; then
    result="XPASS"
    failed=$((failed + 1))
    failures+=("$t (passed but is marked xfail: $(cat "$dir/.xfail"))")
    detail=" - remove the xfail marker"
    show=1
  elif [ "$rc" -eq 0 ]; then
    result="ok"
    passed=$((passed + 1))
    detail=""
  else
    result="FAIL"
    failed=$((failed + 1))
    failures+=("$t")
    detail=""
    show=1
  fi

  printf '%-5s %s [%s]%s\n' "$result" "$t" "$took" "$detail"
  if [ "$show" = 1 ] || [ "$E2E_VERBOSE" = 1 ]; then
    in_github && [ "$show" = 1 ] && printf '::error title=e2e %s::%s\n' "$result" "$t"
    in_github && printf '::group::output of %s\n' "$t"
    sed 's/^/    /' "$dir/output.log"
    in_github && printf '::endgroup::\n'
  fi
  if [ "$show" = 1 ] && [ -n "${E2E_ARTIFACTS:-}" ]; then
    mkdir -p "$E2E_ARTIFACTS/$t"
    cp -R "$dir/." "$E2E_ARTIFACTS/$t/" 2>/dev/null
  fi
done

printf '\n%d passed, %d failed, %d expected failures, %d skipped in %ss\n' \
  "$passed" "$failed" "$xfailed" "$skipped" "$((SECONDS - started))"
if [ "$failed" -ne 0 ]; then
  printf 'Failed:\n'
  printf '  %s\n' "${failures[@]}"
  exit 1
fi
exit 0
