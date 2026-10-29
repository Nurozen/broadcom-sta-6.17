#!/bin/bash
#
# Patch broadcom-sta-dkms 6.30.223.271 for Linux kernel 6.17+
#
# Usage:
#   sudo apt install broadcom-sta-dkms
#   sudo bash patch-and-build.sh
#
# This script patches the existing broadcom-sta-dkms source in-place
# and rebuilds via DKMS. All patches are idempotent (safe to run twice).
#
# Patches applied (target state = repo @ 98e7c81):
#   1.  Makefile: EXTRA_CFLAGS -> ccflags-y, EXTRA_LDFLAGS -> ldflags-y
#   2.  wl_ioctl: ndo_do_ioctl -> ndo_siocdevprivate (6.13+)
#   3.  Timer API: from_timer/del_timer ports (6.17)
#   4.  #include <linux/timer.h>
#   5.  cfg80211: radio_idx for set_tx_power/set_wiphy_params (6.17), fallthrough
#   6.  strncpy -> strscpy/strscpy_pad/memcpy for 7.2+ (linux_osl.c, wl_linux.c)
#   7.  #include <linux/unaligned.h> instead of asm/unaligned.h for 6.12+
#   8.  cfg80211: 7.1 wdev-based get_station/get_tx_power/
#       add_key/del_key/get_key
#   9.  lib80211.h: vendor-side header for 6.13+ (net/lib80211.h
#       removed from the kernel in 6.13)
#   10. dkms.conf: objtool=/bin/true (PVE 7.x objtool link fix)
#
set -e

SRC="/usr/src/broadcom-sta-6.30.223.271"
KVER=$(uname -r)

echo "=== Broadcom STA driver patch for kernel $KVER ==="
echo ""

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Please run as root: sudo bash $0"
    exit 1
fi

if [ ! -d "$SRC" ]; then
    echo "ERROR: $SRC not found."
    echo "Install it first: sudo apt install broadcom-sta-dkms"
    exit 1
fi

# ---------------------------------------------------------------
# 1. Makefile: EXTRA_CFLAGS -> ccflags-y, EXTRA_LDFLAGS -> ldflags-y
# ---------------------------------------------------------------
echo "[1/11] Patching Makefile (EXTRA_CFLAGS -> ccflags-y)..."
if grep -qE 'EXTRA_CFLAGS|EXTRA_LDFLAGS' "$SRC/Makefile"; then
    sed -i 's/EXTRA_CFLAGS/ccflags-y/g' "$SRC/Makefile"
    sed -i 's/EXTRA_LDFLAGS/ldflags-y/g' "$SRC/Makefile"
    echo "  Patched."
elif grep -q 'ccflags-y' "$SRC/Makefile"; then
    echo "  Already patched, skipping."
else
    echo "ERROR: Makefile has neither legacy EXTRA_CFLAGS nor patched ccflags-y; unsupported source layout." >&2
    exit 1
fi

# ---------------------------------------------------------------
# 2. wl_linux.c/h: ndo_do_ioctl -> ndo_siocdevprivate
# ---------------------------------------------------------------
echo "[2/11] Patching wl_linux.c (ndo_do_ioctl -> ndo_siocdevprivate)..."
if grep -q 'ndo_do_ioctl' "$SRC/src/wl/sys/wl_linux.c"; then
    sed -i 's/\.ndo_do_ioctl = wl_ioctl/.ndo_siocdevprivate = wl_ioctl/g' "$SRC/src/wl/sys/wl_linux.c"
    sed -i 's/^wl_ioctl(struct net_device \*dev, struct ifreq \*ifr, int cmd)/wl_ioctl(struct net_device *dev, struct ifreq *ifr, void __user *data, int cmd)/' "$SRC/src/wl/sys/wl_linux.c"
    sed -i 's/extern int  wl_ioctl(struct net_device \*dev, struct ifreq \*ifr, int cmd);/extern int  wl_ioctl(struct net_device *dev, struct ifreq *ifr, void __user *data, int cmd);/' "$SRC/src/wl/sys/wl_linux.h"
    echo "  Patched."
elif grep -q '\.ndo_siocdevprivate = wl_ioctl' "$SRC/src/wl/sys/wl_linux.c"; then
    echo "  Already patched, skipping."
else
    echo "ERROR: Unable to locate the ioctl operation in wl_linux.c; unsupported source layout." >&2
    exit 1
fi

# ---------------------------------------------------------------
# 3. Timer API: from_timer -> timer_container_of, del_timer -> timer_delete
# ---------------------------------------------------------------
echo "[3/11] Patching timer API..."
if grep -q 'from_timer' "$SRC/src/wl/sys/wl_linux.c"; then
    sed -i 's/from_timer(t, tl, timer)/timer_container_of(t, tl, timer)/' "$SRC/src/wl/sys/wl_linux.c"
    echo "  Patched from_timer -> timer_container_of."
else
    echo "  from_timer already patched, skipping."
fi

