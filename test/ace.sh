#!/usr/bin/env bash
# Checks the v2 `ace` command without a panel: docker, curl, date and sleep
# are stubs, so the panel "runs" the version it was last started with and
# answers healthy unless that version is marked broken. It covers the
# Caddyfile `ace` writes (security headers, HSTS, TLS), a good upgrade, a
# rollback by hand, an upgrade that goes back by itself, the refusals (a
# 1.x target, a 1.x panel), the last 3 backups, ace apply, ace certificate
# (with openssl), and that no temporary file stays.
#
# It writes /opt/ace and /usr/local/bin/ace, so it runs only in CI or in a
# throwaway container with openssl:
#
#   docker run --rm -v "$PWD:/src:ro" ubuntu:24.04 bash -c 'apt-get update -qq && apt-get install -y -qq openssl >/dev/null && bash /src/test/ace.sh'
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
mkdir -p "$state" "$work/bin" "$work/tmp" "$work/certs"
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

# docker compose: up starts the version in /opt/ace/.env (and a forced
# recreation of Caddy is counted); the panel answers healthy as that version
# unless $state/broken lists it; a pull fails for the versions in
# $state/unpullable; the dump prints a line.
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
up)
  if [[ " $* " == *" --force-recreate "* && " $* " == *" caddy "* ]]; then
    echo $(($(cat "$ACE_TEST_STATE/caddy" 2>/dev/null || echo 0) + 1)) >"$ACE_TEST_STATE/caddy"
  else
    version /opt/ace/.env >"$ACE_TEST_STATE/running"
  fi
  ;;
exec)
  case "$3" in
  panel-api) grep -qx "$running" "$ACE_TEST_STATE/broken" || printf '{"status":"ok","version":"%s"}\n' "$running" ;;
  postgres) echo "pg_dump of ${running}" ;;
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

# A panel 2.0.0 as install.sh leaves it.
install -d /opt/ace /opt/ace/tls
cp "$src/compose.yml" /opt/ace/compose.yml
printf 'ACE_VERSION=2.0.0\nACE_DOMAIN=panel.example.test\nACE_PUBLIC_IP=192.0.2.10\nACE_TLS=acme\nACE_EMAIL=admin@example.test\n' >/opt/ace/.env
chmod 600 /opt/ace/.env
install -m 755 "$src/ace" /usr/local/bin/ace
echo 2.0.0 >"$state/running"
printf '%s\n' 1.1.0 2.0.0 2.0.1 2.0.2 2.0.3 2.0.4 2.0.5 2.0.6 2.0.7 >"$state/published"
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
  [[ -z "$(find /opt/ace -maxdepth 1 -name '*.??????')" ]] || fail "temporary files stayed in /opt/ace: $(ls -A /opt/ace)"
}

backups() { find /opt/ace/backups -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort; }
caddy_recreated() { cat "$state/caddy" 2>/dev/null || echo 0; }
has() { grep -qF -- "$1" /opt/ace/Caddyfile || fail "the Caddyfile lacks ${1}: $(cat /opt/ace/Caddyfile)"; }
lacks() { ! grep -qF -- "$1" /opt/ace/Caddyfile || fail "the Caddyfile has ${1}: $(cat /opt/ace/Caddyfile)"; }

echo "the Caddyfile install.sh has ace write"
run ace __caddyfile
expect 0 2.0.0
has 'panel.example.test {'
has $'\temail admin@example.test'
has 'read_body_idle 5m'
has 'Strict-Transport-Security "max-age=86400"'
has 'X-Content-Type-Options nosniff'
has 'Referrer-Policy same-origin'
has 'Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=()"'
has 'handle /api/* {'
has "Content-Security-Policy \"default-src 'none'; frame-ancestors 'none'\""
has 'reverse_proxy panel-api:8080'
has 'reverse_proxy panel-web:3000'
[[ "$(grep -c 'Strict-Transport-Security' /opt/ace/Caddyfile)" == 1 ]] || fail "HSTS is set more than once"
lacks '; preload'
lacks 'includeSubDomains'
lacks $'\ttls '
[[ "$(sed -n '/handle \/api/,/reverse_proxy panel-api/p' /opt/ace/Caddyfile)" == *Content-Security-Policy* ]] ||
  fail "the CSP is not inside /api's handle"

