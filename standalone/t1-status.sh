#!/usr/bin/env bash
# t1-status.sh — read-only diagnosis of the T1 (iBridge) Touch Bar stack.
#
# Reports every layer in the order they must work: firmware -> USB enumeration
# -> HID interface ownership -> driver probe -> modules. Needs no root for
# everything except reading the ESP contents, which is attempted and reported
# as "unreadable" if not permitted.
#
# Never changes anything.

set -uo pipefail

ok()   { printf '  \033[32mOK\033[0m    %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; }
skip() { printf '  --    %s\n' "$*"; }
hdr()  { printf '\n=== %s\n' "$*"; }

problems=0
note_problem() { problems=$((problems + 1)); }

# ── hardware ────────────────────────────────────────────────────────────────
hdr "hardware"
product="$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)"
echo "  model: $product"
case "$product" in
  MacBookPro13,[123]|MacBookPro14,[123]) ok "T1 MacBook Pro — correct target" ;;
  MacBookPro15,*|MacBookPro16,*|MacBookPro17,*|MacBookPro18,*)
    warn "this is a T2 machine; this toolkit does not apply (use hid-appletb-kbd)"
    note_problem ;;
  *) warn "not a known T1 model; continuing anyway" ;;
esac

# ── firmware files on the ESP ───────────────────────────────────────────────
hdr "T1 firmware on the ESP"
ESP=""
for cand in /boot/efi /boot /efi; do
  findmnt -no FSTYPE "$cand" 2>/dev/null | grep -qi vfat && { ESP="$cand"; break; }
done
if [[ -n $ESP ]]; then
  ok "ESP mounted at $ESP ($(findmnt -no SOURCE "$ESP"))"
  fw="$ESP/EFI/APPLE/EMBEDDEDOS"
  # The ESP is mode 0700 root-owned, so an unprivileged `-d`/`-e` test fails on
  # a perfectly healthy machine. Distinguish "cannot look" from "is not there"
  # or this script reports firmware absent when it is present.
  if [[ -r "$fw" ]] && [[ -d $fw ]]; then
    for f in combined.memboot FDRData version.plist; do
      if [[ -s "$fw/$f" ]]; then ok "$f present ($(stat -c%s "$fw/$f") bytes)"
      else warn "$f MISSING or empty"; note_problem; fi
    done
  elif sudo -n test -d "$fw" 2>/dev/null; then
    skip "$fw exists but is not readable as this user"
    echo "       re-run with sudo to check the contents"
  else
    # Unreadable and unprovable. Say exactly that rather than claiming the
    # firmware is absent — on a healthy machine it usually is not.
    warn "cannot confirm $fw exists (root-only, and no privilege available here)"
    echo "       re-run with sudo:  sudo $0 ${1:-status}"
  fi
else
  bad "no vfat ESP mounted at /boot/efi, /boot or /efi"; note_problem
fi

# ── local backup ────────────────────────────────────────────────────────────
hdr "firmware backup"
bk="${SUDO_USER:+$(getent passwd "$SUDO_USER" | cut -d: -f6)}"
bk="${bk:-$HOME}/t1-firmware-backup"
if [[ -d $bk ]]; then
  missing=0
  for f in combined.memboot FDRData version.plist; do
    [[ -s "$bk/$f" ]] || missing=1
  done
  if (( missing )); then
    warn "backup at $bk is INCOMPLETE"; note_problem
  elif [[ -f "$bk/SHA256SUMS.txt" ]] && ( cd "$bk" && sha256sum -c SHA256SUMS.txt --quiet 2>/dev/null ); then
    ok "verified backup at $bk"
  else
    warn "backup at $bk exists but failed verification"; note_problem
  fi
  echo "       (this is the only copy — keep one OFF this disk)"
else
  warn "no backup at $bk"
  echo "       Run: sudo $0 backup-firmware      <-- do this before repartitioning"
  note_problem
fi

