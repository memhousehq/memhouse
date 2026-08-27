<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# Install a packaged release

The packaged release includes and supervises a checksum-pinned pg0 PostgreSQL
distribution with pgvector and pgvectorscale 0.9.0.

## Choose a build

Open [MemHouse Releases](https://github.com/memhousehq/memhouse/releases),
select a version, and download the archive and adjacent `.sha256` file matching
your machine:

| System | Architecture check | Archive |
| --- | --- | --- |
| macOS, Apple Silicon | `uname -m` prints `arm64` | `memhouse-macos-arm64.tar.gz` |
| Linux, Intel/AMD 64-bit | `uname -m` prints `x86_64` | `memhouse-linux-x86_64.tar.gz` |
| Linux, ARM 64-bit | `uname -m` prints `aarch64` or `arm64` | `memhouse-linux-arm64.tar.gz` |

Windows, Intel macOS, and Linux musl need external PostgreSQL with pgvector and
pgvectorscale, or a container deployment.

The container build for external PostgreSQL is
`ghcr.io/memhousehq/memhouse:<version>`.

## Download and verify

The browser download works without extra tools. The commands below use the
[GitHub CLI](https://cli.github.com/) to download both required files. Replace
`v0.4.0` with the release tag you want.

=== "macOS"

    ```bash
    release_tag=v0.4.0
    arch=$(uname -m)
    mkdir -p memhouse-download
    gh release download "$release_tag" \
      --repo memhousehq/memhouse \
      --pattern "memhouse-macos-${arch}.tar.gz*" \
      --dir memhouse-download
    cd memhouse-download
    shasum -a 256 -c "memhouse-macos-${arch}.tar.gz.sha256"
    tar -xzf "memhouse-macos-${arch}.tar.gz"
    cd memhouse
    ```

=== "Linux"

    ```bash
    release_tag=v0.4.0
    mkdir -p memhouse-download
    gh release download "$release_tag" \
      --repo memhousehq/memhouse \
      --pattern "memhouse-linux-x86_64.tar.gz*" \
      --dir memhouse-download
    cd memhouse-download
    sha256sum -c memhouse-linux-x86_64.tar.gz.sha256
    tar -xzf memhouse-linux-x86_64.tar.gz
    cd memhouse
    ```

=== "Windows"

    ```powershell
    $releaseTag = "v0.4.0"
    $download = "memhouse-download"
    gh release download $releaseTag `
      --repo memhousehq/memhouse `
      --pattern "memhouse-windows-x86_64.zip*" `
      --dir $download
    Set-Location $download
    $expected = (Get-Content memhouse-windows-x86_64.zip.sha256).Split()[0]
    $actual = (Get-FileHash -Algorithm SHA256 memhouse-windows-x86_64.zip).Hash.ToLowerInvariant()
    if ($actual -ne $expected) { throw "Checksum verification failed" }
    Expand-Archive memhouse-windows-x86_64.zip
    Set-Location memhouse
    ```

Do not run an archive when its checksum fails. Download both files again from
the same release and retry verification.

## Recommended local setup

For a single-machine installation, use the packaged PostgreSQL, keep all
durable state in one private directory, and enable signed patch/minor updates
before each start:

```bash
export MEMHOUSE_DATA_ROOT="$HOME/.memhouse"
export MEMHOUSE_DATABASE_MODE=pg0
export MEMHOUSE_AUTO_MIGRATE=true
export MEMHOUSE_UPDATE_CHECK=true
export MEMHOUSE_AUTO_UPDATE=minor
export MEMHOUSE_UPDATE_CHECK_INTERVAL_HOURS=24

bin/server
```

`minor` accepts only an eligible signed stable patch/minor release in the
current major version. Use `bin/update --check` to inspect availability, or
set `MEMHOUSE_AUTO_UPDATE=off` when you want to approve every update yourself.

## Run it

From the extracted `memhouse` directory:

```bash
bin/server
```

The macOS archives are not yet signed or notarized by Apple. If macOS blocks
the verified build, try to open it once, then use **System Settings → Privacy &
Security → Open Anyway**. Apple documents the security tradeoff and exact steps
in [Safely open apps on your Mac](https://support.apple.com/en-us/102445). Do
not disable Gatekeeper globally.

On first start the launcher:

1. creates a private data root at `~/.memhouse`;
2. generates the local signing secret;
3. starts the packaged pg0 binary and creates its PostgreSQL cluster;
4. runs every migration against the fresh database;
5. starts Phoenix on port 4000.

Confirm it is up:

```bash
curl -fsS http://127.0.0.1:4000/api/ready
```

A 200 means the database, job queues, and model roles are ready. A 503 names
failing components with content-safe counts, versions, and error classes.

!!! warning "It fails closed, on purpose"
    If the port is occupied, or the data directory and configuration are
    unhealthy, the release refuses to accept traffic rather than starting in a
    half-working state.

## Change the defaults

Set these **before the first start**; they decide where durable state is
created:

| Variable | Default | Meaning |
| --- | --- | --- |
| `MEMHOUSE_DATA_ROOT` | `~/.memhouse` | Private data root for database, blobs, and secrets |
| `PORT` | `4000` | HTTP port |
| `MEMHOUSE_PG0_PORT` | `5432` | Port the supervised PostgreSQL listens on |

The complete list is in [Configuration](../reference/configuration.md).

## Point it at your own PostgreSQL instead

The same release can use operator-run PostgreSQL 18 with pgvector and
pgvectorscale 0.9.0. Boot fails with an actionable error if `vectorscale` is
not available to install.

```bash
export MEMHOUSE_DATABASE_MODE=external
export DATABASE_URL='ecto://user:password@db.example/memhouse'
export MEMHOUSE_AUTO_MIGRATE=true
export MEMHOUSE_AUTH_SIGNING_SECRET='at-least-64-random-bytes...'
export MEMHOUSE_BLOB_ROOT=/absolute/durable/blob/path
bin/memhouse start
```

Set `MEMHOUSE_AUTO_MIGRATE=false` when change control requires migrations to
be a separate step, then run `bin/migrate` before starting the release.

## Build a release from source

The package script downloads the exact pg0 asset named in `rel/pg0/VERSION`,
verifies it against `rel/pg0/checksums.txt`, and builds the pinned pgvectorscale
source against that pg0 installation:

```bash
./scripts/package-release
```

An approved campaign container must embed its full source revision before the
release compiles:

    revision=$(git rev-parse HEAD)
    docker build \
      --build-arg "MEMHOUSE_CAMPAIGN_BUILD_SHA=$revision" \
      --tag memhouse:campaign \
      .

Omit the build argument for an ordinary image. It embeds `unknown`, which
cannot activate campaign spend.

## Next

- [Quickstart tutorial](quickstart.md) — bootstrap an administrator and record
  your first observation.
- [Operations overview](../operations/index.md) — upgrades, backups, and
  running this in earnest.
