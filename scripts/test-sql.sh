#!/bin/sh
set -eu
mkdir -p /scratch/home /scratch/tmp /scratch/socket
export PGHOST=/scratch/socket PGUSER=postgres
initdb -D /scratch/data -U postgres -A trust -E UTF8 --no-locale > /scratch/init.log 2>&1 || { cat /scratch/init.log; exit 1; }
trap 'pg_ctl -D /scratch/data stop -m immediate -w >/dev/null 2>&1 || true' EXIT
pg_ctl -D /scratch/data -l /scratch/server.log -o "-k /scratch/socket -h '' -c max_connections=20 -c shared_buffers=32MB" -w start > /scratch/start.log 2>&1 || { cat /scratch/start.log /scratch/server.log; exit 1; }

sql() {
  if ! psql -X -q -A -t -d "$1" -v ON_ERROR_STOP=1 -f "$2" > /scratch/sql.log 2>&1; then
    printf 'FAIL %s: %s\n' "$1" "$2"
    tail -n 30 /scratch/sql.log
    return 1
  fi
}

migrate() {
  for migration in /source/migrations/*.sql; do
    sql "$1" "$migration"
    if [ "${migration##*/}" = "$2" ]; then return; fi
  done
  [ "$2" = all ] || { printf 'Missing migration boundary: %s\n' "$2"; exit 1; }
}

createdb fixture
sql fixture /source/tests/fixtures/privacy-bootstrap.sql
createdb -T fixture current_schema
migrate current_schema all
printf 'PASS current schema migrations\n'
failures=0
for test in "$@"; do
  if sql current_schema "/source/tests/$test"; then
    printf 'PASS %s\n' "$test"
  else
    failures=$((failures + 1))
  fi
done

createdb -T fixture rounds_upgrade
migrate rounds_upgrade 20261114055600_qr_bingo.sql
sql rounds_upgrade /source/tests/migrations/bingo_rounds_before.sql
sql rounds_upgrade /source/migrations/20261114064206_bingo_rounds.sql
sql rounds_upgrade /source/tests/migrations/bingo_rounds_after.sql
printf 'PASS bingo rounds upgrade (before/after)\n'

createdb -T fixture duration_upgrade
migrate duration_upgrade 20261115102246_event_timetable.sql
sql duration_upgrade /source/tests/migrations/bingo_duration_before.sql
sql duration_upgrade /source/migrations/20261115105127_bingo_twenty_five_minutes.sql
sql duration_upgrade /source/tests/migrations/bingo_duration_after.sql
printf 'PASS bingo duration upgrade (before/after)\n'

[ "$failures" -eq 0 ] || { printf '%s SQL suite(s) failed\n' "$failures"; exit 1; }
printf 'PASS all %s SQL suites and 2 upgrade scenarios\n' "$#"
