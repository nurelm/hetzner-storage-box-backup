# hetzner-storage-box-backup

A minimal Docker image that backs up a Postgres database to a [Hetzner Storage Box](https://www.hetzner.com/storage/storage-box) using [restic](https://restic.net/), designed for single-server deployments running Docker Compose (e.g. [Kamal](https://kamal-deploy.org/)).

Runs as an ephemeral container on the host. No persistent state, no sidecar, no daemon. The host cron calls it, it does its job, it exits.

## How it works

```
cron (host)
  └── hpb-run.sh (host wrapper)
        └── docker run nurelmdevelopment/hetzner-storage-box-backup:pg16.14-latest backup
              ├── pg_dump (stdout) ──────────────────────────────────────┐
              └── restic backup --stdin ← dump piped in, no disk writes  │
                    └── sftp → Hetzner Storage Box                       ┘
```

The dump is streamed directly from `pg_dump` to `restic` via stdin — no temporary files on disk.

## Requirements

- Docker running on the host
- A [Hetzner Storage Box](https://www.hetzner.com/storage/storage-box)
- An SSH key pair authorized on the Storage Box (see [Setup](#setup))
- The Postgres container reachable on a named Docker network (only required for `backup`)

## Images

Images are tagged as `pg<major>.<minor>-<version>` where `<major>.<minor>` is the Postgres client version and `<version>` is the tool version.

Minor versions matter — `16.9` and `16.14` are not interchangeable, so we pin to both major and minor. If your Postgres server runs a version not listed, add it to `PG_VERSIONS.txt` and push a new tag.

| Tag | Postgres client | Notes |
|-----|----------------|-------|
| `pg16.14-latest` | 16.14 | Always the latest tool release for this PG version |
| `pg16.14-1.0.5` | 16.14 | Pinned release — recommended for production crons |

```bash
docker pull nurelmdevelopment/hetzner-storage-box-backup:pg16.14-1.0.5
```

## Setup

### 1. Create an SSH key for the Storage Box

```bash
ssh-keygen -t ed25519 -f ~/.ssh/storagebox_key -N "" -C "hetzner-storage-box-backup"
```

Add the public key to your Storage Box's `authorized_keys`. The Storage Box uses a mixed format — each key appears twice: once in OpenSSH format and once in RFC 4716 format. Use an SFTP client (e.g. Cyberduck) to edit the file at `.ssh/authorized_keys`, and replicate the same format for your new key:

```
ssh-ed25519 AAAA... your-comment
---- BEGIN SSH2 PUBLIC KEY ----
Comment: "your-comment"
AAAA...
---- END SSH2 PUBLIC KEY ----
```

The OpenSSH line comes from `cat ~/.ssh/storagebox_key.pub`. The RFC 4716 block comes from `ssh-keygen -e -f ~/.ssh/storagebox_key.pub`.

Verify the key works (expect "PTY allocation request failed" — that's normal, it means SSH connected successfully):

```bash
ssh -i ~/.ssh/storagebox_key uXXXXX@uXXXXX.your-storagebox.de
```

### 2. Create the `.env` file

```bash
cp example.env /root/.env    # or /home/backup/.env — wherever your hpb-run.sh points
chmod 600 /root/.env
# edit and fill in all values
```

See [Environment variables](#environment-variables) for the full reference.

### 3. Install `hpb-run.sh`

```bash
cp hpb-run.sh.example /usr/local/bin/hpb-run.sh
chmod +x /usr/local/bin/hpb-run.sh
# edit ENV_FILE and IMAGE to match your setup
```

### 4. Initialize the restic repo

Runs once per `STORAGEBOX_REPO_PATH`. Idempotent — safe to run again if unsure.

```bash
hpb-run.sh init
```

### 5. Verify the first backup

```bash
hpb-run.sh backup
hpb-run.sh snapshots    # should list one snapshot
```

### 6. Install the cron jobs

Two entries in `/etc/cron.d/hpb`: one for hourly backups, one for the daily prune.

```
0 * * * * root /usr/local/bin/hpb-run.sh backup >> /var/log/hpb.log 2>&1
0 3 * * * root /usr/local/bin/hpb-run.sh forget >> /var/log/hpb.log 2>&1
```

Adjust the user (`root` above) to whoever owns the `.env` and the SSH key.

## Commands

All commands are passed as the first argument to the container. `hpb-run.sh` is the recommended wrapper, but you can invoke the container directly.

### `init`

Initializes the restic repo in the Storage Box. Idempotent — safe to run multiple times.

```bash
hpb-run.sh init
```

### `backup`

Dumps the configured Postgres database and stores it in the restic repo. Fails with a clear message if `init` hasn't been run yet. Requires `DOCKER_NETWORK` to be set (the container needs to reach the Postgres container).

```bash
hpb-run.sh backup
```

### `forget`

Applies the retention policy and prunes unreferenced data from the repo. Run daily — not on every backup, as `--prune` is expensive.

```bash
hpb-run.sh forget
```

Default retention policy (override via env vars):
- Last 24 hourly snapshots
- Last 14 daily snapshots
- Last 8 weekly snapshots
- All snapshots tagged `last-known-good` (never rotated)

### `snapshots`

Lists all snapshots in the repo, including their tags. Does not require `DOCKER_NETWORK`.

```bash
hpb-run.sh snapshots
```

Snapshots tagged `suspect` may contain corrupted data — do not restore from them without understanding why they were tagged.

### `restore <SNAPSHOT_ID>`

Restores a snapshot and prints the SQL dump to stdout. Does not require `DOCKER_NETWORK`.

```bash
# List snapshots first
hpb-run.sh snapshots

# Restore to stdout and pipe to psql
hpb-run.sh restore abc123def | psql -U postgres your_database_name

# If Postgres runs in a Docker container on the same host:
hpb-run.sh restore abc123def | docker exec -i <postgres-container> psql -U postgres your_database_name
```

**Important:** if the target database already has content, drop and recreate the schema first to avoid foreign key conflicts during the restore:

```bash
docker exec -i <postgres-container> psql -U postgres -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" your_database_name
```

The dump uses `--clean --if-exists` semantics, which works cleanly against an empty schema. Against a populated database with foreign keys, the drop order can cause conflicts — the `DROP SCHEMA CASCADE` above resolves this.

### `tag <SNAPSHOT_ID> <TAG>`

Adds a tag to a snapshot. Does not require `DOCKER_NETWORK`.

```bash
hpb-run.sh tag abc123def last-known-good
hpb-run.sh tag abc123def suspect
```

Tags used by convention:

| Tag | Meaning |
|-----|---------|
| `last-known-good` | This snapshot was used to recover production and the app was verified healthy afterward. Preserved permanently by the retention policy. |
| `suspect` | This snapshot was taken after a data incident and may contain corrupted data. Rotates normally with the retention policy alongside the snapshot itself. |

## Environment variables

### Required for `backup`

| Variable | Used by | Description |
|----------|---------|-------------|
| `DOCKER_NETWORK` | `hpb-run.sh` | Docker network where the Postgres container lives. Not needed for `snapshots`, `restore`, `tag`, `init`, `forget`. |
| `POSTGRES_CONTAINER` | container | Name of the Postgres container on the Docker network |
| `POSTGRES_DB` | container | Database name to back up |
| `POSTGRES_USER` | container | Postgres user |
| `POSTGRES_PASSWORD` | container | Postgres password |

### Required for all commands

| Variable | Used by | Description |
|----------|---------|-------------|
| `STORAGEBOX_SSH_KEY_PATH` | `hpb-run.sh` | Absolute path to the SSH private key on the host |
| `STORAGEBOX_HOST` | container | Storage Box hostname (e.g. `uXXXXX.your-storagebox.de`) |
| `STORAGEBOX_USER` | container | Storage Box username (same `uXXXXX` as in the hostname) |
| `STORAGEBOX_REPO_PATH` | container | Directory inside the Storage Box for this project's restic repo (e.g. `/pbrain-production`) |
| `RESTIC_PASSWORD` | container | Passphrase for restic repo encryption. **Not** the Storage Box password. Losing this makes your backups unreadable. |

### Optional (retention policy)

| Variable | Default | Description |
|----------|---------|-------------|
| `KEEP_HOURLY` | `24` | Number of hourly snapshots to keep |
| `KEEP_DAILY` | `14` | Number of daily snapshots to keep |
| `KEEP_WEEKLY` | `8` | Number of weekly snapshots to keep |

Snapshots tagged `last-known-good` are always kept regardless of these settings.

## Sharing one Storage Box across projects

One Storage Box can hold multiple restic repos. Use a distinct `STORAGEBOX_REPO_PATH` per project:

```
uXXXXX.your-storagebox.de/
  /pbrain-production      ← STORAGEBOX_REPO_PATH for pbrain prod
  /pbrain-staging         ← STORAGEBOX_REPO_PATH for pbrain staging
  /other-project          ← STORAGEBOX_REPO_PATH for another project
```

## Adding a new Postgres version

Edit `PG_VERSIONS.txt` and add the full `major.minor` version (one per line):

```
16.14
15.13
```

Push a new tag to trigger the autobuild. Docker Hub will produce:
- `pg16.14-<version>` and `pg16.14-latest`
- `pg15.13-<version>` and `pg15.13-latest`

## License

MIT
