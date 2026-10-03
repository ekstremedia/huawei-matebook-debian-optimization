#!/usr/bin/env bash
# 05-browsers.sh - Native Wayland + Intel hardware video decoding (VA-API) for Chrome and Brave.
#
# Run as your NORMAL user (not sudo):  bash scripts/05-browsers.sh
#
# Creates per-user copies of the browsers' .desktop launchers in ~/.local/share/applications
# with extra command-line flags. GNOME then starts the browsers with these flags from the
# app grid / dock. Package updates do not touch the copies; re-run this script after a browser
# update if the system launcher changed. Undo: delete the two files it reports.
#
# Note: the Comet Lake iGPU decodes H.264, HEVC and VP9 in hardware but NOT AV1. YouTube
# prefers AV1, so also install the "enhanced-h264ify" extension and tick only "Block AV1".
set -euo pipefail

if [[ $EUID -eq 0 ]]; then echo "Run this as your normal user, not with sudo."; exit 1; fi

FLAGS='--ozone-platform=wayland --enable-features=AcceleratedVideoDecodeLinuxGL,AcceleratedVideoDecodeLinuxZeroCopyGL,AcceleratedVideoEncoder'
DEST="$HOME/.local/share/applications"
mkdir -p "$DEST"

for app in google-chrome brave-browser; do
    src="/usr/share/applications/$app.desktop"
    if [[ ! -f $src ]]; then echo "  $app: not installed, skipped"; continue; fi
    # Insert the flags right after the binary on every Exec= line (main window, new window, incognito).
    sed -E "s#^(Exec=/usr/bin/[a-z-]+-stable)#\1 $FLAGS#" "$src" > "$DEST/$app.desktop"
    sed -i '1a # Local override (huawei-matebook-debian-optimization): native Wayland + VA-API video decoding. Delete to undo.' "$DEST/$app.desktop"
    echo "  $app: wrote $DEST/$app.desktop"
done

update-desktop-database "$DEST" 2>/dev/null || true
echo "Done. Fully quit the browsers and start them again from the GNOME menu."
echo "Check: chrome://gpu (or brave://gpu) -> 'Video Decode: Hardware accelerated'."
