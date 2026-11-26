# broadcom-sta patched for Linux 6.17+ and 7.0

Broadcom STA wireless driver (wl) version 6.30.223.271, patched to compile and run on **Linux kernel 6.17+, including 7.0**.

Fixes WiFi on **MacBook Pro 2015, iMac** (and other Macs) running Linux with kernel 6.17+ / 7.0.

Based on `broadcom-sta-dkms 6.30.223.271-23ubuntu1.1` from Ubuntu non-free.

## Tested On

- **MacBook Pro Mid-2015 (MacBookPro11,5)** — BCM4360, Ubuntu 24.04, kernel 6.17.0-14-generic
- **iMac (Apple subsystem 106b:0111)** — BCM4360, Ubuntu 26.04, kernel 7.0.0-30-generic

## Supported Hardware

Any device supported by the original broadcom-sta driver, including:

| Chip | PCI ID | Found in |
|------|--------|----------|
| BCM4360 | `14e4:43a0` | MacBook Pro 2013–2015, iMac 2013–2015 |
| BCM43602 | `14e4:43ba` | MacBook Pro 2015–2016, MacBook Air 2015 |
| BCM4352 | `14e4:43b1` | MacBook Pro 2012–2013 |
| BCM43228 | `14e4:4359` | Various laptops |
| BCM4331 | `14e4:4331` | MacBook Pro 2011–2012, MacBook Air 2011–2012 |

Full list in `/usr/share/broadcom-sta/broadcom-sta.ids`.

**Keywords:** MacBook Pro WiFi Linux 6.17, MacBook Air WiFi Linux, Apple Mac wireless not working Linux, broadcom-sta DKMS build failed kernel 6.17, BCM4360 Linux driver, wl driver kernel 6.17, broadcom-sta kernel 7.0, objtool unannotated intra-function call wl.o

## Patches Applied

| File | Change | Reason |
|------|--------|--------|
| `Makefile` | `EXTRA_CFLAGS` → `ccflags-y`, `EXTRA_LDFLAGS` → `ldflags-y` | Removed from kbuild in 6.17 |
| `wl_linux.c/h` | `ndo_do_ioctl` → `ndo_siocdevprivate` | Required since kernel 5.15 for SIOCDEVPRIVATE |
| `wl_linux.c` | `from_timer` → `timer_container_of` | `from_timer` removed in 6.17 |
| `wl_linux.c` | `del_timer` → `timer_delete` | `del_timer` removed in 6.17 |
| `wl_linux.c` | Added `#include <linux/timer.h>` | No longer transitively included |
| `linuxver.h` | `del_timer_sync` → `timer_delete` | Same timer API rename |
| `wl_cfg80211_hybrid.c` | Added `radio_idx` param to `set_wiphy_params`, `set_tx_power`, `get_tx_power` | cfg80211 multi-radio API in 6.17 |
| `wl_cfg80211_hybrid.c` | `/* falls through */` → `fallthrough;` | `-Wimplicit-fallthrough` fix |
| `Makefile`, `objtool-wrapper.sh` | Build through an objtool wrapper that tolerates errors | On 7.0 IBT kernels objtool always checks the linked `wl.o` and aborts on the prebuilt blob: `objtool: aes_cbc_encrypt_pad+0x4c: unannotated intra-function call` |

## Install

### Option 1: One-step install script (recommended)

```bash
sudo bash install.sh
```

Installs build dependencies, copies the source to `/usr/src/broadcom-sta-6.30.223.271`, builds and installs it with DKMS, blacklists conflicting drivers (`b43`, `bcma`, `ssb`, `brcmsmac`, `brcmfmac`), regenerates the initramfs and loads `wl`. Run it from a real terminal so sudo can ask for your password.

### Option 1b: Use pre-patched source manually

```bash
# Copy source to DKMS location
sudo cp -r . /usr/src/broadcom-sta-6.30.223.271

# Build and install
sudo dkms install broadcom-sta/6.30.223.271

# Blacklist conflicting drivers and load wl
sudo tee /etc/modprobe.d/broadcom-wl.conf <<EOL
blacklist brcmfmac
blacklist bcma
blacklist b43
EOL

sudo modprobe -r brcmfmac bcma
sudo modprobe wl
```

### Option 2: Patch existing broadcom-sta-dkms install

If you already have `broadcom-sta-dkms` installed from your distro's repos, you can patch it in-place:

```bash
sudo apt install broadcom-sta-dkms
sudo bash patch-and-build.sh
```

The script patches the source at `/usr/src/broadcom-sta-6.30.223.271`, rebuilds via DKMS, and tells you how to load the driver. All patches are idempotent (safe to run multiple times).

> **Note:** this script does not apply the kernel 7.0 objtool fix. On 7.0+ use Option 1.

### Option 3: Manual build

```bash
make KVER=$(uname -r)
sudo insmod wl.ko
```

## License

The open-source wrapper code is licensed under the **ISC License** by Broadcom Corporation.
The binary blobs (`lib/wlc_hybrid.o_*`) are proprietary. See source file headers for full license text.
