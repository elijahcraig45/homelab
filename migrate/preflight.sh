#!/bin/bash
# Run ON pihome before the migration. Collects everything the new box needs into
# /mnt/appdata/_migration/ so that a single rsync of /mnt/appdata moves the lot.
#
#   sudo ./preflight.sh
#
# Safe to re-run; it overwrites its own output and touches nothing else.
set -euo pipefail
OUT=/mnt/appdata/_migration
STAMP=$(date +%Y%m%d-%H%M%S)
[ "$(id -u)" = 0 ] || { echo "needs root: sudo $0" >&2; exit 1; }

install -d -m 755 "$OUT"/{etc,units,bin,stack,inventory}

echo "== 1/6 Immich Postgres dump (NOT a data-dir copy - PG dirs are not portable across arches) =="
started=0
if [ "$(docker inspect -f '{{.State.Running}}' immich_postgres 2>/dev/null)" != true ]; then
  echo "   starting immich_postgres temporarily..."
  docker start immich_postgres >/dev/null; started=1
  for i in $(seq 30); do docker exec immich_postgres pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
fi
docker exec immich_postgres pg_dumpall --clean --if-exists -U postgres > "$OUT/immich-pgdumpall-$STAMP.sql"
gzip -f "$OUT/immich-pgdumpall-$STAMP.sql"
ln -sf "immich-pgdumpall-$STAMP.sql.gz" "$OUT/immich-pgdumpall-latest.sql.gz"
ls -lh "$OUT/immich-pgdumpall-$STAMP.sql.gz" | awk '{print "   dump: "$5}'
[ "$started" = 1 ] && { docker stop immich_postgres >/dev/null; echo "   immich_postgres stopped again"; }

echo "== 2/6 compose stacks =="
cp -a /opt/stack/docker-compose.yml /opt/stack/.env                  "$OUT/stack/" 2>/dev/null || true
install -d "$OUT/stack/immich"
cp -a /opt/stack/immich/docker-compose.yml \
      /opt/stack/immich/docker-compose.override.yml \
      /opt/stack/immich/.env                                          "$OUT/stack/immich/" 2>/dev/null || true

echo "== 3/6 host config =="
# pihome-health.conf holds the Kuma push token; without it monitoring comes up
# silently dead. It was missing from this list until 2026-09-19.
for f in /etc/samba/smb.conf /etc/caddy-pihome.Caddyfile /etc/smartd.conf \
         /etc/ntfy-alert.conf /etc/immich-thermal.conf /etc/pihome-health.conf \
         /etc/fstab; do
  [ -r "$f" ] && cp -a "$f" "$OUT/etc/$(basename "$f")"
done
cp -a /var/www/pihome "$OUT/etc/www-pihome" 2>/dev/null || true

echo "== 4/6 host scripts =="
# pihome-status is required by pihome-status.service, which IS collected below -
# omitting it left the unit pointing at a missing binary. backup-mark/-status are the
# user-facing half of the backup tooling. Deliberately NOT collected: frame-* (they
# live on the Pi 3), burnin-*/powertest/scratch-guard (one-off Pi build tools).
for b in pihome-health pihome-alert pihome-status ntfy-send smartd-ntfy \
         backup-run backup-mark backup-status \
         immich-cpu-profile immich-thermal-guard; do
  [ -x "/usr/local/bin/$b" ] && cp -a "/usr/local/bin/$b" "$OUT/bin/"
done

echo "== 5/6 systemd units (NOT the picture-frame ones - those live on the Pi 3 now) =="
for u in backup-offsite.service backup-offsite.timer cpu-governor.service \
         pihome-health.service pihome-health.timer pihome-status.service \
         tailscale-gro.service; do
  [ -r "/etc/systemd/system/$u" ] && cp -a "/etc/systemd/system/$u" "$OUT/units/"
done
# Thermal guard is deliberately NOT collected: the new box has adequate cooling
# and does not need a CPU governor babysitting Immich. See MIGRATION.md.

echo "== 6/6 inventory =="
{
  echo "# captured $(date -Is) on $(hostname)"
  echo; echo "## os"; . /etc/os-release; echo "$PRETTY_NAME $(uname -m) kernel $(uname -r)"
  echo; echo "## containers"; docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}'
  echo; echo "## pool fstab lines"; grep -E "disk1|disk2|mergerfs" /etc/fstab || true
  echo; echo "## blkid"; blkid /dev/sda1 /dev/sdb1 2>/dev/null || true
  echo; echo "## network"; echo "eth0 MAC: $(cat /sys/class/net/eth0/address)"
  ip -4 addr show eth0 | grep inet || true
  echo "NOTE: <pi-lan-ip> is a DYNAMIC lease. The new box has a different MAC -"
  echo "      add a DHCP reservation for it, or AdGuard (LAN DNS) moves and DNS breaks."
  echo; echo "## samba shares"; grep -E "^\[|path *=" /etc/samba/smb.conf 2>/dev/null || true
  echo; echo "## tailscale"; tailscale status --self --peers=false 2>/dev/null || true
  echo "advertised routes: <lan-cidr>"
  echo; echo "## disk"; df -h / /mnt/appdata /mnt/storage 2>/dev/null
} > "$OUT/inventory/inventory.txt"

chmod -R go-rwx "$OUT/etc" 2>/dev/null || true
echo
echo "Done -> $OUT"
du -sh "$OUT" | awk '{print "  bundle: "$1}'
echo "  (appdata total, which is what you rsync: $(du -sh /mnt/appdata | cut -f1))"
