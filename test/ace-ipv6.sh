#!/usr/bin/env bash
# Checks the stack's network and ACE_IPV6 in `ace`, against the stubs of
# test/ace-stubs.sh (docker, curl, sysctl): install.sh's `ace __ipv6`; an
# upgrade from a stack without IPv6 (as 2.0.0-rc.2 runs it) that makes the
# network again with IPv6, even one Compose would keep as it is; a rollback
# by hand and an upgrade that goes back by itself, which take the network
# back without IPv6; no restart when nothing changed; ACE_IPV6=false, which
# stays and turns it off; turning it on again; the fallbacks to IPv4 only (a
# kernel booted without IPv6 or with IPv6 off, Docker older than 27, Docker
# that cannot make an IPv6 network); a check's network left behind; a bad
# value, which changes nothing; and a Compose that cannot print its config,
# which leaves the network to Compose.
#
# It writes /opt/ace and /usr/local/bin/ace, so it runs only in CI or in a
# throwaway container:
#
#   docker run --rm -v "$PWD:/src:ro" ubuntu:24.04 bash /src/test/ace-ipv6.sh
set -euo pipefail

# shellcheck source=test/ace-stubs.sh
. "$(dirname "${BASH_SOURCE[0]}")/ace-stubs.sh"

# ipv6_is VALUE checks ACE_IPV6 in .env ("" for none).
ipv6_is() {
  local v
  v="$(sed -n 's/^ACE_IPV6=//p' /opt/ace/.env | tail -1)"
  [[ "$v" == "$1" ]] || fail "ACE_IPV6 is \"${v}\" in .env, not \"${1}\""
}
# net_is VALUE checks the network's IPv6.
net_is() { [[ "$(cat "$state/net" 2>/dev/null)" == "$1" ]] || fail "the network's IPv6 is $(cat "$state/net" 2>/dev/null), not $1"; }
downs() { wc -l <"$state/downs"; }
checks() { grep -c '^network create' "$state/network.log" || true; }
no_ipv6() { sed -i '/^ACE_IPV6=/d' /opt/ace/.env; } # as 2.0.0-rc.2's .env

echo "install.sh's ace __ipv6 writes ACE_IPV6=true where the server can"
no_ipv6
run ace __ipv6
expect 0 2.0.0
ipv6_is true
[[ "$(checks)" == 1 ]] || fail "the check did not make its network: $(cat "$state/network.log")"

echo "a stack without IPv6, as 2.0.0-rc.2 runs it, upgrades to a network with IPv6"
# compose.yml before its network had IPv6: no networks block.
sed -E "s#^( +image: ghcr\.io/kup1ng/[a-z0-9-]+)[:@].*#\1:2.0.0@sha256:$(printf '%064d' 0)#" "$src/compose.yml" |
  sed '/^networks:$/,/^$/d' >/opt/ace/compose.yml
! grep -q enable_ipv6 /opt/ace/compose.yml || fail "the old stack still has enable_ipv6"
old_compose="$(cat /opt/ace/compose.yml)"
no_ipv6
echo false >"$state/net"
before="$(downs)"
run ace upgrade 2.0.1
expect 0 2.0.1 "Making the panel's network again with enable_ipv6 true"
ipv6_is true
net_is true
[[ "$(downs)" == $((before + 1)) ]] || fail "the stack did not go down once for its network: $(downs) downs"
! grep -q '^ACE_IPV6=' /opt/ace/rollback/.env || fail "the rollback's .env has ACE_IPV6"
[[ "$(cat /opt/ace/rollback/compose.yml)" == "$old_compose" ]] || fail "the rollback lacks the old stack"

echo "a rollback by hand takes the network back without IPv6"
before="$(downs)"
run ace rollback
expect 0 2.0.0 "Making the panel's network again with enable_ipv6 false"
ipv6_is ""
net_is false
[[ "$(downs)" == $((before + 1)) ]] || fail "the rollback did not go down once for its network"
[[ "$(cat /opt/ace/compose.yml)" == "$old_compose" ]] || fail "the rollback did not put the old stack back"

echo "an upgrade that goes back by itself takes the network back too"
echo 2.0.2 >"$state/broken"
before="$(downs)"
run ace upgrade 2.0.2
expect 1 2.0.0 "the upgrade to 2.0.2 failed, and the panel runs 2.0.0 again"
ipv6_is ""
net_is false
[[ "$(downs)" == $((before + 2)) ]] || fail "not one down each way: $(($(downs) - before)) downs"
: >"$state/broken"

