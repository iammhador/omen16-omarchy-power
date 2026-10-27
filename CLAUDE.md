# Runbook for Claude: HP OMEN 16-ap0xxx (8E35) on Omarchy

You're helping the owner restore the shutdown and battery fixes after a reinstall. [`README.md`](README.md) explains why each fix exists; this file is the procedure. Follow it in order, **check before each change**, and **measure after each one**.

## Rules from past sessions (don't relearn these the hard way)
- The user's sudo password can't be typed through Claude's `!` prefix. Give root steps as a command for the user to run **in their own terminal**, then verify the result yourself.
- **Never write `/sys/devices/system/cpu/cpufreq/boost`.** power-profiles-daemon manages boost for each CPU policy. A global write makes it fail with `EINVAL` and leaves it stuck in `performance` on battery.
- **Never check the dGPU with `nvidia-smi`**, because it wakes the GPU. Read `/sys/bus/pci/devices/0000:01:00.0/power/{runtime_status}` and `.../power_state` instead.
- **EasyEffects and qBittorrent must always run.** Don't disable them or suggest bypassing them for battery.
- Docker's `awi-postgres` container autostarts. Leave `docker.service` enabled; don't switch it to socket activation.
- Don't block NVIDIA globally (EGL, Vulkan or env vars in Hyprland). HDMI is wired to the dGPU, and games need it. Pin **individual apps** with `user/igpu-run`.
- Don't edit `/usr/share/omarchy/`. User config goes in `~/.config`, and desktop overrides go in `~/.local/share/applications`.
- Read any third-party repo **before** running it as root.

## 0. Confirm it's the same machine
```bash
cat /sys/class/dmi/id/{board_name,bios_version}   # 8E35, F.13 (re-check the ACPI step if the BIOS is newer)
lspci -D | grep -Ei 'vga|3d'                      # NVIDIA 0000:01:00.0, AMD 0000:06:00.0
ls -l /dev/dri/by-path/                           # note which renderD is which
bootctl status | grep Product                     # Limine
```
If any PCI address differs, update `system/80-nvidia-pm.rules` (it isn't address-specific), `user/igpu-run`, `user/zen-igpu` and `user/mpv/mpv.conf` (these contain `pci-0000:06:00.0-render`), and the dGPU path used in `bin/gpu-watch`.

## 1. Shutdown fix
1. Have the user run `sudo bash shutdown/install-shutdown-fix.sh`. The `omen-acpi-check` step must show **all PASS**. If anything FAILs, stop and read the dump.
2. Verify: `ls -d /sys/module/omen_s5` and `journalctl -k -b -g omen_s5` should show `ready`.
3. Real test: unplug, shut down, leave it off for at least 1 hour, then run `~/omen16-linux-fix/bin/omen-drain report`, which should say `OK: really off`.

## 2. dGPU runtime D3
1. Look for a DPM override: `grep -r NVreg_DynamicPowerManagement /etc/modprobe.d/`. The value `0x00` is the bug.
2. Have the user run `sudo bash system/install-system.sh`, then reboot.
3. Verify:
   - `grep DynamicPowerManagement: /proc/driver/nvidia/params` shows `3`
   - `runtime_status` shows `suspended`
   - `power_state` shows `D3cold`

## 3. User settings
1. Run `bash user/install-user.sh` (no sudo; you can run this yourself).
2. Verify:
   - `systemctl --user is-active refresh-by-power` shows `active`
   - `cat ~/.local/state/omarchy/powerprofiles/battery` shows `power-saver`
   - `grep ^Exec ~/.local/share/applications/zen.desktop` points at `zen-igpu`
3. Restart Zen and whatsie, and check that their processes have the variables (`/proc/<pid>/environ` should contain `__EGL_VENDOR_LIBRARY_FILENAMES`).

## Verify everything
On battery:
```bash
echo "boost=$(cat /sys/devices/system/cpu/cpufreq/policy0/boost) profile=$(powerprofilesctl get)"   # 0, power-saver
hyprctl monitors | grep -E '^\s+[0-9]+x[0-9]+@'                                                    # @60
cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status                                         # suspended
bin/gpu-watch 120 &  bin/watts 60        # use the apps normally meanwhile
```
Expected:
- idle with nothing open: **about 17 W**
- typical (Zen, Spotify, EasyEffects, whatsie): **about 25 W**
- if the dGPU is `active`: **about 30–35 W**, which means something is waking it

Plugged in, it should switch back to `performance` and 240 Hz.

## If the dGPU keeps waking up
1. Run `bin/gpu-watch 120` while the user reproduces it. Each `active` line lists the processes holding `/dev/nvidia*` or `renderD128`.
2. For each new process, check how it touches the GPU:
   ```bash
   p=<pid>; ls -l /proc/$p/fd | grep -oE '/dev/(nvidia[^ ]*|dri/[^ ]+)' | sort | uniq -c
   grep -cE 'libEGL_nvidia' /proc/$p/maps            # NVIDIA EGL loaded
   grep -cE 'libnvidia-glvkspirv' /proc/$p/maps      # NVIDIA Vulkan loaded
   ```
3. Fix it **per app**:
   - start it through `~/.local/bin/igpu-run <cmd>`, with a desktop override (copy the system `.desktop` and prefix `Exec=`) or a systemd user drop-in (`Environment=` lines)
   - Chromium-family browsers (Brave, Chromium) also accept `--render-node-override=/dev/dri/by-path/pci-0000:06:00.0-render` in `~/.config/<browser>-flags.conf`
   - for mpv-style Vulkan renderers, switch to OpenGL
4. Confirm the dGPU gets back to `D3cold` within a few seconds, and re-measure.

An open file alone doesn't keep the dGPU awake; Hyprland holds `/dev/nvidia0` for HDMI and it still suspends. Only processes that **actively** use it matter.
