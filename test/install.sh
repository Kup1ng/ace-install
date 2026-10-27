#!/usr/bin/env bash
# Checks install.sh's version resolution with ACE_DRY_RUN=1, which changes
# nothing on the machine: curl is a stub that serves this checkout's files
# for the refs listed in $state/refs, with each ref's VERSION from
# $state/VERSION.<ref>. It covers an explicit version, the VERSION of main
# and of ACE_INSTALL_REF, prereleases of the 2.x line, the refusal of 1.x
# versions and of malformed ones, a version ace-install has no tag for, bad
# options, that it runs when piped into bash, and that ACE_PROXY reaches curl
# through its environment, never its command line. It also sources install.sh
# to check apt_proxy and docker_proxy against a stub systemctl: apt reads the
# proxy from a root-only file, and Docker's goes into a root-only
# EnvironmentFile, never into the unit's Environment=, which every user can
# read. No root needed:
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

echo "piped into bash, as the install command runs it, it runs main"
set +e
out="$(env -u ACE_VERSION -u ACE_INSTALL_REF -u ACE_TLS -u ACE_PROXY ACE_DRY_RUN=1 bash <"$src/install.sh" 2>&1)"
code=$?
set -e
expect 0 $'version=2.0.1\nref=v2.0.1'

# A proxy whose URL holds an (obviously fake) password, percent-encoded.
proxy_url='http://ace:fake%2Fpassword@proxy.example.test:3128'

echo "the proxy reaches curl through its environment, never its command line"
: >"$state/curl.args"
: >"$state/curl.proxy"
dry ACE_PROXY="$proxy_url"
expect 0 $'version=2.0.1\nref=v2.0.1'
[[ -s "$state/curl.args" ]] || fail "curl did not run"
! grep -qF 'fake%2Fpassword' "$state/curl.args" || fail "the proxy is on curl's command line: $(cat "$state/curl.args")"
[[ "$(sort -u "$state/curl.proxy")" == "$proxy_url" ]] || fail "curl did not get the proxy in its environment: $(cat "$state/curl.proxy")"

cat >"$work/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$ACE_TEST_STATE/systemctl"
EOF
chmod 755 "$work/bin/systemctl"
dropins="$work/docker.service.d"
mkdir -p "$work/private"

# real_modes is 1 where chmod is real (not on Git Bash's NTFS).
: >"$work/probe"
chmod 600 "$work/probe"
real_modes=0
[[ "$(stat -c %a "$work/probe")" != 600 ]] || real_modes=1

# installer URL apt|docker runs a shell that sources install.sh (so it only
# defines its functions) with ACE_PROXY=URL, Docker's drop-ins in $dropins
# and its temporary files in $work/private, then prints the options it gives
# apt-get (apt) or runs docker_proxy (docker), keeping the output and exit
# status.
installer() {
  set +e
  # shellcheck disable=SC2016 # expanded by the inner shell
  out="$(ACE_PROXY="$1" bash -c '
    source "$1"
    docker_dropins="$2" tmp="$3"
    case "$4" in
    apt) apt_proxy && printf "%s\n" "${apt_opts[@]}" ;;
    docker) docker_proxy ;;
    esac' installer "$src/install.sh" "$dropins" "$work/private" "$2" 2>&1)"
  code=$?
  set -e
}

echo "apt reads the proxy from a root-only file, never its command line"
installer "$proxy_url" apt
expect 0 "-c"$'\n'"$work/private/apt-proxy.conf"
[[ "$out" != *fake%2Fpassword* ]] || fail "the proxy is on apt's command line: ${out}"
[[ "$(cat "$work/private/apt-proxy.conf")" == "Acquire::http::Proxy \"${proxy_url}\";"$'\n'"Acquire::https::Proxy \"${proxy_url}\";" ]] ||
  fail "apt's proxy file is wrong: $(cat "$work/private/apt-proxy.conf")"
((real_modes == 0)) || [[ "$(stat -c %a "$work/private/apt-proxy.conf")" == 600 ]] || fail "apt's proxy file is not root's only"
installer "" apt
expect 0
[[ "$out" != *apt-proxy.conf* ]] || fail "apt gets a proxy file without ACE_PROXY: ${out}"

# expect_proxied SYSTEMCTL checks that Docker pulls through $proxy_url from
# a root-only file, which the unit names but never holds, and that systemctl
# was told SYSTEMCTL.
expect_proxied() {
  local unit env
  unit="$(cat "$dropins/ace-proxy.conf" 2>/dev/null || true)"
  env="$(cat "$dropins/ace-proxy.env" 2>/dev/null || true)"
  [[ "$unit" == *$'\n[Service]\nEnvironmentFile='"$dropins/ace-proxy.env" ]] || fail "the drop-in does not name the proxy's file: ${unit}"
  [[ "$unit" != *proxy.example.test* && "$unit" != *Environment=* ]] || fail "the drop-in holds the proxy: ${unit}"
  [[ "$env" == "HTTP_PROXY='${proxy_url}'"$'\n'"HTTPS_PROXY='${proxy_url}'"$'\n'"NO_PROXY=localhost,127.0.0.0/8,::1" ]] ||
    fail "the proxy's file is wrong: ${env}"
  ((real_modes == 0)) || [[ "$(stat -c %a "$dropins/ace-proxy.env")" == 600 ]] || fail "the proxy's file is not root's only"
  [[ "$(cat "$state/systemctl" 2>/dev/null)" == "$1" ]] || fail "systemctl was told: $(cat "$state/systemctl" 2>/dev/null)"
}

echo "Docker's proxy goes into a root-only file, never into the unit"
installer "$proxy_url" docker
expect 0 "Docker restarts"
expect_proxied $'daemon-reload\nrestart docker'

echo "the same proxy again restarts nothing"
: >"$state/systemctl"
installer "$proxy_url" docker
expect 0
[[ -z "$out" ]] || fail "docker_proxy said: ${out}"
expect_proxied ""

echo "no proxy: Docker keeps the one it has"
installer "" docker
expect 0 "Docker still pulls through the proxy"
expect_proxied ""

echo "the 1.x drop-in, with the proxy in Environment=, moves to the file"
rm -f "$dropins/ace-proxy.env"
old_proxy="${proxy_url//%/%%}" # systemd's specifiers: 1.x wrote %% for each %
printf '%s\n' '# Written by the Ace installer: Docker pulls through this proxy.' '[Service]' \
  "Environment=\"HTTP_PROXY=${old_proxy}\" \"HTTPS_PROXY=${old_proxy}\" \"NO_PROXY=localhost,127.0.0.0/8,::1\"" \
  >"$dropins/ace-proxy.conf"
: >"$state/systemctl"
installer "" docker
expect 0 "Docker restarts"
expect_proxied $'daemon-reload\nrestart docker'

echo "all good"
