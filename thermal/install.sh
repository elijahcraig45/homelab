#!/bin/bash
# Install the Immich thermal/stability profile on pihome.
# Run ON pihome, from this directory:  sudo ./install.sh
#
#   --dry-run    show what would change, touch nothing
#   --uninstall  remove the timers/scripts and restore the previous override
set -euo pipefail

STACK=/opt/stack/immich
BIN=/usr/local/bin
UNITS=/etc/systemd/system
STATEDIR=/var/lib/immich-thermal
TIMERS=(immich-thermal-guard.timer immich-night-profile.timer immich-day-profile.timer)
CONF=/etc/immich-thermal.conf
SRC="$(cd "$(dirname "$0")" && pwd)"
STAMP=$(date +%Y%m%d-%H%M%S)

DRY=0; UNINSTALL=0
for a in "$@"; do
  case "$a" in
    --dry-run)   DRY=1 ;;
    --uninstall) UNINSTALL=1 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done
run() { if [ "$DRY" = 1 ]; then echo "  [dry-run] $*"; else "$@"; fi; }

[ "$(hostname)" = pihome ] || { echo "This is meant for pihome, not $(hostname)." >&2; exit 1; }
[ "$DRY" = 1 ] || [ "$(id -u)" = 0 ] || { echo "needs root: sudo $0" >&2; exit 1; }
[ -d "$STACK" ] || { echo "missing $STACK" >&2; exit 1; }

if [ "$UNINSTALL" = 1 ]; then
  echo "== uninstalling =="
  for t in "${TIMERS[@]}"; do
    run systemctl disable --now "$t" || true
  done
  run rm -f "$UNITS"/immich-thermal-guard.{service,timer} \
            "$UNITS"/immich-night-profile.{service,timer} \
            "$UNITS"/immich-day-profile.{service,timer}
  run systemctl daemon-reload
  run rm -f "$BIN/immich-cpu-profile" "$BIN/immich-thermal-guard"
  run rm -f "$CONF.dist"
  echo "leaving $CONF in place (it holds your tuning); delete it by hand if you want it gone"
  run rm -rf "$STATEDIR"
  last=$(ls -1t "$STACK"/docker-compose.override.yml.bak-* 2>/dev/null | head -1 || true)
  if [ -n "$last" ]; then
    echo "restoring override from $last"
    run cp "$last" "$STACK/docker-compose.override.yml"
    echo "now run:  cd $STACK && docker compose up -d"
  else
    echo "no override backup found - leaving $STACK/docker-compose.override.yml as-is"
  fi
  echo "done. Quotas stay as last applied until you recreate the containers."
  exit 0
fi

echo "== 1/5 backing up the current override =="
run cp -v "$STACK/docker-compose.override.yml" \
          "$STACK/docker-compose.override.yml.bak-$STAMP"

echo "== 2/5 installing override (persists the hard cpus quotas + ML thread caps) =="
# This is the fix for the known 'live-only, reverts on any container recreate'
# gap: the quotas now live in the file, so a recreate lands in the SAFE profile.
run install -m 664 -o pi -g pi "$SRC/docker-compose.override.yml" \
    "$STACK/docker-compose.override.yml"
if [ "$DRY" = 0 ]; then
  ( cd "$STACK" && docker compose config --quiet ) \
    && echo "  compose config validates" \
    || { echo "!! compose config FAILED - restoring backup" >&2
         cp "$STACK/docker-compose.override.yml.bak-$STAMP" \
            "$STACK/docker-compose.override.yml"; exit 1; }
fi

echo "== 3/5 installing scripts + tunables =="
run install -m 755 "$SRC/immich-cpu-profile"   "$BIN/immich-cpu-profile"
run install -m 755 "$SRC/immich-thermal-guard" "$BIN/immich-thermal-guard"
run install -d -m 755 "$STATEDIR"
# Never clobber local tuning (HOT is the knob people actually change).
if [ -e "$CONF" ]; then
  echo "  keeping existing $CONF (HOT=$(sed -n 's/^HOT=\([0-9.]*\).*/\1/p' "$CONF" | head -1))"
  echo "  new defaults for reference -> $CONF.dist"
  run install -m 644 "$SRC/immich-thermal.conf" "$CONF.dist"
else
  run install -m 644 "$SRC/immich-thermal.conf" "$CONF"
fi

echo "== 4/5 installing + enabling timers =="
run install -m 644 "$SRC"/systemd/*.service "$SRC"/systemd/*.timer "$UNITS/"
run systemctl daemon-reload
for t in "${TIMERS[@]}"; do run systemctl enable --now "$t"; done

echo "== 5/5 recreating the Immich containers =="
# Required: the MACHINE_LEARNING_* thread caps are env vars, and env only
# takes effect on recreate. `docker update` cannot set them.
echo "  (brief Immich downtime; in-flight jobs are re-queued by BullMQ, not lost)"
run bash -c "cd $STACK && docker compose up -d immich-machine-learning immich-server"

# Land in whichever profile matches the wall clock.
hour=$(date +%-H)
# Night window is 23:30-08:00 (see immich-night-profile.timer for why 23:30).
if [ "$hour" -ge 23 ] || [ "$hour" -lt 8 ]; then prof=night; else prof=day; fi
echo "== setting initial profile: $prof =="
run "$BIN/immich-cpu-profile" "$prof"

echo
echo "Settling takes a while by design: the guard moves 0.25 cores at most every"
echo "2 min, so from the starting ceiling it needs ~10-15 min to find its level."
echo
echo "Watch it:    immich-cpu-profile status"
echo "Guard log:  journalctl -t immich-thermal-guard -n 20"
echo "Rollback:   sudo $SRC/install.sh --uninstall"
