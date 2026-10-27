#!/usr/bin/env bash
# Ace panel installer (v2). Run it as root on a fresh Ubuntu 22.04 or 24.04:
#
#   curl -fsSL https://raw.githubusercontent.com/Kup1ng/ace-install/main/install.sh | bash
#
# It checks the server, installs Docker when it is missing or older than 25,
# asks for the panel's domain, how it gets its HTTPS certificate, a GHCR
# token and the Owner's name, makes the secrets on this server, starts the
# panel in /opt/ace, creates the Owner with a generated password it prints
# once, and adds the `ace` command. v2 installs only on a server without a
# panel: nothing carries over from 1.x (D52.2).
#
# Optional, in the environment (the README explains each one):
#   ACE_VERSION=<x.y.z>    the version, 2.0.0 or later (default: the VERSION
#                          file of ACE_INSTALL_REF, else main)
#   ACE_DOMAIN, ACE_EMAIL, ACE_GHCR_USER, ACE_GHCR_TOKEN, ACE_OWNER: answers
#   ACE_TLS=acme|custom    acme (default): Let's Encrypt, renewed by Caddy;
#                          custom: ACE_TLS_CERT and ACE_TLS_KEY (PEM files)
#   ACE_PROXY=<url>        http:// or socks5:// proxy for apt and Docker (for
#                          good); root-only files, never a command line
#   ACE_APT_MIRROR=<url>   mirror of the Ubuntu archive, for this install only
#   ACE_ANY_OS=1           try a system other than Ubuntu 22.04/24.04 (unsupported)
#   ACE_INSTALL_REF=<ref>  the ace-install ref to take the files from (default: v<version>)
#   ACE_DRY_RUN=1          only resolve the version and check the files; change nothing
set -euo pipefail

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

repo_raw=https://raw.githubusercontent.com/Kup1ng/ace-install
dir=/opt/ace
docker_dropins=/etc/systemd/system/docker.service.d # test/install.sh moves it
proxy="${ACE_PROXY:-}"
mirror="${ACE_APT_MIRROR:-}"
url_chars='^[][A-Za-z0-9._~:/?#@!$&()*+,;=%-]+$'

os_id="" os_version="" os_codename="" os_name="this system"
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  IFS=$'\t' read -r os_id os_version os_codename os_name < <(. /etc/os-release &&
    printf '%s\t%s\t%s\t%s\n' "${ID:-}" "${VERSION_ID:-}" "${VERSION_CODENAME:-}" "${PRETTY_NAME:-this system}")
fi

# --- The server ---------------------------------------------------------

