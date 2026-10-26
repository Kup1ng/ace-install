#!/usr/bin/env bash
# Checks install.sh's version resolution with ACE_DRY_RUN=1, which changes
# nothing on the machine: curl is a stub that serves this checkout's files
# for the refs listed in $state/refs, with each ref's VERSION from
# $state/VERSION.<ref>. It covers an explicit version, the VERSION of main
# and of ACE_INSTALL_REF, prereleases of the 2.x line, the refusal of 1.x
# versions and of malformed ones, a version ace-install has no tag for, and
# bad options. No root needed:
#
#   bash test/install.sh
set -euo pipefail

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

src="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
state="$work/state"
mkdir -p "$state" "$work/bin" "$work/tmp"
export ACE_TEST_SRC="$src" ACE_TEST_STATE="$state"

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
name="$(basename "$url")"
ref="$(basename "$(dirname "$url")")"
grep -qx "$ref" "$ACE_TEST_STATE/refs" || exit 22
if [[ "$name" == VERSION && -f "$ACE_TEST_STATE/VERSION.$ref" ]]; then
  file="$ACE_TEST_STATE/VERSION.$ref"
else
  file="$ACE_TEST_SRC/$name"
fi
[[ -f "$file" ]] || exit 22
if [[ -n "$out" ]]; then cp "$file" "$out"; else cat "$file"; fi
EOF
chmod 755 "$work/bin/curl"
export PATH="$work/bin:$PATH" TMPDIR="$work/tmp"

printf '%s\n' main v2.0.0 v2.0.1 v2.0.0-rc.1 m15-install-v2 >"$state/refs"
echo 2.0.1 >"$state/VERSION.main"
echo 2.0.0-rc.1 >"$state/VERSION.m15-install-v2"

# dry ENV... runs a dry run with only these ACE_* variables set, keeping its
# output and exit status.
dry() {
  set +e
  out="$(env -u ACE_VERSION -u ACE_INSTALL_REF -u ACE_TLS -u ACE_PROXY ACE_DRY_RUN=1 "$@" bash "$src/install.sh" 2>&1)"
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
}

echo "an explicit version takes its own tag"
dry ACE_VERSION=2.0.0
expect 0 $'version=2.0.0\nref=v2.0.0' "nothing changed"

echo "no version: main's VERSION"
dry
expect 0 $'version=2.0.1\nref=v2.0.1'

echo "a branch: its VERSION, its files"
dry ACE_INSTALL_REF=m15-install-v2
expect 0 $'version=2.0.0-rc.1\nref=m15-install-v2'

echo "a prerelease of 2.x"
dry ACE_VERSION=2.0.0-rc.1
expect 0 $'version=2.0.0-rc.1\nref=v2.0.0-rc.1'

echo "an explicit version with a branch's files"
dry ACE_VERSION=2.0.1 ACE_INSTALL_REF=m15-install-v2 ACE_TLS=custom
expect 0 $'version=2.0.1\nref=m15-install-v2'

echo "1.x is the v1 installer's"
dry ACE_VERSION=1.1.0
expect 1 "1.1.0 is a 1.x version" "/v1/install.sh"
echo 1.1.0 >"$state/VERSION.main"
dry
expect 1 "1.1.0 is a 1.x version"
echo 2.0.1 >"$state/VERSION.main"

echo "malformed versions"
dry ACE_VERSION=latest
expect 1 "ACE_VERSION must be a version"
dry ACE_VERSION=2.0
expect 1 "ACE_VERSION must be a version"

echo "a version without a tag"
dry ACE_VERSION=2.0.9
expect 1 "cannot download compose.yml from ace-install (v2.0.9)"

echo "a ref without a VERSION"
dry ACE_INSTALL_REF=no-such-branch
expect 1 "cannot read the current version from ace-install (no-such-branch)"

echo "bad options"
dry ACE_VERSION=2.0.0 ACE_TLS=letsencrypt
expect 1 "ACE_TLS must be acme or custom"
dry ACE_VERSION=2.0.0 ACE_PROXY=ftp://proxy.example.test
expect 1 "ACE_PROXY must be"

echo "all good"