if grep -q 'del_timer(&' "$SRC/src/wl/sys/wl_linux.c"; then
    sed -i 's/del_timer(&/timer_delete(\&/g' "$SRC/src/wl/sys/wl_linux.c"
    echo "  Patched del_timer -> timer_delete."
else
    echo "  del_timer already patched, skipping."
fi

if grep -qE 'del_timer_sync\(timer\) +del_timer\(timer\)' "$SRC/src/include/linuxver.h"; then
    sed -i 's/#define del_timer_sync(timer) del_timer(timer)/#define del_timer_sync(timer) timer_delete(timer)/' "$SRC/src/include/linuxver.h"
    echo "  Patched del_timer_sync -> timer_delete in linuxver.h."
else
    echo "  del_timer_sync already patched, skipping."
fi

# ---------------------------------------------------------------
# 4. Add #include <linux/timer.h>
# ---------------------------------------------------------------
echo "[4/11] Ensuring linux/timer.h is included..."
if ! grep -q '#include <linux/timer.h>' "$SRC/src/wl/sys/wl_linux.c"; then
    sed -i '/#include <linux\/delay.h>/a #include <linux/timer.h>' "$SRC/src/wl/sys/wl_linux.c"
    if ! grep -Fq '#include <linux/timer.h>' "$SRC/src/wl/sys/wl_linux.c"; then
        echo "ERROR: Could not insert linux/timer.h (linux/delay.h anchor absent)." >&2
        exit 1
    fi
    echo "  Added."
else
    echo "  Already included, skipping."
fi

# ---------------------------------------------------------------
# 5. cfg80211 API: add radio_idx param (6.17), fix fallthrough
# ---------------------------------------------------------------
echo "[5/11] Patching cfg80211 API (radio_idx, fallthrough)..."
python3 - "$SRC/src/wl/sys/wl_cfg80211_hybrid.c" << 'PYEOF'
import sys

cfg_path = sys.argv[1]

with open(cfg_path, 'r') as f:
    content = f.read()

changes = 0

# 1. set_wiphy_params forward declaration
old = 'static s32 wl_cfg80211_set_wiphy_params(struct wiphy *wiphy, u32 changed);'
new = """#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 17, 0)
static s32 wl_cfg80211_set_wiphy_params(struct wiphy *wiphy, int radio_idx, u32 changed);
#else
static s32 wl_cfg80211_set_wiphy_params(struct wiphy *wiphy, u32 changed);
#endif"""
if new in content:
    print("  set_wiphy_params forward declaration already patched")
elif old in content:
    content = content.replace(old, new, 1)
    changes += 1
    print("  Patched set_wiphy_params forward declaration")
else:
    raise SystemExit("ERROR: set_wiphy_params forward declaration: neither unpatched nor patched source pattern found")

# 2. set_wiphy_params implementation
old = 'static s32 wl_cfg80211_set_wiphy_params(struct wiphy *wiphy, u32 changed)\n{'
new = """#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 17, 0)
static s32 wl_cfg80211_set_wiphy_params(struct wiphy *wiphy, int radio_idx, u32 changed)
#else
static s32 wl_cfg80211_set_wiphy_params(struct wiphy *wiphy, u32 changed)
#endif
{"""
if new in content:
    print("  set_wiphy_params implementation already patched")
elif old in content:
    content = content.replace(old, new, 1)
    changes += 1
    print("  Patched set_wiphy_params implementation")
else:
    raise SystemExit("ERROR: set_wiphy_params implementation: neither unpatched nor patched source pattern found")

# 3. set_tx_power forward declaration
old = """#if LINUX_VERSION_CODE >= KERNEL_VERSION(3, 8, 0)
static s32
wl_cfg80211_set_tx_power(struct wiphy *wiphy, struct wireless_dev *wdev,
                         enum nl80211_tx_power_setting type, s32 mbm);
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 36)"""
new = """#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 17, 0)
static s32
wl_cfg80211_set_tx_power(struct wiphy *wiphy, struct wireless_dev *wdev,
                         int radio_idx,
                         enum nl80211_tx_power_setting type, s32 mbm);
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(3, 8, 0)
static s32
wl_cfg80211_set_tx_power(struct wiphy *wiphy, struct wireless_dev *wdev,
                         enum nl80211_tx_power_setting type, s32 mbm);
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 36)"""
if new in content:
    print("  set_tx_power forward declaration already patched")
elif old in content:
    content = content.replace(old, new, 1)
    changes += 1
    print("  Patched set_tx_power forward declaration")
else:
    raise SystemExit("ERROR: set_tx_power forward declaration: neither unpatched nor patched source pattern found")

