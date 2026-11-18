# ace-install

The installer of the **Ace** panel (CS2 hosting) and its `ace` command, for **Ace 2.x**. This repository holds scripts only: no code and no secrets. The panel's images are private on GHCR, so an install needs a GitHub token that may read them.

> **v2 starts on a fresh install.** Nothing carries over from 1.x: v2 has a new database and no MySQL. This installer refuses a server that runs a 1.x panel, and `ace upgrade` never moves a 1.x panel to 2.x (nor a 2.x panel back to 1.x). The 1.x line keeps its own installer on the [`v1`](https://github.com/Kup1ng/ace-install/tree/v1) branch: `curl -fsSL https://raw.githubusercontent.com/Kup1ng/ace-install/v1/install.sh | bash`.

## Install

On a fresh server running **Ubuntu 24.04 or 22.04** (x86_64), as root:

```bash
curl -fsSL https://raw.githubusercontent.com/Kup1ng/ace-install/main/install.sh | bash
```

Until 2.0.0 is released, `main` still installs 1.x. To install a 2.x release candidate, use the command under [Versions](#versions).

Before you start:

- a domain whose DNS (an A record) points to the server, for the panel's address; an AAAA record as well when the server has IPv6 (under [The stack's network](#the-stacks-network));
- ports 80 and 443 open to everyone;
- a GitHub token with the `read:packages` scope only, for the panel's images (it stays on the server: under [Files](#files));
- for your own certificate (`ACE_TLS=custom`): its PEM file with the chain, and its key without a passphrase.

The installer:

1. checks the server: Ubuntu 22.04 or 24.04, root, no panel on it already; it warns when memory, disk or the clock look wrong;
2. asks for the domain, how the panel gets its HTTPS certificate (below), the GitHub user and token (without showing what you type), and the Owner's username;
3. installs Docker Engine from Docker's repository when it is missing or older than 25 (replacing Ubuntu's `docker.io`);
4. writes the panel to `/opt/ace` and makes its secrets there (the master key and the database password), on the server only;
5. checks whether the server can give the panel's network IPv6 (`ACE_IPV6`, under [The stack's network](#the-stacks-network)), starts the panel behind Caddy with HTTPS, then creates the Owner with a generated password, **shown once** at the end;
6. gives the panel the same GitHub user and token for its nodes, sealed with the panel's master key (Settings → Nodes), so they can pull the private agent image.

### HTTPS: `ACE_TLS`

| `ACE_TLS` | Certificate | Renewal |
|---|---|---|
| `acme` (default) | Caddy gets one from Let's Encrypt for the domain | Caddy renews it by itself, a month before it expires. Let's Encrypt is abroad: on the national network a renewal can fail for days |
| `custom` | Your own, e.g. from an Iranian CA or a long-lived one: `ACE_TLS_CERT` (PEM, with its chain) and `ACE_TLS_KEY` (its key); the installer checks that the key belongs to it, that it names the domain and has not expired | You renew it: `ace certificate <cert.pem> <key.pem>` |

Either way the panel watches the certificate Caddy serves: the **Overview** warns 21 days before it expires, and when Caddy has not renewed a Let's Encrypt certificate in time. HTTPS answers carry HSTS with a low max-age (1 day) and no `preload`, so an expired certificate during a long cut never locks browsers out for good; raise it with `ACE_HSTS_MAX_AGE` once the certificate plan is settled.

### Options

Set them before `bash`, e.g. `... | ACE_TLS=custom ACE_TLS_CERT=/root/panel.pem ACE_TLS_KEY=/root/panel.key bash`.

| Variable | Use |
|---|---|
| `ACE_VERSION` | The version to install, 2.0.0 or later (its prereleases too); by default the one in [`VERSION`](VERSION) of `ACE_INSTALL_REF`, else of `main`. |
| `ACE_DOMAIN`, `ACE_GHCR_USER`, `ACE_OWNER` | Answers, so the install does not ask for them. The GitHub token is not one of these: let the installer ask for it, since a token typed before `bash` stays in the shell's history. |
| `ACE_TLS`, `ACE_EMAIL` | `acme` or `custom` (above); for `acme`, an optional email for Let's Encrypt's notices. |
| `ACE_TLS_CERT`, `ACE_TLS_KEY` | For `custom`: the certificate (with its chain) and its key, as PEM files. They are copied to `/opt/ace/tls`. |
| `ACE_PROXY` | An `http://` or `socks5://` proxy for apt and Docker on a server that cannot reach them directly. Docker keeps pulling through it (upgrades too). Its URL may hold a password, so other users of the server never see it: curl gets it in its environment and apt in a root-only file, never on a command line, and Docker reads it from a root-only `EnvironmentFile` (below), not from its unit's `Environment=`, which `systemctl show docker` shows everyone. |
| `ACE_APT_MIRROR` | A mirror of the Ubuntu archive, e.g. `http://mirror.arvancloud.ir/ubuntu`, for this install only; the server's own sources stay. |
| `ACE_ANY_OS=1` | Try a system other than Ubuntu 22.04/24.04. Unsupported. |
| `ACE_INSTALL_REF` | Take this repository's files (and the default version) from another branch or tag instead of the version's tag `v<version>`, for development. A release (`x.y.z`, `x.y.z-rc.N`) installs from its own tag: leave this out (the command under [Versions](#versions)). |
| `ACE_DRY_RUN=1` | Only resolve the version, check that this repository has its files at the ref, and check the stack's images (under [Files](#files)); nothing changes, no root needed. It prints `version=`, `ref=` and `stack=` (`pinned` or `unpinned`). |

An install that stopped half-way can run again: it keeps the secrets it already made. If it stopped after the panel's containers started (while it waited for the panel or created the Owner), stop them first, or the installer finds a panel running and refuses:

```bash
docker compose -f /opt/ace/compose.yml down
```

This keeps the database and the other volumes; then run the install command again.

## After the install

- Sign in at `https://<domain>` as the Owner, and change the password.
- Add game servers' machines on **Nodes → New Node**: the panel shows the command to run on each.
- A node accepts its panel's address only: a node that moves to this panel runs `ace-node panel-ip <this server's address>`.

## The `ace` command

| Command | Does |
|---|---|
| `ace status` | The panel's containers, its version, address and HTTPS mode |
| `ace logs [service...]` | Follow the logs, e.g. `ace logs panel-api` |
| `ace version` | The installed version |
| `ace restart [service]` | Restart the panel, or one service |
| `ace apply` | Apply a change to `/opt/ace/.env`: writes the Caddyfile again and recreates only the services whose settings changed (Caddy when its Caddyfile did); a change to `ACE_IPV6` makes the network again, so the whole panel stops and starts |
| `ace certificate <cert.pem> <key.pem>` | Use your own certificate, or renew it: checks it (the key matches, it names the domain, it has not expired; a warning within 21 days), copies it to `/opt/ace/tls`, sets `ACE_TLS=custom` and restarts Caddy. Back to Let's Encrypt: set `ACE_TLS=acme` in `.env` and run `ace apply` |
| `ace upgrade <version>` | Back up the database to `/opt/ace/backups` (the last 3 stay), move the panel to `<version>`, and go back by itself if it is not healthy within 3 minutes |
| `ace rollback` | Go back to the version before the last upgrade. The data stays as it is: the panel's migrations only expand the schema until a later version contracts it |

An upgrade runs the target version's own `ace` from this repository's tag, so each version brings the steps it needs, its Caddyfile included. Nothing changes before its files are downloaded, its stack's images checked (under [Files](#files)) and pulled, and the backup is made before the switch. A 1.x panel is refused with nothing changed: v2 starts on a fresh install. When the switch changes the network's IPv6 (the first upgrade to 2.0.0-rc.3 or later on a server with IPv6, and every way back from it), the stack goes down and up once for it; going back, by hand or by itself, takes the network back as the older version had it (under [The stack's network](#the-stacks-network)).

## Files

| Path | Holds |
|---|---|
| `/opt/ace/compose.yml` | The stack: PostgreSQL, the panel's API and web app, and Caddy |
| `/opt/ace/.env` | The version, the domain, the server's address, `ACE_TLS`, `ACE_IPV6` and the optional settings (below) |
| `/opt/ace/Caddyfile` | Written by `ace` from `.env`, never by hand: one origin for the web app and the API; HSTS, `X-Content-Type-Options: nosniff`, `Referrer-Policy: same-origin` and `Permissions-Policy` on every answer, and `Content-Security-Policy: default-src 'none'; frame-ancestors 'none'` on `/api` (pages get theirs from the web app, with a per-request nonce); an upload that stalls gets 5 minutes (`read_body_idle`) |
| `/opt/ace/tls/` | Your certificate for `ACE_TLS=custom`: `cert.pem` and `key.pem` (root only), mounted read-only into Caddy; empty for `acme` |
| `/opt/ace/secrets/` | The master key and the database password (mode 700; never shown) |
| `/root/.docker/config.json` | The GitHub token: the installer signs Docker in to `ghcr.io` with it (`docker login`), and Docker keeps it there unencrypted, as it warns when it signs in, in root's home, so only root reads it. `ace upgrade` pulls the next version's images with it. To replace the token: `docker login ghcr.io -u <user>` (it asks for the token), and the new one in **Settings → Nodes** for the nodes; the panel keeps that copy sealed with its master key |
| `/opt/ace/backups/` | The database as it was before each of the last 3 upgrades (root only, no password) |
| `/opt/ace/rollback/` | The files of the version before the last upgrade (`compose.yml`, `.env`, `Caddyfile`, `ace`), for `ace rollback` |
| `/etc/systemd/system/docker.service.d/ace-proxy.conf` | With `ACE_PROXY`: the drop-in that points Docker at `ace-proxy.env` next to it, which holds the proxy (root only). An install with `ACE_PROXY` rewrites both, so a drop-in with the proxy in `Environment=` (as 1.x wrote it) goes away |

Every image comes from GHCR with the panel's version, PostgreSQL and Caddy included: each release copies them there, so one version is one known set of images. From the first release candidate (2.0.0-rc.1) on, the stack pins each image by the digest its release records, not only by its tag (`ghcr.io/kup1ng/<name>:<version>@sha256:<digest>`), so a tag that moves later cannot change an installed version. The development versions before it pull by tag.

The installer and `ace upgrade` check the stack they download before they change anything: every image must be one of Ace's own on GHCR and name the version being installed, and a release's (`x.y.z` or `x.y.z-rc.N`) must be pinned by digest; only a development prerelease (e.g. `2.1.0-alpha.1`) may pull by tag. Otherwise they stop with one line that says what to do, for example to take the version's own tag rather than a branch's files (`ACE_INSTALL_REF`).

The panel reads the certificate Caddy serves with a TLS handshake to `caddy:443` on the stack's network (`ACE_PANEL_TLS_CHECK_ADDR`, `ACE_PANEL_TLS_DOMAIN`, `ACE_PANEL_TLS_MODE` in `compose.yml`): Caddy's admin API lists no certificates, and its Let's Encrypt files are root-only next to their keys.

The web app asks the API for the panel's default language from the server side (the sign-in page). `compose.yml` gives it the API's address, `ACE_API_ORIGIN=http://panel-api:8080`, and `NO_PROXY=panel-api`, so the request never goes through a proxy variable; without them the sign-in page silently falls back to Persian.

Optional settings in `/opt/ace/.env`; after a change run `ace apply`:

| Setting | Default | What it does |
|---|---|---|
| `ACE_HSTS_MAX_AGE` | `86400` (1 day) | HSTS's `max-age` in seconds, without `preload`. Raise it once the certificate plan is settled. |
| `ACE_EMAIL` | none | For `ACE_TLS=acme`: the email Let's Encrypt sends its notices to. |
| `ACE_TLS` | `acme` | `acme` or `custom`; switch to `custom` with `ace certificate`. |
| `ACE_PROXY` | none | The proxy `ace` downloads this repository's files through (the installer's `ACE_PROXY`), handed to curl in its environment, never on its command line. |
| `ACE_IPV6` | set by the installer and `ace upgrade` | `true`: the stack's network has IPv6; `false`: IPv4 only. `false` stays until you change it; `true` is checked again by every `ace apply` and `ace upgrade` (below). |

### The stack's network

The four services share one network, `ace_default`. Docker publishes Caddy's ports 80 and 443 on IPv4 and IPv6. An IPv4 client reaches Caddy through Docker's NAT, with its own address. An IPv6 client reaches it through Docker's NAT too only when the network itself has IPv6; on a network without IPv6, Docker's proxy (`docker-proxy`) carries the connection over IPv4, and Caddy and the panel see the network's gateway instead of the client. Every IPv6 client would then share one sign-in rate limit and one address in the audit log. So the network has IPv6 (`enable_ipv6: ${ACE_IPV6:-false}` in `compose.yml`) wherever the server can give it:

- **When.** The installer and `ace upgrade` set `ACE_IPV6=true` only when all of these hold: the kernel has IPv6 on (`net.ipv6.conf.all.disable_ipv6` is 0; a kernel booted with `ipv6.disable=1` has no such setting and no `/proc/net/if_inet6`); Docker is 27 or later (from 27, `ip6tables` is on by default, so Docker NATs IPv6 as it does IPv4, and it gives IPv6 subnets from its own pool); and Docker creates an IPv6 network (`ace-ipv6-check`, removed at once). Otherwise they set `ACE_IPV6=false`, warn, and the network stays IPv4 only, as it was before 2.0.0-rc.3: nothing else changes. `ace apply` runs the same check when `ACE_IPV6=true`, so the network never asks for IPv6 that the server cannot give.
- **Its subnet.** Docker picks the IPv6 subnet itself: a `/64` from a ULA `/48` that it derives from the engine's ID. No prefix is written in `compose.yml`, so it cannot collide with another network on the server or with a VPN's prefix. A collision would surface only when Compose makes the network, after it has removed the old one. The subnet may change when the network is made again; nothing depends on it.
- **Making it again.** Docker cannot switch a network's IPv6 in place. Compose (checked with 2.40.3, the version on our servers, and 5.6.1) makes the network again when the stack's config of it changed, but it keeps a network that an older Compose made (one without its `com.docker.compose.config-hash` label) as it is, IPv4 only. So `ace` compares the network's IPv6 with the stack's (`docker compose config`) before it starts the stack. When they differ, it stops the stack first with `docker compose down`: the containers and the network go, and the volumes (the database, the panel's data, Caddy's certificates) stay. This happens in `ace upgrade`, in `ace rollback`, in the upgrade that goes back by itself, and in `ace apply`. The panel stops for as long as its containers take to start.
- **Turning it off or on.** Set `ACE_IPV6=false` in `/opt/ace/.env` and run `ace apply`. To turn it on again, set `ACE_IPV6=true` and run `ace apply`; the check sets it back to `false`, with a warning, when the server cannot give IPv6.
- **Checking it.** `docker network inspect ace_default --format '{{.EnableIPv6}}'` prints `true`, and the API's log (`ace logs panel-api`) shows an IPv6 client's request with that client's own address.

## Versions

[`VERSION`](VERSION) names the current release. The tag `v<version>` of this repository holds the files of that version, which the installer and `ace upgrade` take. Until 2.0.0 is released, `main` stays the 1.x installer and v2 lives on the branch `m15-install-v2`, whose `VERSION` is the 2.x release it is working towards (`2.0.0-rc.1` first). To install a release candidate, take `install.sh` from that branch, since `main`'s is the 1.x installer, and name the release candidate; the installer then takes its files from the tag `v2.0.0-rc.N`:

```bash
curl -fsSL https://raw.githubusercontent.com/Kup1ng/ace-install/m15-install-v2/install.sh | ACE_VERSION=2.0.0-rc.N bash
```

Replace `N` with the release candidate's number; this works for every release candidate that has its tag. Do not add `ACE_INSTALL_REF=m15-install-v2`: a branch's `compose.yml` pulls by tag until a release pins it, and then holds that release's pins only, so the installer refuses a release candidate from the branch's files unless the branch's latest pin is that one. `ACE_INSTALL_REF` is for development branches.

## Checks

CI runs shellcheck and `bash -n` on the scripts, checks that every action in [`.github/workflows`](.github/workflows) is pinned by its full commit SHA with its version in a comment (`uses: actions/checkout@<40-hex sha> # v7.0.1`; a tag can move, a commit cannot: to update one, take the new tag's commit with `gh api repos/<owner>/<action>/git/ref/tags/<tag>`, dereferencing an annotated tag), `docker compose config` on the stack, [`test/compose.sh`](test/compose.sh) (the four `image:` lines of `compose.yml` are all unpinned, or all pinned to `VERSION` by a 64-hex digest, and name exactly the images Docker resolves from it with every profile, `docker compose config --images`, so an image the installer's line check cannot see, e.g. in YAML flow style, fails; and the network: the project is named `ace`, no service picks a network of its own, and the default network is exactly `enable_ipv6: ${ACE_IPV6:-false}` with no fixed subnet), that Docker resolves one network whose IPv6 follows `ACE_IPV6` (`false` when unset, `true` and `false` as set, and refusing a value that is neither), and four tests:

- [`test/install.sh`](test/install.sh) runs `install.sh` with `ACE_DRY_RUN=1` against a stub `curl`: an explicit version, the `VERSION` of `main` and of a branch, prereleases, the refusal of 1.x and malformed versions, a version without a tag, the stack's images (pinned to the version for a release, by tag for a development prerelease only, another version's, not Ace's own), bad options, that it runs when piped into `bash` (as the install command runs it), that `ACE_PROXY` reaches curl in its environment, never on its command line, and that the install settles `ACE_IPV6` (`ace __ipv6`) after writing `.env` and before it pulls and starts the stack. It also sources `install.sh` (which then only defines its functions) to check that apt gets the proxy from a root-only file and that Docker's goes into a root-only `EnvironmentFile`, never into its unit (an old drop-in with `Environment=` and a loose file included; a loose file that already holds the same proxy is made root's only again), against a stub `systemctl`. It changes nothing and needs no root: `bash test/install.sh`.
- [`test/ace.sh`](test/ace.sh) runs `ace` against stub `docker` and `curl`: panel-web's settings in `compose.yml` (`ACE_API_ORIGIN`, `NO_PROXY`), the Caddyfile (headers, HSTS, TLS), a good upgrade, a rollback, an upgrade that goes back by itself, the refusals (a 1.x target, a 1.x panel, a release's stack that pulls by tag or is another version's; a development prerelease may pull by tag), the last 3 backups, `ace apply`, `ace certificate`, `ACE_PROXY` kept off curl's command line, and no temporary file left.
- [`test/ace-ipv6.sh`](test/ace-ipv6.sh) runs `ace` against the same stubs (and a stub `sysctl`) for the stack's network: the installer's `ace __ipv6`; an upgrade from a stack without IPv6 (as 2.0.0-rc.2 runs it) that makes the network again with IPv6, even when Compose would keep the old one; a rollback by hand and an upgrade that goes back by itself, which both take the network back; no restart when nothing changed; `ACE_IPV6=false`, which stays; turning it on again; the fallbacks (a kernel booted without IPv6 or with IPv6 off, Docker older than 27, Docker that cannot make an IPv6 network); a check's network left behind; a bad value, which changes nothing; and a Compose that cannot print its config.

Both share their stubs and helpers, [`test/ace-stubs.sh`](test/ace-stubs.sh). They write `/opt/ace`, so they run in CI or a throwaway container only, each in its own:

```bash
docker run --rm -v "$PWD:/src:ro" ubuntu:24.04 bash -c 'apt-get update -qq && apt-get install -y -qq openssl >/dev/null && bash /src/test/ace.sh'
docker run --rm -v "$PWD:/src:ro" ubuntu:24.04 bash /src/test/ace-ipv6.sh
```

- [`test/pin-release.sh`](test/pin-release.sh) runs `scripts/pin-release.sh` in a scratch copy against stub `gh` and `docker`: a release that does not exist yet, a draft, a digest the notes lack or give twice, a tag that moved on GHCR or is missing there, retried network drops, the pin itself (only the four image lines and `VERSION` change), running it again, `--check`, the next release candidate, and `test/compose.sh` on pinned, unpinned and broken stacks (their images, and their network: a service on a network of its own, a fixed subnet, IPv6 not from `ACE_IPV6`, no network block, a project not named `ace`) and against lists of the images Docker resolves (the same four, one more, one fewer). No root, no network: `bash test/pin-release.sh`.

## Releasing (maintainers)

This repository is tagged for release candidates and final releases only, on the branch that serves v2 (`m15-install-v2` until 2.0.0, then `main`). On the release machine, with `gh` signed in and Docker logged in to `ghcr.io`:

1. Release the panel (Ace-Panel) `<version>` first, with its `scripts/release.sh`: its GitHub release records each image's digest in its notes, as `ghcr.io/kup1ng/<name>@sha256:<digest>`.
2. Run [`scripts/pin-release.sh <version>`](scripts/pin-release.sh). It reads those digests, refuses a draft release, a missing or doubled digest and a tag that moved on GHCR since, and writes `compose.yml`'s four images as `ghcr.io/kup1ng/<name>:<version>@sha256:<digest>` and `VERSION` = `<version>`. Running it again changes nothing; `scripts/pin-release.sh --check <version>` checks the files without writing.
3. Commit `compose.yml` and `VERSION` as `chore: <version>`, and push.
4. Wait for CI on that push (CI runs on every push to `m15-install-v2` and `main`): `gh run list --repo Kup1ng/ace-install --branch m15-install-v2 --commit "$(git rev-parse HEAD)" --event push --limit 1` (`main` from 2.0.0 on; the commit filter finds that push's own run, not the previous one, which may still be the newest for a few seconds), then `gh run watch <id> --repo Kup1ng/ace-install --exit-status`; it must pass.
5. Tag that commit and push the tag: `git tag -a v<version> -m v<version>`, then `git push origin refs/tags/v<version>`.
