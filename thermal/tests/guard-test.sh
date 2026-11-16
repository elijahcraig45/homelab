#!/bin/bash
# Exercise immich-thermal-guard's control loop off-box with a stubbed docker.
# Usage: tests/guard-test.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GUARD="$HERE/../immich-thermal-guard"
T=$(mktemp -d)
export STUB_STATE="$T/stub"
export IMMICH_GUARD_STATEDIR="$T/state"
export IMMICH_GUARD_TEMPFILE="$T/temp"
export IMMICH_GUARD_SWAPS="$T/swaps"
export IMMICH_GUARD_DOCKER="$HERE/docker-stub"
export IMMICH_GUARD_NTFY="$T/ntfy-stub"
export IMMICH_GUARD_CONF="$T/conf"
mkdir -p "$STUB_STATE" "$IMMICH_GUARD_STATEDIR"
printf '#!/bin/bash\necho "NTFY: $1" >> '"$T"'/ntfy.log\n' > "$T/ntfy-stub"; chmod +x "$T/ntfy-stub"

# Mirrors the shipped immich-thermal.conf defaults.
conf() { cat > "$T/conf" <<C
HOT=${1:-76.0}
COOL=${2:-70.0}
STEP=0.25
HOT_STREAK_NEEDED=2
DAY_ML=0.6
DAY_SRV=1.2
NIGHT_ML=1.2
NIGHT_SRV=0.6
ML_FLOOR=0.25
SRV_FLOOR=0.50
CPUSET="0-2"
SWAP_WARN_MIB=192
SWAP_CLEAR_MIB=384
C
}

fails=0
setswap() { printf 'Filename\tType\tSize\tUsed\tPriority\n/dev/zram0 partition %s %s 100\n' "$1" "$2" > "$T/swaps"; }
settemp() { awk -v c="$1" 'BEGIN{printf "%d", c*1000}' > "$T/temp"; }
cpus()    { awk -v n="$(cat "$STUB_STATE/$1.nanocpus")" 'BEGIN{printf "%.2f", n/1e9}'; }
total()   { awk -v a="$(cpus immich_machine_learning)" -v b="$(cpus immich_server)" 'BEGIN{printf "%.2f", a+b}'; }
reset()   { rm -rf "$IMMICH_GUARD_STATEDIR" "$STUB_STATE"; mkdir -p "$IMMICH_GUARD_STATEDIR" "$STUB_STATE"
            echo 0 > "$STUB_STATE/immich_machine_learning.nanocpus"
            echo 0 > "$STUB_STATE/immich_server.nanocpus"; }
want()    { local label="$1" got="$2" exp="$3"
            if [ "$got" = "$exp" ]; then printf '  ok   %-40s %s\n' "$label" "$got"
            else printf '  FAIL %-40s got=%s want=%s\n' "$label" "$got" "$exp"; fails=$((fails+1)); fi; }
tick()    { settemp "$1"; "$GUARD" >/dev/null 2>&1; }
hot2()    { tick "$1"; tick "$1"; }   # two samples = one adjustment

conf; setswap 2097136 1000000

echo "== the property the fixed-quota design lacked: it can reach a cool state =="
reset; echo day > "$IMMICH_GUARD_STATEDIR/profile"
tick 80;  want "1st hot sample only arms the streak" "$(cpus immich_machine_learning)" "0.60"
tick 80;  want "2nd hot sample trims ml"             "$(cpus immich_machine_learning)" "0.35"
hot2 80;  want "ml reaches its floor"                "$(cpus immich_machine_learning)" "0.25"
want      "server untouched while ml had room"       "$(cpus immich_server)"           "1.20"
hot2 80;  want "then server trims"                   "$(cpus immich_server)"           "0.95"
hot2 80;  hot2 80
want      "server reaches its floor"                 "$(cpus immich_server)"           "0.50"
want      "total floor = 0.75 cores (was 2.20)"      "$(total)"                        "0.75"

echo "== day restores server first (thumbnails gate every other queue) =="
tick 65;  want "restore server"                      "$(cpus immich_server)"           "0.75"
tick 65;  tick 65
want      "server back to its ceiling"               "$(cpus immich_server)"           "1.20"
tick 65;  want "only then restore ml"                "$(cpus immich_machine_learning)" "0.50"
tick 65;  want "ml clamped at its ceiling"           "$(cpus immich_machine_learning)" "0.60"
tick 65;  want "no overshoot past ceiling"           "$(total)"                        "1.80"

