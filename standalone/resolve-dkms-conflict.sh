#!/usr/bin/env bash
# Resolve the DKMS conflict: two packages claim the same three module names.
#
#   appleibridge/0.1          -> installed, owns /lib/modules/<kver>/updates/dkms/
#   macbook12-spi-driver/0+git.315 -> 'added' only, but will rebuild on the next
#                                      kernel and race the one above for the same
#                               paths. Whichever finishes last wins.
#
# This keeps the distro package (it is the upstream source) but stops it
# registering the same modules. Safe to re-run.
#
# Run: sudo bash resolve-dkms-conflict.sh

set -euo pipefail

say() { printf '\n=== %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root: sudo bash $0"

DISTRO_NAME=macbook12-spi-driver
OURS=appleibridge

say "before"
dkms status || true

# --- 1. Confirm our own build is the one that should win ---------------------
# Never remove the distro registration unless ours is actually installed and
# serving the modules, or this would leave the machine with no driver at all.
if ! dkms status | grep -q "^${OURS}/.*: installed"; then
  die "$OURS is not installed. Build and install it first:
    sudo ~/t1-touchbar/t1-touchbar.sh install
Refusing to remove the only working registration."
fi

for m in apple-ibridge apple-ib-tb apple-ib-als; do
  path="$(modinfo -F filename "$m" 2>/dev/null || true)"
  case "$path" in
    */updates/dkms/*) : ;;
    *) die "$m resolves to '$path', not the DKMS tree. Investigate before continuing." ;;
  esac
done
echo "all three modules resolve into the DKMS tree — safe to proceed"

# --- 2. Remove the distro registration --------------------------------------
say "removing the $DISTRO_NAME registration"
if dkms status | grep -q "^${DISTRO_NAME}/"; then
  # Emit one version per line; the status format is name/ver[, kernel, arch]: state.
  # Read via a here-string, not a pipeline: a `while read` on the right side of a
  # pipe runs in a subshell, and any failure inside it is invisible to `set -e`,
  # which is exactly how this silently reported success while removing nothing.
  versions="$(dkms status | sed -n "s#^${DISTRO_NAME}/\([^,]*\),.*#\1#p")"
  if [[ -z $versions ]]; then
    # Fall back: a line with no kernel/arch fields is "name/ver: state"
    versions="$(dkms status | sed -n "s#^${DISTRO_NAME}/\([^:]*\):.*#\1#p")"
  fi
  [[ -n $versions ]] || die "could not parse a version out of: $(dkms status | grep "^${DISTRO_NAME}/")"

  while IFS= read -r ver; do
    [[ -n $ver ]] || continue
    echo "  removing ${DISTRO_NAME}/${ver}"
    dkms remove -m "$DISTRO_NAME" -v "$ver" --all || die "dkms remove failed for $ver"
  done <<<"$versions"
else
  echo "  not registered"
fi

# --- 3. Stop the distro tree re-registering on the next kernel --------------
# dkms add is what a kernel post-install hook would call; AUTOINSTALL=no is what
# its own dkms.conf asks for, so this is the package's supported off switch.
say "disabling AUTOINSTALL in the distro source tree"
shopt -s nullglob
trees=(/usr/src/${DISTRO_NAME}-*)
shopt -u nullglob
if (( ${#trees[@]} == 0 )); then
  echo "  no ${DISTRO_NAME} source tree found; nothing to change"
else
  for t in "${trees[@]}"; do
    conf="$t/dkms.conf"
    [[ -f $conf ]] || { echo "  $t: no dkms.conf"; continue; }
    if [[ ! -f "$conf.orig" ]]; then
      cp -a "$conf" "$conf.orig"
      echo "  $t: original saved as dkms.conf.orig"
    fi
    if grep -q '^AUTOINSTALL="yes"' "$conf"; then
      sed -i 's/^AUTOINSTALL="yes"/AUTOINSTALL="no"/' "$conf"
      echo "  $t: AUTOINSTALL=yes -> no"
    else
      echo "  $t: already disabled"
    fi
  done
fi

# --- 4. Verify --------------------------------------------------------------
say "after"
dkms status || true

echo
if dkms status | grep -q "^${DISTRO_NAME}/"; then
  die "the $DISTRO_NAME registration is still present"
fi
echo "resolved: only $OURS is registered, and it owns all three modules."
echo
echo "The distro package is untouched and still provides the upstream source"
echo "(its dkms.conf keeps the original as dkms.conf.orig)."
echo
echo "Next kernel update will rebuild only $OURS."
