#!/usr/bin/env bash
# Checks the stack's network in `ace`, against the stubs of
# test/ace-stubs.sh: it is IPv4 only, whatever .env says. The upgrade from
# 2.0.0-rc.3 on a server whose network has IPv6 (ACE_IPV6=true) removes
# ACE_IPV6 from .env with one note and makes the network again without
# IPv6, once; a rollback by hand and an upgrade that goes back by itself
# give 2.0.0-rc.3 back its ACE_IPV6 and its network with IPv6; a 2.0.0-rc.3
# panel with ACE_IPV6=false loses the line with no restart; nothing
# restarts when nothing changed; ace apply removes a leftover ACE_IPV6 (any
# value, every such line) with one note and keeps the rest of .env, and
# makes a network that has IPv6 again without it; ace __ipv6 is gone;
# Docker is never asked to make or remove a network; a Compose that cannot
# print its config leaves the network to Compose; and after a rollback that
# died before it put back 2.0.0-rc.3's ace, ace apply keeps ACE_IPV6 for
# that version's stack.
#
# It writes /opt/ace and /usr/local/bin/ace, so it runs only in CI or in a
# throwaway container:
#
#   docker run --rm -v "$PWD:/src:ro" ubuntu:24.04 bash /src/test/ace-network.sh
set -euo pipefail

# shellcheck source=test/ace-stubs.sh
. "$(dirname "${BASH_SOURCE[0]}")/ace-stubs.sh"

note="Removed ACE_IPV6 from /opt/ace/.env"
remake="Making the panel's network again with enable_ipv6"

# ipv6_is VALUE checks ACE_IPV6 in .env ("" for none).
ipv6_is() {
  local v
  v="$(sed -n 's/^ACE_IPV6=//p' /opt/ace/.env | tail -1)"
  [[ "$v" == "$1" ]] || fail "ACE_IPV6 is \"${v}\" in .env, not \"${1}\""
}
# net_is VALUE checks the network's IPv6.
net_is() { [[ "$(cat "$state/net" 2>/dev/null)" == "$1" ]] || fail "the network's IPv6 is $(cat "$state/net" 2>/dev/null), not $1"; }
downs() { wc -l <"$state/downs"; }
# said TEXT prints how many lines of the last command's output hold TEXT.
said() { grep -cF -- "$1" <<<"$out" || true; }

# as_rc3 IPV6 makes the panel a 2.0.0-rc.3 one as its upgrade left it, on a
# server whose network has IPv6 (true) or not (false): that version's stack
# (the network's IPv6 from ACE_IPV6, Caddy on every address), ACE_IPV6=IPV6
# in .env, the network, and no rollback files.
# shellcheck disable=SC2016 # compose.yml's text, not this shell's
as_rc3() {
  sed -E "s#^( +image: ghcr\.io/kup1ng/[a-z0-9-]+)[:@].*#\1:2.0.0-rc.3@sha256:$(printf '%064d' 0)#" "$src/compose.yml" |
    sed -e 's#^    enable_ipv6: false$#    enable_ipv6: ${ACE_IPV6:-false}#' -e 's#"0\.0\.0\.0:#"#' >/opt/ace/compose.yml
  if ! grep -qxF '    enable_ipv6: ${ACE_IPV6:-false}' /opt/ace/compose.yml || grep -qF '"0.0.0.0:' /opt/ace/compose.yml; then
    fail "the 2.0.0-rc.3 stack was not made: $(cat /opt/ace/compose.yml)"
  fi
  sed -i -e '/^ACE_IPV6=/d' -e 's/^ACE_VERSION=.*/ACE_VERSION=2.0.0-rc.3/' /opt/ace/.env
  printf 'ACE_IPV6=%s\n' "$1" >>/opt/ace/.env
  echo 2.0.0-rc.3 >"$state/running"
  echo "$1" >"$state/net"
  rm -rf /opt/ace/rollback
  rc3_stack="$(cat /opt/ace/compose.yml)"
}

printf '%s\n' 2.0.0-rc.3 2.0.0-rc.4 2.0.0-rc.5 >>"$state/published"

echo "a panel installed without ACE_IPV6, IPv4 only: nothing to do"
run ace apply
expect 0 2.0.0 "applied /opt/ace/.env"
[[ "$(said "$note") $(said "$remake") $(downs)" == "0 0 0" ]] || fail "ace apply noted or restarted something with nothing to do: ${out}"
ipv6_is ""
net_is false

