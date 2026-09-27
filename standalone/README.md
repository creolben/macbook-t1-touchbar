# T1 Touch Bar on Linux — reusable fix

Reusable setup for the Apple **T1** (iBridge) Touch Bar on Linux, for
MacBookPro13,x and MacBookPro14,x (2016–2017 Touch Bar MacBook Pros).

Verified on **MacBookPro14,3** · Omarchy/Arch · kernel **7.2.5-4** · Limine ·
LUKS+btrfs. Expected to apply to any T1 model.

> **This is T1, not T2.** The T2 chip starts with the 2018 models
> (MacBookPro15,x). Almost every Linux-on-Mac guide is written for T2 and
> installs packages that silently do nothing here. See *T2 packages that look
> relevant and are not* below.

## Quick start

On a fresh install, one command:

```bash
sudo ./bootstrap-t1-touchbar.sh
```

It checks the hardware, installs prerequisites, obtains and patches the driver
source, builds it, registers DKMS, installs the boot-time interface handover,
and rebuilds the initramfs. It fails early and loudly if the T1 firmware is
missing — which is the most common blocker and has nothing to do with drivers.

If you already have the modules installed and just need to load them:

```bash
sudo ./load-t1-touchbar.sh
```

## The one rule that decides everything

The T1 has **no firmware in ROM**. macOS writes it to the EFI System Partition at
`EFI/APPLE/EMBEDDEDOS/combined.memboot` (~30 MB, plus `FDRData` and
`version.plist`), and Apple's boot firmware loads it into the chip on every
power-on.

A whole-disk Linux install erases that partition. The T1 then enumerates as
`05ac:1281 Apple Mobile Device (Recovery Mode)` instead of `05ac:8600 iBridge`,
and Touch Bar, webcam, Touch ID and ambient light sensor all stop working.

Check this first, always:

```bash
for d in /sys/bus/usb/devices/*/; do
  [ "$(cat $d/idVendor 2>/dev/null)" = 05ac ] &&
    echo "05ac:$(cat $d/idProduct) $(cat $d/product 2>/dev/null)"
done
```

| Result | Meaning |
|---|---|
| `05ac:8600 iBridge` | firmware loaded — drivers can work |
| `05ac:1281 ... (Recovery Mode)` | firmware missing — **no driver can help** |

Only booting macOS fixes `1281`. Install macOS to a partition, boot it **with
internet**, and let `EmbeddedOSInstallService` (EOSIS) provision the chip. It
downloads a device-personalised package; a valid preflight in
`/Library/Updates/PreflightContainers` allows an offline run, but a bare ESP
means you need the network. No Apple ID sign-in or activation is involved —
this is firmware provisioning, not licensing.

The resulting files are bound to this machine's **ECID**. They are worthless on
another Mac and irreplaceable on this one. Back them up off-disk, and do not
wipe the directory afterwards.

## Why the driver is needed at all

Nothing in mainline drives a T1 Touch Bar. The driver is the out-of-tree trio
`apple-ibridge` / `apple-ib-tb` / `apple-ib-als`. Arch's
`macbook12-spi-driver-dkms` ships the source but it arrives uncompiled
(`dkms status` → `added`, not `installed`) because it predates current kernels.

## The two traps

### Trap 1 — the 634-byte interface gets stolen

The iBridge exposes the Touch Bar over **two** USB HID interfaces. Generic
drivers claim both at boot, and `hid-sensor-hub` keeps the second one:

```
0003:05AC:8600.0001    83 bytes  -> hid-generic        boot keyboard
0003:05AC:8600.0002   634 bytes  -> hid-sensor-hub     <-- the Touch Bar
```

`apple-ibridge` reclaims `.0001` on load but **not** `.0002`, so
`appletb_probe()` never runs and the strip stays dark.

This is the trap that wastes hours, because the failure is silent: the modules
load, they bind, `lsmod` looks correct, and `dmesg` shows no error. There is
nothing to search for. The only reliable tell is the **absence of the writable
sysfs controls** that a successful probe creates:

```bash
ls /sys/bus/hid/devices/0003:05AC:8600.0001/   # want fnmode, idle_timeout, dim_timeout
```

`634` bytes is the exact size `appleib_report_fixup()` tests for, so it is a
reliable identifier. Never match on interface numbering.

The fix is a handover — unbind from `hid-sensor-hub`, bind to
`apple-ibridge-hid`:

```bash
DEV=0003:05AC:8600.0002
echo "$DEV" | sudo tee /sys/bus/hid/drivers/hid-sensor-hub/unbind
echo "$DEV" | sudo tee /sys/bus/hid/drivers/apple-ibridge-hid/bind
```

`apple-touchbar-handover` does this at boot and is idempotent.

### Trap 2 — kernel API drift

The source is dated and does not compile against modern kernels. Three fixes,
all applied automatically by `t1-patch-source.py`:

| Break | Fix | Since |
|---|---|---|
| `report_fixup` must return `const __u8 *` | qualify the return type | 6.x |
| `.owner` removed from `struct acpi_driver` | delete the field | 6.x |
| `platform_driver.remove` returns `void` | change signature, early-return | 6.11 |

`appletb_platform_remove` and `appleals_platform_remove` each keep their error
path as a bare `return` (the previous code used `goto error` + `return rc`).

## Layout

