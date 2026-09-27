# macbook-t1-touchbar-linux

Touch Bar support for the Apple **T1** (iBridge) MacBook Pro on Linux —
MacBookPro13,x and MacBookPro14,x (2016–2017 Touch Bar models).

> **T1, not T2.** The T2 chip starts with the 2018 models (MacBookPro15,x).
> Almost every Linux-on-Mac guide is written for T2 and installs packages that
> silently do nothing here. This repo is T1-only.

Two ways to use it:

| | |
|---|---|
| **`plugin-t1-touchbar/`** | A Hermes Agent plugin — five tools the agent can call, plus the diagnostic skill |
| **`standalone/`** | Plain scripts, no Hermes required; one entry point |

## Start here: back up the firmware

```bash
sudo ./standalone/t1-touchbar.sh backup-firmware
```

Then copy the result **off the disk**. This is the one thing on a T1 Mac that
cannot be regenerated: the firmware is personalised to your chip's ECID, cannot
be downloaded, and no other Mac's copy will work.

### Why this is worth doing even though Apple is involved once

It is easy to read "the T1 needs Apple" and conclude a backup is pointless. It
is not, because **provisioning** and **booting** are different events:

| | Needs Apple? | Needs your backup? |
|---|---|---|
| T1 boots at power-on | **No** | **No** — it reads the ESP |
| ESP wiped by an installer | — | **Yes** — instant, offline |
| Re-provision from scratch | **Yes** | slower alternative |

Your Mac does not talk to Apple to boot. The chip reads
`EFI/APPLE/EMBEDDEDOS/combined.memboot` off the ESP about **0.8 seconds** into
power-on — before networking exists, before userspace. On a healthy machine you
can watch it happen:

```bash
sudo dmesg | grep -m1 'Product: iBridge'      # ~0.77s into boot
```

Apple's servers were involved **once**, when macOS ran
`EmbeddedOSInstallService` and asked to have a boot image signed for this chip's
ECID. That produced the ~30 MB blob now sitting on your disk, and macOS has not
been needed since. The blob is a self-contained, Apple-signed, machine-bound boot
image — there is no per-boot validation and no account attached to it.

So the backup replaces the *only* step that needs Apple. With it, a wiped ESP is
a five-second file copy, offline. Without it, you go back to Apple — and only
while Apple still signs this firmware. From t1-revive's own documentation:

> If Apple stops signing this firmware, regeneration stops working for everyone,
> macOS reinstalls included. That is the one permanent scenario, and the reason
> an off-disk copy of `EFI/APPLE` is worth taking while the folder still exists.

### The one thing a backup cannot cover

