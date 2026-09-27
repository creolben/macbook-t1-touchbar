# Upstream status

What already exists for the T1 on Linux, what this repo adds, and where the
upstream work is. Last checked 2026-09-27.

This matters because most of the T1 write-ups on the web predate the tools
below, and some of their claims are now wrong. In particular, two things this
repo's own history asserted are no longer true: **Touch ID is not impossible**,
and **firmware no longer has to come from macOS**.

## The projects

| Project | What it does | State |
|---|---|---|
| [standardagents/t1bridge](https://github.com/standardagents/t1bridge) | Touch Bar, camera, Touch ID, T1 lifecycle. Signed Arch packages. | Active. 44★. Touch ID via `fprintd`. |
| [niconistal/t1-revive](https://github.com/niconistal/t1-revive) | Regenerates the ECID-bound firmware from Linux, no macOS. | Active. 6★. 0.1.3, verified on all four T1 models. |
| [omacom/omarchy-iso#174](https://github.com/omacom/omarchy-iso/pull/174) | Stops the installer erasing `EFI/APPLE` on the way in. | **Open**, mergeable, needs review. |
| [basecamp/omarchy#8271](https://github.com/basecamp/omarchy/issues/8271) | The tracking issue for the above. #8323 was closed as its duplicate. | Open. |
| [roadrunner2/macbook12-spi-driver](https://github.com/roadrunner2/macbook12-spi-driver) | The out-of-tree driver trio this repo builds. | Upstream of this work. |

## What changed, and when

**Touch ID.** Every older guide says no Linux driver exists and none is coming.
That was true for years. `t1bridge` ships `libfprint-t1bridge` +
`fprintd-t1bridge`, replacing the distro pair system-wide, and Touch ID then
works through the standard `fprintd-enroll` / `fprintd-verify` tools with
enrolments surviving reboot.

It requires **this machine's** `EFI/APPLE/EMBEDDEDOS/FDRData` — the same file
this repo's backup script archives. A regenerated or foreign copy will not do.
So the backup advice here is not merely belt-and-braces; for Touch ID it is the
prerequisite.

**Firmware regeneration.** `t1-revive` drives Apple's own EmbeddedOS restore
protocol with patched libimobiledevice tools: the chip fetches its own
Apple-signed factory data, gets a personalised boot image, boots from it, and
the three resulting files are staged to the ESP. Verified on MacBookPro13,2 /
13,3 / 14,2 / 14,3.

Caveats worth knowing: it needs a network path to Apple (`gs.apple.com`,
`swcdn.apple.com`), and it talks to Apple's signing service, so it can only work
while Apple still signs this firmware. It also writes new factory data into the
chip, and takes 4–5 minutes.

**An off-disk copy of `EFI/APPLE` is a different kind of thing** — not a slower
version of the same trick. Once provisioned, the chip boots straight off the ESP
and never contacts Apple: it reads the blob about 0.8 s into power-on, before
networking exists. Restoring a backup therefore covers the realistic failure
(a wiped partition) with no network, no Apple, and no dependency on Apple's
signing policy continuing. What it cannot do is re-flash a chip that has lost
its own flash contents; that is the case t1-revive exists for, and the only one
that genuinely needs Apple.

**The installer.** #174 adds two hooks in `orchestrator/apple_efi.py`:
`prepare_live` copies `EFI/APPLE` to RAM before `omarchy-iso-cleanup-disk`
touches the disk, and `_install_limine_omarchy` writes it back to the new ESP
before Limine is installed. 72 unit tests pass. Not yet exercised on a live T1
install. Until it merges, a full-disk Omarchy install still destroys the folder.

## The conflict between this repo and t1bridge

**They cannot run at the same time.** `t1-revive`'s preflight refuses to proceed
while the pre-t1bridge drivers are present:

> the out-of-tree drivers that predate t1bridge — apple-ib-drv and its forks
> (`apple_ibridge`, `apple_ib_tb`, `apple_ib_als`) — bind the T1's HID interfaces,
> and the udev rules that ship with them pin its USB configuration to 1. On the
> 13,2 in #10 the boot step reached 05ac:8600 and the post-watch USB walk then
> wedged against a device something else was holding: the chain died twice with
> `result=error code=5`, and finished at the first attempt once that stack was
> disabled.

Disable this stack first. `t1-touchbar.sh status` prints the exact steps and
detects the conflict; the sequence is in the README.

## What this repo is still for

Not everything is superseded. This repo:

- **works on a stock kernel**, with no third-party pacman repository and no
  signing key to trust;
- **backs up and restores the firmware** as a plain file copy — offline, instant,
  and independent of Apple's signing service;
- **documents the diagnosis** — the 634-byte interface, the silent
  `hid-sensor-hub` theft, the kernel API drift — in enough detail to be useful
  when something else breaks;
- **carries the API fixes** (const `report_fixup`, no `.owner`, `void` platform
  remove) as a re-runnable patcher rather than hand-edited source.

It is the small, dependency-free path. t1bridge is the complete one.

## If you are choosing

**Fresh T1 install, want everything:** t1bridge. Accept the third-party repo,
trust the signing key, and preserve `FDRData`.

**Existing working setup, or want no third-party repositories:** this repo.
You keep Touch Bar and camera; you do not get Touch ID.

**Already wiped `EFI/APPLE`, no backup:** `t1-revive`, then t1bridge.

**About to install Linux on a T1 for the first time:** back up `EFI/APPLE` to
separate hardware first, and watch #174.
