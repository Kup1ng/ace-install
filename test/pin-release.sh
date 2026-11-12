#!/usr/bin/env bash
# Checks scripts/pin-release.sh in a scratch copy of this checkout, whose
# compose.yml is made unpinned first, against stubs: gh serves the panel's
# release notes from $state/release.<tag> (a draft when $state/draft.<tag>
# says true), docker serves GHCR's digests from $state/ghcr, both drop the
# link $state/<tool>.drops times first, and sleep returns at once. It covers
# a release that does not exist yet, a draft, a digest the notes lack or give
# twice, a tag that moved on GHCR or is missing there, retried drops, the
# pin itself (only the four image lines and VERSION change), running it
# again, --check, the next release candidate, and test/compose.sh on pinned,
# unpinned and broken stacks, and against lists of the images Docker
# resolves (the same four, one more, one fewer). No root, no network:
#
#   bash test/pin-release.sh
# shellcheck disable=SC2016 # the notes quote images in backticks; ${ACE_VERSION} is text here
set -euo pipefail

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

src="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
state="$work/state" repo="$work/repo"
mkdir -p "$state" "$work/bin" "$work/tmp" "$repo/scripts" "$repo/test"
export ACE_TEST_STATE="$state"

cat >"$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$ACE_TEST_STATE/gh.args"
drops="$(cat "$ACE_TEST_STATE/gh.drops" 2>/dev/null || echo 0)"
if ((drops > 0)); then
  echo $((drops - 1)) >"$ACE_TEST_STATE/gh.drops"
  echo 'Post "https://api.github.com/graphql": unexpected EOF' >&2
  exit 1
fi
[[ "$1 $2" == "release view" && "${*:4}" == "--repo Kup1ng/Ace-Panel --json body,isDraft --jq .isDraft, .body" ]] || {
  echo "unexpected call: gh $*" >&2
  exit 3
}
[[ -f "$ACE_TEST_STATE/release.$3" ]] || {
  echo "release not found" >&2
  exit 1
}
cat "$ACE_TEST_STATE/draft.$3" 2>/dev/null || echo false
cat "$ACE_TEST_STATE/release.$3"
EOF
cat >"$work/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$ACE_TEST_STATE/docker.args"
drops="$(cat "$ACE_TEST_STATE/docker.drops" 2>/dev/null || echo 0)"
if ((drops > 0)); then
  echo $((drops - 1)) >"$ACE_TEST_STATE/docker.drops"
  echo 'ERROR: failed to do request: Head "https://ghcr.io/v2/": tls: bad record MAC' >&2
  exit 1