echo "a good upgrade writes its own Caddyfile"
printf '# an older Caddyfile\npanel.example.test {\n\treverse_proxy panel-api:8080\n}\n' >/opt/ace/Caddyfile
old_caddy="$(cat /opt/ace/Caddyfile)"
run ace upgrade 2.0.1
expect 0 2.0.1 "Done: the panel runs 2.0.1"
b="/opt/ace/backups/$(backups | tail -1)"
[[ "$b" == *-2.0.0-to-2.0.1 ]] || fail "no backup of 2.0.0: $(backups)"
[[ "$(cat "$b/ace.pgdump")" == "pg_dump of 2.0.0" ]] || fail "the backup is not 2.0.0's"
[[ "$(ls "$b")" == ace.pgdump ]] || fail "the backup holds more than the database: $(ls "$b")"
[[ "$(stat -c %a "$b") $(stat -c %a "$b/ace.pgdump")" == "700 600" ]] || fail "the backup is not root's only"
grep -qx 'ACE_VERSION=2.0.0' /opt/ace/rollback/.env || fail "the rollback files are not 2.0.0's"
[[ "$(cat /opt/ace/rollback/Caddyfile)" == "$old_caddy" ]] || fail "the rollback files lack 2.0.0's Caddyfile"
has 'Strict-Transport-Security "max-age=86400"'
[[ "$(stat -c %a /opt/ace/Caddyfile)" == 644 ]] || fail "the Caddyfile is not 644"

echo "a rollback by hand"
run ace rollback
expect 0 2.0.0 "Done: the panel runs 2.0.0 again"
[[ ! -e /opt/ace/rollback ]] || fail "the rollback files stayed"
[[ "$(cat /opt/ace/Caddyfile)" == "$old_caddy" ]] || fail "the rollback did not put 2.0.0's Caddyfile back"
run ace rollback
expect 1 2.0.0 "nothing to go back to"

echo "an upgrade that goes back by itself"
echo 2.0.2 >"$state/broken"
run ace upgrade 2.0.2
expect 1 2.0.0 "the upgrade to 2.0.2 failed, and the panel runs 2.0.0 again"
[[ ! -e /opt/ace/rollback ]] || fail "the rollback files stayed after going back"
[[ "$(cat /opt/ace/Caddyfile)" == "$old_caddy" ]] || fail "going back did not put 2.0.0's Caddyfile back"

echo "refusals change nothing"
run ace upgrade 2.0.0
expect 1 2.0.0 "already runs 2.0.0"
run ace upgrade 9.9.9
expect 1 2.0.0 "no version 9.9.9"
run ace upgrade latest
expect 1 2.0.0 "usage: ace upgrade"
run ace upgrade 1.1.0
expect 1 2.0.0 "cannot go back to 1.1.0, a 1.x version"

echo "a 1.x panel is never upgraded to 2.x"
cp -p /opt/ace/.env "$work/env.v2"
compose_before="$(cat /opt/ace/compose.yml)"
backups_before="$(backups)"
sed -i 's/^ACE_VERSION=.*/ACE_VERSION=1.1.0/' /opt/ace/.env
echo 1.1.0 >"$state/running"
cp "$src/ace" "$work/tmp/next-ace" # what 1.x's `ace upgrade 2.0.3` fetches, then runs
run bash "$work/tmp/next-ace" __upgrade 2.0.3 "$work/tmp/next-ace"
expect 1 1.1.0 "starts on a fresh install: nothing carries over from 1.x"
[[ "$out" == *"nothing changed"* ]] || fail "the refusal does not say nothing changed: ${out}"
[[ "$(cat /opt/ace/compose.yml)" == "$compose_before" && "$(backups)" == "$backups_before" && ! -e /opt/ace/rollback ]] ||
  fail "the refused upgrade changed something"
cp -p "$work/env.v2" /opt/ace/.env
echo 2.0.0 >"$state/running"

echo "the last 3 backups stay"
run ace upgrade 2.0.3
expect 0 2.0.3
run ace upgrade 2.0.4
expect 0 2.0.4
[[ "$(backups | wc -l)" == 3 ]] || fail "$(backups | wc -l) backups, not 3: $(backups)"
[[ "$(backups | head -1)" == *-2.0.0-to-2.0.2 ]] || fail "not the oldest backup went: $(backups)"

