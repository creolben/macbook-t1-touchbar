#!/usr/bin/env bash
# t1-boot-audit.sh — read-only audit of the T1 Touch Bar boot path.
#
# Why this exists: the modules can be loaded by hand and the whole stack look
# healthy, while the boot-time wiring (DKMS, modules-load.d, the handover unit,
# its ordering) is configured but never exercised. After a kernel upgrade or a
# fresh install, this says which layer would fail and why — without rebooting.
#
# It deliberately does not claim a reboot is proven. Run it, then reboot and
# check with `t1-touchbar.sh status`.
#
# Usage: sudo ./t1-boot-audit.sh

set -uo pipefail

ok()   { printf '  \033[32mOK\033[0m    %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; }
hdr()  { printf '\n=== %s\n' "$*"; }

problems=0

# --- 1. module loading ------------------------------------------------------
hdr "1. module loading at boot"
conf=/etc/modules-load.d/apple-touchbar.conf
if [[ -f $conf ]]; then
  ok "$conf exists"
  while IFS= read -r m; do
    [[ -n $m && $m != \#* ]] || continue
    if modinfo -F filename "$m" >/dev/null 2>&1; then
      ok "  $m resolves"
    else
      bad "  $m listed but NOT resolvable — boot will log a failure"
      problems=$((problems + 1))
    fi
  done <"$conf"
else
  bad "$conf missing — modules will not load at boot"
  problems=$((problems + 1))
fi

# --- 2. modules match the running kernel ------------------------------------
hdr "2. modules exist for THIS kernel"
kver="$(uname -r)"
echo "  kernel: $kver"
for m in apple-ibridge apple-ib-tb apple-ib-als; do
  p="$(modinfo -F filename "$m" 2>/dev/null)"
  case "$p" in
    *"/lib/modules/$kver/"*) ok "$(basename "$p")" ;;
    "") bad "$m not found at all"; problems=$((problems + 1)) ;;
    *)  warn "$m resolves outside $kver: $p"; problems=$((problems + 1)) ;;
  esac
done

# --- 3. the handover unit ---------------------------------------------------
hdr "3. the handover unit"
unit=apple-touchbar.service
if systemctl is-enabled "$unit" >/dev/null 2>&1; then
  ok "$unit is enabled"
else
  bad "$unit NOT enabled — the handover will not run"
  problems=$((problems + 1))
fi

# Ordering: check the resolved real unit, not the alias. systemd resolves
# `Before=display-manager.service` to the concrete unit (sddm on Omarchy), so
# grepping for the alias name is a false negative.
resolved="$(systemctl show "$unit" -p Before --value 2>/dev/null)"
if echo "$resolved" | grep -qiE 'sddm|gdm|lightdm|greetd|display-manager'; then
  ok "ordered before the display manager"
else
  warn "Before= is $(echo "$resolved" | tr '\n' ' ') — no display manager found"
fi
wanted="$(systemctl show "$unit" -p WantedBy --value 2>/dev/null)"
echo "        WantedBy: $wanted"

exe="$(systemctl show "$unit" -p ExecStart --value 2>/dev/null)"
script="$(echo "$exe" | sed -n 's/.*path=\([^ ]*\).*/\1/p')"
script="${script:-/usr/local/sbin/apple-touchbar-handover}"
if [[ -x $script ]]; then
  ok "$(basename "$script") present and executable"
else
  bad "$script missing or not executable — the unit will fail"
  problems=$((problems + 1))
fi
if grep -q 'WAIT_SECS' "$script" 2>/dev/null; then
  ok "the script waits for the HID devices before acting"
else
  warn "no wait loop — it may run before the iBridge enumerates"
fi

# --- 4. has it actually run? ------------------------------------------------
hdr "4. has the handover run successfully?"
last="$(journalctl -u "$unit" -b --no-pager -o cat 2>/dev/null | tail -5)"
if echo "$last" | grep -q 'touch bar ready'; then
  ok "it ran on this boot and self-verified:"
  echo "$last" | sed 's/^/        /'
elif echo "$last" | grep -q 'Finished'; then
  warn "it ran but did not report 'touch bar ready' — check the output:"
  echo "$last" | sed 's/^/        /'
  problems=$((problems + 1))
else
  echo "        no run recorded this boot (normal if you have not rebooted yet)"
fi

# --- 5. failure visibility --------------------------------------------------
hdr "5. would a failure be visible?"
sevs="$(systemctl show "$unit" -p SuccessExitStatus --value 2>/dev/null)"
echo "        SuccessExitStatus: ${sevs:-<none>}"
case "$sevs" in
  *1*)
    warn "exit 1 counts as success, so a failed handover will NOT mark the unit failed"
    echo "        (deliberate: a dark strip must not take the boot down. But it means"
    echo "         'the unit is active' is not evidence the strip works — check for"
    echo "         'touch bar ready' above, or the fnmode attribute directly.)"
    ;;
  *) ok "a failure would mark the unit failed" ;;
esac

# --- 6. boot artefacts ------------------------------------------------------
hdr "6. boot artefacts"
found_uki=0
for d in /boot/EFI/Linux /boot/efi/EFI/Linux /boot/EFI/omarchy; do
  shopt -s nullglob
  ukis=("$d"/*.efi)
  shopt -u nullglob
  for u in "${ukis[@]}"; do
    printf '        %s  (%s bytes, built %s)\n' \
      "$(basename "$u")" "$(stat -c%s "$u")" "$(stat -c%y "$u" | cut -d. -f1)"
    found_uki=1
  done
done
if (( found_uki )); then
  ok "kernel image(s) present"
  echo "        (the DKMS modules are not needed inside it — they load afterwards,"
  echo "         which is why a stale initramfs does not break the Touch Bar)"
else
  warn "no kernel image found in the usual places — is the ESP mounted?"
fi

# --- summary ----------------------------------------------------------------
hdr "summary"
if (( problems == 0 )); then
  ok "the boot path is configured correctly"
else
  printf '  %d problem(s) above\n' "$problems"
fi
cat <<'EOF'

  This cannot prove the reboot — only the reboot can. After it:

    sudo t1-touchbar.sh status
    sudo journalctl -u apple-touchbar.service -b

  The one line that means success is:  touch bar ready: fnmode=...
EOF
exit 0
