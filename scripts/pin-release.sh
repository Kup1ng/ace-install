#!/usr/bin/env bash
# Pins the stack's images to a release (D52.53 (4), ADR 0013). For each of
# ace-postgres, ace-panel-api, ace-panel-web and ace-caddy it reads the one
# digest Ace-Panel's GitHub release v<version> records in its notes as
# `ghcr.io/kup1ng/<name>@sha256:<64 hex>` (the panel's release.sh appends
# them), checks that ghcr.io/kup1ng/<name>:<version> still names that digest
# on GHCR (the multi-platform index's, as `docker buildx imagetools inspect`
# shows it), then writes the image in compose.yml as
# ghcr.io/kup1ng/<name>:<version>@sha256:<digest>, and <version> to VERSION.
# It refuses a draft release, a digest the notes lack or give twice, and a
# tag that moved on GHCR after the release, and then writes nothing. Network
# drops are retried. Running it again changes nothing.
#
# Maintainers only, on the release machine, with gh signed in and Docker
# logged in to ghcr.io, after Ace-Panel's release (README.md, Releasing):
#
#   scripts/pin-release.sh <version>          pin compose.yml, set VERSION
#   scripts/pin-release.sh --check <version>  check this checkout's
#                                             compose.yml and VERSION against
#                                             the release and GHCR; writes
#                                             nothing
#   scripts/pin-release.sh --help             this help
#
# <version> is a release: x.y.z or x.y.z-rc.N (a leading v is dropped).
set -euo pipefail

PANEL_REPO=Kup1ng/Ace-Panel
REGISTRY=ghcr.io/kup1ng
IMAGES=(ace-postgres ace-panel-api ace-panel-web ace-caddy)

root="$(cd "$(dirname "$0")/.." && pwd)"
compose="$root/compose.yml"
version_file="$root/VERSION"

say() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

# retry WHAT CMD... runs CMD up to 5 times through drops of the link abroad
# (tls: bad record MAC, unexpected EOF), keeping its output in $out and the
# last line of its errors in $last_error. An answer that another attempt
# cannot change (not found, unauthorized, denied) ends it at once.
retry() {
  local what="$1" attempt
  shift
  for attempt in 1 2 3 4 5; do
    if out="$("$@" 2>"$tmp/err")"; then return 0; fi
    last_error="$(tail -n 1 "$tmp/err")"
    if grep -qiE 'not found|unauthori[sz]ed|denied|forbidden|HTTP 40[134]' "$tmp/err"; then break; fi
    warn "${what} failed (attempt ${attempt}): ${last_error}"
    if ((attempt < 5)); then sleep $((attempt * 3)); fi
  done
  return 1
}

# recorded NAME prints the distinct digests the release's notes ($notes)
# record for ghcr.io/kup1ng/NAME, one per line: none, one or several.
recorded() {
  { grep -oE "(^|[^A-Za-z0-9._/-])ghcr[.]io/kup1ng/$1@sha256:[0-9a-f]{64}([^0-9a-f]|$)" <<<"$notes" || true; } |
    { grep -oE 'sha256:[0-9a-f]{64}' || true; } | sort -u
}

# on_ghcr REF sets ghcr to the digest REF names on GHCR now.
on_ghcr() {
  ghcr=""
  retry "resolving ${1} on GHCR" docker buildx imagetools inspect "$1" || return 1
  ghcr="$(tr -d '\r' <<<"$out" | awk '/^Digest:/ { print $2; exit }')"
  [[ "$ghcr" =~ ^sha256:[0-9a-f]{64}$ ]] && return 0
  last_error="docker buildx imagetools inspect showed no digest"
  return 1
}

# image_lines NAME prints compose.yml's image lines of ghcr.io/kup1ng/NAME.
image_lines() { grep -E "^[[:space:]]+image:[[:space:]]+ghcr[.]io/kup1ng/$1[:@]" "$compose" || true; }

# pinned_compose prints compose.yml with each image of IMAGES pinned to
# $version and its digest in $digests.
pinned_compose() {
  local line i
  while IFS= read -r line || [[ -n "$line" ]]; do
    for i in "${!IMAGES[@]}"; do
      if [[ "$line" =~ ^([[:space:]]+image:[[:space:]]+)ghcr[.]io/kup1ng/${IMAGES[i]}[:@] ]]; then
        line="${BASH_REMATCH[1]}${REGISTRY}/${IMAGES[i]}:${version}@${digests[i]}"
      fi
    done
    printf '%s\n' "$line"
  done <"$compose"
}

mode=pin
case "${1:-}" in
-h | --help)
  usage
  exit 0
  ;;
--check)
  mode=check
  shift
  ;;
