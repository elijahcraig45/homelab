#!/usr/bin/env bash
# Restore the offsite backup on the homelab (it has never run there: rclone was never installed and the append-only
# key stayed on the old Pi). Run from the Mac, as YOU: it creates a service-account key, which Claude may not do.
#
#   ./setup-offsite-backup.sh --dry-run    # print every step, change nothing
#   ./setup-offsite-backup.sh              # do it
#
# What it does:
#   1. creates ONE new key for pihome-backup@<backup-project> (append-only: create+read on the bucket, no delete/overwrite)
#      and streams it to /etc/backup/gcs-sa.json on the homelab (root 0600). It never touches this Mac's disk.
#   2. installs rclone from apt and writes root's rclone remote `gcs:` (the name backup-run uses).
#   3. installs the corrected backup-run (old one kept as backup-run.bak-<date>): preflight, real exit codes, ntfy on failure.
#   4. proves the bucket is reachable. It does NOT start the 132 GB first upload; see the last line it prints.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SA=<backup-sa>@<backup-project>.iam.gserviceaccount.com
PROJECT=<backup-project>
ACCOUNT=you@example.com
HOST=homelab
BUCKET=<backup-bucket>
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
run(){ if [ "$DRY" = 1 ]; then echo "[dry-run] $*"; else "$@"; fi; }

[ "$(gcloud config get-value account 2>/dev/null)" = "$ACCOUNT" ] || echo "note: using --account $ACCOUNT for gcloud calls" >&2
ssh -n "$HOST" true || { echo "cannot ssh to $HOST" >&2; exit 1; }

echo "== 1. key for $SA -> $HOST:/etc/backup/gcs-sa.json"
ssh -n "$HOST" 'sudo test ! -e /etc/backup/gcs-sa.json' || { echo "   /etc/backup/gcs-sa.json already exists; refusing to overwrite" >&2; exit 1; }
if [ "$DRY" = 1 ]; then
  echo "[dry-run] gcloud iam service-accounts keys create /dev/stdout --iam-account=$SA --project=$PROJECT | ssh $HOST 'sudo sh -c \"umask 077; mkdir -p /etc/backup; cat > /etc/backup/gcs-sa.json\"'"
else
  gcloud iam service-accounts keys create /dev/stdout --iam-account="$SA" --project="$PROJECT" --account="$ACCOUNT" \
    | ssh "$HOST" 'sudo sh -c "umask 077; mkdir -p /etc/backup; cat > /etc/backup/gcs-sa.json" && sudo chmod 0600 /etc/backup/gcs-sa.json && sudo python3 -c "import json;d=json.load(open(\"/etc/backup/gcs-sa.json\"));assert d[\"client_email\"]==\"'"$SA"'\";print(\"   key installed for\",d[\"client_email\"])"'
fi

echo "== 2. rclone + remote"
run ssh -n "$HOST" 'sudo apt-get install -y rclone >/dev/null && rclone version | head -1'
run ssh -n "$HOST" 'sudo install -d -m 0700 /root/.config/rclone && printf "[gcs]\ntype = google cloud storage\nservice_account_file = /etc/backup/gcs-sa.json\nbucket_policy_only = true\n" | sudo tee /root/.config/rclone/rclone.conf >/dev/null && sudo chmod 0600 /root/.config/rclone/rclone.conf'

echo "== 3. corrected backup-run"
run scp -q "$HERE/backup-run" "$HOST:/tmp/backup-run.new"
run ssh -n "$HOST" 'sudo cp -p /usr/local/bin/backup-run /usr/local/bin/backup-run.bak-$(date +%Y%m%d) && sudo install -m 0755 /tmp/backup-run.new /usr/local/bin/backup-run && rm /tmp/backup-run.new'

echo "== 4. bucket reachable?"
run ssh -n "$HOST" "sudo rclone lsf gcs:$BUCKET --max-depth 1 | head -5"
echo
echo "Done. Start the first run (about 132 GB of photos, hours; it yields to Jellyfin, Nice=10/idle IO):"
echo "  ssh $HOST 'sudo systemctl start --no-block backup-offsite'; ssh $HOST 'sudo journalctl -fu backup-offsite'"
echo "Afterwards consider deleting the old pihome key (ssh to the old Pi is down): gcloud iam service-accounts keys list --iam-account=$SA --project=$PROJECT"
