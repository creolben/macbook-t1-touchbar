#!/usr/bin/env bash
# restore-t1-firmware.sh — put the T1 (iBridge) EmbeddedOS back on the ESP.
#
# ── What this does and does not do ──────────────────────────────────────────
#
# The T1 has no firmware in ROM. macOS writes three machine-specific files to
# the ESP and Apple's boot firmware loads them into the chip at EVERY power-on:
#
#   EFI/APPLE/EMBEDDEDOS/combined.memboot
#   EFI/APPLE/EMBEDDEDOS/FDRData
#   EFI/APPLE/EMBEDDEDOS/version.plist
#
# THIS RESTORES FILES YOU ALREADY HAVE. It is a file copy.
#
# It does NOT regenerate the firmware. If you have no copy, no backup, and the
# ESP is empty, this script cannot help — the firmware must be re-personalized
# for this machine's ECID, which means booting macOS once with internet so
# EmbeddedOSInstallService can provision the chip. See README.md.
#
# ── Why it is worth having ──────────────────────────────────────────────────
#
# A full-disk Linux install erases EFI/APPLE and the T1 drops to 05ac:1281
# recovery mode: Touch Bar, webcam, Touch ID and the ambient light sensor all
# stop working. With a verified backup on hand, that is a five-second fix from
# Linux alone instead of a macOS reinstall.
#
# Usage:
#   sudo ./restore-t1-firmware.sh [backup-dir]     # default ~/t1-firmware-backup
#   sudo ./restore-t1-firmware.sh --verify         # check only, change nothing

set -euo pipefail

# Under sudo, $HOME is /root — but the backup belongs to the invoking user.
# Resolve the real home from SUDO_USER so the default path works as expected.
if [[ -n "${SUDO_USER:-}" ]]; then
  _user_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
else
  _user_home="$HOME"
fi
DEFAULT_BACKUP="${_user_home:-$HOME}/t1-firmware-backup"

BACKUP_DIR="$DEFAULT_BACKUP"
VERIFY_ONLY=0
case "${1:-}" in
  --verify) VERIFY_ONLY=1; BACKUP_DIR="${2:-$DEFAULT_BACKUP}" ;;
  "")       ;;
  *)        BACKUP_DIR="$1" ;;
esac

FILES=(combined.memboot FDRData version.plist)

