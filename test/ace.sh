#!/usr/bin/env bash
# Checks `ace upgrade` and `ace rollback` without a panel: docker, curl,
# date and sleep are stubs, so the panel "runs" the version it was last
# started with and answers healthy unless that version is marked broken.
# It covers a good upgrade, a rollback by hand, an upgrade that goes back by
# itself, the refusals, the last 3 backups, and that no temporary file stays.
#
# It writes /opt/ace and /usr/local/bin/ace, so it runs only in CI or in a
# throwaway container:
#
#   docker run --rm -v "$PWD:/src:ro" ubuntu:24.04 bash /src/test/ace.sh
set -euo pipefail

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ $EUID -eq 0 ]] || fail "run as root"
[[ -n "${CI:-}" || -f /.dockerenv ]] || fail "this test writes /opt/ace: run it in CI or a throwaway container"
[[ ! -e /opt/ace ]] || fail "/opt/ace exists: this is no place for the test"

src="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
state="$work/state"
mkdir -p "$state" "$work/bin" "$work/tmp"
export ACE_TEST_SRC="$src" ACE_TEST_STATE="$state"

# curl serves this checkout's files for every version listed in
# $state/published: the script under test is the target version's own.
cat >"$work/bin/curl" <<'EOF'
#!/usr/bin/env bash
out="" url=""
while (($#)); do
  case "$1" in
  -o) out="$2"; shift 2 ;;
  -x | --retry | --connect-timeout) shift 2 ;;
  -*) shift ;;
  *) url="$1"; shift ;;
  esac
done
ref="$(basename "$(dirname "$url")")"
grep -qx "${ref#v}" "$ACE_TEST_STATE/published" || exit 22
cp "$ACE_TEST_SRC/$(basename "$url")" "$out"
EOF

# docker compose: up starts the version in /opt/ace/.env; the panel answers
# healthy as that version unless $state/broken lists it; a pull fails for
# the versions in $state/unpullable; the dumps print a line.
cat >"$work/bin/docker" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == compose ]] || exit 1
shift
env_file=/opt/ace/.env
while [[ "${1:-}" == -* ]]; do
  case "$1" in
  --env-file) env_file="$2"; shift 2 ;;
  -f) shift 2 ;;
  *) shift ;;
  esac
done
version() { sed -n 's/^ACE_VERSION=//p' "$1" | tail -1; }
running="$(cat "$ACE_TEST_STATE/running")"
case "${1:-}" in
pull) ! grep -qx "${ACE_VERSION:-$(version "$env_file")}" "$ACE_TEST_STATE/unpullable" ;;
up) version /opt/ace/.env >"$ACE_TEST_STATE/running" ;;
exec)
  case "$3" in
  panel-api) grep -qx "$running" "$ACE_TEST_STATE/broken" || printf '{"status":"ok","version":"%s"}\n' "$running" ;;
  postgres) echo "pg_dump of ${running}" ;;
  mysql) echo "mysqldump of ${running}" ;;
  esac
  ;;
esac
EOF

# date numbers the backups, as several are made in one second here; sleep
# returns at once, so a panel that never gets healthy fails in no time.
cat >"$work/bin/date" <<'EOF'
#!/usr/bin/env bash
n=$(($(cat "$ACE_TEST_STATE/clock" 2>/dev/null || echo 0) + 1))
echo "$n" >"$ACE_TEST_STATE/clock"
printf '20260101-%06d\n' "$n"
EOF
printf '#!/bin/sh\n' >"$work/bin/sleep"
chmod 755 "$work/bin/"*
export PATH="$work/bin:$PATH" TMPDIR="$work/tmp"

# A panel 1.0.0 as install.sh leaves it.
install -d /opt/ace
cp "$src/compose.yml" /opt/ace/compose.yml
printf 'ACE_VERSION=1.0.0\nACE_DOMAIN=panel.example.test\nACE_PUBLIC_IP=192.0.2.10\n' >/opt/ace/.env
chmod 600 /opt/ace/.env
install -m 755 "$src/ace" /usr/local/bin/ace
echo 1.0.0 >"$state/running"
printf '%s\n' 1.0.0 1.0.1 1.0.2 1.0.3 1.0.4 1.0.5 1.0.6 >"$state/published"
: >"$state/broken"
: >"$state/unpullable"