echo "the network as the stack wants it: no restart"
run ace upgrade 2.0.3
expect 0 2.0.3
net_is true
before="$(downs)"
run ace apply
expect 0 2.0.3 "applied /opt/ace/.env"
[[ "$(downs)" == "$before" ]] || fail "ace apply stopped the stack with nothing changed"

echo "ACE_IPV6=false turns it off, and stays"
sed -i 's/^ACE_IPV6=.*/ACE_IPV6=false/' /opt/ace/.env
before="$(downs)" n="$(checks)"
run ace apply
expect 0 2.0.3 "enable_ipv6 false"
net_is false
run ace apply
expect 0 2.0.3
run ace upgrade 2.0.4
expect 0 2.0.4
ipv6_is false
net_is false
[[ "$(downs)" == $((before + 1)) ]] || fail "$(($(downs) - before)) downs for one change"
[[ "$(checks)" == "$n" ]] || fail "ACE_IPV6=false was checked again"

echo "the owner turns it on again"
sed -i 's/^ACE_IPV6=.*/ACE_IPV6=true/' /opt/ace/.env
run ace apply
expect 0 2.0.4 "enable_ipv6 true"
ipv6_is true
net_is true

echo "a kernel booted without IPv6 falls back to IPv4 only"
echo none >"$state/sysctl"
n="$(checks)"
run ace apply
expect 0 2.0.4 "the panel's network stays IPv4 only (ACE_IPV6=false in /opt/ace/.env)"
ipv6_is false
net_is false
[[ "$(checks)" == "$n" ]] || fail "Docker was asked for an IPv6 network on a kernel without IPv6"

echo "a kernel with IPv6 off falls back"
echo 1 >"$state/sysctl"
no_ipv6
run ace apply
expect 0 2.0.4 "stays IPv4 only"
ipv6_is false
[[ "$(checks)" == "$n" ]] || fail "Docker was asked for an IPv6 network with IPv6 off"

echo "Docker older than 27 falls back"
echo 0 >"$state/sysctl"
echo 26.1.4 >"$state/docker-version"
no_ipv6
run ace apply
expect 0 2.0.4 "stays IPv4 only"
ipv6_is false
[[ "$(checks)" == "$n" ]] || fail "Docker 26 was asked for an IPv6 network"
echo 29.1.3 >"$state/docker-version"

echo "Docker that cannot make an IPv6 network falls back"
touch "$state/docker-no-ipv6"
no_ipv6
run ace apply
expect 0 2.0.4 "stays IPv4 only"
ipv6_is false
net_is false
[[ "$(checks)" == $((n + 1)) ]] || fail "Docker was not asked for an IPv6 network"
rm "$state/docker-no-ipv6"

echo "a fresh install on a server without IPv6"
echo 1 >"$state/sysctl"
no_ipv6
run ace __ipv6
expect 0 2.0.4 "stays IPv4 only"
ipv6_is false
echo 0 >"$state/sysctl"

echo "a check's network left behind is removed before the check"
touch "$state/probe"
no_ipv6
run ace apply
expect 0 2.0.4 "enable_ipv6 true"
ipv6_is true
net_is true

echo "a bad ACE_IPV6 changes nothing"
sed -i 's/^ACE_IPV6=.*/ACE_IPV6=yes/' /opt/ace/.env
compose_before="$(cat /opt/ace/compose.yml)" backups_before="$(backups)" before="$(downs)"
run ace apply
expect 1 2.0.4 "ACE_IPV6 in /opt/ace/.env must be true or false"
run ace upgrade 2.0.5
expect 1 2.0.4 "ACE_IPV6 in /opt/ace/.env must be true or false; nothing changed"
[[ "$(cat /opt/ace/compose.yml)" == "$compose_before" && "$(backups)" == "$backups_before" && "$(downs)" == "$before" ]] ||
  fail "a bad ACE_IPV6 changed something"
net_is true

echo "a Compose that cannot print its config leaves the network to Compose"
sed -i 's/^ACE_IPV6=.*/ACE_IPV6=false/' /opt/ace/.env
touch "$state/config-fails"
run ace apply
expect 0 2.0.4
[[ "$(downs)" == "$before" ]] || fail "the stack went down with no config to compare"
rm "$state/config-fails"

echo "all good"
