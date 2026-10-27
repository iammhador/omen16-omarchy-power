#!/bin/bash
# Measure how much each battery tweak saves. Stages stack on top of each other.
# Run on battery, idle, hands off. Everything is restored at the end.
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo"; exit 1; }
[[ $(cat /sys/class/power_supply/ACAD/online) == 0 ]] || { echo "Unplug the charger first"; exit 1; }

CPU=/sys/devices/system/cpu
WIFI=wlo1
PPT=$(grep -l amdgpu /sys/class/hwmon/hwmon*/name | head -1 | xargs dirname)/power1_input
CCD1="8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31"
SETTLE=15
SAMPLE=40

restore() {
    echo 1 > $CPU/cpufreq/boost
    echo on > $CPU/smt/control 2>/dev/null
    for c in $CCD1; do echo 1 > $CPU/cpu$c/online 2>/dev/null; done
    iw dev $WIFI set power_save off 2>/dev/null
}
trap restore EXIT

measure() {
    local label=$1 bat=0 ppt=0 i
    sleep $SETTLE
    for ((i = 0; i < SAMPLE; i++)); do
        bat=$((bat + $(cat /sys/class/power_supply/BAT0/power_now)))
        ppt=$((ppt + $(cat "$PPT")))
        sleep 1
    done
    awk -v l="$label" -v b="$bat" -v p="$ppt" -v n=$SAMPLE \
        'BEGIN { printf "%-34s %6.1f W   %5.1f W\n", l, b / n / 1e6, p / n / 1e6 }'
}

echo "Measuring for about 6 minutes. Don't touch the laptop."
printf '%-34s %8s   %7s\n' "stage" "battery" "CPU pkg"

measure "1. baseline"

echo 0 > $CPU/cpufreq/boost
measure "2. + boost off"

iw dev $WIFI set power_save on
measure "3. + Wi-Fi power save"

for c in $CCD1; do echo 0 > $CPU/cpu$c/online; done
measure "4. + second CCD offline (8 cores)"

for c in $CCD1; do echo 1 > $CPU/cpu$c/online; done
echo off > $CPU/smt/control
measure "5. 16 cores, SMT off (instead of 4)"

echo off > $CPU/smt/control
for c in 8 9 10 11 12 13 14 15; do echo 0 > $CPU/cpu$c/online; done
measure "6. 8 cores, SMT off"

echo
echo "Done. All settings restored."