say()  { printf '\n=== %s\n' "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }

[[ $EUID -eq 0 ]] || die "run as root: sudo $0"

# ── 1. Locate the ESP ────────────────────────────────────────────────────────
# Do not assume /boot/efi. This machine mounts its ESP at /boot, and other
# layouts put it elsewhere. Ask the system.
say "locating the ESP"
ESP=""
for cand in /boot/efi /boot /efi; do
  if findmnt -no FSTYPE "$cand" 2>/dev/null | grep -qi vfat; then
    ESP="$cand"; break
  fi
done
[[ -n $ESP ]] || die "no vfat ESP found at /boot/efi, /boot or /efi.
Is the EFI System Partition mounted? Check: findmnt /boot"
echo "  ESP: $ESP ($(findmnt -no SOURCE "$ESP"))"
echo "  free: $(df -h "$ESP" | awk 'NR==2{print $4}')"

# ── 2. Check the backup is complete and intact ───────────────────────────────
say "checking backup at $BACKUP_DIR"
[[ -d $BACKUP_DIR ]] || die "backup directory not found: $BACKUP_DIR"
for f in "${FILES[@]}"; do
  [[ -s "$BACKUP_DIR/$f" ]] || die "$f missing or empty in $BACKUP_DIR"
done
if [[ -f "$BACKUP_DIR/SHA256SUMS.txt" ]]; then
  ( cd "$BACKUP_DIR" && sha256sum -c SHA256SUMS.txt --quiet ) \
    && echo "  checksums OK" \
    || die "checksum mismatch — the backup is corrupt. Do not use it."
else
  warn "no SHA256SUMS.txt; skipping integrity check"
fi

# ── 3. Is the T1 actually broken? ────────────────────────────────────────────
# Restoring over a working T1 is pointless risk, so refuse unless forced.
say "T1 state"
prod=""
for d in /sys/bus/usb/devices/*/; do
  [[ -f $d/idVendor ]] || continue
  [[ "$(cat "$d/idVendor")" == 05ac ]] && prod="$(cat "$d/idProduct")"
done
echo "  iBridge product id: ${prod:-none}"

esp_fw="$ESP/EFI/APPLE/EMBEDDEDOS"
esp_ok=0
if [[ -f "$esp_fw/combined.memboot" ]] && \
   cmp -s "$BACKUP_DIR/combined.memboot" "$esp_fw/combined.memboot"; then
  esp_ok=1
fi

if [[ $prod == 8600 && $esp_ok -eq 1 ]]; then
  echo
  echo "The T1 is healthy (05ac:8600) and the ESP firmware already matches the"
  echo "backup byte for byte. There is nothing to restore."
  echo
  echo "Nothing was changed. This is the correct outcome — a restore is only for"
  echo "a missing or corrupt ESP copy."
  exit 0
fi

if [[ $prod == 8600 && $esp_ok -eq 0 ]]; then
  warn "T1 is up (05ac:8600) but the ESP copy does NOT match the backup."
  warn "That is unexpected. Review before proceeding:"
  for f in "${FILES[@]}"; do
    if [[ -f "$esp_fw/$f" ]]; then
      printf '    %-18s esp=%s backup=%s\n' "$f" \
        "$(stat -c%s "$esp_fw/$f")" "$(stat -c%s "$BACKUP_DIR/$f")"
    else
      printf '    %-18s esp=MISSING backup=%s\n' "$f" "$(stat -c%s "$BACKUP_DIR/$f")"
    fi
  done
  [[ ${FORCE:-0} == 1 ]] || die "refusing without FORCE=1 (this is a safety check, not a failure)
If you are certain the backup is the good copy, re-run with:
    sudo FORCE=1 $0 $BACKUP_DIR"
fi

if [[ $prod == 1281 ]]; then
  echo "  T1 is in RECOVERY MODE — firmware is missing from the ESP."
  echo "  This is exactly the case this script exists for."
elif [[ -z $prod ]]; then
  warn "no iBridge device visible at all"
fi

if (( VERIFY_ONLY )); then
  say "--verify: everything checked out; nothing written"
  exit 0
fi

# ── 4. Preserve whatever is currently there ──────────────────────────────────
say "preserving the current ESP contents"
stamp="$(date +%Y%m%d-%H%M%S)"
old="$BACKUP_DIR/esp-before-restore-$stamp"
mkdir -p "$old"
if [[ -d $esp_fw ]]; then
  cp -a "$esp_fw/." "$old/" 2>/dev/null || true
  echo "  saved to $old"
else
  echo "  ESP has no $esp_fw — nothing to preserve"
fi

# ── 5. Write atomically ──────────────────────────────────────────────────────
# Stage on the same filesystem, flush, then rename, so a power loss mid-write
# cannot leave a half-written image the firmware would try to boot.
say "installing firmware"
install -d "$esp_fw"
for f in "${FILES[@]}"; do
  tmp="$esp_fw/.$f.new"
  install -m 600 "$BACKUP_DIR/$f" "$tmp"
  sync -f "$tmp" 2>/dev/null || sync
  mv -f "$tmp" "$esp_fw/$f"
  printf '  %-18s %s bytes\n' "$f" "$(stat -c%s "$esp_fw/$f")"
done
sync "$ESP" 2>/dev/null || sync

# ── 6. Verify what landed ────────────────────────────────────────────────────
say "verifying"
rc=0
for f in "${FILES[@]}"; do
  if cmp -s "$BACKUP_DIR/$f" "$esp_fw/$f"; then
    printf '  %-18s matches backup\n' "$f"
  else
    printf '  %-18s MISMATCH\n' "$f"; rc=1
  fi
done
(( rc == 0 )) || die "verification failed — the ESP copy does not match the backup"

cat <<EOF

Firmware restored and verified.

The chip loads it at power-on, so REBOOT for it to take effect. After reboot:

  for d in /sys/bus/usb/devices/*/; do
    [ "\$(cat \$d/idVendor 2>/dev/null)" = 05ac ] && echo "05ac:\$(cat \$d/idProduct)"
  done

  want: 05ac:8600 iBridge      (not 05ac:1281 recovery)

Then the Touch Bar driver:  sudo ~/t1-touchbar/load-t1-touchbar.sh
EOF
