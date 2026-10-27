# HP OMEN 16 (16-ap0xxx) on Omarchy: shutdown and battery fixes

How I got an **HP OMEN 16-ap0xxx** running Omarchy (Arch + Hyprland) to:

1. **actually turn off when shut down.** Before this, the screen went dark but the NVIDIA GPU stayed powered and drew about 20–30 W.
2. **use much less battery.** Draw went from **34.5 W to about 17 W** idle on battery, and to about 25 W with my everyday apps open, with music playing through EasyEffects.

Everything here was measured on the real machine, one change at a time. The things that were tried and *didn't* help are documented as well, so nobody has to try them again.

> **For Claude or another AI agent:** start with [`CLAUDE.md`](CLAUDE.md). It's the step-by-step runbook, with the checks to run before and after each step.

---

## Hardware this applies to

| Item | Value |
|---|---|
| Model | HP OMEN Gaming Laptop 16-ap0xxx, board **8E35** |
| BIOS | F.13 (2026-05-13) |
| CPU | AMD Ryzen 9 8945HX: 16 cores, 2 CCDs, desktop-class "Dragon Range/Fire Range" |
| iGPU | AMD Radeon 610M, PCI `0000:06:00.0`, `amdgpu`. **Drives the laptop panel (eDP-1).** |
| dGPU | NVIDIA RTX 5070 Laptop (GB206M), PCI `0000:01:00.0`, `nvidia-open`. **Drives the HDMI port.** |
| Panel | 2560×1600, 240 Hz or 60 Hz |
| OS | Omarchy: Hyprland (Lua config), Limine boot loader with a UKI, LUKS and btrfs, `linux-lts` and `linux-omarchy` kernels |
| Secure Boot | Off |

Check your own values before copying any paths:
```bash
cat /sys/class/dmi/id/board_name                 # must be 8E35 for the shutdown fix
lspci -D | grep -Ei 'vga|3d|display'              # PCI addresses of both GPUs
ls -l /dev/dri/by-path/                           # which renderD* belongs to which GPU
```
On this machine **`renderD128` is the NVIDIA GPU** and `renderD129` is the AMD GPU. Almost every "the dGPU won't sleep" problem below comes from that order.

---

## Part 1: The laptop doesn't power off

### Symptom
After `systemctl poweroff`, the screen goes off, but the fans, keyboard light and power LED stay on and the chassis gets warm. The battery drops about 6 % in 7 minutes while "off", roughly 25–30 W. The only way out was holding the power button.

### What it is *not*
- **It's not "Linux uses S3 instead of S5."** My old Fedora notes claimed that, but a Linux poweroff always asks the firmware for S5. The journal showed Linux shutting down cleanly, all the way to unmounting disks.
- **It's not ACPI wake sources.** I disabled every enabled entry in `/proc/acpi/wakeup` (GPP*, XHC0/1/2, PS2K, TAAD) right before poweroff, and nothing changed.
- **It's not the NVIDIA modules staying loaded.** A system-shutdown hook unloaded `nvidia_drm`, `nvidia_modeset`, `nvidia_uvm` and `nvidia` successfully, and nothing changed.
- The old **Windows workaround** (rEFInd boots Windows, which then shuts down cleanly) only works on dual-boot. This laptop runs Omarchy only.

### Root cause (HP firmware bug, board 8E35)
1. `pci_device_shutdown()` in the kernel runtime-resumes every PCI device before shutdown, which turns the dGPU back **on**.
2. HP's `_PTS(5)` (S5 preparation) has **no step that powers the dGPU off**. The firmware does contain the power-off code, `PEGP._PS3 → PG00._OFF`, but it only runs when the guard `OMPR == 3` is set and the NVIDIA driver has set `NVDE == 1`.

So the board reaches a fake S5 with the dGPU power rail still on.

