#!/bin/bash
# Per-user battery settings. Run as your normal user (no sudo):
#   bash user/install-user.sh
set -euo pipefail
cd "$(dirname "$0")"
[[ $EUID -ne 0 ]] || { echo "Run as your normal user, not root"; exit 1; }

BIN=$HOME/.local/bin
APPS=$HOME/.local/share/applications
mkdir -p "$BIN" "$APPS" "$HOME/.config/systemd/user/voxtype.service.d" "$HOME/.config/mpv"

# Wrappers that keep apps on the AMD iGPU
install -m0755 igpu-run zen-igpu refresh-by-power "$BIN/"

# 60 Hz on battery / 240 Hz on AC
install -m0644 systemd/refresh-by-power.service "$HOME/.config/systemd/user/"

# voxtype OSD (GTK4) off the dGPU
install -m0644 systemd/voxtype-igpu.conf "$HOME/.config/systemd/user/voxtype.service.d/igpu.conf"

# mpv: decode on the iGPU, render with OpenGL (Vulkan wakes the dGPU)
if [[ -f $HOME/.config/mpv/mpv.conf ]] && ! grep -q vaapi-device "$HOME/.config/mpv/mpv.conf"; then
    cat mpv/mpv.conf >> "$HOME/.config/mpv/mpv.conf"
elif [[ ! -f $HOME/.config/mpv/mpv.conf ]]; then
    install -m0644 mpv/mpv.conf "$HOME/.config/mpv/mpv.conf"
fi

# Desktop overrides: same as the packaged launchers, started through a wrapper
if [[ -f /usr/share/applications/zen.desktop ]]; then
    sed "s#^Exec=/opt/zen-browser-bin/zen-bin#Exec=$BIN/zen-igpu#" \
        /usr/share/applications/zen.desktop > "$APPS/zen.desktop"
fi
if [[ -f /usr/share/applications/com.ktechpit.whatsie.desktop ]]; then
    sed "s#^Exec=whatsie#Exec=$BIN/igpu-run whatsie#" \
        /usr/share/applications/com.ktechpit.whatsie.desktop > "$APPS/com.ktechpit.whatsie.desktop"
fi
update-desktop-database "$APPS" 2>/dev/null || true

systemctl --user daemon-reload
systemctl --user enable --now refresh-by-power.service
systemctl --user try-restart voxtype.service || true

# Power-saver on battery. Omarchy remembers it and re-applies it on every unplug.
# power-profiles-daemon turns CPU boost off in power-saver by itself.
omarchy-powerprofiles-set battery power-saver
omarchy-powerprofiles-set autodetect

echo "Done. Restart Zen and whatsie so they start through the wrappers."
