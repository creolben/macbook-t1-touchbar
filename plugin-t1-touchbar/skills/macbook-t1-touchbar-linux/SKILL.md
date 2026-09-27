---
name: macbook-t1-touchbar-linux
description: Fix the Apple T1 Touch Bar and webcam on a Linux MacBook.
version: 0.1.0
author: creolben, Hermes Agent
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [macbook, touchbar, t1, ibridge, apple, omarchy, dkms]
    related_skills: [omarchy]
---

# Apple T1 Touch Bar on Linux

Diagnose and fix the Touch Bar, webcam and keyboard backlight on a 2016-2017
T1 (iBridge) MacBook Pro running Linux: MacBookPro13,x and MacBookPro14,x.

This is **not** the T2 procedure. T2 starts at MacBookPro15,x (2018+). Most
Linux-on-Mac guides are written for T2 and install packages that silently do
nothing on a T1. Getting this wrong wastes hours, so establish the chip first.

## When to Use

- Touch Bar is dark, blank, or shows nothing on a Linux MacBook Pro
- Touch Bar keys do nothing; only Esc works, or no function row at all
- The webcam / FaceTime camera is missing (`/dev/video*` absent)
- Keyboard backlight keys do not work
- After a Linux install, Apple-specific hardware stopped working
- A `05ac:1281` USB device is present

## Establish the chip: T1 vs T2

```bash
cat /sys/class/dmi/id/product_name
```

| Model | Chip | Touch Bar driver |
|---|---|---|
| MacBookPro13,1/13,2/13,3, MacBookPro14,1/14,2/14,3 | **T1** (iBridge) | out-of-tree `apple-ibridge` trio |
| MacBookPro15,x and later | T2 | mainline `hid-appletb-kbd` / `hid-appletb-bl` |

On a T1, do not install or pursue: `linux-t2`, `apple-bce`, `tiny-dfr`,
`t2fanrd`, `apple-bcm-firmware`, `facetimehd`, `apple-ib-drv-dkms-git`.
Confirm rather than trusting a guide:

```bash
modinfo hid-appletb-kbd | grep '^alias'   # ...p00008302 -> T2 only
modinfo hid-appletb-bl  | grep '^alias'   # ...p00008102 -> T2 only
```

The T1 Touch Bar is USB `05ac:8600`. Those T2 modules match `8302`/`8102` and
will never bind here. Their presence in `/lib/modules` proves nothing.

## Before you build anything: is this the right stack?