# 4. set_tx_power implementation
old = """#if LINUX_VERSION_CODE >= KERNEL_VERSION(3, 8, 0)
static s32
wl_cfg80211_set_tx_power(struct wiphy *wiphy, struct wireless_dev *wdev,
                         enum nl80211_tx_power_setting type, s32 mbm)
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 36)"""
new = """#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 17, 0)
static s32
wl_cfg80211_set_tx_power(struct wiphy *wiphy, struct wireless_dev *wdev,
                         int radio_idx,
                         enum nl80211_tx_power_setting type, s32 mbm)
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(3, 8, 0)
static s32
wl_cfg80211_set_tx_power(struct wiphy *wiphy, struct wireless_dev *wdev,
                         enum nl80211_tx_power_setting type, s32 mbm)
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 36)"""
if new in content:
    print("  set_tx_power implementation already patched")
elif old in content:
    content = content.replace(old, new, 1)
    changes += 1
    print("  Patched set_tx_power implementation")
else:
    raise SystemExit("ERROR: set_tx_power implementation: neither unpatched nor patched source pattern found")

# 5. get_tx_power forward declaration
old = """#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 14, 0)
static s32 wl_cfg80211_get_tx_power(struct wiphy *wiphy, struct wireless_dev *wdev, u32 /*link_id*/, s32 *dbm);
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(3, 8, 0)"""
new = """#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 17, 0)
static s32 wl_cfg80211_get_tx_power(struct wiphy *wiphy, struct wireless_dev *wdev, int radio_idx, unsigned int link_id, s32 *dbm);
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(6, 14, 0)
static s32 wl_cfg80211_get_tx_power(struct wiphy *wiphy, struct wireless_dev *wdev, u32 /*link_id*/, s32 *dbm);
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(3, 8, 0)"""
if new in content:
    print("  get_tx_power forward declaration already patched")
elif old in content:
    content = content.replace(old, new, 1)
    changes += 1
    print("  Patched get_tx_power forward declaration")
else:
    print("  get_tx_power forward declaration: not found (handled in 7.1 step if 6.14 base absent)")

# 6. get_tx_power implementation
old = """#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 14, 0)
static s32 wl_cfg80211_get_tx_power(struct wiphy *wiphy, struct wireless_dev *wdev, u32 /*link_id*/, s32 *dbm)
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(3, 8, 0)"""
new = """#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 17, 0)
static s32 wl_cfg80211_get_tx_power(struct wiphy *wiphy, struct wireless_dev *wdev, int radio_idx, unsigned int link_id, s32 *dbm)
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(6, 14, 0)
static s32 wl_cfg80211_get_tx_power(struct wiphy *wiphy, struct wireless_dev *wdev, u32 /*link_id*/, s32 *dbm)
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(3, 8, 0)"""
if new in content:
    print("  get_tx_power implementation already patched")
elif old in content:
    content = content.replace(old, new, 1)
    changes += 1
    print("  Patched get_tx_power implementation")
else:
    print("  get_tx_power implementation: not found (handled in 7.1 step if 6.14 base absent)")

# 7. fallthrough
old = '        /* falls through */'
new = '        fallthrough;'
if new in content:
    print("  fallthrough statement already patched")
elif old in content:
    content = content.replace(old, new)
    changes += 1
    print("  Fixed fallthrough statement")

with open(cfg_path, 'w') as f:
    f.write(content)

if changes == 0:
    print("  All cfg80211 patches already applied, skipping.")
else:
    print(f"  Applied {changes} cfg80211 patches.")
PYEOF

# ---------------------------------------------------------------
# 6. strscpy: strncpy -> strscpy/strscpy_pad/memcpy for kernels 7.2+
#    (strncpy() became a compile error in 7.2)
# ---------------------------------------------------------------
echo "[6/11] Patching strncpy -> strscpy (7.2+) in linux_osl.c and wl_linux.c..."
python3 - "$SRC/src/shared/linux_osl.c" "$SRC/src/wl/sys/wl_linux.c" << 'PYEOF'
import sys

osl_path, wl_path = sys.argv[1], sys.argv[2]

def patch_file(path, label, replacements):
    with open(path, 'r') as f:
        content = f.read()
    changes = 0
    for old, new, name in replacements:
        if new in content:
            print(f"  {name}: already patched")
        elif old in content:
            content = content.replace(old, new, 1)
            changes += 1
            print(f"  Patched: {name}")
        else:
            raise SystemExit(f"ERROR: {label}: {name}: neither unpatched nor patched source pattern found")
    if changes:
        with open(path, 'w') as f:
            f.write(content)
        print(f"  {label}: applied {changes} replacement(s).")
    else:
        print(f"  {label}: nothing to do (already patched).")

patch_file(osl_path, "linux_osl.c", [
    (
        "\tstrncpy(p->file, basename, BCM_MEM_FILENAME_LEN);\n"
        "\tp->file[BCM_MEM_FILENAME_LEN - 1] = '\\0';",
        "#if LINUX_VERSION_CODE >= KERNEL_VERSION(7, 2, 0)\n"
        "\tstrscpy(p->file, basename, BCM_MEM_FILENAME_LEN);\n"
        "#else\n"
        "\tstrncpy(p->file, basename, BCM_MEM_FILENAME_LEN);\n"
        "\tp->file[BCM_MEM_FILENAME_LEN - 1] = '\\0';\n"
        "#endif",
        "strncpy(p->file) -> strscpy",
    ),
    (
        "\treturn (strncpy(d, s, n));",
        "#if LINUX_VERSION_CODE >= KERNEL_VERSION(7, 2, 0)\n"
        "\tstrscpy_pad(d, s, n);\n"
        "\treturn (d);\n"
        "#else\n"
        "\treturn (strncpy(d, s, n));\n"
        "#endif",
        "osl_strncpy -> strscpy_pad",
    ),
])

