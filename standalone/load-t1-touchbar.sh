#!/usr/bin/env bash
# load-t1-touchbar.sh — bring up the Apple T1 Touch Bar driver stack.
#
# Why this exists
# ---------------
# The T1 (iBridge) exposes the Touch Bar over TWO USB HID interfaces. The
# generic drivers claim both at boot, and hid-sensor-hub keeps the second one:
#
#   0003:05AC:8600.0001    83 bytes  -> hid-generic       boot keyboard, fine
#   0003:05AC:8600.0002   634 bytes  -> hid-sensor-hub    <-- the Touch Bar
#
# 634 bytes is the exact size appleib_report_fixup() tests for, so it is a
# reliable identifier for the Touch Bar interface. apple-ibridge reclaims
# .0001 on load but NOT .0002, so appletb_probe() never finds a device.
#
# The failure mode is the whole problem: the modules load, they bind, lsmod
# looks right, dmesg shows no error — and the strip stays dark. There is
# nothing to search for. Handing .0002 over is the missing step.
#
# Run:  sudo ./load-t1-touchbar.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODDIR="${MODDIR:-$HERE}"

log() { printf '\n--- %s\n' "$*"; }

if [[ $EUID -ne 0 ]]; then
  echo "must run as root: sudo $0" >&2
  exit 1
fi

log "T1 USB state (want 05ac:8600 iBridge, not 1281 recovery)"
found=0
for d in /sys/bus/usb/devices/*/; do
  [[ -f $d/idVendor ]] || continue
  if [[ "$(cat "$d/idVendor")" == "05ac" ]]; then
    prod="$(cat "$d/idProduct")"
    printf '  %s  05ac:%s  %s\n' "$(basename "$d")" "$prod" "$(cat "$d/product" 2>/dev/null)"
    [[ $prod == 8600 ]] && found=1
  fi
done
if (( ! found )); then
  cat >&2 <<'MSG'

ERROR: no 05ac:8600 iBridge device. The T1 is either in recovery mode
(05ac:1281) or the firmware is missing from the ESP. No driver can fix that
combination — the firmware has to be provisioned by booting macOS, which
writes EFI/APPLE/EMBEDDEDOS/combined.memboot. Aborting.
MSG
  exit 1
fi

log "loading apple-ibridge"
if lsmod | grep -q '^apple_ibridge'; then
  echo "  already loaded"
else
  insmod "$MODDIR/apple-ibridge.ko"
  echo "  loaded"
fi
sleep 2

log "hid interfaces after apple-ibridge"
for h in /sys/bus/hid/devices/0003:05AC:8600.*; do
  [[ -d $h ]] || continue
  printf '  %-24s %5s bytes  ->  %s\n' "$(basename "$h")" \
    "$(wc -c < "$h/report_descriptor")" \
    "$(basename "$(readlink -f "$h/driver" 2>/dev/null)" 2>/dev/null || echo none)"
done

log "reclaiming the 634-byte Touch Bar interface from hid-sensor-hub"
for h in /sys/bus/hid/devices/0003:05AC:8600.*; do
  [[ -d $h ]] || continue
  dev="$(basename "$h")"
  sz="$(wc -c < "$h/report_descriptor")"
  drv="$(basename "$(readlink -f "$h/driver" 2>/dev/null)" 2>/dev/null || echo none)"

  [[ $sz == 634 ]] || continue

  if [[ $drv == apple-ibridge-hid ]]; then
    echo "  $dev already owned by apple-ibridge-hid"
    continue
  fi

  echo "  $dev ($sz bytes) is on '$drv' — unbinding"
  printf '%s' "$dev" > /sys/bus/hid/drivers/hid-sensor-hub/unbind 2>/dev/null || true
  printf '%s' "$dev" > /sys/bus/hid/drivers/hid-generic/unbind    2>/dev/null || true
  sleep 1

  if [[ -e /sys/bus/hid/drivers/apple-ibridge-hid/bind ]]; then
    printf '%s' "$dev" > /sys/bus/hid/drivers/apple-ibridge-hid/bind \
      && echo "  $dev -> apple-ibridge-hid"
  else
    echo "  WARNING: apple-ibridge-hid driver not registered" >&2
  fi
done

log "loading apple-ib-tb and apple-ib-als"
for m in apple-ib-tb apple-ib-als; do
  if lsmod | grep -q "^${m//-/_}"; then
    echo "  $m already loaded"
  else
    insmod "$MODDIR/$m.ko" && echo "  $m loaded"
  fi
done
sleep 2

log "final state"
for h in /sys/bus/hid/devices/0003:05AC:8600.*; do
  [[ -d $h ]] || continue
  printf '  %-24s %5s bytes  ->  %s\n' "$(basename "$h")" \
    "$(wc -c < "$h/report_descriptor")" \
    "$(basename "$(readlink -f "$h/driver" 2>/dev/null)" 2>/dev/null || echo none)"
done

log "writable Touch Bar sysfs controls (proof a probe succeeded)"
ls -1 /sys/bus/hid/drivers/apple-ibridge-hid/ 2>/dev/null | head
for f in /sys/devices/platform/apple-ib-tb/*; do
  [[ -e $f ]] && printf '  %s\n' "$f"
done 2>/dev/null || true

log "recent dmesg"
dmesg | grep -iE 'apple|ibridge|appletb|ib-tb' | tail -20

cat <<'MSG'

Done. The strip should light up a few seconds after this.

If it lights up but the keys do nothing, or it stays dark, re-run this script
and read the "final state" and dmesg sections — the failure is almost always
.0002 not ending up on apple-ibridge-hid.
MSG
