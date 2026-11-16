#!/usr/bin/env bash
# Make the offsite bucket protect itself, so the backup key no longer has to be append-only.
# Run from the Mac, as YOU (it changes bucket settings and IAM, which Claude may not do).
#
#   ./harden-offsite-bucket.sh --dry-run    # show the current settings and every command, change nothing
#   ./harden-offsite-bucket.sh              # do it
#
# Why: the key can create but not overwrite, so every file that changes after its first upload fails with a 403.
# backup-run has ended "COMPLETED WITH ERRORS" every night since 2026-11-03, and an edited file keeps only its FIRST
# version offsite. Real failures get lost in that noise.
#
# The bucket already has (checked 2026-11-11): Object Versioning ON, 7-day soft delete, and lifecycle rules that move
# objects to NEARLINE at 30 days and COLDLINE at 90, and delete noncurrent versions 90 days after they are replaced.
# This script:
#   1. keeps versioning ON (no-op if it already is): an overwrite or delete keeps the old copy as a noncurrent version.
#   2. raises soft delete to 90 days: even a deleted version stays recoverable for 90 more days. The key cannot shorten
#      this (that needs storage.buckets.update, which roles/storage.objectUser does not include).
#   3. ADDS one lifecycle rule and keeps every existing one: nightly appdata/ snapshots expire after SNAPSHOT_DAYS.
#      Until now nothing could delete them, so appdata/ only grew (67.6 GiB, 31 snapshots on 2026-11-03).
#      60 days, not less: objects turn NEARLINE at 30 days and NEARLINE bills a 30-day minimum.
#   4. gives the backup key roles/storage.objectUser on this bucket (create, overwrite, delete objects; no IAM, no
#      bucket settings). Its existing roles (objectCreator, objectViewer) are left alone; objectUser covers them.
# Net effect: changed files upload cleanly, and a stolen key or a ransomwared host still cannot destroy history:
# anything it overwrites or deletes stays restorable (noncurrent for 90 days, then soft-deleted for 90 more).
set -euo pipefail
SA=<backup-sa>@<backup-project>.iam.gserviceaccount.com
ACCOUNT=you@example.com
BUCKET=<backup-bucket>
SNAPSHOT_DAYS=60
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
run(){ if [ "$DRY" = 1 ]; then echo "[dry-run] $*"; else "$@"; fi; }
G=(--account="$ACCOUNT")
show(){ gcloud storage buckets describe "gs://$BUCKET" "${G[@]}" \
  --format="yaml(name,versioning_enabled,soft_delete_policy,lifecycle_config)"; }

echo "== current settings for gs://$BUCKET"
show
echo "-- roles held by $SA on the bucket:"
gcloud storage buckets get-iam-policy "gs://$BUCKET" "${G[@]}" --format=json \
  | python3 -c "import json,sys; p=json.load(sys.stdin); print('\n'.join('   '+b['role'] for b in p.get('bindings',[]) if 'serviceAccount:$SA' in b.get('members',[])) or '   (none)')"

# Lifecycle: start from the bucket's current rules and append the snapshot expiry once.
LC=$(mktemp); trap 'rm -f "$LC"' EXIT
gcloud storage buckets describe "gs://$BUCKET" "${G[@]}" --format="json(lifecycle_config)" \
  | python3 -c "
import json, sys
cur = (json.load(sys.stdin).get('lifecycle_config') or {}).get('rule', [])
new = {'action': {'type': 'Delete'}, 'condition': {'age': $SNAPSHOT_DAYS, 'matchesPrefix': ['appdata/'], 'isLive': True}}
if not any(r.get('condition', {}).get('matchesPrefix') == ['appdata/'] for r in cur):
    cur.append(new)
open('$LC', 'w').write(json.dumps({'rule': cur}, indent=1) + '\n')
print('   lifecycle after: %d rules (%s)' % (len(cur), ', '.join(r['action']['type'] + (' ' + r['action'].get('storageClass', '') if r['action'].get('storageClass') else '') for r in cur)))
"

echo; echo "== 1. versioning on"
run gcloud storage buckets update "gs://$BUCKET" "${G[@]}" --versioning
echo "== 2. soft delete 90 days"
run gcloud storage buckets update "gs://$BUCKET" "${G[@]}" --soft-delete-duration=90d
echo "== 3. lifecycle: keep existing rules, add appdata/ expiry at ${SNAPSHOT_DAYS} days"
[ "$DRY" = 1 ] && sed 's/^/[dry-run]   /' "$LC"
run gcloud storage buckets update "gs://$BUCKET" "${G[@]}" --lifecycle-file="$LC"
echo "== 4. backup key may overwrite objects in this bucket"
run gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" "${G[@]}" \
  --member="serviceAccount:$SA" --role=roles/storage.objectUser --format=none

if [ "$DRY" = 0 ]; then
  echo; echo "== after"
  show
fi
echo
echo "Check it: the next nightly run (03:30) should end '=== BACKUP OK ==='. To test now:"
echo "  ssh homelab 'sudo systemctl start --no-block backup-offsite'; ssh homelab backup-status"