patch_file(wl_path, "wl_linux.c", [
    (
        "\tstrncpy(dev->name, intf_name, IFNAMSIZ-1);\n"
        "\tdev->name[IFNAMSIZ-1] = '\\0';",
        "#if LINUX_VERSION_CODE >= KERNEL_VERSION(7, 2, 0)\n"
        "\tstrscpy(dev->name, intf_name, IFNAMSIZ);\n"
        "#else\n"
        "\tstrncpy(dev->name, intf_name, IFNAMSIZ-1);\n"
        "\tdev->name[IFNAMSIZ-1] = '\\0';\n"
        "#endif",
        "strncpy(dev->name) -> strscpy",
    ),
    (
        "\tstrncpy(info->version, EPI_VERSION_STR, sizeof(info->version));\n"
        "\tinfo->version[(sizeof(info->version))-1] = '\\0';",
        "#if LINUX_VERSION_CODE >= KERNEL_VERSION(7, 2, 0)\n"
        "\tstrscpy(info->version, EPI_VERSION_STR, sizeof(info->version));\n"
        "#else\n"
        "\tstrncpy(info->version, EPI_VERSION_STR, sizeof(info->version));\n"
        "\tinfo->version[(sizeof(info->version))-1] = '\\0';\n"
        "#endif",
        "strncpy(info->version) -> strscpy",
    ),
    (
        "\tstrncpy(wlif->dev->name, wlif->name, strlen(wlif->name));",
        "#if LINUX_VERSION_CODE >= KERNEL_VERSION(7, 2, 0)\n"
        "\tmemcpy(wlif->dev->name, wlif->name, strlen(wlif->name));\n"
        "#else\n"
        "\tstrncpy(wlif->dev->name, wlif->name, strlen(wlif->name));\n"
        "#endif",
        "strncpy(wlif->dev->name) -> memcpy",
    ),
])
PYEOF

# ---------------------------------------------------------------
# 7. unaligned.h: asm/unaligned.h moved to linux/unaligned.h in 6.12
# ---------------------------------------------------------------
echo "[7/11] Patching unaligned.h include (6.12+)..."
python3 - "$SRC/src/wl/sys/wl_linux.c" << 'PYEOF'
import sys

path = sys.argv[1]

with open(path, 'r') as f:
    content = f.read()

old = "#include <asm/unaligned.h>"
new = """#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 12, 0)
#include <linux/unaligned.h>
#else
#include <asm/unaligned.h>
#endif"""
if new in content:
    print("  unaligned.h already patched, skipping.")
elif old in content:
    content = content.replace(old, new, 1)
    with open(path, 'w') as f:
        f.write(content)
    print("  Patched unaligned.h include guard.")
else:
    raise SystemExit("ERROR: unaligned.h: neither the original nor guarded include pattern was found")
PYEOF

# ---------------------------------------------------------------
# 8. cfg80211: 7.1 wdev-based ops (get_station, get_tx_power,
#    add_key, del_key, get_key)
# ---------------------------------------------------------------
echo "[8/11] Patching cfg80211 7.1 wdev-based ops..."
python3 - "$SRC/src/wl/sys/wl_cfg80211_hybrid.c" << 'PYEOF'
import sys

cfg_path = sys.argv[1]

with open(cfg_path, 'r') as f:
    content = f.read()

changes = 0

# 1. get_station forward declaration (>= 7.1: wdev-based)
old = (
    "#else\n"
    "static s32 wl_cfg80211_get_station(struct wiphy *wiphy,\n"
    "           struct net_device *dev, const u8 *mac, struct station_info *sinfo);\n"
    "#endif"
)
new = (
    "#elif LINUX_VERSION_CODE < KERNEL_VERSION(7, 1, 0)\n"
    "static s32 wl_cfg80211_get_station(struct wiphy *wiphy,\n"
    "           struct net_device *dev, const u8 *mac, struct station_info *sinfo);\n"
    "#else\n"
    "static s32 wl_cfg80211_get_station(struct wiphy *wiphy,\n"
    "           struct wireless_dev *wdev, const u8 *mac, struct station_info *sinfo);\n"
    "#endif"
)
if old in content:
    content = content.replace(old, new, 1)
    changes += 1
    print("  Patched get_station forward declaration (7.1)")
elif new in content:
    print("  get_station forward declaration already patched")
else:
    raise SystemExit("ERROR: get_station forward declaration: neither unpatched nor patched source pattern found")