# check_options checks the options a dry run uses too.
check_options() {
  [[ -z "$proxy" || ("$proxy" =~ ^(https?|socks5h?):// && "$proxy" =~ $url_chars) ]] ||
    die "ACE_PROXY must be an http://, https:// or socks5:// URL"
  [[ -z "$mirror" || ("$mirror" =~ ^https?:// && "$mirror" =~ $url_chars) ]] ||
    die "ACE_APT_MIRROR must be an http:// or https:// URL"
  [[ -z "${ACE_TLS:-}" || "$ACE_TLS" == acme || "$ACE_TLS" == custom ]] || die "ACE_TLS must be acme or custom"
}

check_server() {
  [[ $EUID -eq 0 ]] || die "run as root (for example: sudo -i, then paste the command again)"
  [[ "$(uname -m)" == x86_64 ]] || die "the Ace panel needs an x86_64 (amd64) server; this one is $(uname -m)"
  if [[ "$os_id" != ubuntu || ("$os_version" != 22.04 && "$os_version" != 24.04) ]]; then
    [[ "${ACE_ANY_OS:-}" == 1 ]] || die "the Ace panel runs on Ubuntu 22.04 or 24.04, not ${os_name}. ACE_ANY_OS=1 tries anyway, unsupported."
    warn "${os_name} is not supported; going on because ACE_ANY_OS=1"
  fi
  for cmd in curl openssl; do
    command -v "$cmd" >/dev/null || die "${cmd} is required"
  done
  if [[ -e "$dir/.installed" ]]; then
    local installed
    installed="$(sed -n 's/^ACE_VERSION=//p' "$dir/.env" 2>/dev/null | tail -1)"
    if [[ "${installed%%.*}" =~ ^[0-9]+$ ]] && ((${installed%%.*} >= 2)); then
      die "the Ace panel ${installed} is already installed in ${dir}; use: ace upgrade <version>"
    fi
    die "the Ace panel ${installed:-1.x} is installed in ${dir}. v2 starts on a fresh install: nothing carries over from 1.x. Install it on a fresh server, or keep this one on the 1.x line"
  fi
  # A panel set up by hand has no marker, but runs.
  if command -v docker >/dev/null && [[ -n "$(docker ps -q --filter label=com.docker.compose.project=ace 2>/dev/null)" ]]; then
    die "an Ace panel already runs on this server (Docker Compose project \"ace\"); this installer is for a fresh one"
  fi
  local mem_gib free_gb
  mem_gib=$(($(awk '/^MemTotal:/ { print $2 }' /proc/meminfo) / 1024 / 1024))
  ((mem_gib >= 2)) || warn "this server has ${mem_gib} GiB of memory; the panel needs about 2 GiB"
  free_gb="$(df -BG --output=avail / | tail -1 | tr -dc '0-9')"
  ((${free_gb:-0} >= 20)) || warn "${free_gb} GB free; the panel needs about 20 GB, more for its database and backups"
  if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" != yes ]]; then
    warn "the clock is not synchronized over NTP; certificates and sign-ins need the right time"
  fi
}

# ask VAR QUESTION [DEFAULT] [secret|optional] reads an answer from the
# terminal, unless VAR is already set. Without a terminal an optional
# answer takes its default.
ask() {
  local var="$1" question="$2" default="${3:-}" kind="${4:-}" answer
  [[ -z "${!var:-}" ]] || return 0
  if [[ ! -r /dev/tty && "$kind" == optional ]]; then
    printf -v "$var" '%s' "$default"
    return 0
  fi
  [[ -r /dev/tty ]] || die "no terminal to ask on; set ${var}"
  while :; do
    if [[ "$kind" == secret ]]; then
      read -rsp "${question}: " answer </dev/tty
      echo >/dev/tty
    else
      read -rp "${question}${default:+ [${default}]}: " answer </dev/tty
    fi
    answer="${answer:-$default}"
    [[ -n "$answer" || "$kind" == optional ]] && break
  done
  printf -v "$var" '%s' "$answer"
}

# public_ip is the panel's address for its nodes (ace-node panel-ip): the
# domain's, else the one this server leaves through.
public_ip() {
  local ip
  ip="$(getent ahostsv4 "$ACE_DOMAIN" 2>/dev/null | awk 'NR == 1 { print $1 }')"
  if [[ -z "$ip" ]]; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit } }')"
  fi
  printf '%s' "$ip"
}

# --- Docker -------------------------------------------------------------

apt_opts=(-y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# download ARGS... runs curl, which gets ACE_PROXY in its root-only
# environment: on its command line (-x) every user could read the password.
download() { if [[ -n "$proxy" ]]; then https_proxy="$proxy" HTTPS_PROXY="$proxy" curl "$@"; else curl "$@"; fi; }

# apt_proxy hands apt ACE_PROXY in a root-only file, not on its command
# line, which every user can read (and history.log keeps).
apt_proxy() {
  [[ -n "$proxy" ]] || return 0
  (umask 077 && printf 'Acquire::http::Proxy "%s";\nAcquire::https::Proxy "%s";\n' "$proxy" "$proxy" >"$tmp/apt-proxy.conf")
  apt_opts+=(-c "$tmp/apt-proxy.conf")
}

docker_major() {
  local v
  v="$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)"
  printf '%s' "${v%%.*}"
}

# install_docker installs Docker Engine from Docker's repository, replacing
# Ubuntu's own packages, which would conflict. Images and containers stay.
install_docker() {
  local repo_os=ubuntu old=() p
  [[ "$os_id" == debian ]] && repo_os=debian
  export DEBIAN_FRONTEND=noninteractive
  install -m 0755 -d /etc/apt/keyrings
  download -fsSL --retry 3 --connect-timeout 15 "https://download.docker.com/linux/${repo_os}/gpg" \
    -o /etc/apt/keyrings/docker.asc || die "cannot download Docker's signing key${proxy:+ through the proxy}"
  chmod a+r /etc/apt/keyrings/docker.asc
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
    "$(dpkg --print-architecture)" "$repo_os" "$os_codename" >/etc/apt/sources.list.d/docker.list
  apt_proxy
  if [[ -n "$mirror" ]]; then
    # This install reads the archive from the mirror; the server's own
    # sources stay as they are.
    mkdir -p "$tmp/apt/parts"
    cp /etc/apt/sources.list.d/docker.list "$tmp/apt/parts/"
    for p in "" -updates -security; do
      printf 'deb %s %s%s main restricted universe\n' "${mirror%/}" "$os_codename" "$p"
    done >"$tmp/apt/sources.list"
    apt_opts+=(-o "Dir::Etc::SourceList=$tmp/apt/sources.list" -o "Dir::Etc::SourceParts=$tmp/apt/parts")
  fi
  apt-get "${apt_opts[@]}" update </dev/null || warn "apt could not read every package list${mirror:+ from the mirror}; going on"
  for p in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    if [[ "$(dpkg-query -W -f '${Status}' "$p" 2>/dev/null)" == "install ok installed" ]]; then old+=("$p"); fi
  done
  if ((${#old[@]})); then apt-get "${apt_opts[@]}" remove "${old[@]}" </dev/null || die "cannot remove Ubuntu's Docker packages: ${old[*]}"; fi
  apt-get "${apt_opts[@]}" install --no-install-recommends \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin </dev/null ||
    die "installing Docker failed${mirror:+ (is the mirror reachable?)}${proxy:+ (is the proxy reachable?)}"
  systemctl enable --now docker >/dev/null 2>&1 || die "Docker was installed but does not start (journalctl -u docker)"
}

ensure_docker() {
  local major
  if [[ -x /snap/bin/docker ]] && snap list docker >/dev/null 2>&1; then
    die "Docker from snap is not supported; remove it (snap remove docker) and run the command again"
  fi
  if ! command -v docker >/dev/null; then
    say "Installing Docker Engine from Docker's repository"
    install_docker
  else
    systemctl is-active --quiet docker || systemctl enable --now docker >/dev/null 2>&1 ||
      die "Docker is installed but does not start (journalctl -u docker)"
    major="$(docker_major)"
    if [[ "$major" =~ ^[0-9]+$ ]] && ((major < 25)); then
      warn "Docker ${major} is older than 25: upgrading it to Docker's own packages; the containers on this server restart"
      install_docker
    fi
  fi
  major="$(docker_major)"
  if ! [[ "$major" =~ ^[0-9]+$ ]] || ((major < 25)); then
    die "Docker 25 or newer is needed; this server has $(docker --version 2>&1)"
  fi
  docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is needed (the docker-compose-plugin package)"
}

# docker_proxy makes Docker pull through ACE_PROXY for good (upgrades too);
# without it an earlier setting stays. The URL goes into a root-only file the
# drop-in names: systemctl show docker prints Environment= to every user.
docker_proxy() {
  local dropin="$docker_dropins/ace-proxy.conf" env="$docker_dropins/ace-proxy.env" want_unit want_env
  if [[ -z "$proxy" ]]; then
    [[ ! -f "$dropin" ]] || say "Docker still pulls through the proxy of ${dropin}"
    return 0
  fi
  want_unit="$(printf '# Written by the Ace installer: Docker pulls through the proxy in a root-only file.\n[Service]\nEnvironmentFile=%s' "$env")"
  # Single quotes: systemd takes the URL as it is, with no specifier or escape.
  want_env="$(printf "HTTP_PROXY='%s'\nHTTPS_PROXY='%s'\nNO_PROXY=localhost,127.0.0.0/8,::1" "$proxy" "$proxy")"
  [[ "$(cat "$dropin" 2>/dev/null)" == "$want_unit" && "$(cat "$env" 2>/dev/null)" == "$want_env" ]] && { chmod 600 "$env"; return 0; }
  say "Docker pulls through the proxy from now on (${env}, root's only); Docker restarts"
  mkdir -p "$docker_dropins"
  install -m 600 /dev/null "$env" # root's only before it holds the URL
  printf '%s\n' "$want_env" >"$env"
  printf '%s\n' "$want_unit" >"$dropin"
  systemctl daemon-reload
  systemctl restart docker || die "Docker does not start with the proxy (journalctl -u docker)"
}

# --- The panel ----------------------------------------------------------

# fetch NAME DEST downloads one of ace-install's files at the install's ref.
fetch() {
  download -fsSL --retry 3 --connect-timeout 15 "${repo_raw}/${ref}/$1" -o "$2" ||
    die "cannot download $1 from ace-install (${ref})${proxy:+ through the proxy}"
}

# make_secrets writes the panel's secrets, readable only by the container
# user that needs each: PostgreSQL (70) reads its password after dropping
# root, and the panel runs as 10001. Secrets an interrupted install made
# stay: the database keeps the password it started with.
make_secrets() {
  local pg
  install -d -m 700 "$dir/secrets"
  if [[ -s "$dir/secrets/master_key" && -s "$dir/secrets/pg_password" && -s "$dir/secrets/api.env" ]]; then
    say "Keeping the secrets of the earlier, unfinished install"
    return 0
  fi
  pg="$(openssl rand -hex 24)"
  umask 077
  openssl rand -base64 32 >"$dir/secrets/master_key"
  printf '%s\n' "$pg" >"$dir/secrets/pg_password"
  printf 'ACE_PANEL_DATABASE_URL=postgres://ace:%s@postgres:5432/ace?sslmode=disable\n' "$pg" >"$dir/secrets/api.env"
  umask 022
  chown 10001:10001 "$dir/secrets/master_key"
  chown 70:70 "$dir/secrets/pg_password"
  chmod 400 "$dir/secrets/master_key" "$dir/secrets/pg_password"
  chmod 600 "$dir/secrets/api.env"
}

# resolve_version sets ACE_VERSION (from the environment, else the VERSION
# file of ACE_INSTALL_REF, else of main) and ref, the ace-install ref to
# take the files from. This installer installs the 2.x line only.
resolve_version() {
  local from="${ACE_INSTALL_REF:-main}"
  if [[ -z "${ACE_VERSION:-}" ]]; then
    ACE_VERSION="$(download -fsSL --retry 3 --connect-timeout 15 "${repo_raw}/${from}/VERSION" | tr -d '[:space:]')" ||
      die "cannot read the current version from ace-install (${from})${proxy:+ through the proxy}"
  fi
  [[ "$ACE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || die "ACE_VERSION must be a version such as 2.0.0, not ${ACE_VERSION}"
  if ((${ACE_VERSION%%.*} < 2)); then
    die "this installer installs 2.0.0 and later; ${ACE_VERSION} is a 1.x version, whose installer is: curl -fsSL ${repo_raw}/v1/install.sh | bash"
  fi
  ref="${ACE_INSTALL_REF:-v${ACE_VERSION}}"
}

# fetch_files downloads the stack and the ace command of the install's ref
# into $tmp, which also proves the ref has them.
fetch_files() {
  fetch compose.yml "$tmp/compose.yml"
  fetch ace "$tmp/ace"
}

# ask_tls reads how the panel gets its HTTPS certificate and, for custom,
# the owner's files, which it checks before anything changes.
ask_tls() {
  ask ACE_TLS "HTTPS certificate: acme (Let's Encrypt, renewed by Caddy) or custom (your own files)" acme
  case "$ACE_TLS" in
  acme)
    ask ACE_EMAIL "An email for Let's Encrypt's notices (optional)" "" optional
    [[ -z "$ACE_EMAIL" || "$ACE_EMAIL" =~ ^[^[:space:]@\"{}]+@[^[:space:]@\"{}]+$ ]] || die "${ACE_EMAIL} is not an email address"
    ;;
  custom)
    ACE_EMAIL=""
    ask ACE_TLS_CERT "The certificate file (PEM, with its chain)"
    ask ACE_TLS_KEY "Its private key file (PEM, without a passphrase)"
    bash "$tmp/ace" __check-cert "$ACE_TLS_CERT" "$ACE_TLS_KEY" "$ACE_DOMAIN" || exit 1
    ;;
  *) die "ACE_TLS must be acme or custom" ;;
  esac
}

# wait_healthy waits for the panel's API to answer its health check.
wait_healthy() {
  local id state
  for _ in $(seq 1 90); do
    id="$(docker compose -f "$dir/compose.yml" ps -q panel-api 2>/dev/null || true)"
    state="$(docker inspect -f '{{.State.Health.Status}}' "$id" 2>/dev/null || true)"
    [[ "$state" == healthy ]] && return 0
    sleep 2
  done
  return 1
}

# main runs the install. Wrapped in a function, the whole script is read before
# anything runs, so no command can read the rest of it from stdin (curl | bash).
main() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  check_options
  if [[ "${ACE_DRY_RUN:-}" == 1 ]]; then
    resolve_version
    fetch_files
    say "Dry run: would install the Ace panel ${ACE_VERSION} from ace-install ${ref}; nothing changed"
    printf 'version=%s\nref=%s\n' "$ACE_VERSION" "$ref"
    return 0
  fi

  check_server
  resolve_version
  say "Installing the Ace panel ${ACE_VERSION}"
  fetch_files

  ask ACE_DOMAIN "The panel's domain (its DNS points to this server)"
  [[ "$ACE_DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] ||
    die "${ACE_DOMAIN} is not a domain name"
  ask_tls
  ask ACE_GHCR_USER "GitHub user for the panel's images (GHCR)" kup1ng
  ask ACE_GHCR_TOKEN "GitHub token with read:packages" "" secret
  ask ACE_OWNER "The Owner's username" owner
  [[ "$ACE_OWNER" =~ ^[A-Za-z0-9._-]{3,32}$ ]] || die "the Owner's username must be 3-32 letters, digits, dots, dashes or underscores"

  ACE_PUBLIC_IP="$(public_ip)"
  [[ -n "$ACE_PUBLIC_IP" ]] || die "cannot tell this server's address; set ACE_DOMAIN to a domain that resolves"
  if ! ip -4 -o addr show | awk '{ print $4 }' | cut -d/ -f1 | grep -qx "$ACE_PUBLIC_IP"; then
    if [[ "$ACE_TLS" == acme ]]; then
      warn "${ACE_DOMAIN} resolves to ${ACE_PUBLIC_IP}, which is not on this server; fine behind NAT, else Let's Encrypt fails until the DNS points here"
    else
      warn "${ACE_DOMAIN} resolves to ${ACE_PUBLIC_IP}, which is not on this server; fine behind NAT"
    fi
  fi

  ensure_docker
  docker_proxy
  say "Signing in to GHCR as ${ACE_GHCR_USER}"
  printf '%s' "$ACE_GHCR_TOKEN" | docker login ghcr.io -u "$ACE_GHCR_USER" --password-stdin >/dev/null ||
    die "GHCR refused the token; it needs the read:packages scope"

  say "Writing the panel to ${dir}"
  install -d -m 755 "$dir" "$dir/tls"
  install -m 644 "$tmp/compose.yml" "$dir/compose.yml"
  install -m 755 "$tmp/ace" /usr/local/bin/ace
  make_secrets
  # Root's only: a proxy's URL may hold a password; ace fetches through it.
  (
    umask 077
    printf 'ACE_VERSION=%s\nACE_DOMAIN=%s\nACE_PUBLIC_IP=%s\nACE_TLS=%s\n' "$ACE_VERSION" "$ACE_DOMAIN" "$ACE_PUBLIC_IP" "$ACE_TLS" >"$dir/.env"
    if [[ -n "${ACE_EMAIL:-}" ]]; then printf 'ACE_EMAIL=%s\n' "$ACE_EMAIL" >>"$dir/.env"; fi
    if [[ -n "$proxy" ]]; then printf 'ACE_PROXY=%s\n' "$proxy" >>"$dir/.env"; fi
  )
  if [[ "$ACE_TLS" == custom ]]; then ace __tls-files "$ACE_TLS_CERT" "$ACE_TLS_KEY"; fi
  ace __caddyfile

  say "Pulling the panel's images"
  docker compose -f "$dir/compose.yml" pull </dev/null || die "cannot pull the panel's images (is the token right?)"
  say "Starting the panel"
  docker compose -f "$dir/compose.yml" up -d </dev/null || die "the panel did not start (see: ace logs)"
  wait_healthy || die "the panel did not become healthy in 3 minutes (see: ace logs panel-api)"

  local password
  password="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"
  printf '%s\n' "$password" | docker compose -f "$dir/compose.yml" exec -T panel-api ace-panel admin create-owner --username "$ACE_OWNER" >/dev/null ||
    die "creating the Owner failed (see: ace logs panel-api)"
  # Nodes pull the private agent image with the same read-only token, which
  # the panel seals with its master key.
  if printf '%s\n' "$ACE_GHCR_TOKEN" | docker compose -f "$dir/compose.yml" exec -T panel-api \
    ace-panel admin set-node-registry --server ghcr.io --username "$ACE_GHCR_USER" >/dev/null 2>&1; then
    say "Nodes pull the agent with the same GitHub token (Settings → Nodes)"
  else
    warn "the panel did not take the GitHub token for nodes; set it in Settings → Nodes before adding one"
  fi

  date -u +%Y-%m-%dT%H:%M:%SZ >"$dir/.installed"
  say "Done: the Ace panel ${ACE_VERSION} runs at https://${ACE_DOMAIN}"
  printf '\n    Owner:    %s\n    Password: %s\n\n' "$ACE_OWNER" "$password"
  say "The password is shown only now; change it in the panel after signing in"
  if [[ "$ACE_TLS" == custom ]]; then say "Your certificate expires $(openssl x509 -in "$dir/tls/cert.pem" -noout -enddate | cut -d= -f2); renew it with: ace certificate <cert.pem> <key.pem>"; fi
  say "Nodes accept their panel's address only: on a node that moves to this panel, run ace-node panel-ip ${ACE_PUBLIC_IP}"
  say "On this server: ace status, ace logs, ace upgrade <version>"
}

[[ "${BASH_SOURCE[0]:-$0}" != "$0" ]] || main "$@" # sourced (test/install.sh): functions only
