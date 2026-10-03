#!/usr/bin/env bash
# 02-apply.sh - Apply the agreed driver fixes and optimisations to the
#               Huawei MateBook X Pro 2020 (MACHC-WAX9) running Debian 13.
#
# Decisions (see README.md): integrated graphics only, no charge limit,
# Docker/Apache on demand. Every file is backed up before it is changed.
#
#   1  APT sources: same components (incl. contrib/non-free) for trixie, -updates and -security
#   2  Integrated graphics only: purge the NVIDIA driver, blacklist nouveau, let the MX250 power off
#   3  Full upgrade
#   4  Audio: upstream MateBook X Pro fixup (all 4 speakers, headset mic, mic-mute LED)
#   5  thermald (Intel DPTF-aware thermal daemon)
#   6  Docker/containerd/Apache start on demand
#   7  Boot/power tweaks: GRUB timeout 2 s, no parallel-port modules, NMI watchdog off, zram swap
#   8  Diagnostic tools: vainfo, intel-gpu-tools, lm-sensors, smartmontools
#   9  Rebuild initramfs and GRUB config
#
# Run:   sudo bash scripts/02-apply.sh      (charger connected, takes a few minutes)
# Then:  reboot, then: sudo bash scripts/03-verify.sh
# Undo:  see "How to revert" in README.md. Backups: /var/backups/matebook-setup/<timestamp>/
set -Eeuo pipefail
export LC_ALL=C DEBIAN_FRONTEND=noninteractive

if [[ $EUID -ne 0 ]]; then echo "Please run with sudo: sudo bash $0"; exit 1; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
OWNER="${SUDO_USER:-$(stat -c %U "$SCRIPT_DIR")}"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$LOG_DIR/02-apply-$STAMP.log"
BACKUP="/var/backups/matebook-setup/$STAMP"
APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -o DPkg::Lock::Timeout=300)
mkdir -p "$LOG_DIR"

# Everything below goes to the terminal and to the log.
exec > >(tee "$LOG") 2>&1
TEE_PID=$!
finish() {
    chown -R "$OWNER": "$LOG_DIR" 2>/dev/null || true
    exec >&- 2>&-
    wait "$TEE_PID" 2>/dev/null || true
}
trap finish EXIT

step() { printf '\n===== [%s] %s =====\n' "$(date +%T)" "$*"; }
info() { printf '  - %s\n' "$*"; }

backup() {
    local f
    for f in "$@"; do
        if [[ -e $f || -L $f ]]; then
            mkdir -p "$BACKUP$(dirname "$f")"
            cp -a "$f" "$BACKUP$f"
            info "backed up $f"
        fi
    done
}

# write_file <path>: replace <path> with stdin (after a backup).
write_file() {
    backup "$1"
    cat > "$1"
    chmod 0644 "$1"
    info "wrote $1"
}

trap 'echo; echo "!!! FAILED at line $LINENO: $BASH_COMMAND"; echo "!!! Steps after this point were not run. Backups: $BACKUP"' ERR

preflight() {
    step "Pre-flight checks"
    if [[ $(cat /sys/class/dmi/id/product_name) != MACHC-WAX9 ]]; then
        echo "This script is only for the Huawei MateBook X Pro 2020 (MACHC-WAX9). Aborting."; exit 1
    fi
    if ! grep -q '^VERSION_CODENAME=trixie$' /etc/os-release; then
        echo "Expected Debian 13 (trixie). Aborting."; exit 1
    fi
    if [[ $(cat /sys/class/power_supply/AC0/online 2>/dev/null) != 1 ]]; then
        echo "Please connect the charger first (kernel/initramfs updates). Aborting."; exit 1
    fi
    info "Model, OS and AC power OK"
    info "Backups will be stored in $BACKUP"
    echo
    echo "This will make the 9 changes listed at the top of $0."
    read -r -p "Type 'yes' to continue: " answer < /dev/tty
    if [[ $answer != yes ]]; then echo "Aborted, nothing changed."; exit 1; fi
    mkdir -p "$BACKUP"
}

apt_sources() {
    step "1/9 APT sources"
    backup /etc/apt/sources.list
    # Add 'contrib non-free' after 'main' on every trixie / trixie-updates / trixie-security line that lacks it.
    sed -i -E '/^deb(-src)?[[:space:]]/{/[[:space:]]trixie(-updates|-security)?[[:space:]]/{/[[:space:]]contrib([[:space:]]|$)/!s/[[:space:]]main([[:space:]]|$)/ main contrib non-free\1/}}' /etc/apt/sources.list
    if [[ -f /etc/apt/sources.list.d/debian-non-free.list ]]; then
        backup /etc/apt/sources.list.d/debian-non-free.list
        rm -f /etc/apt/sources.list.d/debian-non-free.list
        info "removed duplicate /etc/apt/sources.list.d/debian-non-free.list (now covered by sources.list)"
    fi
    grep -Ev '^[[:space:]]*(#|$)' /etc/apt/sources.list | sed 's/^/    /'
    apt-get update
}

