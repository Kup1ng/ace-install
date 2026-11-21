#!/usr/bin/env bash
# Checks compose.yml's images (D52.53 (4), ADR 0013): ace-postgres,
# ace-panel-api, ace-panel-web and ace-caddy from ghcr.io/kup1ng, each once
# and no other image, all four of one state:
#
#   unpinned  ghcr.io/kup1ng/<name>:${ACE_VERSION:?...}, during development
#             and until scripts/pin-release.sh runs for a release
#   pinned    ghcr.io/kup1ng/<name>:<VERSION>@sha256:<64 hex>, what
#             scripts/pin-release.sh writes for the release in VERSION
#
# It also checks the network: the project is named ace, no service picks a
# network of its own, and the default network is exactly
# `enable_ipv6: false`, IPv4 only whatever .env says, with no fixed subnet
# (`ace` relies on all three); and that only Caddy publishes ports, exactly
# 0.0.0.0:80:80, 0.0.0.0:443:443 and 0.0.0.0:443:443/udp in block style, so
# nothing listens on IPv6 (README: The stack's network).
#
# It reads the block-style `image:` lines, as install.sh and ace do. IMAGES,
# when given, is a file of the images Docker resolves from the same
# compose.yml with every profile and ACE_VERSION set (CI's
# `docker compose config --images`): it must name exactly these four, the
# unpinned ones with ACE_VERSION's value as their tag, so an image those
# lines miss (flow style, a quoted key, an anchor, an include) fails too.
#
# No root, no network, no Docker; DIR holds compose.yml and VERSION
# (default: this checkout):
#
#   bash test/compose.sh [DIR [IMAGES]]
set -euo pipefail

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

dir="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
resolved="${2:-}"
names=(ace-postgres ace-panel-api ace-panel-web ace-caddy)
version="$(tr -d '[:space:]' <"$dir/VERSION")"
mapfile -t images < <(sed -nE 's/^[[:space:]]+image:[[:space:]]+//p' "$dir/compose.yml" | tr -d '\r')

[[ ${#images[@]} -eq ${#names[@]} ]] ||
  fail "compose.yml has ${#images[@]} images, not the ${#names[@]} of ${names[*]}: ${images[*]}"
pinned=0 unpinned=0 expected=()
for name in "${names[@]}"; do
  image="" n=0
  for i in "${images[@]}"; do
    if [[ "$i" == "ghcr.io/kup1ng/${name}:"* || "$i" == "ghcr.io/kup1ng/${name}@"* ]]; then image="$i" n=$((n + 1)); fi
  done
  [[ $n -eq 1 ]] || fail "compose.yml has ${n} images of ghcr.io/kup1ng/${name}, not 1"
  if [[ "$image" == "ghcr.io/kup1ng/${name}:\${ACE_VERSION:?"*"}" ]]; then
    unpinned=$((unpinned + 1)) expected+=("ghcr.io/kup1ng/${name}:${ACE_VERSION:-}")
  elif [[ "${image%@*}" == "ghcr.io/kup1ng/${name}:${version}" && "${image#*@}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    pinned=$((pinned + 1)) expected+=("$image")
  else
    fail "${image} is neither ghcr.io/kup1ng/${name}:\${ACE_VERSION:?} nor pinned to VERSION ${version} (ghcr.io/kup1ng/${name}:${version}@sha256:<64 hex>)"
  fi
done
if ((unpinned == ${#names[@]})); then
  echo "compose.yml: the ${#names[@]} images take their tag from ACE_VERSION (unpinned)"
elif ((pinned == ${#names[@]})); then
  echo "compose.yml: the ${#names[@]} images are pinned to ${version} by digest"
else
  fail "compose.yml pins ${pinned} of its ${#names[@]} images to ${version}: all or none (scripts/pin-release.sh ${version})"
fi

# The network: `ace` checks the stack's as ace_default (project ace, its
# default network), so every service is on that one, which is IPv4 only by
# a literal (no .env value turns IPv6 on) and takes its subnet from Docker.
[[ "$(sed -n 's/^name:[[:space:]]*//p' "$dir/compose.yml" | tr -d '\r')" == ace ]] ||
  fail "compose.yml's project is not named ace: ace checks the stack's network as ace_default"
! grep -nE '^[[:space:]]+(networks|network_mode):' "$dir/compose.yml" ||
  fail "a service in compose.yml chooses its network (above): every service stays on the default one"
networks="$(awk '/^networks:/ { on = 1 } on && /^[^[:space:]#]/ && !/^networks:/ { on = 0 } on && NF && !/^[[:space:]]*#/' "$dir/compose.yml" | tr -d '\r')"
want_networks=$'networks:\n  default:\n    enable_ipv6: false'
[[ "$networks" == "$want_networks" ]] ||
  fail "compose.yml's networks are not exactly: ${want_networks} (IPv4 only, Docker's own subnet); they are: ${networks}"
echo "compose.yml: every service is on the default network, which is IPv4 only"

# The published ports, one "SERVICE PORT" line each: a block-style list
# item without its quotes; anything else under ports (flow style, the long
# syntax, a value after ports:) is printed as it is, so it never matches.
ports="$(tr -d '\r' <"$dir/compose.yml" | awk '
  /^[^[:space:]#]/ { top = $1; on = 0; next }
  top != "services:" { next }
  /^  [^[:space:]#]/ { svc = $1; sub(/:$/, "", svc); on = 0; next }
  /^    [^[:space:]#]/ { on = ($1 == "ports:"); if (on && NF > 1) print svc, $0; next }
  on && /^      [^[:space:]#]/ { p = $0; sub(/^      (- )?/, "", p); gsub(/["\047]/, "", p); print svc, p }
')"
want_ports=$'caddy 0.0.0.0:80:80\ncaddy 0.0.0.0:443:443\ncaddy 0.0.0.0:443:443/udp'
[[ "$ports" == "$want_ports" ]] ||
  fail "compose.yml's published ports are not exactly Caddy's, on IPv4 only and in block style: ${want_ports}; they are: ${ports}"
echo "compose.yml: only Caddy publishes ports, on IPv4 only (0.0.0.0)"

[[ -n "$resolved" ]] || exit 0
[[ -n "${ACE_VERSION:-}" ]] || fail "set ACE_VERSION to the value Docker resolved ${resolved} with"
want="$(printf '%s\n' "${expected[@]}" | LC_ALL=C sort)"
got="$(tr -d '\r' <"$resolved" | sed '/^[[:space:]]*$/d' | LC_ALL=C sort)"
# only FLAG prints, on one line, the images comm's FLAG keeps of want and got.
only() { LC_ALL=C comm "$1" <(printf '%s\n' "$want") <(printf '%s\n' "$got") | sed '/^$/d' | paste -sd ' ' -; }
extra="$(only -13)" missing="$(only -23)"
[[ -z "${extra}${missing}" ]] ||
  fail "Docker resolves other images from compose.yml than its image: lines${extra:+; only Docker sees: ${extra}}${missing:+; only the lines name: ${missing}}; give each service its image on one block-style image: line"
echo "compose.yml: Docker resolves the same ${#names[@]} images"