# run CMD... runs a command and keeps its output and exit status.
run() {
  set +e
  out="$("$@" 2>&1)"
  code=$?
  set -e
}

# expect CODE VERSION [TEXT] checks the last command's exit status, the
# version the panel has in .env and runs, a text in the output, and that no
# temporary file stayed.
expect() {
  local want_code="$1" want="$2" text="${3:-}"
  [[ "$code" == "$want_code" ]] || fail "exit ${code}, not ${want_code}: ${out}"
  [[ "$(ace version)" == "$want" ]] || fail "ace version says $(ace version), not ${want}"
  [[ "$(cat "$state/running")" == "$want" ]] || fail "the panel runs $(cat "$state/running"), not ${want}"
  [[ -z "$text" || "$out" == *"$text"* ]] || fail "no \"${text}\" in: ${out}"
  [[ -z "$(ls -A "$TMPDIR")" ]] || fail "temporary files stayed: $(ls -A "$TMPDIR")"
}

backups() { find /opt/ace/backups -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort; }

echo "a good upgrade"
run ace upgrade 1.0.1
expect 0 1.0.1 "Done: the panel runs 1.0.1"
b="/opt/ace/backups/$(backups | tail -1)"
[[ "$b" == *-1.0.0-to-1.0.1 ]] || fail "no backup of 1.0.0: $(backups)"
[[ "$(cat "$b/ace.pgdump")" == "pg_dump of 1.0.0" ]] || fail "the panel's backup is not 1.0.0's"
[[ "$(gzip -dc "$b/mysql.sql.gz")" == "mysqldump of 1.0.0" ]] || fail "MySQL's backup is not 1.0.0's"
[[ "$(stat -c %a "$b") $(stat -c %a "$b/ace.pgdump")" == "700 600" ]] || fail "the backup is not root's only"
grep -qx 'ACE_VERSION=1.0.0' /opt/ace/rollback/.env || fail "the rollback files are not 1.0.0's"

echo "a rollback by hand"
run ace rollback
expect 0 1.0.0 "Done: the panel runs 1.0.0 again"
[[ ! -e /opt/ace/rollback ]] || fail "the rollback files stayed"
run ace rollback
expect 1 1.0.0 "nothing to go back to"

echo "an upgrade that goes back by itself"
echo 1.0.2 >"$state/broken"
run ace upgrade 1.0.2
expect 1 1.0.0 "the upgrade to 1.0.2 failed, and the panel runs 1.0.0 again"
[[ ! -e /opt/ace/rollback ]] || fail "the rollback files stayed after going back"

echo "refusals change nothing"
run ace upgrade 1.0.0
expect 1 1.0.0 "already runs 1.0.0"
run ace upgrade 9.9.9
expect 1 1.0.0 "no version 9.9.9"
run ace upgrade latest
expect 1 1.0.0 "usage: ace upgrade"

echo "the last 3 backups stay"
run ace upgrade 1.0.3
expect 0 1.0.3
run ace upgrade 1.0.4
expect 0 1.0.4
[[ "$(backups | wc -l)" == 3 ]] || fail "$(backups | wc -l) backups, not 3: $(backups)"
[[ "$(backups | head -1)" == *-1.0.0-to-1.0.2 ]] || fail "not the oldest backup went: $(backups)"

echo "images that cannot be pulled change nothing"
echo 1.0.6 >"$state/unpullable"
run ace upgrade 1.0.6
expect 1 1.0.4 "cannot pull the images of 1.0.6; nothing changed"
[[ "$(backups | wc -l)" == 3 && "$(backups | tail -1)" == *-1.0.3-to-1.0.4 ]] || fail "a backup was made: $(backups)"

echo "neither version healthy: the backup is named"
printf '%s\n' 1.0.4 1.0.5 >"$state/broken"
run ace upgrade 1.0.5
expect 1 1.0.4 "1.0.4 is not healthy either; the databases as they were are in /opt/ace/backups/"
[[ -d /opt/ace/rollback ]] || fail "the rollback files went with nothing rolled back"

echo "all good"