# 2. get_tx_power forward declaration (>= 6.17: radio_idx + link_id;
#    >= 6.14: link_id)
old = (
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(3, 8, 0)\n"
    "static s32 wl_cfg80211_get_tx_power(struct wiphy *wiphy, struct wireless_dev *wdev, s32 *dbm);\n"
)
new = (
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 17, 0)\n"
    "static s32 wl_cfg80211_get_tx_power(struct wiphy *wiphy, struct wireless_dev *wdev, int radio_idx, unsigned int link_id, s32 *dbm);\n"
    "#elif LINUX_VERSION_CODE >= KERNEL_VERSION(6, 14, 0)\n"
    "static s32 wl_cfg80211_get_tx_power(struct wiphy *wiphy, struct wireless_dev *wdev, u32 /*link_id*/, s32 *dbm);\n"
    "#elif LINUX_VERSION_CODE >= KERNEL_VERSION(3, 8, 0)\n"
    "static s32 wl_cfg80211_get_tx_power(struct wiphy *wiphy, struct wireless_dev *wdev, s32 *dbm);\n"
)
if old in content:
    content = content.replace(old, new, 1)
    changes += 1
    print("  Patched get_tx_power forward declaration (6.17/6.14)")
elif new in content:
    print("  get_tx_power forward declaration already patched")
else:
    raise SystemExit("ERROR: get_tx_power forward declaration: neither unpatched nor patched source pattern found")

# 3. get_tx_power implementation (>= 6.17 / >= 6.14 branches)
old = (
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(3, 8, 0)\n"
    "static s32 wl_cfg80211_get_tx_power(struct wiphy *wiphy, struct wireless_dev *wdev, s32 *dbm)\n"
)
new = (
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 17, 0)\n"
    "static s32 wl_cfg80211_get_tx_power(struct wiphy *wiphy, struct wireless_dev *wdev, int radio_idx, unsigned int link_id, s32 *dbm)\n"
    "#elif LINUX_VERSION_CODE >= KERNEL_VERSION(6, 14, 0)\n"
    "static s32 wl_cfg80211_get_tx_power(struct wiphy *wiphy, struct wireless_dev *wdev, u32 /*link_id*/, s32 *dbm)\n"
    "#elif LINUX_VERSION_CODE >= KERNEL_VERSION(3, 8, 0)\n"
    "static s32 wl_cfg80211_get_tx_power(struct wiphy *wiphy, struct wireless_dev *wdev, s32 *dbm)\n"
)
if old in content:
    content = content.replace(old, new, 1)
    changes += 1
    print("  Patched get_tx_power implementation (6.17/6.14)")
elif new in content:
    print("  get_tx_power implementation already patched")
else:
    raise SystemExit("ERROR: get_tx_power implementation: neither unpatched nor patched source pattern found")

# 4. key-ops forward declarations (>= 7.1: wdev-based)
old = (
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0)\n"
    "static s32 wl_cfg80211_add_key(struct wiphy *wiphy, struct net_device *dev,\n"
)
new = (
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(7, 1, 0)\n"
    "static s32 wl_cfg80211_add_key(struct wiphy *wiphy, struct wireless_dev *wdev,\n"
    "           int link_id, u8 key_idx, bool pairwise, const u8 *mac_addr,\n"
    "           struct key_params *params);\n"
    "static s32 wl_cfg80211_del_key(struct wiphy *wiphy, struct wireless_dev *wdev,\n"
    "           int link_id, u8 key_idx, bool pairwise, const u8 *mac_addr);\n"
    "static s32 wl_cfg80211_get_key(struct wiphy *wiphy, struct wireless_dev *wdev,\n"
    "           int link_id, u8 key_idx, bool pairwise, const u8 *mac_addr,\n"
    "           void *cookie,\n"
    "           void (*callback) (void *cookie, struct key_params *params));\n"
    "#elif LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0)\n"
    "static s32 wl_cfg80211_add_key(struct wiphy *wiphy, struct net_device *dev,\n"
)
if old in content:
    content = content.replace(old, new, 1)
    changes += 1
    print("  Patched key-ops forward declarations (7.1)")
elif new in content:
    print("  key-ops forward declarations already patched")
else:
    raise SystemExit("ERROR: key-ops forward declarations: neither unpatched nor patched source pattern found")

# 5. add_key implementation signature (>= 7.1: wdev-based)
old = (
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0)\n"
    "static s32\n"
    "wl_cfg80211_add_key(struct wiphy *wiphy, struct net_device *dev,\n"
)
new = (
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(7, 1, 0)\n"
    "static s32\n"
    "wl_cfg80211_add_key(struct wiphy *wiphy, struct wireless_dev *wdev,\n"
    "                    int link_id, u8 key_idx, bool pairwise, const u8 *mac_addr,\n"
    "                    struct key_params *params)\n"
    "#elif LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0)\n"
    "static s32\n"
    "wl_cfg80211_add_key(struct wiphy *wiphy, struct net_device *dev,\n"
)
if old in content:
    content = content.replace(old, new, 1)
    changes += 1
    print("  Patched add_key implementation (7.1)")
