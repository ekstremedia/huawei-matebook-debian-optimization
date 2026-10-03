#!/usr/bin/env bash
# 01-diagnostics.sh - READ-ONLY diagnostics for the Huawei MateBook X Pro 2020 (Debian 13).
#
# Changes NOTHING on the system. It collects what needs root (kernel log, journal,
# i915 debugfs, PCIe link power states) and measures a 60-second idle baseline
# (CPU package C-states, CPU/iGPU power, battery drain if unplugged) BEFORE any changes,
# so the result of the optimisation can be compared afterwards.
#
# Run:  sudo bash scripts/01-diagnostics.sh
# Log:  scripts/logs/01-diagnostics-<timestamp>.log
set -uo pipefail
export LC_ALL=C

if [[ $EUID -ne 0 ]]; then echo "Please run with sudo: sudo bash $0"; exit 1; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
OWNER="${SUDO_USER:-$(stat -c %U "$SCRIPT_DIR")}"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$LOG_DIR/01-diagnostics-$STAMP.log"
mkdir -p "$LOG_DIR"

section() { printf '\n===== %s =====\n' "$*"; }

# Read one 64-bit MSR from CPU 0 (msr module is already loaded by fwupd).
rdmsr() { dd if=/dev/cpu/0/msr bs=8 count=1 skip="$1" iflag=skip_bytes status=none 2>/dev/null | od -An -t u8 | tr -d ' '; }

# Package C-state residency MSRs (Comet Lake-U): name:address
PKG_CSTATES=("PC2:$((0x60D))" "PC3:$((0x3F8))" "PC6:$((0x3F9))" "PC7:$((0x3FA))" "PC8:$((0x630))" "PC9:$((0x631))" "PC10:$((0x632))")
TSC_MSR=$((0x10))

idle_baseline() {
    local secs=60 i name addr
    modprobe msr 2>/dev/null || true
    declare -A c0 c1
    local rapl_dirs=() e0=() e1=()
    for d in /sys/class/powercap/intel-rapl:0 /sys/class/powercap/intel-rapl:0:*; do
        [[ -r $d/energy_uj ]] && rapl_dirs+=("$d")
    done

    echo "Measuring for ${secs}s. Please do not touch the laptop until this finishes."
    sleep 5   # let the terminal settle after pressing Enter

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
        awk -v n="$(cat "$d/name")" -v a="${e0[$i]}" -v b="${e1[$i]}" -v m="$max" -v s="$((secs + 0))" \
            'BEGIN{d=b-a; if (d<0) d+=m; printf "   %-8s %6.2f W\n", n, d/1e6/(s)}'
    done

    if ((bat_n > 0)); then
        awk -v s="$bat_sum" -v n="$bat_n" 'BEGIN{printf "-- Battery drain (whole laptop, idle): %.2f W (avg of %d samples)\n", s/n/1e6, n}'
    else
        echo "-- Battery drain: not measured (charger connected)."
    fi
    echo "-- NVIDIA state during baseline: $(nvidia-smi --query-gpu=pstate,clocks.gr,temperature.gpu --format=csv,noheader 2>/dev/null || echo 'nvidia-smi n/a')"
    echo "-- dGPU root port 00:1c.0 power state: $(cat /sys/bus/pci/devices/0000:00:1c.0/power_state 2>/dev/null)"
}

main() {
    section "Basics"
    echo "Date: $(date -Is)   Kernel: $(uname -r)   Uptime: $(uptime -p)"
    echo "Model: $(cat /sys/class/dmi/id/sys_vendor) $(cat /sys/class/dmi/id/product_name)  BIOS $(cat /sys/class/dmi/id/bios_version)"
    echo "Power: AC online=$(cat /sys/class/power_supply/AC0/online 2>/dev/null)  battery $(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null)% $(cat /sys/class/power_supply/BAT0/status 2>/dev/null)"
    echo "Session of $OWNER: $(grep -hE '^(Session|XSession)=' "/var/lib/AccountsService/users/$OWNER" 2>/dev/null | tr '\n' ' ')"

    section "Kernel log: errors and warnings"
    dmesg --level=emerg,alert,crit,err,warn

    section "Kernel log: hardware / driver / firmware lines"
    dmesg | grep -iE 'firmware|microcode|i915|iwlwifi|bluetooth|btintel|snd_hda|hda_codec|alc256|autoconfig|nvidia|nouveau|thunderbolt|huawei|ACPI (Error|Warning|BIOS)|nvme|psr|dmc|guc|huc|pmc_core|thermal|tpm|i2c_hid|hid-multitouch|uvcvideo|intel_lpss|sof|DPTF|int340' | grep -viE 'audit:'

    section "Journal: priority err and worse (this boot)"
    journalctl -b -p err --no-pager -q | tail -n 150

    section "Journal: module loading time"
    journalctl -b -u systemd-modules-load --no-pager -q -o short-monotonic | tail -n 20

    section "i915 (Intel graphics) power features"
    for p in enable_psr enable_fbc enable_guc enable_dc; do echo "param $p=$(cat /sys/module/i915/parameters/$p 2>/dev/null)"; done
    for d in /sys/kernel/debug/dri/*; do
        if grep -q i915 "$d/name" 2>/dev/null; then
            echo "-- $d"
            for f in i915_edp_psr_status i915_fbc_status i915_dmc_info; do echo "[$f]"; head -n 12 "$d/$f" 2>/dev/null; done
            for f in gt/uc/guc_info gt/uc/huc_info gt0/uc/guc_info gt0/uc/huc_info; do [[ -r $d/$f ]] && { echo "[$f]"; head -n 6 "$d/$f"; }; done
        fi
    done

    section "PCIe link power management (ASPM / L1 substates)"
    for dev in 00:1c.0 01:00.0 00:1d.0 02:00.0 00:14.3 00:1d.4; do
        echo "-- $dev $(lspci -s $dev | cut -d' ' -f2-)"
        lspci -vvv -s $dev 2>/dev/null | grep -E 'LnkCap:|LnkCtl:|LnkSta:|L1SubCap:|L1SubCtl1:' | sed 's/^\s*/   /'
    done

    section "Idle baseline (NVIDIA driver still active)"
    idle_baseline

    section "powertop 20s report (saved as CSV)"
    if command -v powertop >/dev/null; then
        powertop --csv="$LOG_DIR/powertop-before-$STAMP.csv" --time=20 >/dev/null 2>&1 \
            && echo "Saved: $LOG_DIR/powertop-before-$STAMP.csv" \
            && grep -E '^"?Bad' "$LOG_DIR/powertop-before-$STAMP.csv" | head -n 40
    fi

    section "Done"
    echo "Nothing was changed. Log: $LOG"
}

main 2>&1 | tee "$LOG"
chown -R "$OWNER": "$LOG_DIR" 2>/dev/null || true