echo "the upgrade from 2.0.0-rc.3 with IPv6 removes ACE_IPV6 with one note and makes the network again IPv4 only, once"
as_rc3 true
before="$(downs)"
run ace upgrade 2.0.0-rc.4
expect 0 2.0.0-rc.4 "Done: the panel runs 2.0.0-rc.4"
[[ "$(said "$note")" == 1 ]] || fail "not one note for ACE_IPV6: ${out}"
[[ "$(said "$remake false")" == 1 && "$(said "$remake")" == 1 ]] || fail "the network was not made again IPv4 only, once: ${out}"
[[ "$(downs)" == $((before + 1)) ]] || fail "the stack did not go down once for its network: $(($(downs) - before)) downs"
ipv6_is ""
net_is false
for want in ACE_VERSION=2.0.0-rc.4 ACE_DOMAIN=panel.example.test ACE_PUBLIC_IP=192.0.2.10 ACE_TLS=acme ACE_EMAIL=admin@example.test; do
  grep -qx "$want" /opt/ace/.env || fail "the upgrade lost ${want} from .env: $(cat /opt/ace/.env)"
done
[[ "$(stat -c %a /opt/ace/.env)" == 600 ]] || fail ".env is not root's only: $(stat -c %a /opt/ace/.env)"
grep -qx 'ACE_IPV6=true' /opt/ace/rollback/.env || fail "the rollback's .env lost ACE_IPV6=true: $(cat /opt/ace/rollback/.env)"
[[ "$(cat /opt/ace/rollback/compose.yml)" == "$rc3_stack" ]] || fail "the rollback lacks 2.0.0-rc.3's stack"

echo "a rollback by hand gives 2.0.0-rc.3 back its ACE_IPV6 and its network with IPv6"
before="$(downs)"
run ace rollback
expect 0 2.0.0-rc.3 "$remake true"
ipv6_is true
net_is true
[[ "$(downs)" == $((before + 1)) ]] || fail "the rollback did not go down once for its network: $(($(downs) - before)) downs"
[[ "$(cat /opt/ace/compose.yml)" == "$rc3_stack" ]] || fail "the rollback did not put 2.0.0-rc.3's stack back"

echo "an upgrade that goes back by itself gives them back too"
echo 2.0.0-rc.4 >"$state/broken"
before="$(downs)"
run ace upgrade 2.0.0-rc.4
expect 1 2.0.0-rc.3 "the upgrade to 2.0.0-rc.4 failed, and the panel runs 2.0.0-rc.3 again"
[[ "$(said "$note") $(said "$remake false") $(said "$remake true")" == "1 1 1" ]] || fail "not one note and one remake each way: ${out}"
ipv6_is true
net_is true
[[ "$(downs)" == $((before + 2)) ]] || fail "not one down each way: $(($(downs) - before)) downs"
: >"$state/broken"

echo "once upgraded, nothing to do: no note, no restart"
run ace upgrade 2.0.0-rc.4
expect 0 2.0.0-rc.4 "$note"
before="$(downs)"
run ace apply
expect 0 2.0.0-rc.4 "applied /opt/ace/.env"
[[ "$(said "$note") $(said "$remake")" == "0 0" ]] || fail "ace apply noted or remade something with nothing to do: ${out}"
run ace upgrade 2.0.0-rc.5
expect 0 2.0.0-rc.5 "Done: the panel runs 2.0.0-rc.5"
[[ "$(said "$note") $(said "$remake")" == "0 0" ]] || fail "the next upgrade noted or remade something: ${out}"
[[ "$(downs)" == "$before" ]] || fail "the panel stopped with nothing to do: $(($(downs) - before)) downs"
net_is false

echo "a 2.0.0-rc.3 panel with ACE_IPV6=false loses the line, with no restart"
as_rc3 false
before="$(downs)"
run ace upgrade 2.0.0-rc.4
expect 0 2.0.0-rc.4 "$note"
[[ "$(said "$remake")" == 0 && "$(downs)" == "$before" ]] || fail "the panel stopped for a network that has no IPv6: ${out}"
ipv6_is ""
net_is false
grep -qx 'ACE_IPV6=false' /opt/ace/rollback/.env || fail "the rollback's .env lost ACE_IPV6=false"