esac
[[ $# -eq 1 && "$1" != -* ]] || {
  usage >&2
  exit 2
}
version="${1#v}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$ ]] ||
  die "${1} is not a release: give x.y.z or x.y.z-rc.N (development versions pull by tag and are not pinned)"
tag="v${version}"
command -v gh >/dev/null || die "gh is needed to read ${PANEL_REPO}'s release (https://cli.github.com, then gh auth login)"
command -v docker >/dev/null || die "Docker is needed to read the images' digests on GHCR"
[[ -f "$compose" && -f "$version_file" ]] || die "no compose.yml and VERSION in ${root}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
last_error=""

problems=()
for name in "${IMAGES[@]}"; do
  n="$(image_lines "$name" | grep -c . || true)"
  [[ "$n" == 1 ]] || problems+=("compose.yml has ${n} image lines of ${REGISTRY}/${name}, not 1")
done
if ((${#problems[@]})); then
  printf 'error: %s\n' "${problems[@]}" >&2
  die "fix compose.yml first; nothing changed"
fi

say "reading ${PANEL_REPO}'s GitHub release ${tag}"
retry "reading ${PANEL_REPO}'s release ${tag}" gh release view "$tag" --repo "$PANEL_REPO" --json body,isDraft --jq '.isDraft, .body' ||
  die "cannot read ${PANEL_REPO}'s release ${tag} (${last_error}): release the panel first, with its scripts/release.sh, and sign gh in (gh auth login)"
out="${out//$'\r'/}"
draft="$(head -n 1 <<<"$out")"
notes="$(tail -n +2 <<<"$out")"
case "$draft" in
false) ;;
true) die "${PANEL_REPO}'s release ${tag} is a draft: publish it first; nothing changed" ;;
*) die "gh answered something unexpected for ${PANEL_REPO}'s release ${tag}: ${draft}" ;;
esac

digests=()
for i in "${!IMAGES[@]}"; do
  image="${REGISTRY}/${IMAGES[i]}"
  found="$(recorded "${IMAGES[i]}")"
  count="$(grep -c . <<<"$found" || true)"
  if [[ "$count" == 0 ]]; then
    problems+=("${PANEL_REPO}'s release ${tag} records no digest of ${image}: release the panel with its scripts/release.sh, which records each image's")
    continue
  elif [[ "$count" != 1 ]]; then
    problems+=("${PANEL_REPO}'s release ${tag} records ${count} digests of ${image}: $(tr '\n' ' ' <<<"$found")")
    continue
  fi
  if ! on_ghcr "${image}:${version}"; then
    problems+=("cannot resolve ${image}:${version} on GHCR (${last_error}): log Docker in to ghcr.io (gh auth token | docker login ghcr.io -u <user> --password-stdin)")
  elif [[ "$ghcr" != "$found" ]]; then
    problems+=("${image}:${version} is ${ghcr} on GHCR, but the release recorded ${found}: the tag moved after the release; find out why")
  else
    say "${image}:${version} is ${found} on GHCR, as the release recorded"
    digests[i]="$found"
  fi
done

if [[ "$mode" == check ]]; then
  for i in "${!IMAGES[@]}"; do
    [[ -n "${digests[i]:-}" ]] || continue
    want="${REGISTRY}/${IMAGES[i]}:${version}@${digests[i]}"
    have="$(image_lines "${IMAGES[i]}" | sed -E 's/^[[:space:]]+image:[[:space:]]+//')"
    [[ "$have" == "$want" ]] || problems+=("compose.yml pulls ${have}, not ${want}")
  done
  have="$(tr -d '[:space:]' <"$version_file")"
  [[ "$have" == "$version" ]] || problems+=("VERSION is ${have}, not ${version}")
  if ((${#problems[@]})); then
    printf 'error: %s\n' "${problems[@]}" >&2
    die "compose.yml and VERSION do not match ${PANEL_REPO}'s release ${tag}: run scripts/pin-release.sh ${version}"
  fi
  say "compose.yml and VERSION match ${PANEL_REPO}'s release ${tag} and GHCR"
  exit 0
fi

if ((${#problems[@]})); then
  printf 'error: %s\n' "${problems[@]}" >&2
  die "nothing was pinned; compose.yml and VERSION are as they were"
fi
pinned_compose >"$tmp/compose.yml"
printf '%s\n' "$version" >"$tmp/VERSION"
if cmp -s "$tmp/compose.yml" "$compose" && cmp -s "$tmp/VERSION" "$version_file"; then
  say "compose.yml and VERSION already pin ${version}; nothing to change"
  exit 0
fi
cat "$tmp/compose.yml" >"$compose"
cat "$tmp/VERSION" >"$version_file"
say "compose.yml pins the images of ${version} by digest, and VERSION is ${version}"
say "next: git commit -am \"chore: ${version}\", push, wait for CI, then tag v${version} (README.md, Releasing)"
