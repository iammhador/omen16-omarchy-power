#!/bin/bash
# Let the NVIDIA dGPU runtime-suspend (D3cold) when nothing uses it.
#   sudo bash system/install-system.sh      then reboot
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo"; exit 1; }
cd "$(dirname "$0")"

# NVreg_DynamicPowerManagement=0x00 keeps the dGPU in D0 forever (~8-12 W).
# The driver default (0x03, fine-grained) is what we want, so drop any override.
for f in /etc/modprobe.d/*.conf; do
    if grep -q 'NVreg_DynamicPowerManagement' "$f"; then
        echo "Removing DynamicPowerManagement override from $f (backup in /root)"
        cp "$f" "/root/$(basename "$f").bak"
        sed -i '/NVreg_DynamicPowerManagement/d' "$f"
        [[ -s $f ]] || rm "$f"
    fi
done

# NVIDIA's recommended runtime PM udev rule (power/control=auto on bind)
install -m0644 80-nvidia-pm.rules /etc/udev/rules.d/80-nvidia-pm.rules

# modprobe.d is baked into the Limine UKI
limine-mkinitcpio

echo "Done. Reboot, then: cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status  (want: suspended)"
