# scripts

Maintainers' tools for releasing this repository. Nothing here runs on a panel's server.

| Script | Does |
|---|---|
| [`pin-release.sh`](pin-release.sh) | `scripts/pin-release.sh <version>` pins `compose.yml`'s four images to the digests the panel's GitHub release `v<version>` records, after checking each against GHCR, and sets `VERSION`; `--check <version>` checks the files without writing; `--help` explains it. Run it on the release machine (with `gh` signed in and Docker logged in to `ghcr.io`), as the [README](../README.md#releasing-maintainers) describes. Its test is [`test/pin-release.sh`](../test/pin-release.sh). |