nvidia_off() {
    step "2/9 Integrated graphics only: remove the NVIDIA driver"
    local nv=() ar=() ar_ok=() ar_other=() f
    mapfile -t nv < <(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' \
        | awk '$1 ~ /^(ii|hi|rc)$/ {print $2}' \
        | grep -E '^(nvidia-|libnvidia-|xserver-xorg-video-nvidia|libgl1-nvidia|libglx-nvidia|libegl-nvidia|libgles-nvidia|libcuda|libnvcuvid|libnvoptix|glx-alternative-nvidia|firmware-nvidia-gsp)' || true)
    if ((${#nv[@]})); then
        info "purging ${#nv[@]} packages: ${nv[*]}"
        apt-get purge "${APT_OPTS[@]}" "${nv[@]}"
    else
        info "no NVIDIA driver packages installed"
    fi

    # Helpers that only the NVIDIA stack needed (verified with a dry run on 2026-10-03).
    # Anything else that shows up as autoremovable is reported, not removed.
    mapfile -t ar < <(apt-get -s autoremove 2>/dev/null | awk '/^Remv/{print $2}')
    mapfile -t ar_ok < <(printf '%s\n' "${ar[@]}" | grep -E '^(dkms|glx-alternative-mesa|glx-alternative-nvidia|glx-diversions|update-glx|libgles1)$' || true)
    mapfile -t ar_other < <(printf '%s\n' "${ar[@]}" | grep -vE '^(dkms|glx-alternative-mesa|glx-alternative-nvidia|glx-diversions|update-glx|libgles1)$' | grep -v '^$' || true)
    if ((${#ar_ok[@]})); then
        info "purging NVIDIA leftovers: ${ar_ok[*]}"
        apt-get purge "${APT_OPTS[@]}" "${ar_ok[@]}"
    fi
    if ((${#ar_other[@]})); then
        info "NOTE: also autoremovable but left in place (review manually): ${ar_other[*]}"
    fi

    # Config links that were not owned by any package (NVIDIA alternatives); remove if still present.
    for f in /etc/modules-load.d/nvidia.conf /etc/modprobe.d/nvidia.conf /etc/modprobe.d/nvidia-options.conf \
             /etc/modprobe.d/nvidia-blacklists-nouveau.conf /usr/share/X11/xorg.conf.d/nvidia-drm-outputclass.conf; do
        if [[ -e $f || -L $f ]]; then
            backup "$f"
            rm -f "$f"
            info "removed leftover $f"
        fi
    done

    write_file /etc/modprobe.d/matebook-dgpu-off.conf <<'EOF'
# MateBook X Pro 2020: integrated graphics only (installed by huawei-matebook-debian-optimization/scripts/02-apply.sh).
# The NVIDIA MX250 is left without a driver so its PCIe root port can cut its power (D3cold).
# Undo: delete this file and /etc/udev/rules.d/80-matebook-dgpu-power.rules,
#       run 'sudo update-initramfs -u', install nvidia-driver, reboot.
blacklist nouveau
options nouveau modeset=0
EOF

    write_file /etc/udev/rules.d/80-matebook-dgpu-power.rules <<'EOF'
# MateBook X Pro 2020: let the driverless NVIDIA MX250 runtime-suspend, so its root port
# (00:1c.0, ACPI RP05, power resource LNXPOWER:01) can switch it off (D3cold).
# Installed by huawei-matebook-debian-optimization/scripts/02-apply.sh. Undo: delete this file.
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030200", TEST=="power/control", ATTR{power/control}="auto"
EOF
}

full_upgrade() {
    step "3/9 Full system upgrade"
    apt-get full-upgrade "${APT_OPTS[@]}"
}

audio_fix() {
    step "4/9 Audio: all 4 speakers, headset mic, mic-mute LED"
    # Pin 0x19 override: its jack detection falsely reports "plugged in" on the 2020 model,
    # which would make PipeWire record from the empty jack instead of the internal mic.
    write_file /lib/firmware/matebook-x-pro-2020-audio.fw <<'EOF'
[codec]
0x10ec0256 0x1e833223 0

[pincfg]
0x19 0x04a11140
EOF
    write_file /etc/modprobe.d/matebook-audio.conf <<'EOF'
# MateBook X Pro 2020 (ALC256, codec SSID 1e83:3223): apply the upstream kernel fixup of the
# 2018 model "Huawei MACH-WX9" (SSID 19e5:3204, ALC256_FIXUP_HUAWEI_MACH_WX9_PINS): enables the
# second speaker pair (pin 0x14), the headset mic (pin 0x19) and the mic-mute LED hook.
# The patch file turns off jack detection on pin 0x19, which falsely reports "plugged in" on
# this model and would hide the internal mic.
# Installed by huawei-matebook-debian-optimization/scripts/02-apply.sh.
# Undo: delete this file and /lib/firmware/matebook-x-pro-2020-audio.fw, then reboot.
options snd-hda-intel model=19e5:3204 patch=matebook-x-pro-2020-audio.fw
EOF
}

thermal() {
    step "5/9 thermald"
    apt-get install "${APT_OPTS[@]}" thermald
    systemctl enable thermald.service
}

dev_services() {
    step "6/9 Docker, containerd and Apache on demand"
    local u
    for u in docker.service containerd.service apache2.service; do
        if systemctl cat "$u" >/dev/null 2>&1; then systemctl disable "$u"; fi
    done
    systemctl enable docker.socket
    info "docker starts on first use through docker.socket (containerd is pulled in by docker.service)"
    info "apache: 'sudo systemctl start apache2' when needed"
    info "the services keep running until the reboot"
}

tweaks() {
    step "7/9 Boot and power tweaks"
    if grep -q '^GRUB_TIMEOUT=5$' /etc/default/grub; then
        backup /etc/default/grub
        sed -i 's/^GRUB_TIMEOUT=5$/GRUB_TIMEOUT=2/' /etc/default/grub
        info "GRUB menu timeout 5 s -> 2 s"
    fi

    write_file /etc/modprobe.d/matebook-no-parport.conf <<'EOF'
# This laptop has no parallel port. cups-filters lists lp/ppdev/parport_pc in
# /etc/modules-load.d/cups-filters.conf; systemd-modules-load skips blacklisted modules.
# Installed by huawei-matebook-debian-optimization/scripts/02-apply.sh. Undo: delete this file.
blacklist lp
blacklist ppdev
blacklist parport_pc
EOF

    write_file /etc/sysctl.d/90-matebook-power.conf <<'EOF'
# NMI watchdog off: fewer timer interrupts at idle (powertop recommendation).
# Installed by huawei-matebook-debian-optimization/scripts/02-apply.sh. Undo: delete this file.
kernel.nmi_watchdog = 0
EOF
    sysctl -q -p /etc/sysctl.d/90-matebook-power.conf
    info "NMI watchdog now $(cat /proc/sys/kernel/nmi_watchdog)"

    # Config first, so the package starts zram with these settings.
    write_file /etc/systemd/zram-generator.conf <<'EOF'
# Compressed swap in RAM, used before the encrypted disk swap (priority 100 vs -2).
# The disk swap stays for hibernation and overflow.
# Installed by huawei-matebook-debian-optimization/scripts/02-apply.sh. Undo: delete this file and purge systemd-zram-generator.
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
swap-priority = 100
EOF
    apt-get install "${APT_OPTS[@]}" systemd-zram-generator
    systemctl daemon-reload
    modprobe zram || true
    if systemctl start dev-zram0.swap; then
        info "zram swap active: $(swapon --show=NAME,SIZE,PRIO --noheadings | tr -s ' ' | tr '\n' ';')"
    else
        info "zram swap will start after the reboot"
    fi
}

tools() {
    step "8/9 Diagnostic tools"
    apt-get install "${APT_OPTS[@]}" vainfo intel-gpu-tools lm-sensors
    # Without recommends: avoids pulling in a mail server (bsd-mailx -> exim4).
    apt-get install "${APT_OPTS[@]}" --no-install-recommends smartmontools
}

boot_files() {
    step "9/9 Rebuild initramfs and GRUB config"
    update-initramfs -u -k all
    update-grub
}

main() {
    preflight
    apt_sources
    nvidia_off
    full_upgrade
    audio_fix
    thermal
    dev_services
    tweaks
    tools
    boot_files

    step "Done"
    echo "All changes applied. Backups: $BACKUP"
    echo
    echo "Next steps:"
    echo "  1. Reboot:  sudo reboot"
    echo "  2. Log in. GNOME now starts on Wayland ('GNOME on Xorg' stays available via the gear icon)."
    echo "  3. Resume Claude Code with: claude --continue"
    echo "  4. Run:     sudo bash $SCRIPT_DIR/03-verify.sh"
}

main
