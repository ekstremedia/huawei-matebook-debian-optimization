# Huawei MateBook X Pro 2020 on Debian 13: drivers and optimization

Findings, measurements and scripts from setting up a **Huawei MateBook X Pro 2020 (`MACHC-WAX9`)** on **Debian 13 "trixie"**. The goal was simple: every piece of hardware working, and the machine as fast, cool and battery-efficient as possible.

On a stock install, most hardware works. Two things don't:

- **Audio:** only 2 of the 4 speakers play, and the headset mic doesn't work.
- **NVIDIA MX250:** the GPU can never power down, so the CPU can't reach its deep sleep states at idle.

Both are fixable without custom kernels or third-party drivers. This repo explains why each problem happens, how it was diagnosed, and gives scripts that apply and verify the fixes.

## Results

Measured idle (60 s, screen on, no user activity), before and after:

| Metric | Stock Debian 13 + NVIDIA driver | After this repo |
|---|---|---|
| CPU package deep idle (PC8–PC10) | **0 %** (stuck in PC2/PC3) | **88 %** (PC10 61 %) |
| CPU package power (RAPL) | 1.50 W | **0.26 W** |
| Whole-laptop idle drain (battery) | not measured (was on AC) | **2.7 W, ≈18 h idle** on the 52 Wh battery |
| Speakers | 2 of 4 | **4 of 4** |
| Headset microphone (3.5 mm jack) | not detected | **works** |
| Boot, userspace part | 14.9 s | **8.9 s** |
| Desktop session | X11 (forced by the NVIDIA driver) | **Wayland** |
| Kernel taint / Secure Boot | tainted (proprietary module) / off | **clean / on** |

---

## Contents

