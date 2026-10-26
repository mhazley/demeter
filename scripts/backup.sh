#!/usr/bin/env bash
# Nightly backup of media-stack config to S3 with restic.
# Expects /etc/media-backup.env (root:root, 0600) containing:
#   AWS_ACCESS_KEY_ID=...
#   AWS_SECRET_ACCESS_KEY=...
#   AWS_DEFAULT_REGION=eu-west-1
#   RESTIC_REPOSITORY=s3:s3.eu-west-1.amazonaws.com/BUCKET_NAME/media-stack
#   RESTIC_PASSWORD_FILE=/etc/media-backup.restic-pass
#
# cron (sudo crontab -e):
#   0 4 * * * /path/to/demeter/scripts/backup.sh >> /var/log/media-backup.log 2>&1
set -euo pipefail

STACK="$(cd "$(dirname "$0")/.." && pwd)"   # repo root (where docker-compose.yml lives)

set -a; source /etc/media-backup.env; set +a

cd "$STACK"
echo "== $(date -Is) backup start"

docker compose stop
trap 'docker compose start; echo "== $(date -Is) stack restarted"' EXIT

restic backup config .env \
  --tag media-stack \
  --exclude 'config/jellyfin/cache' \
  --exclude 'config/jellyfin/data/transcodes' \
  --exclude 'config/*/logs' \
  --exclude 'config/*/Backups'

# Stack can come back up now; pruning doesn't need it stopped.
docker compose start
trap - EXIT

restic forget --tag media-stack \
  --keep-daily 7 --keep-weekly 4 --keep-monthly 6 \
  --prune

restic check --read-data-subset=5%
echo "== $(date -Is) backup done"
