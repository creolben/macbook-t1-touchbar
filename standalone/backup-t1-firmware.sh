#!/usr/bin/env bash
# backup-t1-firmware.sh — archive the T1 (iBridge) EmbeddedOS from the ESP.
#
# ── Why this is the single most important file to run ───────────────────────
#
# The T1 has no firmware in ROM. macOS writes three machine-specific files to
# the EFI System Partition and Apple's boot firmware loads them into the chip at
# EVERY power-on:
#
#   EFI/APPLE/EMBEDDEDOS/combined.memboot   (~30 MB)
#   EFI/APPLE/EMBEDDEDOS/FDRData            (calibration, incl. Touch Bar)
#   EFI/APPLE/EMBEDDEDOS/version.plist
#
# They are personalised to THIS machine's ECID. They cannot be downloaded, and a
# copy from another Mac will not boot this chip. If the ESP is wiped — a
# full-disk install erases it — the only way to regenerate them is to install
# macOS again and boot it with internet so EmbeddedOSInstallService provisions
# the T1.
#
# A 31 MB archive turns that into a file copy. Run this before touching
# partitions, and keep the result OFF this disk.
#
# Usage:
#   sudo ./backup-t1-firmware.sh [dest-dir]     # default ~/t1-firmware-backup

set -euo pipefail

# Under sudo, $HOME is /root — the backup belongs to the invoking user.
if [[ -n "${SUDO_USER:-}" ]]; then
  _user_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
else
  _user_home="$HOME"
fi
DEST="${1:-${_user_home:-$HOME}/t1-firmware-backup}"

FILES=(combined.memboot FDRData version.plist)

say()  { printf '\n=== %s\n' "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }

[[ $EUID -eq 0 ]] || die "run as root (the ESP is root-only): sudo $0"

# ── 1. Locate the ESP ────────────────────────────────────────────────────────
# Do not assume /boot/efi. This machine mounts its ESP at /boot.
say "locating the ESP"
ESP=""
for cand in /boot/efi /boot /efi; do
  if findmnt -no FSTYPE "$cand" 2>/dev/null | grep -qi vfat; then
    ESP="$cand"; break
  fi
done
[[ -n $ESP ]] || die "no vfat ESP mounted at /boot/efi, /boot or /efi. Check: findmnt /boot"
SRC="$ESP/EFI/APPLE/EMBEDDEDOS"
echo "  ESP: $ESP ($(findmnt -no SOURCE "$ESP"))"
echo "  firmware dir: $SRC"

# ── 2. Is there anything to back up? ─────────────────────────────────────────
if [[ ! -d $SRC ]]; then
  cat >&2 <<EOF

ERROR: $SRC does not exist.

There is nothing to back up — the T1 firmware is ALREADY ABSENT. That is the
state that leaves the Touch Bar dark and /dev/video* missing, and it means the
T1 is enumerating as 05ac:1281 (recovery mode) rather than 05ac:8600.

This script cannot help; it archives firmware that exists. To regenerate it,
install macOS to a partition and boot it once WITH INTERNET so
EmbeddedOSInstallService provisions the chip. Then run this script.

Check the current state with:
  for d in /sys/bus/usb/devices/*/; do
    [ "\$(cat \$d/idVendor 2>/dev/null)" = 05ac ] &&
      echo "05ac:\$(cat \$d/idProduct) \$(cat \$d/product 2>/dev/null)"
  done
EOF
  exit 1
fi

missing=0
for f in "${FILES[@]}"; do
  [[ -s "$SRC/$f" ]] || { warn "$f is missing or empty"; missing=1; }
done
(( missing == 0 )) || warn "the set is incomplete; the archive will be too"

# ── 3. Preserve any previous backup rather than clobbering it ────────────────
say "preparing destination $DEST"
mkdir -p "$DEST"

prev_ok=1
if [[ -f "$DEST/SHA256SUMS.txt" ]]; then
  if ( cd "$DEST" && sha256sum -c SHA256SUMS.txt --quiet 2>/dev/null ); then
    if cmp -s "$SRC/combined.memboot" "$DEST/combined.memboot" 2>/dev/null; then
      echo "  an existing backup matches the ESP byte for byte"
      prev_ok=0
    else
      echo "  an existing backup DIFFERS from the ESP — keeping it aside"
    fi
  else
    warn "existing backup is corrupt — keeping it aside for inspection"
  fi
fi

if (( prev_ok == 1 )); then
  stamp="$(date +%Y%m%d-%H%M%S)"
  for f in "$DEST"/*; do
    [[ -e $f ]] || continue
    case "$(basename "$f")" in
      SHA256SUMS.txt|pre-restore-*) ;;
    esac
  done
  if [[ -f "$DEST/combined.memboot" ]]; then
    old="$DEST/superseded-$stamp"
    mkdir -p "$old"
    cp -a "$DEST"/combined.memboot "$DEST"/FDRData "$DEST"/version.plist "$old"/ 2>/dev/null || true
    echo "  previous copy saved to $old"
  fi
fi

# ── 4. Copy, then verify ─────────────────────────────────────────────────────
say "copying firmware"
for f in "${FILES[@]}"; do
  if [[ -s "$SRC/$f" ]]; then
    cp -a "$SRC/$f" "$DEST/$f"
    printf '  %-18s %s bytes\n' "$f" "$(stat -c%s "$DEST/$f")"
  fi
done

say "verifying the copy against the source"
rc=0
for f in "${FILES[@]}"; do
  [[ -s "$SRC/$f" ]] || continue
  if cmp -s "$SRC/$f" "$DEST/$f"; then
    printf '  %-18s OK\n' "$f"
  else
    printf '  %-18s MISMATCH\n' "$f"; rc=1
  fi
done
(( rc == 0 )) || die "verification failed — do not trust this backup"

# Checksums so a future restore can prove the archive is intact.
( cd "$DEST" && sha256sum "${FILES[@]}" 2>/dev/null > SHA256SUMS.txt )
echo
echo "  recorded:"; sed 's/^/    /' "$DEST/SHA256SUMS.txt"

# ── 5. Hand ownership back to the user ───────────────────────────────────────
if [[ -n "${SUDO_USER:-}" ]]; then
  chown -R "$SUDO_USER" "$DEST" 2>/dev/null || true
  echo
  echo "  ownership returned to $SUDO_USER"
fi

# ── 6. The part that actually matters ────────────────────────────────────────
cat <<EOF

Backup complete and verified.

  $DEST

>>> NOW COPY IT OFF THIS DISK. <<<

This is machine-specific firmware bound to this Mac's ECID. It cannot be
downloaded and no other Mac's copy will work. If this disk is wiped or fails,
the only way to regenerate it is to install macOS again and boot it online.

To a USB stick:

  cp -a "$DEST" /run/media/\$USER/<stick>/t1-firmware-backup

Verify the copy landed intact:

  cd /run/media/\$USER/<stick>/t1-firmware-backup && sha256sum -c SHA256SUMS.txt

To restore later (e.g. after an installer wipes EFI/APPLE):

  sudo $(dirname "$0")/restore-t1-firmware.sh "$DEST"
EOF