echo "ace apply removes a leftover ACE_IPV6, whatever its value, with one note, and keeps the rest of .env"
env_before="$(cat /opt/ace/.env)"
printf 'ACE_IPV6=true\n' >>/opt/ace/.env
before="$(downs)"
run ace apply
expect 0 2.0.0-rc.4 "applied /opt/ace/.env"
[[ "$(said "$note") $(said "$remake")" == "1 0" ]] || fail "not one note, or a remake, for ACE_IPV6=true: ${out}"
[[ "$(cat /opt/ace/.env)" == "$env_before" ]] || fail "ace apply changed more of .env than ACE_IPV6: $(cat /opt/ace/.env)"
net_is false
[[ "$(downs)" == "$before" ]] || fail "ace apply stopped the panel for ACE_IPV6=true"
sed -i '1i ACE_IPV6=yes' /opt/ace/.env
printf 'ACE_IPV6=false\n' >>/opt/ace/.env
run ace apply
expect 0 2.0.0-rc.4 "applied /opt/ace/.env"
[[ "$(said "$note")" == 1 ]] || fail "not one note for two ACE_IPV6 lines: ${out}"
[[ "$(cat /opt/ace/.env)" == "$env_before" ]] || fail "ace apply left an ACE_IPV6 line, or changed more: $(cat /opt/ace/.env)"
[[ "$(stat -c %a /opt/ace/.env)" == 600 ]] || fail ".env is not root's only: $(stat -c %a /opt/ace/.env)"

echo "ace apply makes a network that has IPv6 again IPv4 only"
echo true >"$state/net"
before="$(downs)"
run ace apply
expect 0 2.0.0-rc.4 "$remake false"
[[ "$(said "$note")" == 0 ]] || fail "a note with no ACE_IPV6 in .env: ${out}"
net_is false
[[ "$(downs)" == $((before + 1)) ]] || fail "the stack did not go down once for its network: $(($(downs) - before)) downs"

echo "ace __ipv6 is gone"
run ace __ipv6
expect 1 2.0.0-rc.4 "unknown command: __ipv6"

echo "Docker is only asked about the network, never to make or remove one"
grep -q '^network inspect ace_default ' "$state/network.log" || fail "ace never looked at the network"
! grep -v '^network inspect ace_default ' "$state/network.log" || fail "ace ran the other network commands above"

echo "a Compose that cannot print its config leaves the network to Compose"
echo true >"$state/net"
touch "$state/config-fails"
before="$(downs)"
run ace apply
expect 0 2.0.0-rc.4 "applied /opt/ace/.env"
[[ "$(downs)" == "$before" ]] || fail "the stack went down with no config to compare"
rm "$state/config-fails"

echo "after a rollback that died before it put back 2.0.0-rc.3's ace, ace apply keeps that stack's ACE_IPV6"
as_rc3 true
run ace upgrade 2.0.0-rc.4
expect 0 2.0.0-rc.4 "$remake false"
echo 2.0.0-rc.3 >"$state/broken"
run ace rollback
expect 1 2.0.0-rc.3 "the panel 2.0.0-rc.3 is not healthy within 3 minutes"
: >"$state/broken"
[[ -d /opt/ace/rollback ]] || fail "the rollback that died removed its files"
ipv6_is true
net_is true
env_before="$(cat /opt/ace/.env)"
before="$(downs)"
run ace apply
expect 0 2.0.0-rc.3 "applied /opt/ace/.env"
[[ "$(said "$note") $(said "$remake")" == "0 0" ]] || fail "ace apply removed ACE_IPV6 or remade the network of 2.0.0-rc.3's stack: ${out}"
[[ "$(cat /opt/ace/.env)" == "$env_before" ]] || fail "ace apply changed 2.0.0-rc.3's .env: $(cat /opt/ace/.env)"
net_is true
[[ "$(downs)" == "$before" ]] || fail "ace apply stopped 2.0.0-rc.3's panel"
run ace rollback
expect 0 2.0.0-rc.3 "Done: the panel runs 2.0.0-rc.3 again"
[[ "$(said "$remake")" == 0 && "$(downs)" == "$before" ]] || fail "the second rollback remade the network: ${out}"
ipv6_is true
net_is true

echo "all good"
