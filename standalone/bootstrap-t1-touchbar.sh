#!/usr/bin/env bash
# bootstrap-t1-touchbar.sh — set up the T1 Touch Bar on a FRESH Linux install.
#
#   sudo ./bootstrap-t1-touchbar.sh
#
# Designed to be re-runnable and to fail early with a clear reason: the most
# common blocker is not the driver at all, it is absent T1 firmware, and it is
# worth saying so before anything is installed.
#
# What it does, in order:
#   1. Confirm this is a T1 MacBook and the T1 firmware is present.
#   2. Install prerequisites (dkms, kernel headers).
#   3. Obtain the driver source (distro package, else upstream git).
#   4. Patch it for the running kernel via t1-patch-source.py.
#   5. Hand off to install-t1-touchbar.sh (DKMS + boot load + handover unit).
#   6. Rebuild the initramfs.
#
# Step 6 is the last thing that happens, so a failure anywhere earlier leaves
# the machine fully bootable.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRV_PKG=macbook12-spi-driver-dkms
UPSTREAM_REPO=https://github.com/roadrunner2/macbook12-spi-driver
UPSTREAM_BRANCH=touchbar-driver-hid-driver

say()  { printf '\n=== %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root: sudo $0"

# ---------------------------------------------------------------- 1. hardware
say "checking hardware"
product="$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)"
echo "model: $product"

case "$product" in
  MacBookPro13,[123]|MacBookPro14,[123])
    echo "  T1 MacBook Pro — correct target"
    ;;
  MacBookPro15,*)
    warn "$product is a T2 machine. This driver is for T1 only."
    warn "On T2, use hid-appletb-kbd / hid-appletb-bl (in mainline) instead. Aborting."
    exit 1
    ;;
  *)
    warn "$product is not a known T1 model."
    read -rp "continue anyway? [y/N] " a
    [[ ${a,,} == y ]] || exit 1
    ;;
esac

