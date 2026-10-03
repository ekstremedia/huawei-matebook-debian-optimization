#!/usr/bin/env bash
# 03-verify.sh - READ-ONLY check after 02-apply.sh + reboot (Huawei MateBook X Pro 2020, Debian 13).
#
# Changes NOTHING. Checks every change from 02-apply.sh, collects the kernel log, and repeats the
# 60-second idle measurement from 01-diagnostics.sh so before/after can be compared.
# Tip: unplug the charger before running it, then the idle battery drain is measured too.
#
# Run:  sudo bash scripts/03-verify.sh
# Log:  scripts/logs/03-verify-<timestamp>.log
set -uo pipefail
export LC_ALL=C

if [[ $EUID -ne 0 ]]; then echo "Please run with sudo: sudo bash $0"; exit 1; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
OWNER="${SUDO_USER:-$(stat -c %U "$SCRIPT_DIR")}"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$LOG_DIR/03-verify-$STAMP.log"
mkdir -p "$LOG_DIR"

PASS=0 FAIL=0
section() { printf '\n===== %s =====\n' "$*"; }
# check "<description>" <command...>: prints OK/FAIL depending on the command's exit status.
check() {
    local desc=$1; shift
    if "$@" >/dev/null 2>&1; then printf '  [ OK ] %s\n' "$desc"; PASS=$((PASS + 1))
    else printf '  [FAIL] %s\n' "$desc"; FAIL=$((FAIL + 1)); fi
}

# Read one 64-bit MSR from CPU 0.
rdmsr() { dd if=/dev/cpu/0/msr bs=8 count=1 skip="$1" iflag=skip_bytes status=none 2>/dev/null | od -An -t u8 | tr -d ' '; }
PKG_CSTATES=("PC2:$((0x60D))" "PC3:$((0x3F8))" "PC6:$((0x3F9))" "PC7:$((0x3FA))" "PC8:$((0x630))" "PC9:$((0x631))" "PC10:$((0x632))")
TSC_MSR=$((0x10))

