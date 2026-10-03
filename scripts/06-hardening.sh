#!/usr/bin/env bash
# 06-hardening.sh - Automatic security updates, firewall, and a sustained CPU power limit.
#
#   1  unattended-upgrades: installs Debian security updates automatically every day
#   2  ufw firewall: block all incoming connections, allow outgoing.
#        Exceptions: mDNS (Chromecast / network discovery), libvirt and Docker bridges
#        (VM DHCP/DNS and container traffic), forwarding for VM/container NAT.
#        SSH (22/tcp) stays reachable, rate-limited against password guessing.
#   3  CPU sustained power limit (RAPL PL1) 25 W, re-applied at boot and after suspend.
#        Short bursts (PL2 51 W) are unchanged, so the laptop still feels as fast;
#        only long full-load runs are capped at Intel's highest rating for this CPU
#        (cTDP-up 25 W) instead of "unlimited" (thermal limit, ~100 C, loud fan).
#
# Run:   sudo bash scripts/06-hardening.sh
# Undo:  1  sudo apt purge unattended-upgrades
#        2  sudo ufw disable
#        3  sudo systemctl disable --now matebook-cpu-power-limit.service &&
#           sudo rm /etc/systemd/system/matebook-cpu-power-limit.service /usr/lib/systemd/system-sleep/matebook-cpu-power-limit
set -Eeuo pipefail
export LC_ALL=C DEBIAN_FRONTEND=noninteractive

if [[ $EUID -ne 0 ]]; then echo "Please run with sudo: sudo bash $0"; exit 1; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
OWNER="${SUDO_USER:-$(stat -c %U "$SCRIPT_DIR")}"
LOG="$LOG_DIR/06-hardening-$(date +%Y%m%d-%H%M%S).log"
APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -o DPkg::Lock::Timeout=300)
PL1_WATTS=25
mkdir -p "$LOG_DIR"

exec > >(tee "$LOG") 2>&1
TEE_PID=$!
finish() {
    chown -R "$OWNER": "$LOG_DIR" 2>/dev/null || true
    exec >&- 2>&-
    wait "$TEE_PID" 2>/dev/null || true
}
trap finish EXIT
trap 'echo; echo "!!! FAILED at line $LINENO: $BASH_COMMAND"' ERR

step() { printf '\n===== [%s] %s =====\n' "$(date +%T)" "$*"; }
info() { printf '  - %s\n' "$*"; }

security_updates() {
    step "1/3 Automatic security updates"
    apt-get install "${APT_OPTS[@]}" unattended-upgrades apt-listchanges
    # Debian's default 50unattended-upgrades only installs from the -security origin.
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
    info "wrote /etc/apt/apt.conf.d/20auto-upgrades"
    systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
    unattended-upgrade --dry-run 2>&1 | tail -n 3 | sed 's/^/    /'
}

firewall() {
    step "2/3 Firewall (ufw)"
    apt-get install "${APT_OPTS[@]}" ufw
    # VM/container NAT goes through FORWARD; ufw's default DROP would cut their network.
    sed -i 's/^DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
    ufw --force reset >/dev/null
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow in proto udp to any port 5353 comment 'mDNS (Chromecast, discovery)'
    ufw allow in proto udp from any port 5353 comment 'mDNS replies'
    ufw allow in on virbr0 comment 'libvirt VMs: DHCP/DNS to host'
    ufw allow in on docker0 comment 'Docker containers to host'
    ufw limit 22/tcp comment 'SSH (rate-limited: max 6 connections / 30 s per IP)'
    ufw --force enable
    systemctl enable ufw.service
    ufw status verbose | sed 's/^/    /'
}

cpu_power_limit() {
    step "3/3 CPU sustained power limit ${PL1_WATTS} W"
    cat > /etc/systemd/system/matebook-cpu-power-limit.service <<EOF
[Unit]
Description=MateBook X Pro: CPU sustained power limit (RAPL PL1) ${PL1_WATTS} W
After=thermald.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo $((PL1_WATTS * 1000000)) > /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw'

[Install]
WantedBy=multi-user.target
EOF
    # Firmware can reset RAPL limits on resume, so re-apply after suspend.
    cat > /usr/lib/systemd/system-sleep/matebook-cpu-power-limit <<'EOF'
#!/bin/sh
[ "$1" = post ] && systemctl restart matebook-cpu-power-limit.service
exit 0
EOF
    chmod 0755 /usr/lib/systemd/system-sleep/matebook-cpu-power-limit
    systemctl daemon-reload
    systemctl enable --now matebook-cpu-power-limit.service
    sleep 5
    info "PL1 now $(( $(cat /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw) / 1000000 )) W, PL2 $(( $(cat /sys/class/powercap/intel-rapl:0/constraint_1_power_limit_uw) / 1000000 )) W"
}

main() {
    security_updates
    firewall
    cpu_power_limit
    step "Done"
    echo "Log: $LOG"
}

main
