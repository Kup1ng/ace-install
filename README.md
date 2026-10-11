# ace-install

The installer of the **Ace** panel (CS2 hosting) and its `ace` command. This repository holds scripts only: no code and no secrets. The panel's images are private on GHCR, so an install needs a GitHub token that may read them.

## Install

On a fresh server running **Ubuntu 24.04 or 22.04** (x86_64), as root:

```bash
curl -fsSL https://raw.githubusercontent.com/Kup1ng/ace-install/main/install.sh | bash
```

Before you start:

- a domain whose DNS (an A record) points to the server, for the panel's address and its Let's Encrypt certificate;
- ports 80 and 443 open to everyone, and 3306 to the nodes (the panel keeps MySQL to its nodes' addresses itself);
- a GitHub token with the `read:packages` scope for the panel's images.

The installer:

1. checks the server: Ubuntu 22.04 or 24.04, root, nftables; it warns when memory, disk or the clock look wrong;
2. asks for the domain, an email for Let's Encrypt (optional), the GitHub user and token, and the Owner's username;
3. installs Docker Engine from Docker's repository when it is missing or older than 25 (replacing Ubuntu's `docker.io`);
4. writes the panel to `/opt/ace` and makes its secrets there (the master key and the database passwords), on the server only;
5. starts the panel with an HTTPS certificate, then creates the Owner with a generated password, **shown once** at the end;
6. gives the panel the same GitHub user and token for its nodes (Settings → Nodes), so they can pull the private agent image.

### Options

Set them before `bash`, e.g. `... | ACE_VERSION=1.0.0 bash`.

| Variable | Use |
|---|---|
| `ACE_VERSION` | The version to install; by default the one in [`VERSION`](VERSION). |
| `ACE_DOMAIN`, `ACE_EMAIL`, `ACE_GHCR_USER`, `ACE_GHCR_TOKEN`, `ACE_OWNER` | The answers, so the install asks nothing. |
| `ACE_PROXY` | An `http://` or `socks5://` proxy for apt and Docker on a server that cannot reach them directly. Docker keeps pulling through it (upgrades too). |
| `ACE_APT_MIRROR` | A mirror of the Ubuntu archive, e.g. `http://mirror.arvancloud.ir/ubuntu`, for this install only; the server's own sources stay. |
| `ACE_ANY_OS=1` | Try a system other than Ubuntu 22.04/24.04. Unsupported. |
| `ACE_INSTALL_REF` | Take this repository's files from another branch or tag (for testing). |

An install that stopped half-way can run again: it keeps the secrets it already made.

## After the install

- Sign in at `https://<domain>` as the Owner, and change the password.
- Add game servers' machines on **Nodes → Add node**: the panel shows the command to run on each.
- **Moving a panel to this server:** restore its backup on the **Backups** page. The nodes accept their panel's address only, so run `ace-node panel-ip <this server's address>` on every node.

## The `ace` command

| Command | Does |
|---|---|
| `ace status` | The panel's containers and its version |
| `ace logs [service...]` | Follow the logs, e.g. `ace logs panel-api` |
| `ace version` | The installed version |
| `ace restart [service]` | Restart the panel, or one service |
| `ace upgrade <version>` | Back up both databases to `/opt/ace/backups` (the last 3 stay), move the panel to `<version>`, and go back by itself if it is not healthy within 3 minutes |
| `ace rollback` | Go back to the version before the last upgrade. The data stays as it is: the panel's migrations only expand the schema until a later version contracts it |

An upgrade runs the target version's own `ace` from this repository's tag, so each version brings the steps it needs. Nothing changes before its files and images are downloaded, and the backup is made before the switch.

## Files

| Path | Holds |
|---|---|
| `/opt/ace/compose.yml` | The stack: PostgreSQL, MySQL, the panel's API and web app, Caddy, and `ace-fw` (MySQL's firewall) |
| `/opt/ace/.env` | The version, the domain and the address nodes reach MySQL at |
| `/opt/ace/Caddyfile` | HTTPS for the domain |
| `/opt/ace/secrets/` | The master key and database passwords (mode 700; never shown) |
| `/opt/ace/backups/` | The databases as they were before each of the last 3 upgrades (root only, no password) |
| `/opt/ace/rollback/` | The files of the version before the last upgrade, for `ace rollback` |

Every image comes from GHCR with the panel's version, PostgreSQL, MySQL and Caddy included: each release copies them there, so one version is one known set of images.

## Versions

[`VERSION`](VERSION) names the current release. The tag `v<version>` of this repository holds the files of that version, which the installer takes.
