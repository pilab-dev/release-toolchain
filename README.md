# PiLAB release toolchain

One standard release flow for every Go project in the PiLAB orgs, so releases
stop drifting apart:

```
tag vX.Y.Z  →  GoReleaser (deb + rpm + tar.gz + checksums)
            →  GitHub release
            →  publish to https://dl.pilab.hu (testing tier)
            →  verify hashes over HTTPS + install test in a container
```

The repository is **public** because GitHub only allows cross-*organization*
workflow reuse from public repositories. Everything host-specific (builder
host, user, port, deploy key) is passed in as secrets, so nothing internal is
in the YAML.

## Workflows

### `release.yml` — build, release, publish

Add this to a product repository (`.github/workflows/release.yml`):

```yaml
name: Release
on:
  push:
    tags: ['v*']

jobs:
  release:
    uses: pilab-dev/release-toolchain/.github/workflows/release.yml@v1
    with:
      description: 'WireGuard mesh manager'
      ldflags-package: main
    secrets: inherit
```

What happens:

| step | detail |
|---|---|
| config | if the repo has no `.goreleaser.yaml`, the shared template in [`templates/goreleaser.yaml`](templates/goreleaser.yaml) is rendered, so new projects package identically |
| build | GoReleaser v2, `CGO_ENABLED=0`, linux/amd64+arm64+386 |
| packages | `nFPM` produces `name_version_arch.deb` and `name-version-linux-arch.rpm` |
| release | assets land on the GitHub release |
| publish | `sync-dl.yml` uploads them to the builder and waits for the result |
| test | hashes verified over HTTPS, then a real `apt` and `dnf` install |

Inputs (all optional except `description` in practice):

| input | default | meaning |
|---|---|---|
| `binary` | repo name | binary and archive name |
| `package` | `binary` | deb/rpm package name |
| `main` | `.` | main package path |
| `description` | repo description | package description |
| `ldflags-package` | `main` | where `version`/`commit`/`date` live; `none` to skip |
| `arches` | `amd64 arm64 386` | GOARCH list |
| `config` | *(auto)* | `standard` = render the template, `repo` = use the repo's own `.goreleaser.yaml` |
| `tier` | `testing` | `testing` or `stable` |
| `sync` | `true` | publish to dl.pilab.hu |
| `install-test` | `true` | install from the published repo in a container |
| `install-package` | `package` | package to install when the name differs |
| `toolchain-ref` | `v1` | ref of this repo used to render the template |

Repositories that need extra packaging (systemd units, conffiles, dependency
lists) keep their own `.goreleaser.yaml` — copy the template, extend it, and
pass `config: repo`.

### `sync-dl.yml` — publish an existing release

For a repository that already builds its own packages:

```yaml
  publish:
    uses: pilab-dev/release-toolchain/.github/workflows/sync-dl.yml@v1
    with:
      source: release          # or: artifact
      tier: testing
    secrets: inherit
```

`source: release` pulls `.deb`/`.rpm` assets off the GitHub release by tag;
`source: artifact` uses an artifact named `packages` uploaded by an earlier job.

### `promote-dl.yml` — testing → stable

```yaml
  promote:
    uses: pilab-dev/release-toolchain/.github/workflows/promote-dl.yml@v1
    with:
      package: wgmesh
      type: rpm
    secrets: inherit
```

It sends a `promote` request to the builder, which copies the package into the
`stable` corpus, re-indexes and re-signs that tier, and republishes. Nothing is
rebuilt, so the promoted artifact is byte-identical to the one that was tested.
Manual runs: *Actions → promote-dl → Run workflow*.

## Secrets

Set these per repository (or via `secrets: inherit` from a central place):

| secret | value |
|---|---|
| `DL_SSH_KEY` | private half of the CI deploy key (ed25519) |
| `DL_SSH_HOST` | builder host (ask ops) |
| `DL_SSH_USER` | builder user |
| `DL_SSH_PORT` | SSH port (optional, `22`) |
| `GH_TOKEN` | only for private Go modules (`go.pilab.hu`) |

The deploy key is *forced* through `dl-ssh-gate`: it can only `rsync` into
`~/dl-inbox/incoming/<id>`, `mkdir` a job directory and `cat` finished
`status/`/`logs/` files. It cannot run commands, and the signing key never
leaves the builder.

## How a publish actually works

```
GitHub runner                     builder host                     web
─────────────                     ─────────────                    ───
rsync assets + meta.json
rsync READY                    →  ~/dl-inbox/incoming/<id>/
                                  dl-agent.timer (1 min, flock)
                                    validate names/headers/tier
                                    repo-manage.sh add <type> <tier>
                                    repo-build.sh verify  (all signatures)
                                  rsync --delete --link-dest → ~/dl
cat status/<id>.json           ←  {"status":"ok","packages":[…sha256…]}
curl each url, compare sha256
apt/dnf install in a container
```

The status file lists both `sha256` (published bytes) and `origin_sha256`
(uploaded bytes): RPMs are re-signed with the repository key during ingest, so
those two legitimately differ for `.rpm` and must match for `.deb`.

## Tiers

New releases always land in **`testing`**; `stable` is promoted explicitly.
Each tier indexes its own `dist/<tier>` corpus on the builder — that is what
keeps a `testing` package out of `stable`.

## Layout of this repository

```
.github/workflows/release.yml     build → release → publish → install test
.github/workflows/sync-dl.yml     publish an already-built release
.github/workflows/promote-dl.yml  testing → stable
templates/goreleaser.yaml         shared GoReleaser config (rendered)
```
