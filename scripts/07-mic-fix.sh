#!/usr/bin/env bash
# 07-mic-fix.sh - Fix the internal microphone after the 4-speaker audio fix (02-apply.sh step 4).
#
# Problem: the 2018-model fixup (model=19e5:3204) also enables the headset-mic pin 0x19 with
# jack detection. On the MateBook X Pro 2020 that pin reports "plugged in" with nothing in the
# jack ('Mic Jack' = on, 'Headphone Jack' = off). PipeWire then records from the empty jack
# (silence) and marks the internal mic as unavailable.
#
# Fix: an HDA patch file that keeps the fixup but overrides pin 0x19 to 0x04a11140
# (misc bit 0x1 = "no presence detect"). Without a false "plugged" signal, PipeWire picks the
# internal mic (priority 89) over the jack mic (87); a headset mic can still be chosen manually.
#
# Run:   sudo bash scripts/07-mic-fix.sh   then reboot
# Undo:  sudo rm /lib/firmware/matebook-x-pro-2020-audio.fw and remove 'patch=...' from
#        /etc/modprobe.d/matebook-audio.conf, then reboot
set -Eeuo pipefail
export LC_ALL=C

if [[ $EUID -ne 0 ]]; then echo "Please run with sudo: sudo bash $0"; exit 1; fi
if [[ $(cat /sys/class/sound/hwC0D0/subsystem_id 2>/dev/null) != 0x1e833223 ]]; then
    echo "Expected the MateBook X Pro 2020 codec (subsystem 0x1e833223). Aborting."; exit 1
fi

PATCH=/lib/firmware/matebook-x-pro-2020-audio.fw
CONF=/etc/modprobe.d/matebook-audio.conf

cat > "$PATCH" <<'EOF'
[codec]
0x10ec0256 0x1e833223 0

[pincfg]
0x19 0x04a11140
EOF
echo "  - wrote $PATCH"

cat > "$CONF" <<'EOF'
# MateBook X Pro 2020 (ALC256, codec SSID 1e83:3223): apply the upstream kernel fixup of the
# 2018 model "Huawei MACH-WX9" (SSID 19e5:3204, ALC256_FIXUP_HUAWEI_MACH_WX9_PINS): enables the
# second speaker pair (pin 0x14), the headset mic (pin 0x19) and the mic-mute LED hook.
# The patch file turns off jack detection on pin 0x19, which falsely reports "plugged in" on
# this model and would hide the internal mic.
# Installed by huawei-matebook-debian-optimization (02-apply.sh / 07-mic-fix.sh).
# Undo: delete this file (and the patch file) and reboot.
options snd-hda-intel model=19e5:3204 patch=matebook-x-pro-2020-audio.fw
EOF
echo "  - wrote $CONF"
echo "Done. Reboot, then the internal microphone should be the default input."