fi
[[ "$1 $2 $3" == "buildx imagetools inspect" && $# -eq 4 ]] || {
  echo "unexpected call: docker $*" >&2
  exit 3
}
digest="$(awk -v ref="$4" '$1 == ref { print $2 }' "$ACE_TEST_STATE/ghcr")"
[[ -n "$digest" ]] || {
  echo "ERROR: $4: not found" >&2
  exit 1
}
printf 'Name:      %s\nMediaType: application/vnd.oci.image.index.v1+json\nDigest:    %s\n\n' "$4" "$digest"
printf 'Manifests:\n  Name:      %s@sha256:%064d\n  Platform:  linux/amd64\n' "${4%:*}" 7
EOF
printf '#!/bin/sh\n' >"$work/bin/sleep"
chmod 755 "$work/bin/"*
export PATH="$work/bin:$PATH" TMPDIR="$work/tmp"

images=(ace-postgres ace-panel-api ace-panel-web ace-caddy)
cp "$src/scripts/pin-release.sh" "$repo/scripts/"
cp "$src/test/compose.sh" "$repo/test/"
# The stack as it is before a release: every image takes ACE_VERSION's tag.
sed -E 's#^( +image: ghcr\.io/kup1ng/[a-z0-9-]+)[:@].*#\1:${ACE_VERSION:?set ACE_VERSION in /opt/ace/.env}#' \
  "$src/compose.yml" >"$repo/compose.yml"
echo 2.0.0-rc.1 >"$repo/VERSION"
unpinned="$(cat "$repo/compose.yml")"
: >"$state/ghcr"

# d N is the made-up digest number N.
d() { printf 'sha256:%064x' "$1"; }

# publish VERSION N: the panel's release vVERSION records, and GHCR serves,
# the digest N+i for the i-th image.
publish() {
  local i
  {
    printf '## [%s]\n\nWhat changed.\n\nImages:\n' "$1"
    printf -- '- `ghcr.io/kup1ng/ace-node-agent@%s` (the agent it offers)\n' "$(d 999)"
    for i in "${!images[@]}"; do printf -- '- `ghcr.io/kup1ng/%s@%s`\n' "${images[i]}" "$(d $(($2 + i)))"; done
  } >"$state/release.v$1"
  for i in "${!images[@]}"; do printf 'ghcr.io/kup1ng/%s:%s %s\n' "${images[i]}" "$1" "$(d $(($2 + i)))"; done >>"$state/ghcr"
}

# moved REF DIGEST makes GHCR serve DIGEST for REF.
moved() {
  awk -v ref="$1" -v digest="$2" '$1 == ref { $2 = digest } { print }' "$state/ghcr" >"$state/ghcr.new"
  mv "$state/ghcr.new" "$state/ghcr"
}

files() { cat "$repo/compose.yml" "$repo/VERSION"; }

# pin ARGS... runs the script in the copy, keeping its output and exit status.
pin() {
  set +e
  out="$(cd "$repo" && bash scripts/pin-release.sh "$@" 2>&1)"
  code=$?
  set -e
}

# expect CODE TEXT... checks the last run's exit status, each text in its
# output, and that no temporary file stayed.
expect() {
  local want="$1" text
  shift
  [[ "$code" == "$want" ]] || fail "exit ${code}, not ${want}: ${out}"
  for text in "$@"; do
    [[ "$out" == *"$text"* ]] || fail "no \"${text}\" in: ${out}"
  done
  [[ -z "$(ls -A "$TMPDIR")" ]] || fail "temporary files stayed: $(ls -A "$TMPDIR")"
  [[ "$(LC_ALL=C ls -A "$repo")" == $'VERSION\ncompose.yml\nscripts\ntest' ]] || fail "files stayed in the checkout: $(ls -A "$repo")"
}

# unchanged checks that compose.yml and VERSION are still $before.
unchanged() { [[ "$(files)" == "$before" ]] || fail "the files changed: $(files)"; }

# image NAME prints the image compose.yml names for NAME.
image() { sed -nE "s#^ +image: (ghcr\.io/kup1ng/$1[:@].*)#\1#p" "$repo/compose.yml"; }

# expect_pinned VERSION N checks that each image is pinned to VERSION and the
# digest N+i, VERSION says VERSION, nothing else changed, and test/compose.sh
# agrees.
expect_pinned() {
  local i
  for i in "${!images[@]}"; do
    [[ "$(image "${images[i]}")" == "ghcr.io/kup1ng/${images[i]}:$1@$(d $(($2 + i)))" ]] ||
      fail "${images[i]} is not pinned to $1: $(image "${images[i]}")"
  done
  [[ "$(cat "$repo/VERSION")" == "$1" ]] || fail "VERSION is $(cat "$repo/VERSION"), not $1"
  [[ "$(grep -v '^ *image: ' "$repo/compose.yml")" == "$(grep -v '^ *image: ' <<<"$unpinned")" ]] ||
    fail "more than the image lines changed: $(diff <(echo "$unpinned") "$repo/compose.yml")"
  bash "$repo/test/compose.sh" "$repo" >/dev/null || fail "test/compose.sh refuses the pinned stack"
}

echo "help and usage"
pin --help
expect 0 "scripts/pin-release.sh <version>" "--check <version>"
pin
expect 2 "scripts/pin-release.sh <version>"
pin 2.0.0-alpha.17
expect 1 "2.0.0-alpha.17 is not a release: give x.y.z or x.y.z-rc.N"
pin --check
expect 2

before="$(files)"
echo "no release yet"
pin 2.0.0-rc.1
expect 1 "cannot read Kup1ng/Ace-Panel's release v2.0.0-rc.1 (release not found): release the panel first"
unchanged
[[ "$(wc -l <"$state/gh.args")" == 1 ]] || fail "a missing release was retried: $(cat "$state/gh.args")"

echo "a draft release"
publish 2.0.0-rc.1 100
echo true >"$state/draft.v2.0.0-rc.1"
pin 2.0.0-rc.1
expect 1 "release v2.0.0-rc.1 is a draft: publish it first"
unchanged
rm "$state/draft.v2.0.0-rc.1"

echo "a digest the notes lack"
cp "$state/release.v2.0.0-rc.1" "$work/notes"
sed -i '/ace-caddy@/d' "$state/release.v2.0.0-rc.1"
pin 2.0.0-rc.1
expect 1 "records no digest of ghcr.io/kup1ng/ace-caddy" "nothing was pinned"
unchanged

echo "two digests of one image"
cp "$work/notes" "$state/release.v2.0.0-rc.1"
printf -- '- `ghcr.io/kup1ng/ace-panel-web@%s`\n' "$(d 555)" >>"$state/release.v2.0.0-rc.1"
pin 2.0.0-rc.1
expect 1 "records 2 digests of ghcr.io/kup1ng/ace-panel-web"
unchanged

echo "a tag that moved on GHCR after the release"
cp "$work/notes" "$state/release.v2.0.0-rc.1"
moved ghcr.io/kup1ng/ace-panel-api:2.0.0-rc.1 "$(d 500)"
pin 2.0.0-rc.1
expect 1 "ghcr.io/kup1ng/ace-panel-api:2.0.0-rc.1 is $(d 500) on GHCR, but the release recorded $(d 101): the tag moved"
unchanged
moved ghcr.io/kup1ng/ace-panel-api:2.0.0-rc.1 "$(d 101)"

echo "a tag GHCR does not have"
sed -i '/ace-caddy:2.0.0-rc.1/d' "$state/ghcr"
pin 2.0.0-rc.1
expect 1 "cannot resolve ghcr.io/kup1ng/ace-caddy:2.0.0-rc.1 on GHCR (ERROR: ghcr.io/kup1ng/ace-caddy:2.0.0-rc.1: not found)"
unchanged
printf 'ghcr.io/kup1ng/ace-caddy:2.0.0-rc.1 %s\n' "$(d 103)" >>"$state/ghcr"

echo "network drops are retried, then the stack is pinned"
echo 2 >"$state/gh.drops"
echo 3 >"$state/docker.drops"
printf -- '- `ghcr.io/kup1ng/ace-postgres@%s` (the same digest twice is one)\n' "$(d 100)" >>"$state/release.v2.0.0-rc.1"
pin 2.0.0-rc.1
expect 0 "unexpected EOF" "tls: bad record MAC" "compose.yml pins the images of 2.0.0-rc.1 by digest" 'git commit -am "chore: 2.0.0-rc.1"'
expect_pinned 2.0.0-rc.1 100

echo "running it again changes nothing"
before="$(files)"
pin v2.0.0-rc.1
expect 0 "already pin 2.0.0-rc.1; nothing to change"
unchanged

echo "--check agrees with the release and GHCR"
pin --check 2.0.0-rc.1
expect 0 "compose.yml and VERSION match Kup1ng/Ace-Panel's release v2.0.0-rc.1 and GHCR"

echo "--check finds a digest that differs, and writes nothing"
sed -i "s#ace-caddy:2.0.0-rc.1@sha256:[0-9a-f]*#ace-caddy:2.0.0-rc.1@$(d 777)#" "$repo/compose.yml"
before="$(files)"
pin --check 2.0.0-rc.1
expect 1 "compose.yml pulls ghcr.io/kup1ng/ace-caddy:2.0.0-rc.1@$(d 777), not ghcr.io/kup1ng/ace-caddy:2.0.0-rc.1@$(d 103)" "run scripts/pin-release.sh 2.0.0-rc.1"
unchanged
pin 2.0.0-rc.1
expect 0
expect_pinned 2.0.0-rc.1 100

echo "--check finds a VERSION that differs, a tag that moved, an unpinned stack"
echo 2.0.0-rc.9 >"$repo/VERSION"
pin --check 2.0.0-rc.1
expect 1 "VERSION is 2.0.0-rc.9, not 2.0.0-rc.1"
echo 2.0.0-rc.1 >"$repo/VERSION"
moved ghcr.io/kup1ng/ace-postgres:2.0.0-rc.1 "$(d 600)"
pin --check 2.0.0-rc.1
expect 1 "the tag moved after the release"
moved ghcr.io/kup1ng/ace-postgres:2.0.0-rc.1 "$(d 100)"
pinned="$(cat "$repo/compose.yml")"
printf '%s\n' "$unpinned" >"$repo/compose.yml"
pin --check 2.0.0-rc.1
expect 1 "compose.yml pulls ghcr.io/kup1ng/ace-panel-web:\${ACE_VERSION:?set ACE_VERSION in /opt/ace/.env}, not"
printf '%s\n' "$pinned" >"$repo/compose.yml"

echo "the next release candidate"
publish 2.0.0-rc.2 200
pin 2.0.0-rc.2
expect 0 "compose.yml pins the images of 2.0.0-rc.2 by digest"
expect_pinned 2.0.0-rc.2 200
! grep -q 'ace-node-agent' "$repo/compose.yml" || fail "the agent's digest went into the stack"

echo "a compose.yml without one image, or with it twice, is refused before any call"
cp "$repo/compose.yml" "$work/compose.good"
: >"$state/gh.args"
sed -i '/ace-caddy:/d' "$repo/compose.yml"
pin 2.0.0-rc.2
expect 1 "compose.yml has 0 image lines of ghcr.io/kup1ng/ace-caddy, not 1" "fix compose.yml first"
cp "$work/compose.good" "$repo/compose.yml"
grep 'image: ghcr.io/kup1ng/ace-postgres:' "$work/compose.good" >>"$repo/compose.yml"
pin 2.0.0-rc.2
expect 1 "compose.yml has 2 image lines of ghcr.io/kup1ng/ace-postgres, not 1"
[[ ! -s "$state/gh.args" ]] || fail "gh ran for a broken compose.yml"
cp "$work/compose.good" "$repo/compose.yml"

echo "test/compose.sh: all unpinned or all pinned to VERSION"
check() {
  set +e
  out="$(bash "$repo/test/compose.sh" "$repo" 2>&1)"
  code=$?
  set -e
}
check
expect 0 "the 4 images are pinned to 2.0.0-rc.2 by digest"
printf '%s\n' "$unpinned" >"$repo/compose.yml"
check
expect 0 "the 4 images take their tag from ACE_VERSION (unpinned)"
sed -i "s#ace-caddy:.*#ace-caddy:2.0.0-rc.2@$(d 1)#" "$repo/compose.yml"
check
expect 1 "compose.yml pins 1 of its 4 images to 2.0.0-rc.2: all or none"
cp "$work/compose.good" "$repo/compose.yml"
sed -i "s#ace-caddy:2.0.0-rc.2@#ace-caddy:2.0.0-rc.1@#" "$repo/compose.yml"
check
expect 1 "is neither ghcr.io/kup1ng/ace-caddy:\${ACE_VERSION:?} nor pinned to VERSION 2.0.0-rc.2"
cp "$work/compose.good" "$repo/compose.yml"
sed -i "s#ace-caddy:2.0.0-rc.2@sha256:[0-9a-f]*#ace-caddy:2.0.0-rc.2@sha256:abc#" "$repo/compose.yml"
check
expect 1 "is neither"
cp "$work/compose.good" "$repo/compose.yml"
printf '  extra:\n    image: busybox:1\n' >>"$repo/compose.yml"
check
expect 1 "compose.yml has 5 images, not the 4"
cp "$work/compose.good" "$repo/compose.yml"
check
expect 0

echo "test/compose.sh IMAGES: Docker resolves the same images as the image: lines"
# resolve VALUE runs test/compose.sh with $work/resolved as the images Docker
# resolved with ACE_VERSION=VALUE (unset when VALUE is empty).
resolve() {
  set +e
  out="$(env -u ACE_VERSION ${1:+ACE_VERSION="$1"} bash "$repo/test/compose.sh" "$repo" "$work/resolved" 2>&1)"
  code=$?
  set -e
}
lines="$(for i in "${images[@]}"; do image "$i"; done)"
LC_ALL=C sort -r <<<"$lines" >"$work/resolved"
resolve 0.0.0
expect 0 "pinned to 2.0.0-rc.2 by digest" "Docker resolves the same 4 images"
printf '%s\nbusybox:1\n' "$lines" >"$work/resolved" # e.g. `extra: {image: busybox:1}`
resolve 0.0.0
expect 1 "only Docker sees: busybox:1" "block-style image: line"
printf '%s\n%s\n' "$lines" "$(image ace-caddy)" >"$work/resolved"
resolve 0.0.0
expect 1 "only Docker sees: $(image ace-caddy)"
grep -v ace-caddy <<<"$lines" >"$work/resolved"
resolve 0.0.0
expect 1 "only the lines name: $(image ace-caddy)"
resolve ""
expect 1 "set ACE_VERSION"
printf '%s\n' "$unpinned" >"$repo/compose.yml"
printf 'ghcr.io/kup1ng/%s:0.0.0\n' "${images[@]}" >"$work/resolved"
resolve 0.0.0
expect 0 "(unpinned)" "Docker resolves the same 4 images"
resolve 0.0.1
expect 1 "only Docker sees: ghcr.io/kup1ng/ace-caddy:0.0.0" "only the lines name: ghcr.io/kup1ng/ace-caddy:0.0.1"
cp "$work/compose.good" "$repo/compose.yml"

echo "all good"
