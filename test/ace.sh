#!/usr/bin/env bash
# Checks the v2 `ace` command without a panel: docker, curl, date and sleep
# are stubs, so the panel "runs" the version it was last started with and
# answers healthy unless that version is marked broken. It covers
# panel-web's settings in compose.yml (the API's address, NO_PROXY), the
# Caddyfile `ace` writes (security headers, HSTS, TLS), a good upgrade, a
# rollback by hand, an upgrade that goes back by itself, the refusals (a
# 1.x target, a 1.x panel), the last 3 backups, ace apply, ace certificate
# (with openssl), that ACE_PROXY reaches curl through its environment and
# never its command line, the stack's images (a release's pulling by tag or
# another version's is refused, a development prerelease may pull by tag),
# and that no temporary file stays. The stubs are test/ace-stubs.sh's; the
# stack's network and ACE_IPV6 are test/ace-ipv6.sh's.
#
# It writes /opt/ace and /usr/local/bin/ace, so it runs only in CI or in a
# throwaway container with openssl:
#
#   docker run --rm -v "$PWD:/src:ro" ubuntu:24.04 bash -c 'apt-get update -qq && apt-get install -y -qq openssl >/dev/null && bash /src/test/ace.sh'
set -euo pipefail

# shellcheck source=test/ace-stubs.sh
. "$(dirname "${BASH_SOURCE[0]}")/ace-stubs.sh"

echo "panel-web reaches the API directly, never through a proxy"
web="$(sed -n '/^  panel-web:$/,/^$/p' "$src/compose.yml")"
for want in 'ACE_API_ORIGIN: http://panel-api:8080' 'NO_PROXY: panel-api' 'no_proxy: panel-api'; do
  grep -qxF "      ${want}" <<<"$web" || fail "panel-web in compose.yml lacks ${want}: ${web}"
done

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

echo "ACE_PROXY reaches curl through its environment, never its command line"
proxy_url='http://ace:fake%2Fpassword@proxy.example.test:3128' # an obviously fake password
printf 'ACE_PROXY=%s\n' "$proxy_url" >>/opt/ace/.env
: >"$state/curl.args"
: >"$state/curl.proxy"
run ace upgrade 2.0.7
expect 0 2.0.7 "Done: the panel runs 2.0.7"
[[ "$(wc -l <"$state/curl.args")" == 2 ]] || fail "curl did not fetch ace and compose.yml: $(cat "$state/curl.args")"
! grep -qF 'fake%2Fpassword' "$state/curl.args" || fail "the proxy is on curl's command line: $(cat "$state/curl.args")"
[[ "$(sort -u "$state/curl.proxy")" == "$proxy_url" ]] || fail "curl did not get the proxy in its environment: $(cat "$state/curl.proxy")"

echo "a release's stack that pulls by tag, or is another version's, changes nothing"
printf '%s\n' 2.0.8 2.0.9 2.1.0-alpha.1 >>"$state/published"
# shellcheck disable=SC2016 # compose.yml's text, not this shell's
sed -E 's#^( +image: ghcr\.io/kup1ng/[a-z0-9-]+)[:@].*#\1:${ACE_VERSION:?}#' "$src/compose.yml" >"$state/stack.2.0.8"
sed -E "s#^( +image: ghcr\.io/kup1ng/[a-z0-9-]+)[:@].*#\1:2.0.1@sha256:$(printf '%064d' 0)#" "$src/compose.yml" >"$state/stack.2.0.9"
compose_before="$(cat /opt/ace/compose.yml)"
backups_before="$(backups)"
run ace upgrade 2.0.8
expect 1 2.0.7 "2.0.8 is a release, but ace-install v2.0.8's stack pulls its images by tag, not by the digests its release recorded"
[[ "$out" == *"ace-install's tag v2.0.8 is not a finished release; pick another version; nothing changed"* ]] || fail "the refusal does not say what to do: ${out}"
run ace upgrade 2.0.9
expect 1 2.0.7 "ace-install v2.0.9's stack is 2.0.1's, not 2.0.9's"
[[ "$(cat /opt/ace/compose.yml)" == "$compose_before" && "$(backups)" == "$backups_before" ]] || fail "a refused stack changed something"

echo "a development prerelease may pull by tag"
cp "$state/stack.2.0.8" "$state/stack.2.1.0-alpha.1"
run ace upgrade 2.1.0-alpha.1
expect 0 2.1.0-alpha.1 "Done: the panel runs 2.1.0-alpha.1"
cmp -s "$state/stack.2.1.0-alpha.1" /opt/ace/compose.yml || fail "the prerelease's stack was not installed"

echo "all good"
