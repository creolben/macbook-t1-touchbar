#!/usr/bin/env bash
# install-t1-touchbar.sh — make the T1 Touch Bar survive reboots and kernel upgrades.
#
# Run once, as root:   sudo ~/t1-touchbar/install-t1-touchbar.sh
#
# What it sets up
#   1. DKMS module tree so the three modules rebuild on every kernel update
#      (a plain .ko in /lib/modules dies at the next omarchy update).
#   2. /etc/modules-load.d entry so they load at boot.
#   3. The handover script + systemd unit, because apple-ibridge does NOT
#      reclaim the 634-byte Touch Bar interface on its own.
#
# Safe to re-run.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG=appleibridge
VER=0.1
SRCDIR=/usr/src/${PKG}-${VER}

die() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root: sudo $0"

# --- sanity: this must be a T1 machine in the right state --------------------
prod="$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)"
case "$prod" in
  MacBookPro13,[123]|MacBookPro14,[123]|MacBookPro15,[1234]) ;;
  *) echo "WARNING: $prod is not a known T1 model; continuing anyway" >&2 ;;
esac

tb_found=0
for d in /sys/bus/usb/devices/*/; do
  [[ -f $d/idVendor ]] || continue
  [[ "$(cat "$d/idVendor")" == 05ac ]] || continue
  [[ "$(cat "$d/idProduct")" == 8600 ]] && tb_found=1
done
(( tb_found )) || die "no 05ac:8600 iBridge. T1 firmware missing or in recovery mode — boot macOS first."

# --- dependencies -----------------------------------------------------------
for t in dkms make gcc; do
  command -v "$t" >/dev/null || die "$t not found"
done

# --- 1. DKMS source tree ----------------------------------------------------
echo "--- installing DKMS source to $SRCDIR"
rm -rf "$SRCDIR"
mkdir -p "$SRCDIR"
cp "$HERE"/apple-ibridge.c "$HERE"/apple-ibridge.h \
   "$HERE"/apple-ib-tb.c  "$HERE"/apple-ib-als.c "$SRCDIR"/

# Minimal dkms.conf: the three T1 modules ONLY.
#
# applespi is deliberately absent. The in-tree applespi already drives the
# keyboard and touchpad correctly, and shipping an out-of-tree copy here would
# shadow it and risk the keyboard on every kernel update. Only the missing
# Touch Bar trio belongs in DKMS.
cat > "$SRCDIR/dkms.conf" <<EOF
PACKAGE_NAME="$PKG"
PACKAGE_VERSION="$VER"
BUILT_MODULE_NAME[0]="apple-ibridge"
BUILT_MODULE_NAME[1]="apple-ib-tb"
BUILT_MODULE_NAME[2]="apple-ib-als"
DEST_MODULE_LOCATION[0]="/kernel/drivers/misc"
DEST_MODULE_LOCATION[1]="/kernel/drivers/misc"
DEST_MODULE_LOCATION[2]="/kernel/drivers/misc"
AUTOINSTALL="yes"
MAKE[0]="make KDIR=/lib/modules/\$kernelver/build"
CLEAN="make clean"
EOF

cat > "$SRCDIR/Makefile" <<'EOF'
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

echo "--- registering with DKMS"
dkms remove -m "$PKG" -v "$VER" --all >/dev/null 2>&1 || true
dkms add    -m "$PKG" -v "$VER"
dkms build  -m "$PKG" -v "$VER"
dkms install -m "$PKG" -v "$VER" --force

# The distro's macbook12-spi-driver-dkms also ships these three module names.
# Leaving it installed means two packages own the same modules and whichever
# builds last wins — unpredictable across kernel updates.
if dkms status 2>/dev/null | grep -q '^macbook12-spi-driver/'; then
  echo "--- removing conflicting macbook12-spi-driver DKMS registration"
  dkms status | sed -n 's#^\(macbook12-spi-driver\)/\([^,]*\),.*#\2#p' | while read -r v; do
    [[ -n $v ]] || continue
    dkms remove -m macbook12-spi-driver -v "$v" --all >/dev/null 2>&1 || true
    echo "    removed macbook12-spi-driver/$v"
  done
  # Keep the package (it is the source of this driver) but stop it registering.
  if [[ -f /usr/src/macbook12-spi-driver-*/dkms.conf ]]; then
    for f in /usr/src/macbook12-spi-driver-*/dkms.conf; do
      cp -n "$f" "$f.orig" 2>/dev/null || true
      sed -i 's/^AUTOINSTALL="yes"/AUTOINSTALL="no"/' "$f"
    done
    echo "    set AUTOINSTALL=no in the distro dkms.conf (original saved as .orig)"
  fi
fi

# --- 2. load at boot --------------------------------------------------------
echo "--- /etc/modules-load.d/apple-touchbar.conf"
cat > /etc/modules-load.d/apple-touchbar.conf <<'EOF'
# Apple T1 (iBridge) Touch Bar driver stack.
# apple-ib-tb / apple-ib-als are pulled in by apple-ibridge as child devices,
# but listing them makes the intent explicit and survives ordering changes.
apple-ibridge
apple-ib-tb
EOF

# --- 3. the handover --------------------------------------------------------
echo "--- installing handover script and unit"
install -Dm755 "$HERE/apple-touchbar-handover" /usr/local/sbin/apple-touchbar-handover
install -Dm644 "$HERE/apple-touchbar.service" /etc/systemd/system/apple-touchbar.service

mkdir -p /etc/modprobe.d
if [[ ! -f /etc/modprobe.d/apple-ib-tb.conf ]]; then
  cat > /etc/modprobe.d/apple-ib-tb.conf <<'EOF'
# Touch Bar behaviour. fnmode=1: Esc + media/brightness keys by default, hold
# Fn for F1-F12 (the Mac default). Set fnmode=2 for the opposite.
options apple-ib-tb fnmode=1
EOF
  echo "--- wrote /etc/modprobe.d/apple-ib-tb.conf"
fi

systemctl daemon-reload
systemctl enable apple-touchbar.service

cat <<'EOF'

Installed.

  modules : DKMS appleibridge/0.1 (rebuilds on every kernel update)
  boot    : /etc/modules-load.d/apple-touchbar.conf
  handover: apple-touchbar.service -> /usr/local/sbin/apple-touchbar-handover

Next: rebuild the initramfs and reboot.

  sudo limine-mkinitcpio

After reboot, verify with:

  cat /sys/bus/hid/devices/0003:05AC:8600.0001/fnmode
  systemctl status apple-touchbar.service

If the strip is dark after reboot, run:

  sudo journalctl -u apple-touchbar.service -b
  sudo /usr/local/sbin/apple-touchbar-handover

Note: apple_ib_als may fail with "Unknown symbol iio_triggered_buffer_setup_ext".
That is only the ambient light sensor, which hid-sensor-als already handles, and
it does not affect the Touch Bar. Silence it with:
  echo 'blacklist apple-ib-als' > /etc/modprobe.d/apple-ib-als.conf
EOF
