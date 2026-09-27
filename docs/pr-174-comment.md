# Draft review comment for omacom/omarchy-iso#174

**Not posted.** This is the text to post on
[omacom/omarchy-iso#174 — "Preserve Apple EFI firmware folder across the install"](https://github.com/omacom/omarchy-iso/pull/174)
(open, mergeable, `REVIEW_REQUIRED`, last activity 2026-09-19).

## Why this comment exists

The PR has two open questions in its description. Question 1 is:

> The restore hook writes to `ctx.target / esp_mount.lstrip("/")` because
> `efi_partition.mountpoint` is the installed system's mountpoint (`/boot`),
> matching what `_install_limine_efi` and `_write_limine_defaults` already do.
> Worth a check that this is the right handle on the ESP at that point in the
> phase.

That can be answered with evidence from a real machine rather than opinion, and
the PR has no MacBookPro14,3 coverage yet — its reporting is 14,2-shaped.

## What was verified on this machine before writing it

MacBookPro14,3 · Omarchy 4.0.4 · kernel 7.2.5-4 · Limine · LUKS+btrfs:

- **Single-ESP layout.** `/boot` → vfat → `/dev/nvme0n1p1`. There is no
  `/boot/efi`, and no second ESP — Omarchy created its own 2 GiB one on the
  wiped disk. This is the degenerate case for the PR's selection rule.
- **Firmware intact and healthy.** `EFI/APPLE/EMBEDDEDOS` holds all three files
  (`combined.memboot` 30,725,398 bytes, `FDRData`, `version.plist`); the T1 is
  at `05ac:8600`; the webcam enumerates; the Touch Bar renders.
- **This is a control case, not a recovery case.** No wiped-ESP reproduction is
  offered, deliberately — wiping a working T1 to test a prevention patch is a
  bad trade.

## Honest limits stated in the comment

- No live-ISO run. The comment does not claim one.
- The one thing that cannot be checked from a running system — whether
  `esp_mount` still names the *newly created* ESP during
  `_install_limine_omarchy` rather than the live ISO's own mount — is raised as
  the thing worth asserting, not asserted as a defect.
- Corrections to my own earlier assumptions are included rather than hidden.

## Also proposed in the comment

- Treat `EFI/APPLE/EMBEDDEDOS/combined.memboot` as the presence test rather than
  the directory: the firmware is a matched trio, and a partial folder is
  distinguishable from a machine that never had one.
- A documentation note that "back it up" should mean off-disk. On a single-disk
  Mac, `$HOME` and the ESP are two partitions of the *same* device, so a copy
  there survives a wiped partition and nothing else. Verified on this machine
  with `findmnt` on both paths — this repo's own earlier wording got it wrong.

---

## The comment text

> Posting because I can answer one of your open questions with evidence rather
> than opinion, and because the coverage here is currently 14,2-shaped.
>
> **Context: an intact-firmware MacBookPro14,3.** Not a recovery case — the T1 is
> up as `05ac:8600`, `EFI/APPLE/EMBEDDEDOS` holds all three files
> (`combined.memboot` 30,725,398 bytes, `FDRData`, `version.plist`), the webcam
> enumerates, and the Touch Bar renders. So this machine is a control case for
> your restore step rather than a wiped-ESP reproduction. I am not going to wipe a
> working T1 to test a prevention patch; what I can offer is the layout your
> `esp_select` logic has to get right, which is the failure mode you already hit
> once.
>
> **Open question 1: the ESP handle at restore time**
>
> Your note asks whether `ctx.target / esp_mount.lstrip("/")` is the right handle
> at that point in the phase. On this layout it is, and the shape is worth stating
> explicitly because it is the single-ESP case:
>
> ```
> /boot  ->  vfat  ->  /dev/nvme0n1p1     (2 GiB, the installed system's ESP)
> /boot/EFI/APPLE/EMBEDDEDOS/             (the folder your hooks preserve)
> ```
>
> `/boot` is the mountpoint inside the *installed* system, and
> `findmnt -no SOURCE,FSTYPE /boot` resolves it to `nvme0n1p1` on the real device.
> There is no separate `/boot/efi` here, and no second ESP — Omarchy created its
> own 2 GiB one on the wiped disk. That is exactly the degenerate case where your
> "the folder is the only signal" rule has nothing to disambiguate, which is why I
> think it is the right rule for a fleet-wide installer: no DMI allowlist, and on
> a single-ESP disk no choice to make.
>
> The one thing that cannot be unit-tested against a fixture is whether
> `esp_mount` still names the newly created ESP at that point in the phase rather
> than the live ISO's own mount — i.e. that the value is the one
> `_install_limine_efi` resolves, not a path cached in `prepare_live`. That is the
> only way I can see this writing to the wrong place on a single-ESP disk, so it
> is the assertion worth adding if the phase can expose it.
>
> **On "aborting would be worse than the bug"**
>
> Agreed, and worth saying why from the outside: this failure is silent. A machine
> that boots with a dead Touch Bar looks normal — the install succeeds, the host
> boots, `lsmod` and `dmesg` are clean. The only tell is `05ac:1281` instead of
> `05ac:8600`, or the absence of `/dev/video*`. Trading a silent peripheral loss
> for a dead machine would be the wrong severity, so every-failure-path-logs-and-
> returns is right.
>
> **One edge worth considering**
>
> Since the folder is the only trigger, an `EFI/APPLE/EMBEDDEDOS` that is present
> but *incomplete* currently counts as present. That set is not loadable — the
> firmware is a matched trio, and a chip given `combined.memboot` without its
> `FDRData` still falls back to recovery. Treating "has
> `EFI/APPLE/EMBEDDEDOS/combined.memboot`" as the presence test would let a
> machine carrying a partial folder be diagnosed separately from one that never
> had a folder at all. Not a blocker; the copy is harmless either way.
>
> **One correction to the "back it up" advice**
>
> Worth adding to the docs somewhere, because it is easy to state loosely: an
> off-disk copy is the thing to take, and a copy left in `$HOME` is not it. On a
> single-disk Mac — the common case, and the one this PR targets — `$HOME` and the
> ESP are two partitions of the *same* device. A copy there survives a wiped
> partition and nothing else, and it is the same device an installer is about to
> repartition. I had this wrong in my own notes until I checked `findmnt` on both
> paths, so I suspect other people do too.
