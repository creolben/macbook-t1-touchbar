#!/usr/bin/env bash
# t1-touchbar.sh — one entry point for the T1 (iBridge) Touch Bar toolkit.
#
#   ./t1-touchbar.sh <command>
#
# Commands:
#   status            read-only diagnosis; changes nothing
#   audit-boot        will the stack come up by itself after a reboot?
#   backup-firmware   archive the T1 firmware from the ESP  <-- run this first
#   restore-firmware  put an archived firmware set back on the ESP
#   build             patch + compile the three kernel modules
#   install           DKMS + boot load + interface handover (rebuilds initramfs)
#   load              load the modules and hand over the interface, manually
#   help              this text
#
# Why the ordering matters: the firmware is what the chip boots. Drivers are
# useless without it, and it is the one thing here that cannot be regenerated
# without booting macOS. Back it up before repartitioning anything.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cmd="${1:-help}"
shift || true

need_root() {
  [[ $EUID -eq 0 ]] || { echo "This command needs root: sudo $0 $cmd" >&2; exit 1; }
}

case "$cmd" in
  status)
    exec "$HERE/t1-status.sh" "$@"
    ;;

  backup-firmware)
    need_root
    exec "$HERE/backup-t1-firmware.sh" "$@"
    ;;

  restore-firmware)
    need_root
    exec "$HERE/restore-t1-firmware.sh" "$@"
    ;;

  build)
    # No privilege needed: patches and compiles into a temp directory only.
    exec "$HERE/build-t1-modules.sh" "$@"
    ;;

  audit-boot)
    # Reads systemd state and journal; the ESP checks want root but it degrades
    # to a clear "cannot confirm" rather than a false negative.
    exec "$HERE/t1-boot-audit.sh" "$@"
    ;;

  install)
    need_root
    exec "$HERE/install-t1-touchbar.sh" "$@"
    ;;

  load)
    need_root
    exec "$HERE/load-t1-touchbar.sh" "$@"
    ;;

  help|-h|--help|"")
    sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
    echo
    echo "Scripts in this directory:"
    for f in "$HERE"/*.sh "$HERE"/apple-touchbar-handover; do
      [[ -e $f ]] || continue
      b="$(basename "$f")"
      [[ $b == t1-touchbar.sh ]] && continue
      printf '  %-30s %s\n' "$b" "$(sed -n '2s/^# *//p' "$f" | head -1)"
    done
    ;;

  *)
    echo "unknown command: $cmd" >&2
    echo "run '$0 help'" >&2
    exit 1
    ;;
esac
