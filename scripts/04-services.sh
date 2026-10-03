#!/usr/bin/env bash
# 04-services.sh - Turn off services this MateBook does not need.
#
#   ModemManager   - mobile-broadband modems (this laptop has none)
#   open-iscsi     - iSCSI network disks (iscsid.service/.socket included)
#   cups-browsed   - automatic network-printer discovery (printing itself keeps working)
#
# avahi-daemon is kept on purpose: Chromecast/mDNS discovery needs it.
# Services are stopped, disabled and masked (packages stay installed), so this is fully reversible:
#   sudo systemctl unmask <unit> && sudo systemctl enable --now <unit>
#
# Run:  sudo bash scripts/04-services.sh
# Log:  scripts/logs/04-services-<timestamp>.log
set -uo pipefail
export LC_ALL=C

if [[ $EUID -ne 0 ]]; then echo "Please run with sudo: sudo bash $0"; exit 1; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
OWNER="${SUDO_USER:-$(stat -c %U "$SCRIPT_DIR")}"
LOG="$LOG_DIR/04-services-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$LOG_DIR"

UNITS=(ModemManager.service open-iscsi.service iscsid.service iscsid.socket cups-browsed.service)

main() {
    local u
    for u in "${UNITS[@]}"; do
        if systemctl cat "$u" >/dev/null 2>&1; then
            systemctl disable --now "$u" 2>&1 | sed 's/^/    /'
            systemctl mask "$u" 2>&1 | sed 's/^/    /'
            printf '  %-22s enabled=%-8s active=%s\n' "$u" "$(systemctl is-enabled "$u" 2>/dev/null)" "$(systemctl is-active "$u" 2>/dev/null)"
        else
            printf '  %-22s not installed, skipped\n' "$u"
        fi
    done
    printf '  %-22s enabled=%-8s active=%s (kept for Chromecast)\n' avahi-daemon.service \
        "$(systemctl is-enabled avahi-daemon.service 2>/dev/null)" "$(systemctl is-active avahi-daemon.service 2>/dev/null)"
    echo "Done. Log: $LOG"
}

main 2>&1 | tee "$LOG"
chown -R "$OWNER": "$LOG_DIR" 2>/dev/null || true
