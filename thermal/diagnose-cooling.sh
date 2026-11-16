#!/bin/bash
# Measure pihome's ACTUAL thermal resistance, to separate "bad SoC contact"
# from "high ambient". Run ON pihome:  sudo ./diagnose-cooling.sh
#
# It pauses Immich, lets the SoC settle to idle, then applies a bounded
# all-core load and watches the rise. Idle temp and dT/dW are what discriminate:
#
#   idle ~45-50 C, loaded ~65-70 C  -> cooling is FINE, look elsewhere
#   idle ~65-70 C, loaded 85 C      -> poor SoC contact (rise is steep from a high floor)
#   idle ~55-60 C, loaded ~75-80 C  -> high ambient, contact probably OK
#
# Immich is always restored, including on Ctrl-C or error.
set -uo pipefail

SETTLE=${SETTLE:-180}     # seconds to settle at idle
LOAD=${LOAD:-120}         # seconds of load
ABORT_AT=87.0             # bail out of the load phase above this

temp() { awk '{printf "%.1f", $1/1000}' /sys/class/thermal/thermal_zone0/temp; }
clk()  { vcgencmd measure_clock arm | cut -d= -f2 | awk '{printf "%.2f", $1/1e9}'; }
busy() { # average busy cores over $1 seconds
  local t1 i1 t2 i2
  t1=$(awk '/^cpu /{for(j=2;j<=NF;j++)s+=$j; print s}' /proc/stat)
  i1=$(awk '/^cpu /{print $5+$6}' /proc/stat); sleep "$1"
  t2=$(awk '/^cpu /{for(j=2;j<=NF;j++)s+=$j; print s}' /proc/stat)
  i2=$(awk '/^cpu /{print $5+$6}' /proc/stat)
  awk -v t="$((t2-t1))" -v d="$((i2-i1))" 'BEGIN{printf "%.2f", (t-d)/t*4}'
}

LOADPIDS=()
restore() {
  # Kill load generators by explicit PID. BUILD-LOG's own note: do NOT rely on
  # job control here, reparented children survive it.
  for p in "${LOADPIDS[@]:-}"; do [ -n "$p" ] && kill -9 "$p" 2>/dev/null; done
  echo
  echo "restoring Immich..."
  docker start immich_machine_learning immich_server >/dev/null 2>&1
  /usr/local/bin/immich-thermal-guard --apply-now >/dev/null 2>&1 || true
  echo "done. immich-cpu-profile status"
}
trap restore EXIT INT TERM

[ "$(id -u)" = 0 ] || { echo "needs root: sudo $0" >&2; exit 1; }

echo "=== 0. before (Immich running) ==="
printf '  temp=%s C  clk=%s GHz  busy=%s cores\n' "$(temp)" "$(clk)" "$(busy 10)"
printf '  fan=%s rpm  pmic=%s  nvme=%.1f C  \n' \
  "$(cat /sys/class/hwmon/hwmon3/fan1_input)" \
  "$(vcgencmd measure_temp pmic | cut -d= -f2)" \
  "$(awk '{print $1/1000}' /sys/class/hwmon/hwmon1/temp1_input)"

echo
echo "=== 1. pausing Immich, settling ${SETTLE}s to idle ==="
docker stop immich_machine_learning immich_server >/dev/null
for ((i=SETTLE; i>0; i-=30)); do sleep 30; printf '  t-%3ds  temp=%s C\n' "$i" "$(temp)"; done
IDLE=$(temp); IDLE_BUSY=$(busy 10)
printf '  IDLE: temp=%s C  busy=%s cores  pmic=%s  fan=%s rpm\n' \
  "$IDLE" "$IDLE_BUSY" "$(vcgencmd measure_temp pmic | cut -d= -f2)" \
  "$(cat /sys/class/hwmon/hwmon3/fan1_input)"

echo
echo "=== 2. all-core load for ${LOAD}s (aborts above ${ABORT_AT} C) ==="
for i in 1 2 3 4; do ( while :; do :; done ) & LOADPIDS+=($!); done
PEAK="$IDLE"
for ((i=0; i<LOAD; i+=15)); do
  sleep 15; t=$(temp)
  awk -v a="$t" -v b="$PEAK" 'BEGIN{exit !(a>b)}' && PEAK="$t"
  printf '  +%3ds  temp=%s C  clk=%s GHz\n' "$((i+15))" "$t" "$(clk)"
  if awk -v a="$t" -v b="$ABORT_AT" 'BEGIN{exit !(a>b)}'; then echo "  ABORT: over ${ABORT_AT} C"; break; fi
done
for p in "${LOADPIDS[@]}"; do kill -9 "$p" 2>/dev/null; done; LOADPIDS=()

echo
echo "=== 3. verdict ==="
printf '  idle   %s C\n  loaded %s C (peak)\n' "$IDLE" "$PEAK"
awk -v i="$IDLE" -v p="$PEAK" 'BEGIN{
  d=p-i
  printf "  rise under ~4 cores: %.1f C\n", d
  # Pi 5 SoC is roughly 3 W idle, 11 W all-core -> ~8 W delta.
  printf "  implied dT/dW: %.2f C/W  (healthy Pi 5 + active cooler: 1.5-2.5)\n", d/8
  print  ""
  if (i < 55)      print "  -> IDLE IS NORMAL. Cooling contact is fine; the earlier 82 C was real load. Re-check with the guard."
  else if (i > 62) printf "  -> IDLE IS %.0f C, ~15-20 C too high. Heat is not leaving the SoC even at ~3 W:\n     suspect pad COMPRESSION/thickness or case seating, not film. Also check ambient.\n", i
  else             print "  -> BORDERLINE idle. Most likely elevated ambient. Measure room/cabinet air temp."
  if (d/8 > 4)     print "  -> dT/dW is high too, which points at the interface rather than ambient."
  else if (d/8 < 2.5) print "  -> dT/dW is HEALTHY, so the interface conducts fine -> the high floor is AMBIENT."
}'