say "checking T1 (iBridge) firmware"
t1_state=""
for d in /sys/bus/usb/devices/*/; do
  [[ -f $d/idVendor ]] || continue
  [[ "$(cat "$d/idVendor")" == 05ac ]] || continue
  t1_state="$(cat "$d/idProduct")"
done
echo "T1 USB product id: ${t1_state:-none}"

if [[ $t1_state != 8600 ]]; then
  cat >&2 <<'MSG'

The T1 is not enumerating as the production iBridge (05ac:8600).

  05ac:1281  = T1 in recovery mode, firmware missing from the ESP
  (nothing)  = no iBridge device at all

No driver can work in this state — the firmware is absent, not merely unbound.
The T1 has no boot ROM: macOS writes its firmware to the ESP at
EFI/APPLE/EMBEDDEDOS/combined.memboot, and Apple's boot firmware loads it at
every power-on. A whole-disk Linux install erases it.

Fix: install macOS to a partition, boot it once WITH INTERNET, and let
EmbeddedOSInstallService provision the T1. Confirm with:

  ls /boot/EFI/APPLE/EMBEDDEDOS/

You want combined.memboot + FDRData + version.plist. Then re-run this script.

Do NOT wipe that directory afterwards, and back it up off-disk — the files are
personalized to this machine's chip (ECID) and are irreplaceable for it.
MSG
  exit 1
fi
echo "  firmware present (05ac:8600)"

if [[ ! -s /boot/EFI/APPLE/EMBEDDEDOS/combined.memboot ]]; then
  warn "05ac:8600 is up but combined.memboot is not visible at /boot/EFI/APPLE/EMBEDDEDOS/"
  warn "This is fine if the T1 is already provisioned; continuing."
fi

# ------------------------------------------------------------ 2. prerequisites
say "installing prerequisites"
# The kernel package name varies (linux, linux-omarchy, linux-lts...).
kver="$(uname -r)"
hdr=""
for cand in linux-headers linux-omarchy-headers "linux${kver#*-}"-headers; do
  pacman -Si "$cand" >/dev/null 2>&1 && hdr="$cand" && break
done
pkgs=(dkms base-devel)
[[ -n $hdr ]] && pkgs+=("$hdr")

echo "kernel: $kver   headers package: ${hdr:-<not found, using what is installed>}"
if ! ls -d "/lib/modules/$kver/build" >/dev/null 2>&1; then
  die "no build tree at /lib/modules/$kver/build — install matching kernel headers first"
fi

if command -v omarchy-pkg-add >/dev/null 2>&1; then
  omarchy-pkg-add "${pkgs[@]}"
elif command -v pacman >/dev/null 2>&1; then
  pacman -S --needed --noconfirm "${pkgs[@]}"
else
  die "neither omarchy-pkg-add nor pacman found; install manually: ${pkgs[*]}"
fi
for t in dkms make gcc python3; do
  command -v "$t" >/dev/null || die "$t still missing after install"
done

# ------------------------------------------------------------- 3. driver source
say "obtaining driver source"
SRCROOT=""
for d in /usr/src/${DRV_PKG}-* /usr/src/macbook12-spi-driver-*; do
  [[ -f $d/apple-ibridge.c ]] && SRCROOT="$d" && break
done

if [[ -z $SRCROOT ]]; then
  echo "no local source; installing $DRV_PKG for its source tree"
  if command -v omarchy-pkg-add >/dev/null 2>&1; then
    omarchy-pkg-add "$DRV_PKG" || true
  else
    pacman -S --needed --noconfirm "$DRV_PKG" || true
  fi
  for d in /usr/src/${DRV_PKG}-* /usr/src/macbook12-spi-driver-*; do
    [[ -f $d/apple-ibridge.c ]] && SRCROOT="$d" && break
  done
fi

if [[ -z $SRCROOT ]]; then
  warn "package did not provide usable source; falling back to upstream git"
  command -v git >/dev/null || die "git not installed"
  rm -rf /tmp/t1src && git clone --depth 1 -b "$UPSTREAM_BRANCH" \
    "$UPSTREAM_REPO" /tmp/t1src
  SRCROOT=/tmp/t1src
fi
echo "source: $SRCROOT"
[[ -f $SRCROOT/apple-ibridge.c ]] || die "no apple-ibridge.c in $SRCROOT"

# ------------------------------------------------------------------ 4. patch it
say "patching source for kernel $kver"
WORK=/tmp/t1-touchbar-build
rm -rf "$WORK" && mkdir -p "$WORK"
cp "$SRCROOT"/apple-ibridge.c "$SRCROOT"/apple-ibridge.h \
   "$SRCROOT"/apple-ib-tb.c  "$SRCROOT"/apple-ib-als.c "$WORK"/

python3 "$HERE/t1-patch-source.py" "$WORK" || {
  rc=$?
  if (( rc == 2 )); then
    cat >&2 <<'MSG'

The driver source has moved on and t1-patch-source.py no longer matches it.
This is expected eventually — it means upstream or the distro package changed,
not that your machine is broken. See README.md, "When the kernel API moves
again", for how to find and apply the fix. Nothing was installed.
MSG
  fi
  exit "$rc"
}

say "test-compiling"
cat > "$WORK/Makefile" <<'EOF'
obj-m += apple-ibridge.o
obj-m += apple-ib-tb.o
obj-m += apple-ib-als.o
KDIR := /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)
all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules
clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
EOF
if ! ( cd "$WORK" && make ); then
  die "compile failed. Nothing was installed (modules are not in DKMS yet).
Re-run with 'make V=1' in $WORK for the full command lines, and check that the
headers at /lib/modules/$kver/build match the running kernel."
fi
echo "  compile OK: $(ls "$WORK"/*.ko | wc -l) modules"

# ------------------------------------------------------------------- 5. install
say "installing (DKMS + boot load + interface handover)"
mkdir -p "$WORK/.installer"
cp "$HERE/install-t1-touchbar.sh" "$HERE/apple-touchbar-handover" \
   "$HERE/apple-touchbar.service" "$WORK"/
(cd "$WORK" && ./install-t1-touchbar.sh)

# ------------------------------------------------- 6. initramfs (last, always)
say "rebuilding initramfs"
if command -v limine-mkinitcpio >/dev/null 2>&1; then
  limine-mkinitcpio
elif command -v mkinitcpio >/dev/null 2>&1; then
  mkinitcpio -P
else
  warn "no limine-mkinitcpio or mkinitcpio found — rebuild the initramfs yourself"
fi

cat <<'EOF'

Bootstrap complete.

The Touch Bar should come up by itself after a reboot. To verify without
rebooting:

  modprobe apple-ibridge
  /usr/local/sbin/apple-touchbar-handover
  cat /sys/bus/hid/devices/0003:05AC:8600.0001/fnmode

If the strip stays dark, the handover did not take:

  sudo journalctl -u apple-touchbar.service -b
EOF
