# hetzner-storage-box-backup

A minimal Docker image that backs up a Postgres database to a [Hetzner Storage Box](https://www.hetzner.com/storage/storage-box) using [restic](https://restic.net/), designed for single-server deployments running Docker Compose (e.g. [Kamal](https://kamal-deploy.org/)).

Runs as an ephemeral container on the host. No persistent state, no sidecar, no daemon. The host cron calls it, it does its job, it exits.

## How it works

```
cron (host)
  └── hpb-run.sh (host wrapper)
        └── docker run nurelmdevelopment/hetzner-storage-box-backup:pg16-latest backup
              ├── pg_dump (stdout) ──────────────────────────────────────┐
              └── restic backup --stdin ← dump piped in, no disk writes  │
                    └── sftp → Hetzner Storage Box                       ┘
```

The dump is streamed directly from `pg_dump` to `restic` via stdin — no temporary files on disk.

## Requirements

- Docker running on the host
- A [Hetzner Storage Box](https://www.hetzner.com/storage/storage-box)
- An SSH key pair authorized on the Storage Box (see [Setup](#setup))
- The Postgres container reachable on a named Docker network

## Images

Images are tagged as `pg<major>-<version>` where `<major>` is the Postgres major version and `<version>` is the tool version.

| Tag | Postgres client | Notes |
|-----|----------------|-------|
| `pg16-latest` | 16.x (latest patch) | Recommended for Postgres 16 |
| `pg16-1.0.0` | 16.x | Pinned tool release |

Use the tag matching your Postgres server's **major version**. Minor version mismatches between client and server are safe; major version mismatches may cause `pg_dump` errors.

```bash
docker pull nurelmdevelopment/hetzner-storage-box-backup:pg16-latest
```

## Setup

### 1. Create an SSH key for the Storage Box

```bash
ssh-keygen -t ed25519 -f ~/.ssh/storagebox_key -N ""
```

Upload the public key to your Storage Box via SFTP:

```bash
sftp uXXXXX@uXXXXX.your-storagebox.de
sftp> mkdir .ssh
sftp> put ~/.ssh/storagebox_key.pub .ssh/authorized_keys
sftp> exit
```

Verify it works:

```bash
ssh -i ~/.ssh/storagebox_key uXXXXX@uXXXXX.your-storagebox.de df -h
```

### 2. Create the `.env` file

```bash
cp example.env /home/backup/.env
chmod 600 /home/backup/.env
# edit /home/backup/.env and fill in all values
```

See [Environment variables](#environment-variables) for the full reference.

### 3. Install `hpb-run.sh`

```bash
cp hpb-run.sh.example /usr/local/bin/hpb-run.sh
chmod +x /usr/local/bin/hpb-run.sh
# edit /usr/local/bin/hpb-run.sh if your ENV_FILE path or image tag differ
```

### 4. Initialize the restic repo

This runs once per Storage Box path. It is idempotent — safe to run again if you're unsure.

```bash
hpb-run.sh init
```

### 5. Verify the first backup

```bash
hpb-run.sh backup
hpb-run.sh snapshots    # should list one snapshot
```

### 6. Install the cron jobs

Two entries: one for hourly backups, one for the daily prune.

```bash
# /etc/cron.d/hpb
# Run as the user that owns the .env and the SSH key.
# Start with the backup commented out — enable it once you've verified manually.

# 0 * * * * backup /usr/local/bin/hpb-run.sh backup >> /var/log/hpb.log 2>&1
0 3 * * * backup /usr/local/bin/hpb-run.sh forget >> /var/log/hpb.log 2>&1
```

Uncomment the backup line once you're happy with the manual run.

## Commands

### `init`

Initializes the restic repo in the Storage Box. Safe to run multiple times.

```bash
hpb-run.sh init
```

### `backup`

Dumps the configured Postgres database and stores it in the restic repo.
Fails with a clear message if `init` hasn't been run yet.

```bash
hpb-run.sh backup
```

### `forget`

Applies the retention policy and prunes unreferenced data from the repo.
Run daily (not on every backup — `--prune` is expensive).

```bash
hpb-run.sh forget
```

Default retention policy (override via env vars — see below):
- Last 24 hourly snapshots
- Last 14 daily snapshots
- Last 8 weekly snapshots
- All snapshots tagged `last-known-good` (never rotated)

### `snapshots`

Lists all snapshots in the repo, including their tags.

```bash
hpb-run.sh snapshots
```

Snapshots tagged `suspect` may contain data from a corrupted state — do not restore from them without understanding why they were tagged. See [Tagging snapshots](#tagging-snapshots).

### `restore <SNAPSHOT_ID>`

Restores a snapshot and prints the SQL dump to stdout.
Pipe it to `psql` to import.

```bash
# List snapshots to find the ID
hpb-run.sh snapshots

# Restore and import
hpb-run.sh restore abc123def | psql your_database_name
```

The restored dump uses `--clean --if-exists` semantics: it drops and recreates the schema before inserting data, so it works against an existing database without manual cleanup first.

### `tag <SNAPSHOT_ID> <TAG>`

Adds a tag to a snapshot.

```bash
hpb-run.sh tag abc123def last-known-good
hpb-run.sh tag abc123def suspect
```

Tags used by convention:

| Tag | Meaning |
|-----|---------|
| `last-known-good` | This snapshot was used to recover production and the app was verified healthy. Preserved permanently by the retention policy. |
| `suspect` | This snapshot was taken after a data incident and may contain corrupted data. Rotates normally with the retention policy. |

## Environment variables

### Required

| Variable | Used by | Description |
|----------|---------|-------------|
| `DOCKER_NETWORK` | `hpb-run.sh` | Docker network where the Postgres container lives |
| `STORAGEBOX_SSH_KEY_PATH` | `hpb-run.sh` | Path to the SSH private key on the host |
| `POSTGRES_CONTAINER` | container | Name of the Postgres container on the Docker network |
| `POSTGRES_DB` | container | Database name to back up |
| `POSTGRES_USER` | container | Postgres user |
| `POSTGRES_PASSWORD` | container | Postgres password |
| `STORAGEBOX_HOST` | container | Storage Box hostname (e.g. `uXXXXX.your-storagebox.de`) |
| `STORAGEBOX_USER` | container | Storage Box username (same as the `uXXXXX` part of the host) |
| `STORAGEBOX_REPO_PATH` | container | Path inside the Storage Box for this project's repo (e.g. `/pbrain-production`) |
| `RESTIC_PASSWORD` | container | Passphrase for the restic repo encryption. **Not** the Storage Box password. Keep this safe — without it, your backups are unreadable. |

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
  /pbrain-production      ← STORAGEBOX_REPO_PATH for pbrain
  /other-project          ← STORAGEBOX_REPO_PATH for another project
```

## Adding a new Postgres version

Edit `PG_VERSIONS.txt` and add the full version number (one per line):

```
16.9
15.13
```

Push a new tag to trigger the autobuild. Docker Hub will produce:
- `pg16-<version>` and `pg16-latest`
- `pg15-<version>` and `pg15-latest`

## License

MIT