# ── USB enumeration ─────────────────────────────────────────────────────────
hdr "T1 USB enumeration"
pid=""
for d in /sys/bus/usb/devices/*/; do
  [[ -f $d/idVendor ]] || continue
  [[ "$(cat "$d/idVendor")" == 05ac ]] && pid="$(cat "$d/idProduct")"
done
case "$pid" in
  8600) ok "05ac:8600 iBridge — firmware loaded, chip is up" ;;
  1281|1280) bad "05ac:$pid recovery mode — firmware NOT loaded"; note_problem
    echo "       Restore a backup, or boot macOS once with internet." ;;
  "")   bad "no Apple USB device found"; note_problem ;;
  *)    warn "unexpected Apple product id 05ac:$pid"; note_problem ;;
esac

# ── HID interface ownership ─────────────────────────────────────────────────
hdr "iBridge HID interfaces"
tb_iface=""
attr_iface=""
for h in /sys/bus/hid/devices/0003:05AC:8600.*; do
  [[ -d $h ]] || continue
  sz="$(wc -c < "$h/report_descriptor" 2>/dev/null || echo 0)"
  drv="$(basename "$(readlink -f "$h/driver" 2>/dev/null)" 2>/dev/null || echo none)"
  printf '  %-24s %5s bytes -> %s\n' "$(basename "$h")" "$sz" "$drv"
  # The 634-byte interface is the one that must move to apple-ibridge-hid...
  [[ $sz == 634 ]] && tb_iface="$h"
  # ...but the driver's sysfs controls land on the OTHER (83-byte) interface.
  [[ -e "$h/fnmode" ]] && attr_iface="$h"
done

if [[ -n $tb_iface ]]; then
  drv="$(basename "$(readlink -f "$tb_iface/driver" 2>/dev/null)" 2>/dev/null || echo none)"
  if [[ $drv == apple-ibridge-hid ]]; then
    ok "the 634-byte Touch Bar interface is on apple-ibridge-hid"
  else
    bad "the 634-byte Touch Bar interface is held by '$drv'"; note_problem
    echo "       This is the silent trap. Run: sudo $0 load"
  fi
else
  skip "no 634-byte interface (expected while the T1 is in recovery)"
fi

# ── driver probe ────────────────────────────────────────────────────────────
# A successful appletb_probe() creates fnmode/idle_timeout/dim_timeout. Their
# presence is the only reliable proof the driver bound — lsmod and dmesg both
# look correct even when it did not.
hdr "Touch Bar driver"
for m in apple_ibridge apple_ib_tb apple_ib_als; do
  if grep -q "^$m " /proc/modules 2>/dev/null; then ok "$m loaded"
  else skip "$m not loaded"; fi
done
if [[ -n $attr_iface ]]; then
  ok "appletb_probe() ran — fnmode=$(cat "$attr_iface/fnmode") idle_timeout=$(cat "$attr_iface/idle_timeout")"
  echo "       (on $(basename "$attr_iface"); these attributes only exist after a successful probe)"
elif [[ -n $tb_iface ]]; then
  warn "no fnmode attribute anywhere — the driver has not probed"; note_problem
else
  skip "nothing to probe yet"
fi

# ── DKMS ────────────────────────────────────────────────────────────────────
hdr "DKMS"
if command -v dkms >/dev/null; then
  dkms status 2>/dev/null | sed 's/^/  /' || skip "no dkms entries"
  if dkms status 2>/dev/null | grep -q '^macbook12-spi-driver/'; then
    warn "macbook12-spi-driver is also registered — two packages claim the same"
    warn "modules and whichever builds last wins. Fix:"
    echo "       sudo dkms remove -m macbook12-spi-driver -v <version> --all"
    note_problem
  fi
else
  skip "dkms not installed"
fi

# ── summary ─────────────────────────────────────────────────────────────────
printf '\n=== summary\n'
if (( problems == 0 )); then
  ok "everything checks out"
else
  printf '  %d item(s) need attention (see FAIL/WARN above)\n' "$problems"
fi
exit 0