### Fix: the `omen_s5` kernel module
I used [jacobdeanpugh/omen16-linux-fix](https://github.com/jacobdeanpugh/omen16-linux-fix), which wraps [Adiakys/omen16-s5-fix](https://github.com/Adiakys/omen16-s5-fix). It's a small DKMS module that:
- loads a 211-byte SSDT with one method, `\OS5F`, which sets `OMPR = 3` and then calls `PEGP._PS3()`
- registers a power-off-prepare handler at priority 192, so it runs right after ACPI's `_PTS(5)` (priority 224)

It uses HP's own power-off code, and it does nothing on reboot. It doesn't flash the BIOS or touch the boot loader. Uninstalling it means the next boot is stock.

I reviewed everything before installing it:
- the module C source (about 70 lines)
- the SSDT bytes: 211 bytes, valid checksum, and they reference only `PEGP.OMPR` and `PEGP._PS3`
- all four helper scripts
- the upstream pinned commit `13740806`, whose 4 files match the hashes pinned in the installer

```bash
sudo bash shutdown/install-shutdown-fix.sh
```
On success it prints `omen_s5: ready: dGPU will be powered off before S5`. It needs the **NVIDIA proprietary or open driver loaded**; with nouveau it does nothing.

### Verify
```bash
~/omen16-linux-fix/bin/omen-status          # module loaded?
# Unplug the charger, then run systemctl poweroff, wait 1 hour or more, boot:
~/omen16-linux-fix/bin/omen-drain report    # ≤ 3 W = really off, ≥ 8 W = dGPU still powered
```
After a BIOS update, run `sudo ~/omen16-linux-fix/bin/omen-acpi-check` again.

---

## Part 2: Battery draw (34.5 W → about 17 W idle)

All numbers are on battery with brightness at 50 %, measured with `bin/watts` (an average of `BAT0/power_now`).

| # | Change | Before → after | How |
|---|---|---|---|
| 1 | **Let the NVIDIA dGPU sleep (D3cold)** | about −8 to −12 W | `system/install-system.sh` |
| 2 | **60 Hz on battery**, 240 Hz on AC | about −4 W | `user/refresh-by-power` (user service) |
| 3 | **Power-saver profile on battery** (power-profiles-daemon also turns CPU boost off) | about −1 W for the profile, about −3 W for boost off | `omarchy-powerprofiles-set battery power-saver` |
| 4 | **Stop everyday apps from waking the dGPU** (Zen, WhatsApp/whatsie, voxtype, mpv) | prevents jumps back to 30–35 W | `user/igpu-run`, `user/zen-igpu`, desktop overrides |

### 1. The dGPU was never allowed to sleep
`/etc/modprobe.d/nvidia-pm.conf` contained `options nvidia NVreg_DynamicPowerManagement=0x00`. I'd added it during an earlier attempt to fix shutdown, and it didn't help with that. It pins the GPU in **D0**: nvidia-smi showed 7.6 W at 0 % load, plus the VRAM and PCIe rails, even though the panel runs on the AMD iGPU.

Fix:
- remove that option, so the driver default `0x03` (fine-grained runtime D3) applies
- add NVIDIA's udev rule ([`system/80-nvidia-pm.rules`](system/80-nvidia-pm.rules)), which sets `power/control=auto` on bind
- rebuild the UKI with `limine-mkinitcpio`, because modprobe.d is baked into it

Check:
```bash
cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status   # suspended
cat /sys/bus/pci/devices/0000:01:00.0/power_state            # D3cold
```
**Don't check with `nvidia-smi`**, because it wakes the GPU.

### 2. 240 Hz panel
The panel at 240 Hz costs about 4 W more than at 60 Hz. [`user/refresh-by-power`](user/refresh-by-power):
- watches UPower's `OnBattery`, the same signal the Omarchy shell uses
- re-applies `eDP-1` with the same resolution, position and scale at `@60` or `@240`, using `hyprctl eval 'hl.monitor({...})'`
- runs as the `refresh-by-power.service` user unit, `WantedBy=graphical-session.target`
- applies the right rate once when it starts, so booting on battery comes up at 60 Hz

### 3. Power profile and CPU boost
Without a saved choice, Omarchy uses `balanced` on battery. `omarchy-powerprofiles-set battery power-saver` saves `power-saver` for battery, and the Omarchy shell (`shell/plugins/services/battery/Service.qml`) re-applies it on every unplug. On AC it uses `performance`.

**power-profiles-daemon 0.30 turns CPU boost off in power-saver by itself**, per cpufreq policy, which gives the measured −3 W.

> ⚠️ **Don't write `/sys/devices/system/cpu/cpufreq/boost` yourself.** I tried a udev rule that set global boost to 0 on unplug. power-profiles-daemon then fails with `Error writing '/sys/devices/system/cpu/cpufreq/policy11/boost': Invalid argument`, and it **gets stuck in `performance` on battery**, which measured 29.6 W instead of about 17 W. It's been removed.

### 4. Apps that kept waking the dGPU (the jump back to 35 W)
With items 1–3 done, idle was about 17 W, but normal use jumped back to 35 W because `runtime_status` went `active`. I found the causes with [`bin/gpu-watch`](bin/gpu-watch), which logs every dGPU state change and the processes holding `/dev/nvidia*` or `renderD128`. There are three separate ways an app wakes the dGPU:

| Mechanism | Who | Fix |
|---|---|---|
| **VA-API/DMABuf picks the first render node.** `renderD128` is the NVIDIA GPU. | Zen's `rdd` (video decode) process, mpv | `MOZ_DRM_DEVICE=/dev/dri/by-path/pci-0000:06:00.0-render` for Firefox/Zen; `vaapi-device=` for mpv |
| **glvnd loads NVIDIA's EGL.** `10_nvidia.json` takes priority over Mesa, and just loading `libEGL_nvidia` opens `/dev/nvidia0`. | Zen, whatsie (QtWebEngine), voxtype OSD | `__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json` |
| **The Vulkan loader enumerates every GPU.** Picking the AMD device doesn't help; enumerating alone wakes the NVIDIA GPU. | mpv's `gpu-next`, GTK4 apps (default renderer) | mpv `gpu-api=opengl`; GTK4 `GSK_RENDERER=ngl` |

Applied **per app**, not globally, so Lutris and Steam games and the HDMI port can still use the NVIDIA GPU:
- [`user/igpu-run`](user/igpu-run): a generic wrapper that sets all three variables. whatsie uses it through `~/.local/share/applications/com.ktechpit.whatsie.desktop`.
- [`user/zen-igpu`](user/zen-igpu): Zen's wrapper. A user copy of `zen.desktop` points its `Exec=` at it. Omarchy's `omarchy-launch-browser` reads the first word of `Exec=`, so this has to be a wrapper script; an `env …` prefix won't work.
- [`user/systemd/voxtype-igpu.conf`](user/systemd/voxtype-igpu.conf): a drop-in for `voxtype.service`.
- [`user/mpv/mpv.conf`](user/mpv/mpv.conf): `hwdec=vaapi`, `vaapi-device=<iGPU node>`, `gpu-api=opengl`.

What I verified:
- With all of this in place, Zen playing H.264 shows `FFmpegVideoDecoder … IsHardwareAccelerated=true` and `VA-API frame` lines in `MOZ_LOG`, so it **decodes in hardware on the AMD GPU**.
- The dGPU stays in `D3cold` throughout.
- Hyprland still holds `/dev/nvidia0`, because it drives the HDMI connector. That's fine: an open file doesn't stop the GPU from suspending; only active use does.

> Desktop overrides in `~/.local/share/applications/` don't pick up package updates to the original `.desktop` files. If Zen or whatsie launch oddly after an update, re-run `user/install-user.sh`.

### Things that were measured and *not* worth it
Measured with [`bin/measure-tweaks.sh`](bin/measure-tweaks.sh); stages stack, idle on battery, starting from 19.8 W:

| Tweak | Saving | Verdict |
|---|---|---|
| CPU boost off | **−3.0 W** | Kept, through power-profiles-daemon's power-saver |
| Wi-Fi power save (`iw … power_save on`) | −0.1 W | Not worth the latency. Omarchy turns it off on purpose. |
| Second CCD offline (8 cores) | 0 W | Idle Zen 4 cores already sit in CC6 |
| SMT off | −0.3 W | Noise |
| PCIe ASPM `powersupersave` | n/a | Not possible: `ACPI FADT declares the system doesn't support PCIe ASPM`. Forcing it with `pcie_aspm=force` risks hangs. |

### What's left (about 25 W in real use)
- **Base, about 16–17 W:** the panel at 50 % plus a desktop-class 16-core CPU whose package idles at about 9 W. Mobile APUs idle at 1–2 W.
- Spotify plus EasyEffects (always running, by choice) add about 3–5 W.
- The Omarchy bar (quickshell plugins) adds about 1 W, and open browsers about 2–3 W.
- Brightness is the biggest remaining lever: going to about 30 % saves 2–3 W.
- **EasyEffects and qBittorrent stay running on purpose.** Don't "optimise" them away.

---

## Install on a fresh Omarchy
```bash
git clone https://github.com/iammhador/omen16-omarchy-power.git
cd omen16-omarchy-power

sudo bash shutdown/install-shutdown-fix.sh   # Part 1: real poweroff
sudo bash system/install-system.sh           # dGPU runtime D3
bash user/install-user.sh                    # 60 Hz on battery, power-saver, apps pinned to iGPU
reboot
```
Then follow the checks in [`CLAUDE.md`](CLAUDE.md#verify-everything).

## Tools in `bin/`
| Script | What it does |
|---|---|
| `watts [secs]` | Average battery draw. Must be unplugged. |
| `gpu-watch [secs]` | Logs dGPU state changes and **which processes hold it** at each wake. This is the main debugging tool. |
| `measure-tweaks.sh` | Root. Measures CPU-side tweaks one by one, then restores everything. |

## Undo
```bash
sudo ~/omen16-linux-fix/bin/omen-s5-install uninstall      # stays active until reboot
sudo ~/omen16-linux-fix/bin/omen-drain uninstall
sudo rm /etc/udev/rules.d/80-nvidia-pm.rules && sudo limine-mkinitcpio
systemctl --user disable --now refresh-by-power
rm ~/.local/share/applications/{zen,com.ktechpit.whatsie}.desktop \
   ~/.config/systemd/user/voxtype.service.d/igpu.conf
```

## Credits and sources
- [Adiakys/omen16-s5-fix](https://github.com/Adiakys/omen16-s5-fix): the `omen_s5` module
- [jacobdeanpugh/omen16-linux-fix](https://github.com/jacobdeanpugh/omen16-linux-fix): Arch/Omarchy installer, ACPI check, battery ledger
- [paolo-de-marinis/omen-acpi](https://github.com/paolo-de-marinis/omen-acpi): original `_PTS → PEGP._PS3 → PG00._OFF` analysis
- [omarchy-asus#26](https://github.com/omarchy-asus/omarchy-asus/issues/26): hybrid VA-API pinned to the iGPU (render-node order)
- [NVIDIA forum: OMEN 16 battery drains after shutdown](https://forums.developer.nvidia.com/t/hp-omen-16-rtx-5060-battery-drains-after-shutdown-on-linux-gps-acpi-dsm-bug/364074)
- [NVIDIA driver README: Dynamic Power Management](https://download.nvidia.com/XFree86/Linux-x86_64/latest/README/dynamicpowermanagement.html)