**Check [t1bridge](https://github.com/standardagents/t1bridge) first.** It is the
maintained T1 stack and covers more than this driver trio does:

| | this stack | t1bridge |
|---|---|---|
| Touch Bar | yes | yes, own renderer |
| Touch ID | no | yes, via `fprintd` |
| Camera | free with firmware | packaged UVC driver |
| Distribution | stock kernel | third-party signed pacman repo |

This stack remains the right choice when the user wants no third-party
repository or signing key, or already has it working. It is the small,
dependency-free path. Say which one you are setting up before starting, because
**they conflict** and the install order matters.

The rest of this skill documents this stack. If t1bridge is the answer, install
that instead and stop here — do not install both.

## Step 1 — check the firmware (do this first, always)

**Back it up before anything else.** The three files below are personalised to
this machine's ECID, cannot be downloaded, and no other Mac's copy will boot
this chip. If the ESP is wiped, only a macOS reinstall regenerates them. A
31 MB archive turns that into a file copy:

```bash
sudo ~/t1-touchbar/backup-t1-firmware.sh
```

Then copy the result **off the disk**. Verify it later with
`sha256sum -c SHA256SUMS.txt` in the archive directory. Restore with
`sudo ~/t1-touchbar/restore-t1-firmware.sh` (refuses to touch a healthy T1).

The T1 has no firmware in ROM. macOS writes it to the ESP at
`EFI/APPLE/EMBEDDEDOS/combined.memboot` (~30 MB, plus `FDRData`,
`version.plist`), and Apple's boot firmware loads it at every power-on. A
whole-disk Linux install erases it.

```bash
for d in /sys/bus/usb/devices/*/; do
  [ "$(cat $d/idVendor 2>/dev/null)" = 05ac ] &&
    echo "05ac:$(cat $d/idProduct) $(cat $d/product 2>/dev/null)"
done
```

- **`05ac:8600 iBridge`** — firmware loaded. Proceed to Step 2.
- **`05ac:1281` (Recovery Mode)** — firmware absent. **Stop.** No driver can
  help: the firmware is absent, not merely unbound.

To fix `1281`: install macOS to a partition, boot it **with internet**, and let
`EmbeddedOSInstallService` provision the chip. This is firmware provisioning,
not licensing — no Apple ID sign-in or activation is involved. macOS writes the
files to the **internal** ESP; writing to a different disk's ESP is the classic
failure. Verify afterwards with `ls /boot/EFI/APPLE/EMBEDDEDOS/`.

If a backup already exists, you do not need macOS at all — restore the archive
and reboot. The firmware is loaded into the chip at power-on, so nothing takes
effect until you reboot.

### The interface is not re-enumerated without a reboot

Restoring the files does not revive a running chip. Reboot, then confirm
`05ac:8600` before touching the driver layer.

The files are bound to this machine's **ECID** — worthless on another Mac,
irreplaceable on this one. Back them up off-disk and never wipe the directory.

## Step 2 — build and install the driver

The driver is the out-of-tree trio `apple-ibridge` / `apple-ib-tb` /
`apple-ib-als`. A prepared, tested toolkit should exist at `~/t1-touchbar`
(see the user's own copy; it carries `bootstrap-t1-touchbar.sh`).

```bash
sudo ~/t1-touchbar/bootstrap-t1-touchbar.sh
```

If that directory is absent, reconstruct it:

1. Get the source: `pacman -S macbook12-spi-driver-dkms` (ships source to
   `/usr/src/macbook12-spi-driver-*`), or
   `git clone -b touchbar-driver-hid-driver https://github.com/roadrunner2/macbook12-spi-driver`.
2. Patch it — see Step 3.
3. Build only `apple-ibridge`, `apple-ib-tb`, `apple-ib-als`. **Never build
   `applespi`**: the in-tree one already drives keyboard and touchpad, and an
   out-of-tree copy would shadow it.
4. Register with DKMS so it survives kernel upgrades, add
   `/etc/modules-load.d/`, and install the handover from Step 4.

## Step 3 — kernel API drift

The source does not compile against modern kernels. Three fixes:

| Break | Fix | Since |
|---|---|---|
| `report_fixup` must return `const __u8 *` | qualify the return type | 6.x |
| `.owner` removed from `struct acpi_driver` | delete the field | 6.x |
| `platform_driver.remove` returns `void` | change signature, early-return | 6.11 |

The two `*_platform_remove` functions keep their error path as a bare `return`
(they previously used `goto error` + `return rc`).

When a new error appears, read it, find the new API shape under
`/lib/modules/$(uname -r)/build/include/linux/`, fix, and re-verify the build.

## Step 4 — the 634-byte interface handover (the silent trap)

The iBridge exposes the Touch Bar over **two** USB HID interfaces. Generic
drivers claim both at boot and `hid-sensor-hub` keeps the second:

```
0003:05AC:8600.0001    83 bytes  -> hid-generic        boot keyboard
0003:05AC:8600.0002   634 bytes  -> hid-sensor-hub     <-- the Touch Bar
```

`apple-ibridge` reclaims `.0001` but **not** `.0002`, so `appletb_probe()` never
runs and the strip stays dark. The modules load, they bind, `lsmod` looks
correct, and `dmesg` shows no error. The only reliable tell is the **absence of
the writable sysfs controls** a successful probe creates:

```bash
ls /sys/bus/hid/devices/0003:05AC:8600.0001/   # want fnmode, idle_timeout, dim_timeout
```

`634` bytes is the exact size `appleib_report_fixup()` tests for — match on
that, never on interface numbering. Hand it over:

```bash
DEV=0003:05AC:8600.0002
printf '%s' "$DEV" | sudo tee /sys/bus/hid/drivers/hid-sensor-hub/unbind
printf '%s' "$DEV" | sudo tee /sys/bus/hid/drivers/apple-ibridge-hid/bind
```

This must run at every boot; a systemd unit ordered before `display-manager`
is the right place. The user's toolkit ships one.

## Step 5 — keyboard backlight (often reported as "backlight broken")

On these machines the F1-F12 row exists **only on the Touch Bar**, so until the
Touch Bar works the backlight keys are physically unreachable. Verify the
hardware is fine, which it usually is:

```bash
cat /sys/class/leds/spi::kbd_backlight/brightness   # 0-255
brightnessctl -d spi::kbd_backlight set 128         # user-writable, no root
```

While the Touch Bar is unavailable, bind the actions to real keys in
`~/.config/hypr/bindings.lua` (Omarchy/Hyprland):

```lua
o.bind("SUPER + minus", "Keyboard backlight down", "omarchy-brightness-keyboard down")
o.bind("SUPER + equal", "Keyboard backlight up", "omarchy-brightness-keyboard up")
o.bind("SUPER + 0", "Keyboard backlight toggle", "omarchy-brightness-keyboard cycle")
```

`omarchy-brightness-display +5%` handles the display the same way. Do **not**
edit `/usr/share/omarchy/`; see the `omarchy` skill. Apply with
`hyprctl reload` and confirm with `hyprctl configerrors`.

## Pitfalls

1. **Treating this as a T2 problem.** The single most expensive mistake. Check
   `product_name` before anything else.
2. **Assuming a driver can fix `05ac:1281`.** It cannot. Firmware is absent.
   Only booting macOS rewrites it.
3. **Reporting the Touch Bar as fixed because the modules loaded.** Loading is
   not binding. Require the presence of `fnmode` as proof.
4. **Building `applespi`.** It shadows the working in-tree driver and risks the
   keyboard on every kernel update.
5. **Leaving two DKMS packages owning the same modules.** Whichever builds last
   wins, unpredictably. Disable one.
6. **A bare `.ko` in `/lib/modules`.** Dies at the next kernel update. Use DKMS.
7. **Blaming the Touch Bar driver for a dark strip when `fnmode` exists.** If
   the sysfs controls are there, the probe succeeded — the problem is elsewhere.
8. **`apple-ib-als` failing to load.** `Unknown symbol
   iio_triggered_buffer_setup_ext` is module ordering, affects only the ambient
   light sensor (`hid-sensor-als` already covers it), and does not affect the
   Touch Bar. Blacklist it to silence the noise.
9. **Believing Touch ID is impossible.** Older guides — including earlier
   versions of this skill — say no Linux driver exists. That is out of date:
   t1bridge ships `libfprint-t1bridge` + `fprintd-t1bridge` and Touch ID works
   through standard `fprintd-enroll` / `fprintd-verify`. It needs this machine's
   preserved `EFI/APPLE/EMBEDDEDOS/FDRData`; a regenerated or foreign copy will
   not do.
14. **Running this stack and t1bridge together.** They conflict. t1bridge's
    preflight refuses while `apple_ibridge` / `apple_ib_tb` / `apple_ib_als` are
    present — they bind the T1 HID interfaces and pin its USB configuration, and
    a run started with them loaded has been reported to wedge with
    `result=error code=5`. Disable this stack first; see
    docs/upstream-status.md in the toolkit.
10. **Not backing up the firmware before repartitioning.** The most expensive
    omission. 31 MB now, versus a macOS reinstall later. Back it up first and
    keep it off the machine.
11. **Assuming the ESP is at `/boot/efi`.** On Omarchy it is at `/boot`.
    Resolve it with `findmnt -no SOURCE,FSTYPE /boot` rather than hardcoding.
12. **Trying to source the firmware from elsewhere.** It is not downloadable.
    `combined.memboot` is assembled on-machine and signed for this chip's ECID;
    a donor copy fails signature validation. It *can* be regenerated from Linux
    without macOS, via [t1-revive](https://github.com/niconistal/t1-revive)
    (released, verified on all four T1 models) — but that needs a network path
    to Apple and only works while Apple still signs this firmware. A local
    backup is faster, offline, and does not depend on Apple's signing policy.
13. **Running ACPI `SOCW(1)` as a T1 reset.** It can hard-freeze these
    machines. The only reset observed to work is `FRST`.

## Verification

```bash
# 0. firmware archived and verified (do this first)
ls -la ~/t1-firmware-backup/ && (cd ~/t1-firmware-backup && sha256sum -c SHA256SUMS.txt)

# 1. iBridge healthy (want 05ac:8600)
for d in /sys/bus/usb/devices/*/; do
  [ "$(cat $d/idVendor 2>/dev/null)" = 05ac ] && echo "05ac:$(cat $d/idProduct)"
done

# 2. 634-byte interface on apple-ibridge-hid
for h in /sys/bus/hid/devices/0003:05AC:8600.*; do
  echo "$(basename $h) $(wc -c < $h/report_descriptor) -> $(basename $(readlink -f $h/driver))"
done

# 3. probe succeeded (only exists after appletb_probe runs)
cat /sys/bus/hid/devices/0003:05AC:8600.0001/fnmode     # expect 1

# 4. survives reboot
systemctl status apple-touchbar.service --no-pager
```

`fnmode`: `1` = Esc + media/brightness keys by default, Fn gives F1-F12 (Mac
default). `2` = opposite. Set via `/etc/modprobe.d/apple-ib-tb.conf` or
`echo 2 > /sys/bus/hid/devices/0003:05AC:8600.0001/fnmode`.

A working webcam (`/dev/video0`) is independent confirmation that the T1
firmware loaded, since the camera hangs off the same chip with no Linux driver
of its own.
