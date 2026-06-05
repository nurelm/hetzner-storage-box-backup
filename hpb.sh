#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# hetzner-storage-box-backup — entrypoint
# Commands: init | backup | forget | snapshots | restore <SNAPSHOT_ID>
# ---------------------------------------------------------------------------

# --- Validate required environment variables --------------------------------

required_vars=(
  POSTGRES_CONTAINER
  POSTGRES_DB
  POSTGRES_USER
  POSTGRES_PASSWORD
  STORAGEBOX_HOST
  STORAGEBOX_USER
  STORAGEBOX_REPO_PATH
  RESTIC_PASSWORD
)

missing=()
for var in "${required_vars[@]}"; do
  [[ -z "${!var:-}" ]] && missing+=("$var")
done

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: missing required environment variables:"
  for var in "${missing[@]}"; do
    echo "  - $var"
  done
  exit 1
fi

# --- SSH key setup ----------------------------------------------------------
# The key is mounted at /tmp/storagebox_key by hpb-run.sh (-v flag).
# We copy it to a temp location with strict permissions to satisfy SSH.

SSH_KEY_SRC="/tmp/storagebox_key"
SSH_KEY="/tmp/hpb_storagebox_key"

if [[ ! -f "$SSH_KEY_SRC" ]]; then
  echo "ERROR: SSH key not found at $SSH_KEY_SRC"
  echo "Make sure hpb-run.sh mounts STORAGEBOX_SSH_KEY_PATH to /tmp/storagebox_key"
  exit 1
fi

cp "$SSH_KEY_SRC" "$SSH_KEY"
chmod 600 "$SSH_KEY"

# --- restic environment ------------------------------------------------------

export RESTIC_REPOSITORY="sftp:${STORAGEBOX_USER}@${STORAGEBOX_HOST}:${STORAGEBOX_REPO_PATH}"
export RESTIC_RSH="ssh -i ${SSH_KEY} -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null"
# RESTIC_PASSWORD is already in the environment

# --- Retention policy (convention over configuration) -----------------------
# Defaults mirror what the DR runbook expects.
# Override via KEEP_HOURLY, KEEP_DAILY, KEEP_WEEKLY in your .env.

KEEP_HOURLY="${KEEP_HOURLY:-24}"
KEEP_DAILY="${KEEP_DAILY:-14}"
KEEP_WEEKLY="${KEEP_WEEKLY:-8}"

# --- Helper: check if repo is initialized -----------------------------------

repo_initialized() {
  restic snapshots &>/dev/null
}

# --- Commands ----------------------------------------------------------------

cmd="${1:-}"

case "$cmd" in

  # --------------------------------------------------------------------------
  init)
    if repo_initialized; then
      echo "Repo already initialized at $RESTIC_REPOSITORY — nothing to do."
      exit 0
    fi
    echo "Initializing restic repo at $RESTIC_REPOSITORY ..."
    restic init
    echo "Done. You can now run: hpb backup"
    ;;

  # --------------------------------------------------------------------------
  backup)
    if ! repo_initialized; then
      echo "ERROR: restic repo not initialized."
      echo "Run first: hpb-run.sh init"
      exit 1
    fi

    echo "[$(date -u +%FT%TZ)] Starting backup of $POSTGRES_DB on $POSTGRES_CONTAINER ..."

    PGPASSWORD="$POSTGRES_PASSWORD" pg_dump \
      --host="$POSTGRES_CONTAINER" \
      --username="$POSTGRES_USER" \
      --format=plain \
      --no-owner \
      --no-acl \
      --clean \
      --if-exists \
      "$POSTGRES_DB" \
      | restic backup \
          --stdin \
          --stdin-filename dump.sql

    echo "[$(date -u +%FT%TZ)] Backup complete."
    ;;

  # --------------------------------------------------------------------------
  forget)
    echo "[$(date -u +%FT%TZ)] Running forget --prune ..."
    echo "Policy: --keep-hourly $KEEP_HOURLY --keep-daily $KEEP_DAILY --keep-weekly $KEEP_WEEKLY --keep-tag last-known-good"

    restic forget --prune \
      --keep-hourly  "$KEEP_HOURLY" \
      --keep-daily   "$KEEP_DAILY" \
      --keep-weekly  "$KEEP_WEEKLY" \
      --keep-tag     last-known-good

    echo "[$(date -u +%FT%TZ)] forget --prune complete."
    ;;

  # --------------------------------------------------------------------------
  snapshots)
    # Lists all snapshots in the repo. Snapshots tagged 'suspect' are shown
    # with their tag so the operator can avoid restoring them by mistake.
    restic snapshots
    ;;

  # --------------------------------------------------------------------------
  restore)
    snapshot_id="${2:-}"
    if [[ -z "$snapshot_id" ]]; then
      echo "Usage: hpb-run.sh restore <SNAPSHOT_ID>"
      echo "List available snapshots with: hpb-run.sh snapshots"
      exit 1
    fi

    # Restore prints the SQL dump to stdout so the operator can pipe it
    # wherever needed:
    #   hpb-run.sh restore abc123 | psql nurelm_pbrain_production
    #
    # restic restore to stdout requires dumping to a temp path and catting it,
    # because restic doesn't support --target - (stdout) directly.
    # We use a tmpdir inside the container (gone when container dies).

    TMPDIR=$(mktemp -d)
    restic restore "$snapshot_id" --target "$TMPDIR"

    # The dump was stored as dump.sql
    cat "$TMPDIR/dump.sql"
    ;;

  # --------------------------------------------------------------------------
  tag)
    # Usage: hpb-run.sh tag <SNAPSHOT_ID> <TAG>
    # Example: hpb-run.sh tag abc123 last-known-good
    #          hpb-run.sh tag abc123 suspect
    snapshot_id="${2:-}"
    tag_name="${3:-}"
    if [[ -z "$snapshot_id" || -z "$tag_name" ]]; then
      echo "Usage: hpb-run.sh tag <SNAPSHOT_ID> <TAG>"
      echo "Tags used by convention: last-known-good, suspect"
      exit 1
    fi
    restic tag --add "$tag_name" "$snapshot_id"
    echo "Tagged snapshot $snapshot_id as '$tag_name'."
    ;;

  # --------------------------------------------------------------------------
  *)
    echo "hetzner-storage-box-backup"
    echo ""
    echo "Usage: hpb-run.sh <command> [args]"
    echo ""
    echo "Commands:"
    echo "  init                       Initialize the restic repo (idempotent)"
    echo "  backup                     Dump Postgres and back up to Storage Box"
    echo "  forget                     Apply retention policy and prune old snapshots"
    echo "  snapshots                  List available snapshots"
    echo "  restore <SNAPSHOT_ID>      Restore a snapshot to stdout (pipe to psql)"
    echo "  tag <SNAPSHOT_ID> <TAG>    Add a tag to a snapshot (e.g. last-known-good, suspect)"
    echo ""
    echo "See README.md or https://github.com/nurelm/hetzner-storage-box-backup"
    exit 1
    ;;

esac