A file copy restores the ESP; it does not re-flash the chip. Restoring works
because the T1 re-reads those files at boot — which covers the case that actually
happens, an installer wiping the partition. If the T1's own flash ever loses its
data, no file copy helps and the restore protocol in
[t1-revive](https://github.com/niconistal/t1-revive) is the only route. That one
does need Apple's servers.

31 MB now, covering the realistic failure offline and instantly, versus a macOS
reinstall or an Apple-dependent recovery later.

## The whole toolkit

Everything goes through one entry point:

```bash
./t1-touchbar.sh status            # read-only diagnosis, in dependency order
sudo ./t1-touchbar.sh backup-firmware
sudo ./t1-touchbar.sh restore-firmware
./t1-touchbar.sh build             # patch + compile the modules (no root)
sudo ./t1-touchbar.sh install      # DKMS + boot load + handover
sudo ./t1-touchbar.sh load         # manual load, for an already-installed system
sudo ./resolve-dkms-conflict.sh    # stop two DKMS packages claiming the same modules
```

`status` walks the layers in the order they must work — firmware → USB
enumeration → HID interface ownership → driver probe → DKMS — and says what to
do about each failure. `build` needs no privilege at all; it patches and
compiles into a temp directory.

## Install as a Hermes plugin

```bash
hermes plugins install creolben/macbook-t1-touchbar/plugin-t1-touchbar --force --no-enable
hermes plugins enable t1-touchbar
```

Five tools, none requiring tool-override rights:

| Tool | Privilege | Side effects |
|---|---|---|
| `t1_touchbar_status` | none | none — read-only diagnosis |
| `t1_touchbar_build` | none | none — compiles to a temp dir |
| `t1_touchbar_install` | required | DKMS + systemd + initramfs, needs `confirm=true` |
| `t1_touchbar_backup_firmware` | required | writes an archive of the ESP firmware |
| `t1_touchbar_restore_firmware` | required | writes to the ESP; refuses a healthy T1 |

Plus the skill, loadable as `skill_view('t1-touchbar:macbook-t1-touchbar-linux')`.

On a T2 machine or any non-T1 Mac, every tool returns an explanation instead of
acting — because the right answer there is a different driver entirely.

## Install standalone (no Hermes)

```bash
sudo ./standalone/bootstrap-t1-touchbar.sh
```

Checks the hardware, installs prerequisites, obtains and patches the driver
source, builds it, registers DKMS, installs the boot-time HID interface
handover, and rebuilds the initramfs.

## The one rule that decides everything

The T1 has **no firmware in ROM**. macOS writes it to the ESP at
`EFI/APPLE/EMBEDDEDOS/combined.memboot` (~30 MB), and Apple's boot firmware
loads it at power-on. A whole-disk Linux install erases it, and the chip falls
back to recovery mode:

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

Only booting macOS fixes `1281`. This is firmware provisioning, not licensing —
no Apple ID sign-in or activation is involved. The resulting files are bound to
this machine's ECID: worthless on another Mac, irreplaceable on this one. Back
them up off-disk.

## The two traps

**1. The 634-byte interface gets stolen.** The iBridge exposes the Touch Bar
over two USB HID interfaces. `hid-sensor-hub` keeps the one carrying the bar,
so `apple-ibridge` reclaims only the first and `appletb_probe()` never runs. The
failure is silent — modules load, `lsmod` looks right, `dmesg` is clean, and the
strip stays dark. The only reliable tell is the absence of the `fnmode` sysfs
attribute that a successful probe creates. `634` bytes is what
`appleib_report_fixup()` tests for; match on that, never on interface numbering.

**2. Kernel API drift.** The driver source predates several kernel changes:

| Break | Fix | Since |
|---|---|---|
| `report_fixup` must return `const __u8 *` | qualify the return type | 6.x |
| `.owner` removed from `struct acpi_driver` | delete the field | 6.x |
| `platform_driver.remove` returns `void` | change signature, early-return | 6.11 |

`t1-patch-source.py` applies all three idempotently and exits 2 when the source
has moved on — meaning upstream changed, not that your machine is broken.

## Design decisions

**`applespi` is never built.** The in-tree driver already handles the keyboard
and touchpad; an out-of-tree copy would shadow it and risk the keyboard on every
kernel update. Only the three missing T1 modules are built.

**The distro package's DKMS registration is disabled.** `macbook12-spi-driver-dkms`
ships the same three module names. Two owners means whichever builds last wins,
unpredictably. The installer keeps the package (it is the source) but sets
`AUTOINSTALL="no"` in its `dkms.conf`.

**`apple-ib-als` may fail to load** with
`Unknown symbol iio_triggered_buffer_setup_ext`. That is module load ordering,
affects only the ambient light sensor (which `hid-sensor-als` already covers),
and does not affect the Touch Bar.

## Verified on

MacBookPro14,3 · Omarchy/Arch · kernel 7.2.5-4 · Limine · LUKS+btrfs.

Expected to apply to any T1 model. If you run it on different hardware, please
report what happened.

## Superseded for Touch Bar and Touch ID: t1bridge

**If you are starting fresh, look at [t1bridge](https://github.com/standardagents/t1bridge)
first.** It is the maintained T1 stack and it covers more than this project does.

| | This toolkit | t1bridge |
|---|---|---|
| Touch Bar | ✅ | ✅ (own renderer, customisable) |
| FaceTime camera | ✅ free with firmware | ✅ packaged UVC driver |
| Touch ID | ❌ | ✅ via `fprintd` |
| Ambient light sensor | ❌ (`hid-sensor-als` only) | 🔴 planned |
| Suspend/resume | — | 🔴 not working on the tested machine |
| Distribution | this repo | signed pacman repo from `linux.standardagents.ai` |
| Needs preserved `FDRData` | no | **yes, for Touch ID** |

**They conflict.** t1bridge's tooling refuses to run while the pre-t1bridge
out-of-tree drivers (`apple_ibridge`, `apple_ib_tb`, `apple_ib_als`) are
present: they bind the T1's HID interfaces and their udev rules pin its USB
configuration, and a run started with them loaded has been reported to wedge
partway through with `result=error code=5`. Disable this stack before migrating:

```bash
sudo systemctl disable --now apple-touchbar.service
sudo rm -f /etc/modules-load.d/apple-touchbar.conf
sudo rmmod apple_ib_tb apple_ib_als apple_ibridge
sudo dkms remove -m appleibridge -v 0.1 --all
sudo dkms remove -m macbook12-spi-driver -v 0+git.315 --all
```

`t1-touchbar.sh status` reports this conflict and prints the same steps.

**Why this repo still exists.** It does three things t1bridge does not attempt:
it works on a *stock kernel* with no third-party repository or signing key, it
backs up and restores the ECID-bound firmware (a plain file copy, no Apple
servers), and it documents the diagnosis in enough detail to be useful when
something else breaks. It is the small, dependency-free path; t1bridge is the
complete one.

## Touch ID: what changed

If you read an earlier version of this file, it said Touch ID was impossible on
Linux. That was correct when the community write-ups were written and is no
longer true — [t1bridge](https://github.com/standardagents/t1bridge) provides it
through standard `fprintd` tooling, on the same `EFI/APPLE/EMBEDDEDOS/FDRData`
this repo tells you to back up. It requires that preserved copy; a regenerated
or foreign one will not do.

Similarly, T1 firmware **can** now be regenerated from Linux without macOS, via
[t1-revive](https://github.com/niconistal/t1-revive). Restoring this repo's
backup is still faster and does not depend on Apple's signing service — but
"only a macOS reinstall can fix it" is no longer the whole picture.

## Credits

Driver by Ronald Tschalär — [roadrunner2/macbook12-spi-driver](https://github.com/roadrunner2/macbook12-spi-driver).

The ESP/T1 firmware insight and the T1-vs-T2 distinction come from the
community write-ups by
[Dunedan/mbp-2016-linux](https://github.com/Dunedan/mbp-2016-linux),
[cschaba/macbookpro14-3-linux](https://github.com/cschaba/macbookpro14-3-linux)
and [nohzafk/omarchy-macbookpro-t1](https://github.com/nohzafk/omarchy-macbookpro-t1).

Upstream paths that supersede parts of this work:
[standardagents/t1bridge](https://github.com/standardagents/t1bridge) (Touch Bar,
camera, Touch ID), [niconistal/t1-revive](https://github.com/niconistal/t1-revive)
(firmware regeneration from Linux), and
[omacom/omarchy-iso#174](https://github.com/omacom/omarchy-iso/pull/174) (stop the
installer erasing `EFI/APPLE` in the first place). See
[docs/upstream-status.md](docs/upstream-status.md).

## License

MIT for the plugin, scripts and documentation. The kernel driver source under
`standalone/apple-ib-*.c` is GPL v2, from the upstream project above.
