#!/usr/bin/env bash
#
# Runs the full suite, integration tests included, against a throwaway server.
#
# The integration suites skip without a database, and a skipped suite is not a
# passing one — this package's whole value is what it proves against real
# infrastructure. Rather than asking a contributor to read CONTRIBUTING and
# assemble the right environment, this starts what is needed, runs everything,
# and cleans up. Postgres is all Hangar needs — it has no cache layer, so
# unlike the Alula scripts this was adapted from there is no valkey here.
#
#   ./scripts/test.sh                 # everything
#   ./scripts/test.sh --filter Foo    # arguments pass through to swift test
#
# Set ALULA_KEEP_SERVERS=1 to leave the container running between runs.
#
set -euo pipefail
cd "$(dirname "$0")/.."

# Assigned before the docker check: under `set -u` the check's own error
# message referenced $pg_port, so the failure path failed.
pg_name="hangar-test-postgres"
pg_port=${ALULA_TEST_PG_PORT:-55497}

if ! command -v docker >/dev/null; then
  echo "docker is needed to start the test server." >&2
  echo "Already have one? Run swift test directly with:" >&2
  echo "  export HANGAR_TEST_DATABASE_URL='postgres://postgres:alula@127.0.0.1:$pg_port/hangar_test'" >&2
  exit 1
fi

cleanup() {
  if [ "${ALULA_KEEP_SERVERS:-0}" != "1" ]; then
    docker rm -f "$pg_name" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

start() { # name image port args...
  local n="$1" image="$2" port="$3"; shift 3
  if docker ps --format '{{.Names}}' | grep -qx "$n"; then return; fi
  docker rm -f "$n" >/dev/null 2>&1 || true
  docker run -d --name "$n" -p "$port" "$@" "$image" >/dev/null
}

echo "── starting the test server"
start "$pg_name" postgres:16-alpine "$pg_port:5432" \
  -e POSTGRES_PASSWORD=alula -e POSTGRES_DB=hangar_test

echo "── waiting for postgres"
for _ in $(seq 1 60); do
  docker exec "$pg_name" pg_isready -U postgres >/dev/null 2>&1 && break
  sleep 1
done
docker exec "$pg_name" pg_isready -U postgres >/dev/null 2>&1 || {
  echo "postgres did not become ready" >&2; exit 1; }

export HANGAR_TEST_DATABASE_URL="postgres://postgres:alula@127.0.0.1:$pg_port/hangar_test"
echo "── running the suite"
./CI/run-tests.sh "$@"
status=$?
exit $status