| File | Purpose |
|---|---|
| `bootstrap-t1-touchbar.sh` | fresh-install entry point; runs everything below |
| `t1-patch-source.py` | idempotent kernel-API patcher; exit 2 means the source moved on |
| `install-t1-touchbar.sh` | DKMS tree + boot load + handover unit |
| `apple-touchbar-handover` | rebinds the 634-byte interface; also usable standalone |
| `apple-touchbar.service` | runs the handover before `display-manager` |
| `load-t1-touchbar.sh` | manual load for an already-installed system |
| `apple-ib-*.c`, `Makefile` | patched source, kernel 7.2.5-4 verified |
| `api-fixes.patch` | the three fixes as a diff, for reference/review |

Installed to the system:

```
/usr/src/appleibridge-0.1/         DKMS source tree
/usr/local/sbin/apple-touchbar-handover
/etc/systemd/system/apple-touchbar.service
/etc/modules-load.d/apple-touchbar.conf
/etc/modprobe.d/apple-ib-tb.conf   fnmode=1
```

## Design decisions worth knowing

**`applespi` is never built.** The in-tree `applespi` already drives the
keyboard and touchpad correctly. Shipping an out-of-tree copy in this DKMS tree
would shadow it and risk the keyboard on every kernel update. Only the three
missing T1 modules are built.

**The distro package's DKMS registration is disabled.** `macbook12-spi-driver-dkms`
ships the same three module names. Two packages owning the same modules means
whichever builds last wins, unpredictably across kernel updates. The installer
removes the distro registration and sets `AUTOINSTALL="no"` in its `dkms.conf`
(original kept as `dkms.conf.orig`) while **keeping the package**, since it is
the source of this driver.

**`apple-ib-als` may fail to load** with
`Unknown symbol iio_triggered_buffer_setup_ext`. That is module load ordering
(modprobe `industrialio-triggered-buffer` first) and affects only the ambient
light sensor, which `hid-sensor-als` already handles. It does not affect the
Touch Bar. Silence it with:

```bash
echo 'blacklist apple-ib-als' | sudo tee /etc/modprobe.d/apple-ib-als.conf
```

## Verification

```bash
# 1. iBridge healthy
for d in /sys/bus/usb/devices/*/; do
  [ "$(cat $d/idVendor 2>/dev/null)" = 05ac ] && echo "05ac:$(cat $d/idProduct)"
done                                   # want 05ac:8600

# 2. both interfaces on the right driver
for h in /sys/bus/hid/devices/0003:05AC:8600.*; do
  echo "$(basename $h) $(wc -c < $h/report_descriptor) -> $(basename $(readlink -f $h/driver))"
done                                   # 634-byte one must say apple-ibridge-hid

# 3. probe succeeded (these only exist after appletb_probe runs)
cat /sys/bus/hid/devices/0003:05AC:8600.0001/fnmode   # expect 1

# 4. service
systemctl status apple-touchbar.service --no-pager
```

`fnmode`: `1` = Esc + media/brightness keys by default, hold Fn for F1–F12 (the
Mac default). `2` = the opposite. Set it in
`/etc/modprobe.d/apple-ib-tb.conf` or at runtime:

```bash
echo 2 | sudo tee /sys/bus/hid/devices/0003:05AC:8600.0001/fnmode
```

## When the kernel API moves again

`t1-patch-source.py` exits **2** when it cannot find a pattern it expects. That
means upstream or the distro source changed — not that the machine is broken.
To fix it:

```bash
cd /tmp/t1-touchbar-build
make V=1            # full command lines
make 2>&1 | grep error
```

Read the error, work out the new API shape from the kernel tree
(`/lib/modules/$(uname -r)/build/include/linux/`), fix the source, then add the
new transformation to `t1-patch-source.py` alongside the existing entries so the
fix is captured for next time. Confirm the result still builds, and that a
second run reports `0 change(s) applied` (idempotency).

## Still not possible: Touch ID

No Linux driver exists for the T1 or T2 Touch ID sensor, and none is in
progress. It is wired to the Secure Enclave and speaks an encrypted,
Apple-signed protocol; `libfprint` has nothing for it. This is true **with or
without** firmware. Plan around it.

## T2 packages that look relevant and are not

On a T1 these match nothing (T2 product IDs are `05ac:8302` / `8102`) and should
not be installed:

`linux-t2` · `linux-t2-headers` · `apple-bce` · `tiny-dfr` · `t2fanrd` ·
`apple-bcm-firmware` · `apple-t2-audio-config` · `facetimehd` ·
`apple-ib-drv-dkms-git`

Verify for yourself rather than trusting a guide:

```bash
modinfo hid-appletb-kbd | grep '^alias'   # ...p00008302 -> T2 only
modinfo hid-appletb-bl  | grep '^alias'   # ...p00008102 -> T2 only
```

`tiny-dfr` renders onto the `appletbdrm` DRM node, which never exists on a T1.
And note `hid-appletb-kbd` / `hid-appletb-bl` **are** in mainline — their
presence in `/lib/modules` is not evidence they apply to your machine.

## Credits

Driver by Ronald Tschalär (`roadrunner2/macbook12-spi-driver`). The ESP/T1
firmware insight and the T2-vs-T1 distinction come from the community write-ups
by `Dunedan/mbp-2016-linux`, `cschaba/macbookpro14-3-linux` and
`nohzafk/omarchy-macbookpro-t1`.