- [Hardware](#hardware)
- [Driver status on a stock install](#driver-status-on-a-stock-install)
- [Findings explained](#findings-explained)
- [The scripts](#the-scripts)
- [Quick start](#quick-start)
- [Choices made and things deliberately not done](#choices-made-and-things-deliberately-not-done)
- [Reverting](#reverting)
- [FAQ](#faq)
- [Other MateBook models](#other-matebook-models)
- [References](#references)

---

## Hardware

| Component | Details |
|---|---|
| Model | Huawei MateBook X Pro 2020, `MACHC-WAX9` (built by the ODM Huaqin, PCI subsystem vendor `1e83`) |
| BIOS | 1.26 (2023-03-09); no updates on LVFS/fwupd |
| CPU | Intel Core i7-10510U (Comet Lake-U, 4C/8T, up to 4.9 GHz). CPUID `06-8e-0c` (Kaby Lake model number + Cannon Point PCH) |
| iGPU | Intel UHD Graphics (CometLake-U GT2, Gen 9.5) |
| dGPU | NVIDIA GeForce MX250 2 GB (GP108, **Pascal**), Optimus: no display outputs wired to it |
| Display | 13.9" 3000×2000 (3:2) touchscreen, PSR2-capable eDP panel |
| Storage | Samsung PM981 NVMe 1 TB |
| Wi-Fi / BT | Intel Wireless-AC 9560 160 MHz (CNVi) + Bluetooth (USB `8087:0aaa`) |
| Audio | Intel cAVS (HDA mode) + Realtek **ALC256**, codec subsystem `1e83:3223`, 4 speakers, digital mic on the codec |
| Input | Synaptics I2C touchpad (`SYNA2393`), I2C touchscreen (`HQTL2393`) |
| Camera | Foxlink pop-up UVC camera (`05c8:03c0`) |
| Thunderbolt | Intel JHL7540 Titan Ridge (TB3) |
| Sensors | ACPI ambient light sensor, Intel DPTF thermal tables, ACPI fan |
| Other | TPM 2.0 (Intel PTT), Goodix fingerprint reader `GXFP51B7` in the power button |

## Driver status on a stock install

| Component | Driver | Stock status |
|---|---|---|
| Intel graphics | `i915` | ✅ DMC firmware, PSR2 and FBC enabled |
| NVIDIA MX250 | `nvidia` 550 (Debian non-free) | ⚠️ works, but **never powers down** (see F1) |
| Wi-Fi | `iwlwifi` | ✅ firmware `QuZ-a0-jf-b0-77`, 160 MHz |
| Bluetooth | `btusb`/`btintel` | ✅ |
| Speakers | `snd_hda_intel` + Realtek | ⚠️ **only 2 of 4** (see F2) |
| Internal mic | `snd_hda_intel` | ✅ |
| Headset mic | `snd_hda_intel` | ❌ **not configured** (see F2) |
| HDMI/DP audio | `snd_hda_intel` | ✅ |
| Camera | `uvcvideo` | ✅ |
| Touchpad / touchscreen | `i2c_hid` + `hid_multitouch` | ✅ |
| Hotkeys, mic-mute LED, Fn-lock, charge limit | `huawei_wmi` | ✅ (mic-mute LED fixed by F2) |
| Backlight | `intel_backlight` | ✅ |
| Ambient light sensor | `acpi-als` + iio-sensor-proxy | ✅ GNOME auto-brightness works |
| Thunderbolt 3 | `thunderbolt` + bolt | ✅ |
| NVMe | `nvme` | ✅ APST + ASPM L1.2 |
| Fingerprint reader | — | ❌ **no Linux driver** (Goodix sensor not on USB; libfprint can't use it) |
| Microcode | `intel-microcode` | ✅ revision `0x100` (latest) |

---

## Findings explained

### F1. The NVIDIA MX250 keeps the whole laptop out of deep idle

**Symptom.** With the proprietary NVIDIA driver loaded, the CPU package spends ~80 % of idle time in PC3 and **0 % in PC6–PC10**. RAPL shows 1.5 W package power at idle, and the i915 display engine never reaches DC6.

**Why.**
1. NVIDIA's driver can only power a GPU off at runtime (*RTD3*, "Runtime D3") on **Turing or newer**. The MX250 is Pascal. `/proc/driver/nvidia/gpus/*/power` says `Runtime D3 status: Disabled by default` and `Video Memory Off: Not Supported`. With the driver loaded, the card sits in P8 at PCI power state D0 forever.
2. The BIOS reports the dGPU's root port (00:1c.0) as `ASPM not supported`, so its PCIe link can't drop into a low-power state either. An always-active PCIe link stops the platform from entering package C8/C9/C10.
3. Xorg also opens the NVIDIA device (PRIME offload provider `NVIDIA-G0`).

**The way out.** Windows doesn't keep the GPU in D0; it cuts its power through ACPI. Linux can do the same once **no driver is bound**:

```
GPU ACPI node      \_SB_.PCI0.RP05.PXSX   -> no power resources of its own
Root port node     \_SB_.PCI0.RP05        -> _PR0/_PR2/_PR3 = LNXPOWER:01
LNXPOWER:01 is referenced only by RP05
```

When the driverless GPU is allowed to runtime-suspend (`power/control=auto`), the PCI core lets its parent root port suspend. Because the port has `_PR3`, the kernel picks **D3cold** and switches `LNXPOWER:01` off, cutting power to the GPU slot.

Verified after the change:

```
$ cat /sys/bus/pci/devices/0000:00:1c.0/power_state                 -> D3cold
$ cat /sys/bus/acpi/devices/LNXPOWER:01/resource_in_use             -> 0
```

Result: PC10 61 %, package power 0.26 W, 2.7 W whole-laptop idle.

**Trade-off.** You lose the MX250. It is an entry-level chip, roughly 2–3× the iGPU in 3D, with 2 GB VRAM. It's only useful for light gaming or small CUDA tests; desktop work, browsers and video don't need it. See the [FAQ](#faq) for getting it back.

### F2. Only 2 of 4 speakers work, and the headset mic is missing

**Symptom.** The sound is thin, and the kernel log shows:

```
autoconfig for ALC256: line_outs=1 (0x1b/0x0/0x0/0x0/0x0) type:speaker
inputs: Mic=0x12
```

**Why.** The BIOS pin table on the ALC256 declares only pin `0x1b` as a speaker. Pin `0x14` (the second speaker pair) and pin `0x19` (the headset mic) are marked unconnected (`0x411111f0`).

This is exactly the 2018 MateBook X Pro bug ([kernel bug 200501](https://bugzilla.kernel.org/show_bug.cgi?id=200501)), which got an upstream fix in 2019: `ALC256_FIXUP_HUAWEI_MACH_WX9_PINS`. That fix is keyed to Huawei's subsystem ID **`19e5:3204`**. The 2020 model is built by Huaqin and reports **`1e83:3223`**, so the existing fix never triggers. Neither 6.12 nor current mainline has a quirk for `1e83:3223`. The factory pin values of the 2020 model are identical to the 2018 model's "before" state.

**Fix: no patch, no firmware file.** Since kernel 5.x the HDA driver accepts a *PCI SSID alias* as model name (`hda_auto_parser.c`: `sscanf(codec->modelname, "%04x:%04x", ...)` → "alias SSID"). One line applies the 2018 model's upstream fixup:

```
# /etc/modprobe.d/matebook-audio.conf
options snd-hda-intel model=19e5:3204
```

The fixup sets `0x14 = 0x90170110` (speaker), `0x1b = 0x90170112` (second speaker), `0x19 = 0x04a11040` (headset mic), and chains `ALC255_FIXUP_MIC_MUTE_LED`. After a reboot:

```
autoconfig for ALC256: line_outs=2 (0x14/0x1b/0x0/0x0/0x0) type:speaker
inputs: Internal Mic=0x12  Mic=0x19
```

You don't need the "Analog Surround 4.0" profile that older guides recommend. The generic HDA parser never sets `no_share_stream`, so a stereo stream is copied to the second DAC and all four speakers play in the normal stereo profile. A new `Bass Speaker` mixer control appears.

> Tip: `/proc/asound/card0/codec#0` still shows the BIOS values. The active ones are in `/sys/class/sound/hwC0D0/driver_pin_configs`.

### F3. GNOME was forced onto X11

GDM's udev rule (`/usr/lib/udev/rules.d/61-gdm.rules`) turns Wayland off when the NVIDIA driver is loaded without `NVreg_PreserveVideoMemoryAllocations=1`. That was the case on the stock driver setup. With the NVIDIA driver gone, GDM defaults to **Wayland**, which handles the 3K screen, fractional scaling and touch gestures better. "GNOME on Xorg" is still selectable from the gear icon on the login screen.

### F4. Inconsistent APT sources

The installer produced `main non-free-firmware` for `trixie`, `trixie-updates` and `trixie-security`. `contrib non-free` was added later through a second list file, on a different mirror and for `trixie` only. Updates to non-free packages published through `trixie-security`/`trixie-updates` would therefore be missed. The fix adds `contrib non-free` to every line and removes the duplicate file.

### F5. Thermal management (thermald and a DPTF BIOS bug)

The laptop has Intel DPTF tables (`INT3400`, 22 `INT3403` sensors, `INT3404` fan), but the BIOS has a bug:

```
ACPI BIOS Error (bug): Could not resolve symbol [\DPPP], AE_NOT_FOUND
ACPI Error: Aborting method \_SB.IETM.IDSP due to previous error
```

The DPTF policy list is therefore empty (`available_uuids: UNKNOWN`), and **thermald can't use its adaptive mode**; it runs in polling mode instead. It's still installed as a safety net.

> ⚠️ Observed afterwards: the RAPL long-term limit (PL1) went from the BIOS value **18 W** to **200 W** (effectively unlimited). Short bursts get faster, but long loads run at the thermal limit. Pinning PL1 to a sane value (e.g. 25 W, Intel's cTDP-up for this CPU) is a possible next step and is **not** done by these scripts.

### F6. Boot time

- The NVIDIA modules took **5.3 s** inside `systemd-modules-load`.
- `cups-filters` loads parallel-port modules (`lp`, `ppdev`, `parport_pc`) on a laptop with no parallel port.
- The GRUB menu waited 5 s.
- Docker, containerd and Apache started at every boot. containerd alone caused ~15 CPU wakeups per second at idle with no containers running.

### F7. Video playback: no AV1 in hardware

`vainfo` on the Gen 9.5 iGPU lists hardware decoding for **H.264, HEVC 8/10-bit, VP9 8/10-bit, VP8, MPEG-2 and JPEG**, but **not AV1**. YouTube prefers AV1 whenever the browser can decode it (in software), which means a hot CPU and short battery life. Solution: make Chrome/Brave use VA-API (script 05) and block AV1 with the **enhanced-h264ify** extension (tick only "Block AV1"). YouTube then serves VP9, which is hardware-decoded.

### F8. Thunderbolt controller "HC died"

When nothing is connected, the firmware powers the Titan Ridge controller down. After `boltd` briefly force-powered it, the kernel logged `xhci_hcd 0000:3a:00.0: Controller not ready at resume -19 ... HC died`. This is expected for this firmware-managed mode and harmless; the controller comes back on hotplug.

### Harmless log messages (no action needed)

| Message | Meaning |
|---|---|
| `iwlwifi: firmware: failed to load iwl-debug-yoyo.bin` | Optional debug firmware, never shipped |
| `i801_smbus: SMBus is busy, can't use it!` | The embedded controller owns the SMBus |
| `nvme: missing or invalid SUBNQN field` | Cosmetic, common on Samsung OEM drives |
| `ACPI(PXSX) defines _DOD but not _DOS` | Firmware bug in the (now unused) dGPU node |
| `thermal: Invalid critical threshold (-274000)` | Firmware bug in one ACPI thermal zone |
| `atkbd: Unknown key pressed (... code 0xf8)` | A Huawei Fn key with no mapping |
| `90-alsa-restore.rules ... has no matching label` | Debian alsa-utils packaging warning |
| GNOME keyring `Failed to start app-gnome-gnome-keyring-*.scope` | Known GNOME/Debian 13 noise at login |

---

## The scripts

All scripts are bash, idempotent where possible, and log to `scripts/logs/` (git-ignored, because logs contain MAC addresses and serial numbers). The system-changing script refuses to run on anything but a `MACHC-WAX9` with Debian 13.

| Script | Run as | Changes the system? | Purpose |
|---|---|---|---|
| [`01-diagnostics.sh`](scripts/01-diagnostics.sh) | `sudo` | No | Baseline: kernel log, journal errors, i915 PSR/FBC/DMC state, PCIe ASPM states, **60 s idle measurement**, powertop report |
| [`02-apply.sh`](scripts/02-apply.sh) | `sudo` | **Yes** | The main fixes (9 steps, see below), with backups |
| [`03-verify.sh`](scripts/03-verify.sh) | `sudo` | No | 24 OK/FAIL checks plus the same idle measurement, NVMe SMART, sensors, boot time |
| [`04-services.sh`](scripts/04-services.sh) | `sudo` | **Yes** | Masks services the laptop doesn't need |
| [`05-browsers.sh`](scripts/05-browsers.sh) | your user | Yes (user files only) | Chrome/Brave on native Wayland with VA-API video decoding |

### How the idle measurement works (01 and 03)

The scripts read the CPU's package C-state residency counters directly from the model-specific registers (MSRs), the same method `turbostat` uses:

| MSR | Counter |
|---|---|
| `0x60D` | PC2 |
| `0x3F8` | PC3 |
| `0x3F9` | PC6 |
| `0x3FA` | PC7 |
| `0x630` | PC8 |
| `0x631` | PC9 |
| `0x632` | PC10 |

The time-stamp counter (`0x10`) is read at the start and end of the window. Each state's share is `Δcounter / ΔTSC`. RAPL energy counters (`/sys/class/powercap/intel-rapl:*`) give average CPU/iGPU/DRAM power. On battery, `BAT0/power_now` gives the whole-laptop drain. Unplug the charger before running 03 to get that number.

### What `02-apply.sh` does

Before it starts, it checks the model, the OS and AC power, then asks you to type `yes`. Every file is copied to `/var/backups/matebook-setup/<timestamp>/` before it is changed.

1. **APT sources:** adds `contrib non-free` to all trixie lines (an idempotent `sed`), removes the duplicate list, then runs `apt update`.
2. **Integrated graphics only:**
   - Purges the NVIDIA driver stack (43 packages, plus `dkms`, `glx-*` and `update-glx`, but only if they're on a fixed allowlist of NVIDIA leftovers; anything else is reported, not removed).
   - Removes stray NVIDIA config links and writes `/etc/modprobe.d/matebook-dgpu-off.conf`, which blacklists nouveau.
   - Writes `/etc/udev/rules.d/80-matebook-dgpu-power.rules`, which sets `power/control=auto` on the MX250 so its root port can enter D3cold.
3. **`apt-get full-upgrade`.**
4. **Audio fix:** writes `/etc/modprobe.d/matebook-audio.conf` (`model=19e5:3204`).
5. **thermald:** installs and enables it.
6. **Docker/containerd/Apache on demand:** disables the services at boot. `docker.socket` stays enabled, so `docker` starts on first use.
7. **Tweaks:**
   - GRUB timeout 5 → 2 s.
   - Blacklists the parallel-port modules.
   - Sets `kernel.nmi_watchdog=0`.
   - Sets up **zram swap** (zstd, min(RAM/2, 8 GB), priority 100). The encrypted disk swap stays as a fallback at priority -2.
8. **Tools:** `vainfo`, `intel-gpu-tools`, `lm-sensors`, `smartmontools` (without recommends, to avoid pulling in a mail server).
9. **Boot files:** `update-initramfs -u -k all`, `update-grub`.

### What `04-services.sh` does

Stops, disables and **masks** these services (the packages stay installed):

- `ModemManager`: no WWAN modem in this laptop.
- `open-iscsi` / `iscsid`: no iSCSI disks.
- `cups-browsed`: automatic network-printer discovery. Printing itself still works.

`avahi-daemon` is kept, because Chromecast and other mDNS discovery need it.

### What `05-browsers.sh` does

Copies the Chrome and Brave `.desktop` launchers to `~/.local/share/applications/` and adds:

```
--ozone-platform=wayland
--enable-features=AcceleratedVideoDecodeLinuxGL,AcceleratedVideoDecodeLinuxZeroCopyGL,AcceleratedVideoEncoder
```

To check it worked:
1. Open `chrome://gpu` (`brave://gpu` in Brave). "Video Decode" should say *Hardware accelerated*.
2. On YouTube, open "Stats for nerds". The codec should be `vp09` once AV1 is blocked.

---

## Quick start

```bash
git clone https://github.com/ekstremedia/huawei-matebook-debian-optimization
cd huawei-matebook-debian-optimization

sudo bash scripts/01-diagnostics.sh   # read-only baseline (don't touch the laptop for 60 s)
less scripts/02-apply.sh              # read it first!
sudo bash scripts/02-apply.sh         # charger connected, type "yes"
sudo reboot

sudo bash scripts/03-verify.sh        # unplug the charger first to measure battery drain
sudo bash scripts/04-services.sh      # optional
bash scripts/05-browsers.sh           # optional, as your normal user
```

**Read the scripts before running them.** They were written for one specific machine and set of choices, such as removing the NVIDIA driver and making Docker/Apache on-demand. Edit `02-apply.sh` if your choices differ: each step is a separate function called from `main()`, so you can comment steps out.

### Secure Boot

The test machine came with Secure Boot **off** and the firmware in Setup Mode. With the NVIDIA DKMS module gone, nothing unsigned needs to load, so Secure Boot was turned on in the BIOS (F2 at power-on). Debian's Microsoft-signed shim, GRUB and kernel boot without extra steps.

After enabling it:
- `mokutil --sb-state` reports `SecureBoot enabled`.
- The kernel runs in lockdown `integrity` mode.
- The kernel taint is `0`.

Side effects:
- **Hibernation is blocked** by lockdown. Suspend to RAM (S3 "deep", the default here) works as before.
- Any future DKMS module, such as the NVIDIA driver, needs its MOK key enrolled once: `sudo mokutil --import /var/lib/dkms/mok.pub`, then reboot and confirm.

---

## Choices made and things deliberately not done

| Not done | Reason |
|---|---|
| TLP | `power-profiles-daemon` already handles EPP (incl. `balance_power` on battery) and integrates with GNOME; TLP conflicts with it and added little here |
| `vm.dirty_writeback_centisecs=1500` | More data loss on a crash for a tiny gain on NVMe |
| Audio `power_save=1` | Default 10 s is fine and avoids pops on the ALC256 |
| `pcie_aspm=powersupersave` | Stability risk; the system already reaches PC10 |
| Forcing runtime PM on the Thunderbolt root port | Kernel deliberately refuses D3 on that firmware-managed hotplug port |
| `intel-media-va-driver-non-free` | Only adds encoding features; decoding is identical |
| nouveau runtime PM instead of "no driver" | Extra moving parts and a slow, unreclocked GPU; driverless D3cold works perfectly |
| A battery charge limit | Personal choice. To set one: `echo "75 80" \| sudo tee /sys/devices/platform/huawei-wmi/charge_control_thresholds` (`"0 100"` to turn off) |
| Firewall / SSH hardening | Out of scope, but recommended: `sshd` listens on all interfaces with password login by default |
| Undervolting | Usually locked on Comet Lake after the Plundervolt fixes, and MSR writes are blocked by kernel lockdown |

---

## Reverting

`02-apply.sh` stores the originals in `/var/backups/matebook-setup/<timestamp>/`, using the same paths as under `/`.

| Change | Undo |
|---|---|
| APT sources | Copy `etc/apt/sources.list` (and the `.list.d` file) back from the backup, then `sudo apt update` |
| Integrated-only graphics | `sudo rm /etc/modprobe.d/matebook-dgpu-off.conf /etc/udev/rules.d/80-matebook-dgpu-power.rules && sudo apt install nvidia-driver && sudo update-initramfs -u`, then reboot (with Secure Boot, enroll the MOK key) |
| Audio fix | `sudo rm /etc/modprobe.d/matebook-audio.conf`, then reboot |
| thermald | `sudo apt purge thermald` |
| Docker/Apache on demand | `sudo systemctl enable docker.service containerd.service apache2.service` |
| GRUB timeout | `GRUB_TIMEOUT=5` in `/etc/default/grub`, then `sudo update-grub` |
| Parallel-port blacklist | `sudo rm /etc/modprobe.d/matebook-no-parport.conf` |
| NMI watchdog | `sudo rm /etc/sysctl.d/90-matebook-power.conf` |
| zram | `sudo rm /etc/systemd/zram-generator.conf && sudo apt purge systemd-zram-generator`, then reboot |
| Masked services | `sudo systemctl unmask <unit> && sudo systemctl enable --now <unit>` |
| Browser flags | `rm ~/.local/share/applications/{google-chrome,brave-browser}.desktop` |

---

## FAQ

**Is the NVIDIA GPU still in the laptop?**
Yes. It still shows up in `lspci`, but it has no driver and no power. Note that `lspci` reading its config space wakes it for a moment; it powers off again right after.

**How do I get the NVIDIA GPU back?**
See [Reverting](#reverting). Expect idle drain to roughly double (an estimate), because on Pascal the NVIDIA driver can't power the card down. To switch back and forth, a small "gpu-mode" toggle (modprobe blacklist plus reboot) is the cleanest option.

**Fractional scaling (150 % / 175 %) on the 3K screen?**
```
gsettings set org.gnome.mutter experimental-features "['scale-monitor-framebuffer','xwayland-native-scaling']"
```
Then pick the scale in Settings → Displays.

**Does the fingerprint reader work?**
No. It's a Goodix `GXFP51B7` on a non-USB bus, and libfprint has no driver for it.

**Firmware updates?**
`fwupdmgr` sees the BIOS (UEFI capsule), the NVMe and the TPM, but Huawei publishes nothing on LVFS. BIOS updates require Windows / Huawei PC Manager.

## Other MateBook models

- **MateBook X Pro 2018 (`MACH-WX9`)**: the audio fix is already applied by the kernel (it's the model the fixup was written for). The NVIDIA analysis applies (MX150, also Pascal).
- **MateBook X Pro 2019 (`MACH-W19`)**: very likely the same as 2020. Check `cat /sys/class/sound/hwC0D0/init_pin_configs` against the values above and `cat /sys/class/sound/hwC0D0/subsystem_id`.
- **Others:** the method carries over: check `driver_pin_configs`, the dGPU root port's `firmware_node/power_resources_D3hot`, and package C-states. Change the model check at the top of `02-apply.sh` only once you've checked these.

Contributions with measurements from other models are welcome.

## References

- Kernel bug 200501, "Only 2 of 4 speakers playing sound" (MateBook X Pro): https://bugzilla.kernel.org/show_bug.cgi?id=200501
- Upstream fix "ALSA: hda: fix front speakers on Huawei MBXP": https://lkml.iu.edu/hypermail/linux/kernel/1904.2/03871.html
- Older hdajackretask guide for the 2018 model: https://github.com/hg8/arch-matebook-x-pro/blob/master/guide-fix-matebook-x-pro-speakers-linux.md
- Linux source, `sound/pci/hda/patch_realtek.c` and `hda_auto_parser.c` (SSID alias), `drivers/platform/x86/huawei-wmi.c`, `drivers/pci/pci-driver.c` (runtime PM of driverless devices)
- NVIDIA driver README, "PCI-Express Runtime D3 (RTD3) Power Management" (Turing+ requirement)
- GDM `61-gdm.rules` (Wayland/NVIDIA logic)

---

*Tested on Debian 13.7, kernel 6.12.111, GNOME 48, October 2026. Use at your own risk: read the scripts, keep backups, and have a live USB stick at hand when changing drivers.*