elif new in content:
    print("  add_key implementation already patched")
else:
    raise SystemExit("ERROR: add_key implementation: neither unpatched nor patched source pattern found")

# 6. add_key implementation body: derive dev from wdev (>= 7.1)
old = (
    "{\n"
    "\tstruct wl_cfg80211_priv *wl = ndev_to_wl(dev);\n"
    "\tstruct wl_wsec_key key;\n"
    "\ts32 secval, secnew = 0;\n"
)
new = (
    "{\n"
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(7, 1, 0)\n"
    "\tstruct net_device *dev = wdev->netdev;\n"
    "#endif\n"
    "\tstruct wl_cfg80211_priv *wl = ndev_to_wl(dev);\n"
    "\tstruct wl_wsec_key key;\n"
    "\ts32 secval, secnew = 0;\n"
)
if old in content:
    content = content.replace(old, new, 1)
    changes += 1
    print("  Patched add_key body dev derivation (7.1)")
elif new in content:
    print("  add_key body already patched")
else:
    raise SystemExit("ERROR: add_key body: neither unpatched nor patched source pattern found")

# 7. del_key implementation signature (>= 7.1: wdev-based)
old = (
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0)\n"
    "static s32\n"
    "wl_cfg80211_del_key(struct wiphy *wiphy, struct net_device *dev,\n"
)
new = (
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(7, 1, 0)\n"
    "static s32\n"
    "wl_cfg80211_del_key(struct wiphy *wiphy, struct wireless_dev *wdev,\n"
    "                    int link_id, u8 key_idx, bool pairwise, const u8 *mac_addr)\n"
    "#elif LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0)\n"
    "static s32\n"
    "wl_cfg80211_del_key(struct wiphy *wiphy, struct net_device *dev,\n"
)
if old in content:
    content = content.replace(old, new, 1)
    changes += 1
    print("  Patched del_key implementation (7.1)")
elif new in content:
    print("  del_key implementation already patched")
else:
    raise SystemExit("ERROR: del_key implementation: neither unpatched nor patched source pattern found")

# 8. del_key implementation body
old = (
    "{\n"
    "\tstruct wl_wsec_key key;\n"
    "\ts32 err = 0;\n"
)
new = (
    "{\n"
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(7, 1, 0)\n"
    "\tstruct net_device *dev = wdev->netdev;\n"
    "#endif\n"
    "\tstruct wl_wsec_key key;\n"
    "\ts32 err = 0;\n"
)
if old in content:
    content = content.replace(old, new, 1)
    changes += 1
    print("  Patched del_key body dev derivation (7.1)")
elif new in content:
    print("  del_key body already patched")
else:
    raise SystemExit("ERROR: del_key body: neither unpatched nor patched source pattern found")

# 9. get_key implementation signature (>= 7.1: wdev-based)
old = (
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0)\n"
    "static s32\n"
    "wl_cfg80211_get_key(struct wiphy *wiphy, struct net_device *dev,\n"
)
new = (
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(7, 1, 0)\n"
    "static s32\n"
    "wl_cfg80211_get_key(struct wiphy *wiphy, struct wireless_dev *wdev,\n"
    "                    int link_id, u8 key_idx, bool pairwise, const u8 *mac_addr,\n"
    "                    void *cookie,\n"
    "                    void (*callback) (void *cookie, struct key_params * params))\n"
    "#elif LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0)\n"
    "static s32\n"
    "wl_cfg80211_get_key(struct wiphy *wiphy, struct net_device *dev,\n"
)
if old in content:
    content = content.replace(old, new, 1)
    changes += 1
    print("  Patched get_key implementation (7.1)")
elif new in content:
    print("  get_key implementation already patched")
else:
    raise SystemExit("ERROR: get_key implementation: neither unpatched nor patched source pattern found")

# 10. get_key implementation body
old = (
    "{\n"
    "\tstruct key_params params;\n"
    "\tstruct wl_wsec_key key;\n"
)
new = (
    "{\n"
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(7, 1, 0)\n"
    "\tstruct net_device *dev = wdev->netdev;\n"
    "#endif\n"
    "\tstruct key_params params;\n"
    "\tstruct wl_wsec_key key;\n"
)
if old in content:
    content = content.replace(old, new, 1)
    changes += 1
    print("  Patched get_key body dev derivation (7.1)")
elif new in content:
    print("  get_key body already patched")
else:
    raise SystemExit("ERROR: get_key body: neither unpatched nor patched source pattern found")

