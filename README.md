# broadcom-sta patched for Linux 6.17+

Broadcom STA wireless driver (wl) version 6.30.223.271, patched to compile and run on **Linux kernel 6.17+**.

Fixes WiFi on **MacBook Pro 2015** (and other Macs) running Linux with kernel 6.17+.

Based on `broadcom-sta-dkms 6.30.223.271-23ubuntu1.1` from Ubuntu non-free.

## Tested On

- **MacBook Pro Mid-2015 (MacBookPro11,5)** — BCM4360, Ubuntu 24.04, kernel 6.17.0-14-generic
- **Mac Pro (Late 2013, MacPro6,1)** — Broadcom STA (wl)

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

**Keywords:** MacBook Pro WiFi Linux 6.17, MacBook Air WiFi Linux, Apple Mac wireless not working Linux, broadcom-sta DKMS build failed kernel 6.17, BCM4360 Linux driver, wl driver kernel 6.17

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
| `wl_cfg80211_hybrid.c` | Updated `get_station`, `get_tx_power`, and key operations to use `wireless_dev` | cfg80211 API compatibility for kernel 7.1+ |
| `linux_osl.c`, `wl_linux.c` | Conditional `strncpy` → `strscpy`/`strscpy_pad`/`memcpy` | Kernel 7.2+ string API compatibility |
| `wl_linux.c` | Conditional `linux/unaligned.h` include | Header moved in 6.12 |
| `linuxver.h`, `src/include/lib80211.h` | Use a bundled compatibility header | Kernel removed `net/lib80211.h` in 6.13 |
| `dkms.conf` | Add `objtool=/bin/true` to the DKMS build command | Work around objtool errors on kernels with precompiled Broadcom blobs |


## Objtool workaround on newer Proxmox kernels

Newer versions of the kernel, including Proxmox version 9 with the kernel 7.0.12-pve, might have problems when building the Broadcom wl driver.

It usually occurs in connection with this line:

    LD [M] wl.o

The output could look something like this:

    wl.o: error: objtool: aes_cbc_encrypt_pad+0x4c: unannotated intra-function call

This occurs because some parts of the Broadcom driver consist of precompiled binary blobs. Newer kernels perform objtool analysis during compilation, but the blob lacks additional information expected by objtool.

### Workaround

Compile the driver without objtool enabled:

    make KVER=$(uname -r) objtool=/bin/true

The repository's `dkms.conf` already sets this for Option 1, and `patch-and-build.sh` adds it for Option 2:

    MAKE[0]="make KVER=$kernelver objtool=/bin/true"

## Install

### Option 1: Use pre-patched source (recommended)

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

The script patches the source at `/usr/src/broadcom-sta-6.30.223.271`, rebuilds via DKMS for the running kernel only, and tells you how to load the driver. It preserves DKMS installations for other kernels. Patching is designed to be idempotent, but stops with an error if critical source patterns are unrecognized; review those errors rather than forcing a build.

### Option 3: Manual build

```bash
make KVER=$(uname -r) objtool=/bin/true
sudo insmod wl.ko
```

## License

The open-source wrapper code is licensed under the **ISC License** by Broadcom Corporation.
The binary blobs (`lib/wlc_hybrid.o_*`) are proprietary. See source file headers for full license text.
