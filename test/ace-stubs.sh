# shellcheck shell=bash
# The stubs and helpers test/ace.sh and test/ace-ipv6.sh share: sourced, it
# checks that it may write /opt/ace, makes stub docker, curl, date, sleep and
# sysctl first on PATH, installs a panel 2.0.0 as install.sh leaves it (its
# network with IPv6) and this checkout's `ace`, and defines run, expect and
# the Caddyfile and backup helpers. Nothing here runs on its own.

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ $EUID -eq 0 ]] || fail "run as root"
[[ -n "${CI:-}" || -f /.dockerenv ]] || fail "this test writes /opt/ace: run it in CI or a throwaway container"
[[ ! -e /opt/ace ]] || fail "/opt/ace exists: this is no place for the test"

src="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
state="$work/state"
mkdir -p "$state" "$work/bin" "$work/tmp" "$work/certs"
export ACE_TEST_SRC="$src" ACE_TEST_STATE="$state"

# curl serves this checkout's files for every version listed in
# $state/published: the script under test is the target version's own. A
# version's compose.yml is $state/stack.<version>, else this checkout's with
# every image pinned to that version by a made-up digest.
cat >"$work/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$ACE_TEST_STATE/curl.args"
printf '%s\n' "${https_proxy:-}" >>"$ACE_TEST_STATE/curl.proxy"
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
file="$ACE_TEST_SRC/$(basename "$url")"
if [[ "$(basename "$url")" == compose.yml ]]; then
  file="$ACE_TEST_STATE/stack.${ref#v}"
  [[ -f "$file" ]] || sed -E "s#^( +image: ghcr\.io/kup1ng/[a-z0-9-]+)[:@].*#\1:${ref#v}@sha256:$(printf '%064d' 0)#" \
    "$ACE_TEST_SRC/compose.yml" >"$file"
fi
cp "$file" "$out"
EOF

# docker compose: up starts the version in /opt/ace/.env (and a forced
# recreation of Caddy is counted); the panel answers healthy as that version
# unless $state/broken lists it; a pull fails for the versions in
# $state/unpullable; the dump prints a line. The stack's network is
# $state/net (its EnableIPv6): up makes it when there is none, with the
# IPv6 the stack wants (compose.yml's enable_ipv6 line and ACE_IPV6), and
# keeps one that differs, as Compose does with a network an older Compose
# made; down removes it and is counted; config fails while $state/config-fails
# exists. docker version prints $state/docker-version; the IPv6 check's
# network (ace-ipv6-check, $state/probe) cannot be made while
# $state/docker-no-ipv6 exists.
cat >"$work/bin/docker" <<'EOF'
#!/usr/bin/env bash
s="$ACE_TEST_STATE"
case "${1:-}" in
version) cat "$s/docker-version"; exit ;;
network)
  printf '%s\n' "$*" >>"$s/network.log"
  case "$2" in
  inspect) [[ "$3" == ace_default && -f "$s/net" ]] && cat "$s/net" ;;
  create) [[ "$3" == --ipv6 && "$4" == ace-ipv6-check && ! -e "$s/docker-no-ipv6" && ! -e "$s/probe" ]] && touch "$s/probe" ;;
  rm) [[ "$3" == ace-ipv6-check && -e "$s/probe" ]] && rm "$s/probe" ;;
  *) exit 1 ;;
  esac
  exit
  ;;
compose) shift ;;
*) exit 1 ;;
esac
env_file=/opt/ace/.env file=/opt/ace/compose.yml
while [[ "${1:-}" == -* ]]; do
  case "$1" in
  --env-file) env_file="$2"; shift 2 ;;
  -f) file="$2"; shift 2 ;;
  *) shift ;;
  esac
done
setting() { sed -n "s/^$1=//p" "$2" | tail -1; }
ipv6() { if grep -qF 'enable_ipv6: ${ACE_IPV6:-false}' "$file" && [[ "$(setting ACE_IPV6 "$env_file")" == true ]]; then echo true; else echo false; fi; }
running="$(cat "$s/running")"
case "${1:-}" in
config)
  [[ " $* " == *" --no-env-resolution "* && ! -e "$s/config-fails" ]] || exit 1
  printf '{\n  "networks": {\n    "default": {\n      "name": "ace_default",\n      "ipam": {},\n      "enable_ipv6": %s\n    }\n  }\n}\n' "$(ipv6)"
  ;;
pull) ! grep -qx "${ACE_VERSION:-$(setting ACE_VERSION "$env_file")}" "$s/unpullable" ;;
down)
  echo down >>"$s/downs"
  rm -f "$s/net"
  echo down >"$s/running"
  ;;
up)
  if [[ " $* " == *" --force-recreate "* && " $* " == *" caddy "* ]]; then
    echo $(($(cat "$s/caddy" 2>/dev/null || echo 0) + 1)) >"$s/caddy"
  else
    [[ -f "$s/net" ]] || ipv6 >"$s/net"
    setting ACE_VERSION /opt/ace/.env >"$s/running"
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
# sysctl prints $state/sysctl, the kernel's net.ipv6.conf.all.disable_ipv6;
# "none" stands for a kernel booted without IPv6, which has no such setting.
cat >"$work/bin/sysctl" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "-n net.ipv6.conf.all.disable_ipv6" ]] || exit 1
v="$(cat "$ACE_TEST_STATE/sysctl")"
[[ "$v" != none ]] || { echo "sysctl: cannot stat /proc/sys/net/ipv6/conf/all/disable_ipv6: No such file or directory" >&2; exit 255; }
echo "$v"
EOF
chmod 755 "$work/bin/"*
export PATH="$work/bin:$PATH" TMPDIR="$work/tmp"

# A panel 2.0.0 as install.sh leaves it.
install -d /opt/ace /opt/ace/tls
cp "$src/compose.yml" /opt/ace/compose.yml
printf 'ACE_VERSION=2.0.0\nACE_DOMAIN=panel.example.test\nACE_PUBLIC_IP=192.0.2.10\nACE_TLS=acme\nACE_EMAIL=admin@example.test\nACE_IPV6=true\n' >/opt/ace/.env
chmod 600 /opt/ace/.env
install -m 755 "$src/ace" /usr/local/bin/ace
echo 2.0.0 >"$state/running"
echo true >"$state/net"
printf '%s\n' 1.1.0 2.0.0 2.0.1 2.0.2 2.0.3 2.0.4 2.0.5 2.0.6 2.0.7 >"$state/published"
: >"$state/broken"
: >"$state/unpullable"
: >"$state/downs"
: >"$state/network.log"
echo 29.1.3 >"$state/docker-version"
echo 0 >"$state/sysctl"

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
  [[ ! -e "$state/probe" ]] || fail "the IPv6 check's network stayed"
}

backups() { find /opt/ace/backups -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort; }
caddy_recreated() { cat "$state/caddy" 2>/dev/null || echo 0; }
has() { grep -qF -- "$1" /opt/ace/Caddyfile || fail "the Caddyfile lacks ${1}: $(cat /opt/ace/Caddyfile)"; }
lacks() { ! grep -qF -- "$1" /opt/ace/Caddyfile || fail "the Caddyfile has ${1}: $(cat /opt/ace/Caddyfile)"; }