# 11. get_station implementation (>= 7.1: wdev-based) + body
old = (
    "#else\n"
    "static s32\n"
    "wl_cfg80211_get_station(struct wiphy *wiphy, struct net_device *dev,\n"
    "                        const u8 *mac, struct station_info *sinfo)\n"
    "#endif\n"
    "{\n"
    "\tstruct wl_cfg80211_priv *wl = wiphy_to_wl(wiphy);\n"
    "\tscb_val_t scb_val;\n"
)
new = (
    "#elif LINUX_VERSION_CODE < KERNEL_VERSION(7, 1, 0)\n"
    "static s32\n"
    "wl_cfg80211_get_station(struct wiphy *wiphy, struct net_device *dev,\n"
    "                        const u8 *mac, struct station_info *sinfo)\n"
    "#else\n"
    "static s32\n"
    "wl_cfg80211_get_station(struct wiphy *wiphy, struct wireless_dev *wdev,\n"
    "                        const u8 *mac, struct station_info *sinfo)\n"
    "#endif\n"
    "{\n"
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(7, 1, 0)\n"
    "\tstruct net_device *dev = wdev->netdev;\n"
    "#endif\n"
    "\tstruct wl_cfg80211_priv *wl = wiphy_to_wl(wiphy);\n"
    "\tscb_val_t scb_val;\n"
)
if old in content:
    content = content.replace(old, new, 1)
    changes += 1
    print("  Patched get_station implementation + body (7.1)")
elif new in content:
    print("  get_station implementation already patched")
else:
    raise SystemExit("ERROR: get_station implementation: neither unpatched nor patched source pattern found")

with open(cfg_path, 'w') as f:
    f.write(content)

if changes == 0:
    print("  All 7.1 wdev-ops patches already applied, skipping.")
else:
    print(f"  Applied {changes} 7.1 wdev-ops patches.")
PYEOF

# ---------------------------------------------------------------
# 9. lib80211.h: <net/lib80211.h> was removed from the kernel in
#    6.13; ship the header with the driver instead
# ---------------------------------------------------------------
echo "[9/11] Patching lib80211.h (vendor-side header, 6.13+)..."
if ! grep -q '#include "lib80211.h"' "$SRC/src/include/linuxver.h"; then
    python3 - "$SRC/src/include/linuxver.h" << 'PYEOF'
import sys

path = sys.argv[1]

with open(path, 'r') as f:
    content = f.read()

old = (
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 29)\n"
    "#include <net/lib80211.h>\n"
    "#endif"
)
new = (
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 29)\n"
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 13, 0)\n"
    '#include "lib80211.h"\n'
    "#else\n"
    "#include <net/lib80211.h>\n"
    "#endif\n"
    "#endif\n"
)
if old in content:
    content = content.replace(old, new, 1)
    with open(path, 'w') as f:
        f.write(content)
    print("  Patched linuxver.h include guard.")
elif new in content:
    print("  linuxver.h already patched, skipping.")
else:
    raise SystemExit("ERROR: linuxver.h: expected lib80211 include anchor not found")
PYEOF
else
    echo "  linuxver.h already patched, skipping."
fi

if [ ! -f "$SRC/src/include/lib80211.h" ]; then
    cat > "$SRC/src/include/lib80211.h" << 'LIB80211_H_EOF'
/* SPDX-License-Identifier: GPL-2.0 */
/*
 * lib80211.h -- common bits for IEEE802.11 wireless drivers
 *
 * Copyright (c) 2008, John W. Linville <linville@tuxdriver.com>
 *
 * Some bits copied from old ieee80211 component, w/ original copyright
 * notices below:
 *
 * Original code based on Host AP (software wireless LAN access point) driver
 * for Intersil Prism2/2.5/3.
 *
 * Copyright (c) 2001-2002, SSH Communications Security Corp and Jouni Malinen
 * <j@w1.fi>
 * Copyright (c) 2002-2003, Jouni Malinen <j@w1.fi>
 *
 * Adaption to a generic IEEE 802.11 stack by James Ketrenos
 * <jketreno@linux.intel.com>
 *
 * Copyright (c) 2004, Intel Corporation
 *
 */

#ifndef LIB80211_H
#define LIB80211_H

#include <linux/types.h>
#include <linux/list.h>
#include <linux/atomic.h>
#include <linux/if.h>
#include <linux/skbuff.h>
#include <linux/ieee80211.h>
#include <linux/timer.h>
#include <linux/seq_file.h>

#define NUM_WEP_KEYS	4

enum {
	IEEE80211_CRYPTO_TKIP_COUNTERMEASURES = (1 << 0),
};

struct module;

struct lib80211_crypto_ops {
	const char *name;
	struct list_head list;

	/* init new crypto context (e.g., allocate private data space,
	 * select IV, etc.); returns NULL on failure or pointer to allocated
	 * private data on success */
	void *(*init) (int keyidx);

	/* deinitialize crypto context and free allocated private data */
	void (*deinit) (void *priv);

	/* encrypt/decrypt return < 0 on error or >= 0 on success. The return
	 * value from decrypt_mpdu is passed as the keyidx value for
	 * decrypt_msdu. skb must have enough head and tail room for the
	 * encryption; if not, error will be returned; these functions are
	 * called for all MPDUs (i.e., fragments).
	 */
	int (*encrypt_mpdu) (struct sk_buff * skb, int hdr_len, void *priv);
	int (*decrypt_mpdu) (struct sk_buff * skb, int hdr_len, void *priv);