echo "== night inverts the priority =="
reset; echo night > "$IMMICH_GUARD_STATEDIR/profile"
hot2 80;  want "night trims server first"            "$(cpus immich_server)"           "0.50"
want      "night leaves ml at its ceiling"           "$(cpus immich_machine_learning)" "1.20"
hot2 80;  want "then night trims ml"                 "$(cpus immich_machine_learning)" "0.95"
tick 65;  want "night restores ml first"             "$(cpus immich_machine_learning)" "1.20"

echo "== HOT is the knob: it is read from the conf, not baked in =="
conf 60.0 55.0; reset; echo day > "$IMMICH_GUARD_STATEDIR/profile"
hot2 65;  want "HOT=60 trims at 65 C"                "$(cpus immich_machine_learning)" "0.35"
conf 76.0 70.0; reset; echo day > "$IMMICH_GUARD_STATEDIR/profile"
hot2 65;  want "HOT=76 does not trim at 65 C"        "$(cpus immich_machine_learning)" "0.60"

echo "== hysteresis band holds steady =="
reset; echo day > "$IMMICH_GUARD_STATEDIR/profile"
tick 73; tick 73; tick 73
want      "73 C is between COOL and HOT: ml held"    "$(cpus immich_machine_learning)" "0.60"
want      "73 C: server held"                        "$(cpus immich_server)"           "1.20"

echo "== both floors + still hot -> alert once, not every cycle =="
reset; echo day > "$IMMICH_GUARD_STATEDIR/profile"; rm -f "$T/ntfy.log"
for i in $(seq 1 30); do tick 90; done
want      "ml floored"                               "$(cpus immich_machine_learning)" "0.25"
want      "server floored"                           "$(cpus immich_server)"           "0.50"
want      "floor alert fired exactly once"           "$(grep -c 'still hot' "$T/ntfy.log" 2>/dev/null || echo 0)" "1"

echo "== swap headroom alert latches and re-arms =="
reset; echo day > "$IMMICH_GUARD_STATEDIR/profile"; rm -f "$T/ntfy.log"
setswap 2097136 1958256   # the real observed state: ~135 MiB free
tick 73;  want "alert at 135 MiB free"               "$(grep -c 'swap nearly' "$T/ntfy.log" 2>/dev/null || echo 0)" "1"
tick 73;  want "latched, not spammed"                "$(grep -c 'swap nearly' "$T/ntfy.log" 2>/dev/null || echo 0)" "1"
setswap 2097136 1000000; tick 73; rm -f "$T/ntfy.log"
setswap 2097136 1958256; tick 73
want      "re-arms after recovery"                   "$(grep -c 'swap nearly' "$T/ntfy.log" 2>/dev/null || echo 0)" "1"

echo "== ML stopped: its budget goes to thumbnails, not wasted on a dead container =="
reset; echo day > "$IMMICH_GUARD_STATEDIR/profile"
touch "$STUB_STATE/immich_machine_learning.stopped"
tick 73;  want "server gets the whole 1.8 budget"    "$(cpus immich_server)"           "1.80"
want      "stopped ml is left alone at 0"            "$(cpus immich_machine_learning)" "0.00"
hot2 80;  want "hot: trims server (not dead ml)"     "$(cpus immich_server)"           "1.55"
hot2 80;  want "keeps trimming server"               "$(cpus immich_server)"           "1.30"
tick 65;  want "cool: restores server"               "$(cpus immich_server)"           "1.55"
want      "ml still untouched"                       "$(cpus immich_machine_learning)" "0.00"
rm -f "$STUB_STATE/immich_machine_learning.stopped"

echo "== server stopped: budget goes to ML (symmetric) =="
reset; echo day > "$IMMICH_GUARD_STATEDIR/profile"
touch "$STUB_STATE/immich_server.stopped"
tick 73;  want "ml gets the whole 1.8 budget"        "$(cpus immich_machine_learning)" "1.80"
hot2 80;  want "hot: trims ml"                       "$(cpus immich_machine_learning)" "1.55"
rm -f "$STUB_STATE/immich_server.stopped"

echo "== stack down is a clean no-op =="
reset; echo day > "$IMMICH_GUARD_STATEDIR/profile"; setswap 2097136 1000000
settemp 80; IMMICH_GUARD_DOCKER=/usr/bin/false "$GUARD" >/dev/null 2>&1
want      "exit 0 when containers absent"            "$?" "0"

rm -rf "$T"
echo
if [ "$fails" = 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