idle_measurement() {
    local secs=60 i name addr
    modprobe msr 2>/dev/null || true
    declare -A c0 c1
    local rapl_dirs=() e0=() e1=()
    for d in /sys/class/powercap/intel-rapl:0 /sys/class/powercap/intel-rapl:0:*; do
        [[ -r $d/energy_uj ]] && rapl_dirs+=("$d")
    done

    echo "Measuring for ${secs}s. Please do not touch the laptop until this finishes."
    sleep 5

    local t0; t0=$(rdmsr $TSC_MSR)
    for i in "${PKG_CSTATES[@]}"; do name=${i%%:*}; addr=${i##*:}; c0[$name]=$(rdmsr "$addr"); done
    for d in "${rapl_dirs[@]}"; do e0+=("$(cat "$d/energy_uj")"); done

    local bat_sum=0 bat_n=0 status
    for ((i = 0; i < secs; i += 5)); do
        sleep 5
        status=$(cat /sys/class/power_supply/BAT0/status 2>/dev/null)
        if [[ $status == Discharging ]]; then
            bat_sum=$((bat_sum + $(cat /sys/class/power_supply/BAT0/power_now))); bat_n=$((bat_n + 1))
        fi
    done

    local t1; t1=$(rdmsr $TSC_MSR)
    for i in "${PKG_CSTATES[@]}"; do name=${i%%:*}; addr=${i##*:}; c1[$name]=$(rdmsr "$addr"); done
    for d in "${rapl_dirs[@]}"; do e1+=("$(cat "$d/energy_uj")"); done

    local dt=$((t1 - t0))
    if [[ -n $t0 && $dt -gt 0 ]]; then
        echo "-- CPU package C-state residency (share of the ${secs}s window):"
        for i in "${PKG_CSTATES[@]}"; do
            name=${i%%:*}
            [[ -n ${c0[$name]} && -n ${c1[$name]} ]] && \
                awk -v n="$name" -v a="${c0[$name]}" -v b="${c1[$name]}" -v t="$dt" 'BEGIN{printf "   %-5s %6.2f %%\n", n, (b-a)*100/t}'
        done
    else
        echo "-- MSR read failed; package C-state residency not available."
    fi

    echo "-- Average power from RAPL (CPU package and its sub-domains):"
    for i in "${!rapl_dirs[@]}"; do
        local d=${rapl_dirs[$i]} max; max=$(cat "$d/max_energy_range_uj")
        awk -v n="$(cat "$d/name")" -v a="${e0[$i]}" -v b="${e1[$i]}" -v m="$max" -v s="$secs" \
            'BEGIN{d=b-a; if (d<0) d+=m; printf "   %-8s %6.2f W\n", n, d/1e6/s}'
    done

    if ((bat_n > 0)); then
        awk -v s="$bat_sum" -v n="$bat_n" -v full="$(cat /sys/class/power_supply/BAT0/energy_full)" \
            'BEGIN{w=s/n/1e6; printf "-- Battery drain (whole laptop, idle): %.2f W (avg of %d samples) = ~%.1f h idle on a full battery\n", w, n, full/1e6/w}'
    else
        echo "-- Battery drain: not measured (charger connected)."
    fi
    echo "-- dGPU root port 00:1c.0 power state: $(cat /sys/bus/pci/devices/0000:00:1c.0/power_state 2>/dev/null)"
}

main() {
    local G=/sys/bus/pci/devices/0000:01:00.0 P=/sys/bus/pci/devices/0000:00:1c.0

    section "Basics"
    echo "Date: $(date -Is)   Kernel: $(uname -r)   Uptime: $(uptime -p)"
    echo "Power: AC online=$(cat /sys/class/power_supply/AC0/online 2>/dev/null)  battery $(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null)% $(cat /sys/class/power_supply/BAT0/status 2>/dev/null)"
    local sid; sid=$(loginctl show-user "$OWNER" -p Display --value 2>/dev/null)
    echo "Graphical session of $OWNER: ${sid:-none} type=$( [[ -n $sid ]] && loginctl show-session "$sid" -p Type --value 2>/dev/null)"

    section "Checks"
    check "No NVIDIA or nouveau kernel module loaded" bash -c '! lsmod | grep -qE "^(nvidia|nouveau)"'
    check "No NVIDIA driver packages installed" bash -c '! dpkg -l "nvidia-*" "libnvidia-*" 2>/dev/null | grep -q "^ii"'
    check "MX250 has no driver bound" bash -c "[[ ! -e $G/driver ]]"
    check "MX250 runtime PM allowed (power/control=auto)" bash -c "[[ \$(cat $G/power/control) == auto ]]"
    check "MX250 root port 00:1c.0 is in D3cold (GPU powered off)" bash -c "[[ \$(cat $P/power_state) == D3cold ]]"
    check "Power resource LNXPOWER:01 (dGPU slot) is off" bash -c '[[ $(cat /sys/bus/acpi/devices/LNXPOWER:01/resource_in_use) == 0 ]]'
    check "Only the Intel GPU has a DRM device" bash -c '[[ $(ls -d /sys/class/drm/card[0-9] | wc -l) == 1 ]]'
    check "snd-hda-intel model option active (19e5:3204)" bash -c '[[ $(cat /sys/module/snd_hda_intel/parameters/model) == 19e5:3204* ]]'
    check "Speaker pin 0x14 enabled by driver fixup (0x90170110)" grep -qx '0x14 0x90170110' /sys/class/sound/hwC0D0/driver_pin_configs
    check "Headset mic pin 0x19 enabled by driver fixup (0x04a11040)" grep -qx '0x19 0x04a11040' /sys/class/sound/hwC0D0/driver_pin_configs
    check "Pin 0x19 jack detection off (patch file loaded)" grep -qx '0x19 0x04a11140' /sys/class/sound/hwC0D0/user_pin_configs
    check "No false 'Mic Jack' plugged signal" bash -c '! amixer -c0 cget name="Mic Jack" 2>/dev/null | grep -q ": values=on"'
    check "Mixer has 'Bass Speaker' control (2nd speaker pair)" bash -c 'amixer -c0 scontrols | grep -q "Bass Speaker"'
    check "thermald running" systemctl is-active --quiet thermald.service
    check "zram swap active" bash -c 'swapon --show=NAME --noheadings | grep -q zram'
    check "docker.service not started at boot" bash -c '! systemctl is-enabled --quiet docker.service'
    check "docker.socket listening (Docker on demand)" systemctl is-active --quiet docker.socket
    check "containerd not started at boot" bash -c '! systemctl is-enabled --quiet containerd.service'
    check "apache2 not started at boot" bash -c '! systemctl is-enabled --quiet apache2.service && ! systemctl is-active --quiet apache2.service'
    check "Nothing listening on port 80" bash -c '! ss -tlnH | awk "{print \$4}" | grep -qE ":80$"'
    check "NMI watchdog off" bash -c '[[ $(cat /proc/sys/kernel/nmi_watchdog) == 0 ]]'
    check "Parallel-port modules not loaded" bash -c '! lsmod | grep -qE "^(parport_pc|ppdev|lp) "'
    check "GRUB timeout is 2 s" grep -q '^GRUB_TIMEOUT=2$' /etc/default/grub
    check "APT: trixie-security includes non-free" grep -qE '^deb .*trixie-security.* non-free( |$)' /etc/apt/sources.list
    check "No failed systemd units" bash -c '[[ -z $(systemctl --failed --no-legend --plain) ]]'
    check "VA-API works on the Intel GPU (iHD driver)" bash -c 'vainfo --display drm --device /dev/dri/renderD128 2>&1 | grep -q "Driver version: Intel iHD"'
    echo "  -> $PASS OK, $FAIL FAIL"

    section "Audio details"
    dmesg | grep -E 'autoconfig for ALC256|line_outs|speaker_outs|hp_outs|inputs:|Mic=|Headset Mic|Internal Mic' | sed 's/^/   /'
    echo "   driver pin configs (fixup applied):"; sed 's/^/     /' /sys/class/sound/hwC0D0/driver_pin_configs
    echo "   mixer: $(amixer -c0 scontrols 2>/dev/null | sed "s/Simple mixer control //" | tr '\n' ' ')"

    section "Graphics details"
    # Read the power states first: lspci reads the GPU's config space, which wakes it briefly.
    echo "   GPU runtime_status=$(cat $G/power/runtime_status)  port power_state=$(cat $P/power_state)  port ACPI real_power_state=$(cat $P/firmware_node/real_power_state 2>/dev/null)"
    lspci -nnk -s 01:00.0 | sed 's/^/   /'
    for d in /sys/kernel/debug/dri/*; do
        if grep -q i915 "$d/name" 2>/dev/null; then
            grep -E 'PSR mode|Source PSR' "$d/i915_edp_psr_status" | sed 's/^/   /'
            head -n 1 "$d/i915_fbc_status" | sed 's/^/   /'
            grep -E 'DC3 -> DC5|DC5 -> DC6' "$d/i915_dmc_info" | sed 's/^/   /'
            break
        fi
    done
    vainfo --display drm --device /dev/dri/renderD128 2>&1 | grep -E 'Driver version|VAProfile(H264High|HEVCMain|VP9Profile0|AV1)' | head -n 12 | sed 's/^/   /'

    section "thermald"
    journalctl -b -u thermald --no-pager -q | tail -n 25

    section "Swap and memory"
    swapon --show
    zramctl 2>/dev/null

    section "Services and listening ports"
    for u in docker.service docker.socket containerd.service apache2.service thermald.service libvirtd.service ssh.service; do
        printf '   %-20s enabled=%-9s active=%s\n' "$u" "$(systemctl is-enabled $u 2>/dev/null)" "$(systemctl is-active $u 2>/dev/null)"
    done
    ss -tlnH | awk '{print "   listening: " $4}' | sort -u

    section "Boot time"
    systemd-analyze 2>&1
    systemd-analyze blame 2>/dev/null | head -n 15 | sed 's/^/   /'
    journalctl -b -u systemd-modules-load --no-pager -q -o short-monotonic | tail -n 10

    section "Kernel log: errors and warnings (this boot)"
    dmesg --level=emerg,alert,crit,err,warn

    section "Journal: priority err and worse (this boot)"
    journalctl -b -p err --no-pager -q | tail -n 100

    section "Failed units"
    systemctl --failed --no-legend --plain

    section "NVMe health"
    smartctl -H -A /dev/nvme0 2>&1 | grep -E 'overall-health|Critical Warning|Temperature:|Available Spare:|Percentage Used|Data Units Written|Power On Hours|Unsafe Shutdowns|Media and Data Integrity Errors|Error Information Log Entries'

    section "Sensors"
    sensors 2>/dev/null | grep -vE '^\s*$'

    section "Thunderbolt / USB-C"
    lspci -s 3a:00.0 2>/dev/null | sed 's/^/   /'
    ls /sys/bus/usb/devices/ | grep -E '^usb[0-9]' | while read -r b; do echo "   $b: $(cat /sys/bus/usb/devices/$b/product 2>/dev/null) @ $(basename "$(readlink -f /sys/bus/usb/devices/$b/..)")"; done
    boltctl domains 2>/dev/null | sed 's/^/   /'

    section "Idle measurement (after changes)"
    idle_measurement

    section "powertop 20s report (saved as CSV)"
    if command -v powertop >/dev/null; then
        powertop --csv="$LOG_DIR/powertop-after-$STAMP.csv" --time=20 >/dev/null 2>&1 \
            && echo "Saved: $LOG_DIR/powertop-after-$STAMP.csv" \
            && awk '/Software Settings in Need of Tuning/{f=1} /Untunable Software Issues/{f=0} f' "$LOG_DIR/powertop-after-$STAMP.csv"
    fi

    section "Done"
    echo "Nothing was changed. Checks: $PASS OK, $FAIL FAIL. Log: $LOG"
}

main 2>&1 | tee "$LOG"
chown -R "$OWNER": "$LOG_DIR" 2>/dev/null || true
