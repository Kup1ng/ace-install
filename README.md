# ace-install

The installer of the **Ace** panel (CS2 hosting) and its `ace` command, for **Ace 2.x**. This repository holds scripts only: no code and no secrets. The panel's images are private on GHCR, so an install needs a GitHub token that may read them.

> **v2 starts on a fresh install.** Nothing carries over from 1.x: v2 has a new database and no MySQL. This installer refuses a server that runs a 1.x panel, and `ace upgrade` never moves a 1.x panel to 2.x (nor a 2.x panel back to 1.x). The 1.x line keeps its own installer on the [`v1`](https://github.com/Kup1ng/ace-install/tree/v1) branch: `curl -fsSL https://raw.githubusercontent.com/Kup1ng/ace-install/v1/install.sh | bash`.

## Install

On a fresh server running **Ubuntu 24.04 or 22.04** (x86_64), as root:

```bash
curl -fsSL https://raw.githubusercontent.com/Kup1ng/ace-install/main/install.sh | bash
```

Before you start:

- a domain whose DNS (an A record) points to the server, for the panel's address;
- ports 80 and 443 open to everyone;
- a GitHub token with the `read:packages` scope for the panel's images;
- for your own certificate (`ACE_TLS=custom`): its PEM file with the chain, and its key without a passphrase.

The installer:

1. checks the server: Ubuntu 22.04 or 24.04, root, no panel on it already; it warns when memory, disk or the clock look wrong;
2. asks for the domain, how the panel gets its HTTPS certificate (below), the GitHub user and token, and the Owner's username;
3. installs Docker Engine from Docker's repository when it is missing or older than 25 (replacing Ubuntu's `docker.io`);
4. writes the panel to `/opt/ace` and makes its secrets there (the master key and the database password), on the server only;
5. starts the panel behind Caddy with HTTPS, then creates the Owner with a generated password, **shown once** at the end;
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
| `ACE_DOMAIN`, `ACE_GHCR_USER`, `ACE_GHCR_TOKEN`, `ACE_OWNER` | The answers, so the install asks nothing. |
| `ACE_TLS`, `ACE_EMAIL` | `acme` or `custom` (above); for `acme`, an optional email for Let's Encrypt's notices. |
| `ACE_TLS_CERT`, `ACE_TLS_KEY` | For `custom`: the certificate (with its chain) and its key, as PEM files. They are copied to `/opt/ace/tls`. |
| `ACE_PROXY` | An `http://` or `socks5://` proxy for apt and Docker on a server that cannot reach them directly. Docker keeps pulling through it (upgrades too). |
| `ACE_APT_MIRROR` | A mirror of the Ubuntu archive, e.g. `http://mirror.arvancloud.ir/ubuntu`, for this install only; the server's own sources stay. |
| `ACE_ANY_OS=1` | Try a system other than Ubuntu 22.04/24.04. Unsupported. |
| `ACE_INSTALL_REF` | Take this repository's files (and the default version) from another branch or tag, e.g. `m15-install-v2` before 2.0.0 is released. |
| `ACE_DRY_RUN=1` | Only resolve the version and check that this repository has its files at the ref; nothing changes, no root needed. It prints `version=` and `ref=`. |

An install that stopped half-way can run again: it keeps the secrets it already made.

## After the install

