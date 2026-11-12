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
# No root, no network; DIR holds compose.yml and VERSION (default: this
# checkout):
#
#   bash test/compose.sh [DIR]
set -euo pipefail

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

dir="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
names=(ace-postgres ace-panel-api ace-panel-web ace-caddy)
version="$(tr -d '[:space:]' <"$dir/VERSION")"
mapfile -t images < <(sed -nE 's/^[[:space:]]+image:[[:space:]]+//p' "$dir/compose.yml" | tr -d '\r')

[[ ${#images[@]} -eq ${#names[@]} ]] ||
  fail "compose.yml has ${#images[@]} images, not the ${#names[@]} of ${names[*]}: ${images[*]}"
pinned=0 unpinned=0
for name in "${names[@]}"; do
  image="" n=0
  for i in "${images[@]}"; do
    if [[ "$i" == "ghcr.io/kup1ng/${name}:"* || "$i" == "ghcr.io/kup1ng/${name}@"* ]]; then image="$i" n=$((n + 1)); fi
  done
  [[ $n -eq 1 ]] || fail "compose.yml has ${n} images of ghcr.io/kup1ng/${name}, not 1"
  if [[ "$image" == "ghcr.io/kup1ng/${name}:\${ACE_VERSION:?"*"}" ]]; then
    unpinned=$((unpinned + 1))
  elif [[ "${image%@*}" == "ghcr.io/kup1ng/${name}:${version}" && "${image#*@}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    pinned=$((pinned + 1))
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