echo "images that cannot be pulled change nothing"
echo 2.0.6 >"$state/unpullable"
run ace upgrade 2.0.6
expect 1 2.0.4 "cannot pull the images of 2.0.6; nothing changed"
[[ "$(backups | wc -l)" == 3 && "$(backups | tail -1)" == *-2.0.3-to-2.0.4 ]] || fail "a backup was made: $(backups)"

echo "ace apply writes the Caddyfile from .env and restarts Caddy when it changed"
before="$(caddy_recreated)"
printf 'ACE_HSTS_MAX_AGE=31536000\n' >>/opt/ace/.env
run ace apply
expect 0 2.0.4 "applied /opt/ace/.env"
has 'Strict-Transport-Security "max-age=31536000"'
[[ "$(caddy_recreated)" == $((before + 1)) ]] || fail "Caddy was not recreated for its new Caddyfile"
run ace apply
expect 0 2.0.4
[[ "$(caddy_recreated)" == $((before + 1)) ]] || fail "Caddy was recreated with nothing changed"
with_hsts="$(cat /opt/ace/Caddyfile)"
sed -i 's/^ACE_HSTS_MAX_AGE=.*/ACE_HSTS_MAX_AGE=a-year/' /opt/ace/.env
run ace apply
expect 1 2.0.4 "ACE_HSTS_MAX_AGE in /opt/ace/.env must be a number of seconds"
[[ "$(cat /opt/ace/Caddyfile)" == "$with_hsts" ]] || fail "a bad .env changed the Caddyfile"
sed -i '/^ACE_HSTS_MAX_AGE=/d' /opt/ace/.env

echo "neither version healthy: the backup is named"
printf '%s\n' 2.0.4 2.0.5 >"$state/broken"
run ace upgrade 2.0.5
expect 1 2.0.4 "2.0.4 is not healthy either; the database as it was is in /opt/ace/backups/"
[[ -d /opt/ace/rollback ]] || fail "the rollback files went with nothing rolled back"
: >"$state/broken"
rm -rf /opt/ace/rollback

if command -v openssl >/dev/null; then
  echo "ace certificate: the owner's certificate"
  cd "$work/certs"
  cert() { # cert NAME DOMAIN DAYS
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$1.key" -out "$1.pem" -days "$3" \
      -subj "/CN=$2" -addext "subjectAltName=DNS:$2" 2>/dev/null
  }
  cert good panel.example.test 90
  cert other other.example.test 90
  cert soon panel.example.test 10
  before="$(caddy_recreated)"
  run ace certificate other.pem other.key
  expect 1 2.0.4 "does not name panel.example.test"
  run ace certificate good.pem other.key
  expect 1 2.0.4 "does not belong to the certificate"
  [[ ! -e /opt/ace/tls/cert.pem ]] || fail "a refused certificate was copied"
  grep -qx 'ACE_TLS=acme' /opt/ace/.env || fail "a refused certificate changed ACE_TLS"
  run ace certificate good.pem good.key
  expect 0 2.0.4 "Caddy serves your certificate for panel.example.test"
  [[ "$(stat -c %a /opt/ace/tls/cert.pem) $(stat -c %a /opt/ace/tls/key.pem)" == "644 600" ]] || fail "the certificate's modes are wrong"
  cmp -s good.key /opt/ace/tls/key.pem || fail "the key was not copied"
  grep -qx 'ACE_TLS=custom' /opt/ace/.env || fail "ACE_TLS is not custom"
  has $'\ttls /etc/caddy/tls/cert.pem /etc/caddy/tls/key.pem'
  lacks 'email admin@example.test'
  [[ "$(caddy_recreated)" == $((before + 1)) ]] || fail "Caddy was not restarted with the certificate"
  run ace certificate soon.pem soon.key
  expect 0 2.0.4 "expires within 21 days"
  cmp -s soon.pem /opt/ace/tls/cert.pem || fail "the renewed certificate was not copied"
  cd /
else
  echo "SKIP ace certificate: no openssl"
fi

echo "all good"
