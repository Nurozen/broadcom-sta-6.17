#!/bin/bash
#
# Install this patched broadcom-sta (wl) driver via DKMS and activate it.
# Works on Linux 6.17 and 7.0+.
#
# Usage:  sudo bash install.sh
#
set -e

NAME=broadcom-sta
VER=6.30.223.271
SRC="/usr/src/$NAME-$VER"
KVER=$(uname -r)
HERE="$(cd "$(dirname "$0")" && pwd)"

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: run as root: sudo bash $0"
    exit 1
fi

echo "[1/5] Installing build dependencies..."
apt-get install -y dkms build-essential "linux-headers-$KVER"

echo "[2/5] Copying driver source to $SRC..."
dkms remove "$NAME/$VER" --all 2>/dev/null || true
rm -rf "$SRC"
mkdir -p "$SRC"
cp -a "$HERE"/Makefile "$HERE"/dkms.conf "$HERE"/objtool-wrapper.sh "$HERE"/src "$HERE"/lib "$SRC"/

echo "[3/5] Building and installing with DKMS for kernel $KVER..."
dkms add "$NAME/$VER"
dkms install "$NAME/$VER" -k "$KVER"

echo "[4/5] Blacklisting conflicting drivers..."
cat > /etc/modprobe.d/broadcom-wl.conf <<EOF
blacklist b43
blacklist b43legacy
blacklist bcma
blacklist ssb
blacklist brcmsmac
blacklist brcmfmac
EOF
update-initramfs -u -k "$KVER"

echo "[5/5] Loading wl driver..."
modprobe -r b43 b43legacy ssb bcma brcmsmac brcmfmac 2>/dev/null || true
modprobe wl

echo ""
echo "=== Done ==="
ip link | grep -E '^[0-9]+: wl' || echo "No wl* interface yet; try rebooting."
