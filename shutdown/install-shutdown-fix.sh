#!/bin/bash
# Install the omen_s5 shutdown fix (dGPU power rail off before S5) and the
# omen-drain battery ledger, from jacobdeanpugh/omen16-linux-fix at the commit
# that was reviewed. That repo's installer then fetches Adiakys/omen16-s5-fix at
# a pinned commit and refuses to build unless all 4 files match reviewed hashes.
#
#   sudo bash shutdown/install-shutdown-fix.sh
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo"; exit 1; }
[[ $(cat /sys/class/dmi/id/board_name) == 8E35 ]] || { echo "Board is not 8E35 (OMEN 16-ap0xxx). Stop."; exit 1; }

USER_HOME=$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)
FIX=$USER_HOME/omen16-linux-fix
COMMIT=e0de822

if [[ ! -d $FIX ]]; then
    sudo -u "${SUDO_USER:-root}" git clone https://github.com/jacobdeanpugh/omen16-linux-fix.git "$FIX"
fi
sudo -u "${SUDO_USER:-root}" git -C "$FIX" -c advice.detachedHead=false checkout "$COMMIT"
chmod +x "$FIX"/bin/*

echo "== Firmware check (all checks must PASS)"
"$FIX/bin/omen-acpi-check" "$USER_HOME/omen-acpi-dump"

echo "== Battery ledger"
"$FIX/bin/omen-drain" install

echo "== omen_s5 module (DKMS)"
"$FIX/bin/omen-s5-install"

"$FIX/bin/omen-status"