- Sign in at `https://<domain>` as the Owner, and change the password.
- Add game servers' machines on **Nodes → Add node**: the panel shows the command to run on each.
- A node accepts its panel's address only: a node that moves to this panel runs `ace-node panel-ip <this server's address>`.

## The `ace` command

| Command | Does |
|---|---|
| `ace status` | The panel's containers, its version, address and HTTPS mode |
| `ace logs [service...]` | Follow the logs, e.g. `ace logs panel-api` |
| `ace version` | The installed version |
| `ace restart [service]` | Restart the panel, or one service |
| `ace apply` | Apply a change to `/opt/ace/.env`: writes the Caddyfile again and recreates only the services whose settings changed (Caddy when its Caddyfile did) |
| `ace certificate <cert.pem> <key.pem>` | Use your own certificate, or renew it: checks it (the key matches, it names the domain, it has not expired; a warning within 21 days), copies it to `/opt/ace/tls`, sets `ACE_TLS=custom` and restarts Caddy. Back to Let's Encrypt: set `ACE_TLS=acme` in `.env` and run `ace apply` |
| `ace upgrade <version>` | Back up the database to `/opt/ace/backups` (the last 3 stay), move the panel to `<version>`, and go back by itself if it is not healthy within 3 minutes |
| `ace rollback` | Go back to the version before the last upgrade. The data stays as it is: the panel's migrations only expand the schema until a later version contracts it |

An upgrade runs the target version's own `ace` from this repository's tag, so each version brings the steps it needs, its Caddyfile included. Nothing changes before its files and images are downloaded, and the backup is made before the switch. A 1.x panel is refused with nothing changed: v2 starts on a fresh install.

## Files

| Path | Holds |
|---|---|
| `/opt/ace/compose.yml` | The stack: PostgreSQL, the panel's API and web app, and Caddy |
| `/opt/ace/.env` | The version, the domain, the server's address, `ACE_TLS` and the optional settings (below) |
| `/opt/ace/Caddyfile` | Written by `ace` from `.env`, never by hand: one origin for the web app and the API; HSTS, `X-Content-Type-Options: nosniff`, `Referrer-Policy: same-origin` and `Permissions-Policy` on every answer, and `Content-Security-Policy: default-src 'none'; frame-ancestors 'none'` on `/api` (pages get theirs from the web app, with a per-request nonce); an upload that stalls gets 5 minutes (`read_body_idle`) |
| `/opt/ace/tls/` | Your certificate for `ACE_TLS=custom`: `cert.pem` and `key.pem` (root only), mounted read-only into Caddy; empty for `acme` |
| `/opt/ace/secrets/` | The master key and the database password (mode 700; never shown) |
| `/opt/ace/backups/` | The database as it was before each of the last 3 upgrades (root only, no password) |
| `/opt/ace/rollback/` | The files of the version before the last upgrade (`compose.yml`, `.env`, `Caddyfile`, `ace`), for `ace rollback` |

Every image comes from GHCR with the panel's version, PostgreSQL and Caddy included: each release copies them there, so one version is one known set of images.

The panel reads the certificate Caddy serves with a TLS handshake to `caddy:443` on the stack's network (`ACE_PANEL_TLS_CHECK_ADDR`, `ACE_PANEL_TLS_DOMAIN`, `ACE_PANEL_TLS_MODE` in `compose.yml`): Caddy's admin API lists no certificates, and its Let's Encrypt files are root-only next to their keys.

Optional settings in `/opt/ace/.env`; after a change run `ace apply`:

| Setting | Default | What it does |
|---|---|---|
| `ACE_HSTS_MAX_AGE` | `86400` (1 day) | HSTS's `max-age` in seconds, without `preload`. Raise it once the certificate plan is settled. |
| `ACE_EMAIL` | none | For `ACE_TLS=acme`: the email Let's Encrypt sends its notices to. |
| `ACE_TLS` | `acme` | `acme` or `custom`; switch to `custom` with `ace certificate`. |
| `ACE_PROXY` | none | The proxy `ace` downloads this repository's files through (the installer's `ACE_PROXY`). |

## Versions

[`VERSION`](VERSION) names the current release. The tag `v<version>` of this repository holds the files of that version, which the installer and `ace upgrade` take. Until 2.0.0 is released, `main` stays the 1.x installer and v2 lives on the branch `m15-install-v2` (`ACE_INSTALL_REF=m15-install-v2`), whose `VERSION` is the first 2.x release it installs (`2.0.0-rc.1`; set `ACE_VERSION` for another).

## Checks

CI runs shellcheck and `bash -n` on the scripts, `docker compose config` on the stack, and two tests:

- [`test/install.sh`](test/install.sh) runs `install.sh` with `ACE_DRY_RUN=1` against a stub `curl`: an explicit version, the `VERSION` of `main` and of a branch, prereleases, the refusal of 1.x and malformed versions, a version without a tag, and bad options. It changes nothing and needs no root: `bash test/install.sh`.
- [`test/ace.sh`](test/ace.sh) runs `ace` against stub `docker` and `curl`: the Caddyfile (headers, HSTS, TLS), a good upgrade, a rollback, an upgrade that goes back by itself, the refusals (a 1.x target, a 1.x panel), the last 3 backups, `ace apply`, `ace certificate`, and no temporary file left. It writes `/opt/ace`, so it runs in CI or a throwaway container only:

```bash
docker run --rm -v "$PWD:/src:ro" ubuntu:24.04 bash -c 'apt-get update -qq && apt-get install -y -qq openssl >/dev/null && bash /src/test/ace.sh'
```