	/* These functions are called for full MSDUs, i.e. full frames.
	 * These can be NULL if full MSDU operations are not needed. */
	int (*encrypt_msdu) (struct sk_buff * skb, int hdr_len, void *priv);
	int (*decrypt_msdu) (struct sk_buff * skb, int keyidx, int hdr_len,
			     void *priv);

	int (*set_key) (void *key, int len, u8 * seq, void *priv);
	int (*get_key) (void *key, int len, u8 * seq, void *priv);

	/* procfs handler for printing out key information and possible
	 * statistics */
	void (*print_stats) (struct seq_file *m, void *priv);

	/* Crypto specific flag get/set for configuration settings */
	unsigned long (*get_flags) (void *priv);
	unsigned long (*set_flags) (unsigned long flags, void *priv);

	/* maximum number of bytes added by encryption; encrypt buf is
	 * allocated with extra_prefix_len bytes, copy of in_buf, and
	 * extra_postfix_len; encrypt need not use all this space, but
	 * the result must start at the beginning of the buffer and correct
	 * length must be returned */
	int extra_mpdu_prefix_len, extra_mpdu_postfix_len;
	int extra_msdu_prefix_len, extra_msdu_postfix_len;

	struct module *owner;
};

struct lib80211_crypt_data {
	struct list_head list;	/* delayed deletion list */
	const struct lib80211_crypto_ops *ops;
	void *priv;
	atomic_t refcnt;
};

struct lib80211_crypt_info {
	char *name;
	/* Most clients will already have a lock,
	   so just point to that. */
	spinlock_t *lock;

	struct lib80211_crypt_data *crypt[NUM_WEP_KEYS];
	int tx_keyidx;		/* default TX key index (crypt[tx_keyidx]) */
	struct list_head crypt_deinit_list;
	struct timer_list crypt_deinit_timer;
	int crypt_quiesced;
};

int lib80211_crypt_info_init(struct lib80211_crypt_info *info, char *name,
                                spinlock_t *lock);
void lib80211_crypt_info_free(struct lib80211_crypt_info *info);
int lib80211_register_crypto_ops(const struct lib80211_crypto_ops *ops);
int lib80211_unregister_crypto_ops(const struct lib80211_crypto_ops *ops);
const struct lib80211_crypto_ops *lib80211_get_crypto_ops(const char *name);
void lib80211_crypt_delayed_deinit(struct lib80211_crypt_info *info,
				    struct lib80211_crypt_data **crypt);

#endif /* LIB80211_H */
LIB80211_H_EOF
    echo "  Installed lib80211.h."
else
    echo "  lib80211.h already present, skipping."
fi

# ---------------------------------------------------------------
# 10. dkms.conf: pass objtool=/bin/true by default (PVE 7.x builds
#     fail linking inlined modules without it)
# ---------------------------------------------------------------
echo "[10/11] Patching dkms.conf (objtool=/bin/true default)..."
if grep -q 'objtool=/bin/true' "$SRC/dkms.conf"; then
    echo "  Already set, skipping."
else
    sed -i 's|MAKE\[0\]="make KVER=\$kernelver"|MAKE[0]="make KVER=$kernelver objtool=/bin/true"|' "$SRC/dkms.conf"
    if grep -q 'objtool=/bin/true' "$SRC/dkms.conf"; then
        echo "  Patched."
    else
        echo "ERROR: dkms.conf MAKE[0] pattern not recognized; objtool workaround not installed." >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------
# 11. DKMS rebuild
# ---------------------------------------------------------------
echo "[11/11] Rebuilding driver with DKMS..."
# Only replace the build for the running kernel. Leave fallback kernels intact.
dkms remove broadcom-sta/6.30.223.271 -k "$KVER" 2>/dev/null || true
if ! dkms install broadcom-sta/6.30.223.271 -k "$KVER"; then
    echo "ERROR: DKMS installation failed for kernel $KVER." >&2
    echo "Check /var/lib/dkms/broadcom-sta/6.30.223.271/build/make.log" >&2
    exit 1
fi

echo ""
echo "=== Build complete ==="

if ls /lib/modules/$KVER/updates/dkms/wl.ko* 1>/dev/null 2>&1; then
    echo "Module built successfully!"
    echo ""
    echo "To activate the driver, run:"
    echo "  sudo modprobe -r brcmfmac bcma"
    echo "  sudo modprobe wl"
    echo ""
    echo "To make it permanent:"
    echo "  sudo tee /etc/modprobe.d/broadcom-wl.conf <<EOL"
    echo "  blacklist brcmfmac"
    echo "  blacklist bcma"
    echo "  blacklist b43"
    echo "  EOL"
else
    echo "Build FAILED. Check: /var/lib/dkms/broadcom-sta/6.30.223.271/build/make.log"
    exit 1
fi
