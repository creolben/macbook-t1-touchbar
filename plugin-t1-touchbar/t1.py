"""T1 (iBridge) Touch Bar support for Linux MacBook Pros.

Everything here is scoped to a 2016-2017 T1 MacBook Pro (MacBookPro13,x /
MacBookPro14,x). On a T2 machine every operation here is a no-op with an
explanation, because the answer is a different driver entirely.

Two facts drive the design:

1. The T1 has no firmware in ROM. macOS writes
   ``EFI/APPLE/EMBEDDEDOS/combined.memboot`` to the ESP and Apple's boot
   firmware loads it at power-on. A whole-disk Linux install erases it and the
   chip falls back to recovery mode (``05ac:1281``), where no driver can help.
   So every entry point checks the firmware state first and refuses to pretend
   a driver problem exists when the real problem is an erased partition.

2. The Touch Bar interface is *not* reclaimed automatically. The iBridge
   exposes two USB HID interfaces and ``hid-sensor-hub`` keeps the one carrying
   the Touch Bar (identifiable by its 634-byte report descriptor). The modules
   load, bind, and look correct while the strip stays dark. The only reliable
   evidence of success is the presence of the ``fnmode`` sysfs attribute, which
   ``appletb_probe()`` creates. We require that attribute rather than trusting
   ``lsmod``.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

DRIVER_PKG = "macbook12-spi-driver-dkms"
UPSTREAM_REPO = "https://github.com/roadrunner2/macbook12-spi-driver"
UPSTREAM_BRANCH = "touchbar-driver-hid-driver"

IBRIDGE_OK = "8600"        # production iBridge, firmware loaded
IBRIDGE_RECOVERY = "1281"  # T1 in recovery mode, firmware missing
TB_RDESC_SIZE = 634        # the Touch Bar interface, per appleib_report_fixup()

# Models this plugin is for. T2 models are the 2018+ machines.
T1_MODELS = re.compile(r"^MacBookPro1[34],[123]$")
T2_MODELS = re.compile(r"^MacBookPro1[5-9],|^MacBookPro2[0-9],")

PLUGIN_ROOT = Path(__file__).resolve().parent
PATCHER = PLUGIN_ROOT / "scripts" / "t1-patch-source.py"
HANDOVER = PLUGIN_ROOT / "scripts" / "apple-touchbar-handover"
SERVICE = PLUGIN_ROOT / "scripts" / "apple-touchbar.service"

MAKEFILE = """\
obj-m += apple-ibridge.o
obj-m += apple-ib-tb.o
obj-m += apple-ib-als.o
KDIR := /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)
all:
\t$(MAKE) -C $(KDIR) M=$(PWD) modules
clean:
\t$(MAKE) -C $(KDIR) M=$(PWD) clean
"""

# applespi is deliberately never built: the in-tree driver already handles the
# keyboard and touchpad, and an out-of-tree copy would shadow it.
MODULES = ("apple-ibridge", "apple-ib-tb", "apple-ib-als")


# --------------------------------------------------------------------- helpers

def _read(path: str, default: str = "") -> str:
    try:
        return Path(path).read_text().strip()
    except OSError:
        return default


def product_name() -> str:
    return _read("/sys/class/dmi/id/product_name") or "unknown"


def model_class() -> str:
    """Return 't1', 't2', or 'other'."""
    p = product_name()
    if T1_MODELS.match(p):
        return "t1"
    if T2_MODELS.match(p):
        return "t2"
    return "other"


def ibridge_state() -> dict[str, Any]:
    """Find the Apple USB device and report its product id."""
    out: dict[str, Any] = {"product_id": None, "name": "", "device": None}
    base = Path("/sys/bus/usb/devices")
    if not base.is_dir():
        return out
    for d in base.iterdir():
        if _read(str(d / "idVendor")) != "05ac":
            continue
        out["product_id"] = _read(str(d / "idProduct")) or None
        out["name"] = _read(str(d / "product"))
        out["device"] = d.name
    return out


def hid_interfaces() -> list[dict[str, Any]]:
    """The iBridge HID interfaces and which driver owns each."""
    found = []
    for d in sorted(Path("/sys/bus/hid/devices").glob("0003:05AC:8600.*")):
        try:
            size = len((d / "report_descriptor").read_bytes())
        except OSError:
            size = 0
        drv = ""
        link = d / "driver"
        if link.exists():
            try:
                drv = Path(os.path.realpath(link)).name
            except OSError:
                drv = ""
        found.append(
            {
                "device": d.name,
                "report_descriptor_size": size,
                "driver": drv or None,
                # The Touch Bar interface is the 634-byte one, and only that one.
                "is_touchbar_interface": size == TB_RDESC_SIZE,
                "touchbar_ready": (d / "fnmode").exists(),
            }
        )
    return found


def touchbar_attr_path() -> Path | None:
    """The interface carrying the Touch Bar driver's sysfs controls.

    Note this is the 83-byte interface, NOT the 634-byte one. The driver's
    fnmode/idle_timeout/dim_timeout attributes land on the boot-keyboard
    interface, so looking for them on the 634-byte one always misses. Search
    all iBridge HID devices.
    """
    for d in sorted(Path("/sys/bus/hid/devices").glob("0003:05AC:8600.*")):
        if (d / "fnmode").exists():
            return d
    return None


def firmware_files() -> dict[str, Any]:
    """The T1 firmware macOS writes to the internal ESP.

    The ESP is typically mode 0700 root-owned, so an unprivileged probe cannot
    read it. That is not an error condition — report it as "unreadable" so the
    caller knows to check with privilege rather than concluding the firmware is
    missing.
    """
    d = Path("/boot/EFI/APPLE/EMBEDDEDOS")
    out: dict[str, Any] = {"dir": str(d), "present": None, "readable": True, "files": {}}
    try:
        out["present"] = d.is_dir()
    except PermissionError:
        out["present"] = None
        out["readable"] = False
        return out
    except OSError as exc:
        out["present"] = None
        out["readable"] = False
        out["error"] = str(exc)
        return out

    if out["present"]:
        for name in ("combined.memboot", "FDRData", "version.plist"):
            try:
                out["files"][name] = (d / name).stat().st_size
            except OSError:
                out["files"][name] = None
    return out


def esp_mount() -> dict[str, Any]:
    """Where the EFI System Partition is mounted.

    Do not assume /boot/efi. Plenty of installs (including Omarchy's) put the
    ESP at /boot, and a script that hardcodes the wrong path silently does
    nothing.
    """
    out: dict[str, Any] = {"path": None, "source": None}
    if not shutil.which("findmnt"):
        # Fall back to a plain check when findmnt is unavailable.
        for cand in ("/boot/efi", "/boot", "/efi"):
            if Path(cand).is_dir():
                out["path"] = cand
                break
        return out
    for cand in ("/boot/efi", "/boot", "/efi"):
        r = _run(["findmnt", "-no", "FSTYPE", cand], timeout=30)
        if r.returncode == 0 and "vfat" in (r.stdout or "").lower():
            s = _run(["findmnt", "-no", "SOURCE", cand], timeout=30)
            out["path"] = cand
            out["source"] = (s.stdout or "").strip() or None
            break
    return out


def firmware_backups() -> list[dict[str, Any]]:
    """Any local T1 firmware archives, with integrity state."""
    found = []
    roots = []
    for home in {str(Path.home()), os.path.expanduser("~")}:
        roots.append(Path(home) / "t1-firmware-backup")
    roots.append(Path("/var/lib/t1-touchbar"))

    for d in roots:
        if not d.is_dir():
            continue
        entry: dict[str, Any] = {"path": str(d), "complete": False, "verified": None}
        sizes = {}
        for name in ("combined.memboot", "FDRData", "version.plist"):
            try:
                sizes[name] = (d / name).stat().st_size
            except OSError:
                sizes[name] = None
        entry["files"] = sizes
        entry["complete"] = all(v for v in sizes.values())
        # Verify against the recorded checksums when present.
        sums = d / "SHA256SUMS.txt"
        if sums.is_file() and shutil.which("sha256sum"):
            r = _run(["sha256sum", "-c", "SHA256SUMS.txt"], cwd=d, timeout=180)
            entry["verified"] = r.returncode == 0
        found.append(entry)
    return found


def backlight() -> dict[str, Any]:
    d = Path("/sys/class/leds/spi::kbd_backlight")
    return {
        "device": str(d),
        "present": d.is_dir(),
        "brightness": _read(str(d / "brightness")) or None,
        "max_brightness": _read(str(d / "max_brightness")) or None,
    }


def webcam() -> list[str]:
    return sorted(p.name for p in Path("/dev").glob("video*"))


def root_mode() -> str:
    """How privileged work can be run, if at all.

    An agent-run process has no TTY, so an interactive password prompt can never
    be answered. Report which mechanism is actually usable instead of starting
    something that would hang waiting for input.

    ``sudo -n`` is used purely as a capability *probe*: it is non-interactive,
    so it succeeds only if the credential is already valid and fails cleanly
    otherwise. Nothing here elevates anything.
    """
    if os.geteuid() == 0:
        return "already_root"
    try:
        r = subprocess.run(["sudo", "-n", "true"], capture_output=True, timeout=10)
        if r.returncode == 0:
            return "escalation_available"
    except (OSError, subprocess.SubprocessError):
        pass
    if shutil.which("pkexec"):
        return "pkexec"
    return "none"


def _run(cmd: list[str], cwd: Path | None = None, timeout: int = 900):
    return subprocess.run(
        cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout
    )


def run_privileged(cmd: list[str], **kw) -> tuple[bool, str]:
    """Run a command with privilege, or explain how the user must run it.

    Returns (ok, output). When privilege is unavailable, ok is False and the
    output begins with "NOPRIV:" followed by the exact command the user should
    run in their own terminal — rather than hanging on a password prompt that a
    non-interactive process can never answer.
    """
    mode = root_mode()
    if mode == "already_root":
        r = _run(cmd, **kw)
    elif mode == "escalation_available":
        r = _run(["sudo", "-n", *cmd], **kw)
    elif mode == "pkexec":
        r = _run(["pkexec", *cmd], **kw)
    else:
        quoted = " ".join(shlex_quote(c) for c in cmd)
        return False, (
            "NOPRIV: privileged work is not available to this process "
            "(no TTY for a password prompt).\n"
            "Run this yourself in a terminal:\n\n    sudo " + quoted
        )
    out = (r.stdout or "") + (r.stderr or "")
    return r.returncode == 0, out.strip()


def shlex_quote(s: str) -> str:
    import shlex

    return shlex.quote(s)


# ---------------------------------------------------------------- source + build

def find_source() -> Path | None:
    """Locate the driver source, preferring what the distro already installed."""
    candidates = []
    for pat in (f"/usr/src/{DRIVER_PKG}-*", "/usr/src/macbook12-spi-driver-*"):
        candidates.extend(sorted(Path("/").glob(pat.lstrip("/"))))
    for d in candidates:
        if (d / "apple-ibridge.c").is_file():
            return d
    return None


def obtain_source() -> tuple[Path | None, str]:
    """Return (source_dir, note). Installs the distro package or clones upstream."""
    src = find_source()
    if src:
        return src, f"using distro source at {src}"

    note = f"{DRIVER_PKG} not present; installing it for its source tree"
    for cmd in (["omarchy-pkg-add", DRIVER_PKG], ["pacman", "-S", "--needed", "--noconfirm", DRIVER_PKG]):
        if not shutil.which(cmd[0]):
            continue
        ok, out = run_privileged(cmd)
        if not ok and out.startswith("NOPRIV:"):
            return None, note + "\n" + out
        break

    src = find_source()
    if src:
        return src, note + f" -> {src}"

    if not shutil.which("git"):
        return None, "no local source and git is unavailable"

    dst = Path(tempfile.gettempdir()) / "t1-touchbar-src"
    if dst.exists():
        shutil.rmtree(dst, ignore_errors=True)
    r = _run(
        ["git", "clone", "--depth", "1", "-b", UPSTREAM_BRANCH, UPSTREAM_REPO, str(dst)],
        timeout=300,
    )
    if r.returncode != 0 or not (dst / "apple-ibridge.c").is_file():
        return None, f"upstream clone failed: {(r.stderr or '').strip()[:400]}"
    return dst, f"cloned upstream {UPSTREAM_BRANCH}"


def patch_source(src: Path) -> tuple[bool, str]:
    """Apply the kernel-API fixes. Idempotent; safe to re-run."""
    if not PATCHER.is_file():
        return False, f"patcher missing at {PATCHER}"
    r = _run([sys.executable, str(PATCHER), str(src)], timeout=120)
    out = (r.stdout or "") + (r.stderr or "")
    return r.returncode == 0, out.strip()


def build_modules(workdir: Path | None = None) -> dict[str, Any]:
    """Patch and compile the three modules. Needs no privilege."""
    result: dict[str, Any] = {"ok": False, "steps": []}

    src, note = obtain_source()
    result["steps"].append(note)
    if src is None:
        result["error"] = "could not obtain driver source"
        return result

    kver = _read("/proc/sys/kernel/osrelease") or os.uname().release
    build_dir = Path(f"/lib/modules/{kver}/build")
    if not build_dir.is_dir():
        result["error"] = (
            f"no kernel build tree at {build_dir}. Install matching kernel "
            f"headers (e.g. linux-omarchy-headers) and retry."
        )
        return result
    result["kernel"] = kver

    work = workdir or Path(tempfile.mkdtemp(prefix="t1-touchbar-build-"))
    work = Path(work)
    work.mkdir(parents=True, exist_ok=True)

    for name in ("apple-ibridge.c", "apple-ibridge.h", "apple-ib-tb.c", "apple-ib-als.c"):
        shutil.copy2(src / name, work / name)
    (work / "Makefile").write_text(MAKEFILE)

    ok, out = patch_source(work)
    result["steps"].append(out)
    result["patched"] = ok
    if not ok:
        result["error"] = (
            "patching failed — the driver source no longer matches what the "
            "patcher expects. See the bundled skill, 'When the kernel API "
            "moves again'. Nothing was installed."
        )
        return result

    r = _run(["make"], cwd=work, timeout=900)
    if r.returncode != 0:
        tail = "\n".join((r.stdout or "").splitlines()[-25:] + (r.stderr or "").splitlines()[-25:])
        result["error"] = f"compile failed:\n{tail}"
        return result

    kos = {m: str(work / f"{m}.ko") for m in MODULES if (work / f"{m}.ko").is_file()}
    if len(kos) != len(MODULES):
        result["error"] = f"expected {len(MODULES)} modules, built {list(kos)}"
        return result

    result.update(
        ok=True,
        workdir=str(work),
        modules=kos,
        steps=result["steps"],
    )
    return result


# ---------------------------------------------------------------------- actions

def _module_loaded(name: str) -> bool:
    """Check /proc/modules for a module.

    The kernel normalises hyphens to underscores in module names
    (``apple-ib-tb`` appears as ``apple_ib_tb``), so match on the normalised
    form rather than the file name.
    """
    norm = name.replace("-", "_")
    try:
        text = Path("/proc/modules").read_text()
    except OSError:
        return False
    return bool(re.search(rf"^{re.escape(norm)}\s", text, re.M))


def _module_on_disk(name: str) -> dict[str, Any]:
    """Where a module lives, if modinfo can resolve it."""
    if not shutil.which("modinfo"):
        return {"present": None, "path": None}
    r = _run(["modinfo", "-F", "filename", name], timeout=30)
    path = (r.stdout or "").strip()
    return {"present": r.returncode == 0 and bool(path), "path": path or None}


def _read_dkms() -> dict[str, Any]:
    """DKMS registration state for this driver and the distro one.

    Two packages owning the same three module names is a real hazard: whichever
    builds last wins, unpredictably across kernel upgrades. Report both so a
    conflict is visible rather than surfacing as a mysteriously dark strip
    after an update.
    """
    out: dict[str, Any] = {"ours": [], "distro": [], "conflict": False}
    if not shutil.which("dkms"):
        return out
    r = _run(["dkms", "status"], timeout=60)
    for line in (r.stdout or "").splitlines():
        line = line.strip()
        if not line or ":" not in line:
            continue
        # Line shapes vary with how much dkms knows:
        #   name/ver: state
        #   name/ver, kernel, arch: state
        # Split the trailing state off first, then the comma-separated left side.
        left, state = line.rsplit(":", 1)
        fields = [f.strip() for f in left.split(",")]
        namever = fields[0]
        if "/" not in namever:
            continue
        name, _, ver = namever.partition("/")
        entry = {
            "version": ver,
            "kernel": fields[1] if len(fields) > 1 else "",
            "arch": fields[2] if len(fields) > 2 else "",
            "state": state.strip(),
        }
        if name == "appleibridge":
            out["ours"].append(entry)
        elif name.startswith("macbook12-spi-driver"):
            out["distro"].append(entry)
    # A distro registration that is merely 'added' still claims the module
    # names and will rebuild on the next kernel.
    out["conflict"] = bool(out["ours"]) and any(
        e["state"].startswith("added") for e in out["distro"]
    )
    return out


def do_backup_firmware(dest: str | None = None) -> dict[str, Any]:
    """Archive the T1 firmware from the ESP. Needs privilege (ESP is root-only)."""
    script = PLUGIN_ROOT / "scripts" / "backup-t1-firmware.sh"
    if not script.is_file():
        return {"ok": False, "error": f"backup script missing at {script}"}

    esp = esp_mount()
    if not esp["path"]:
        return {
            "ok": False,
            "error": "no vfat ESP mounted at /boot/efi, /boot or /efi — nothing to archive",
        }

    fw = firmware_files()
    if fw.get("present") is False:
        return {
            "ok": False,
            "error": (
                "EFI/APPLE/EMBEDDEDOS does not exist, so there is nothing to "
                "back up — the firmware is already absent. The T1 is almost "
                "certainly at 05ac:1281. It must be re-provisioned by booting "
                "macOS once with internet; this script archives firmware that "
                "exists and cannot regenerate it."
            ),
        }

    cmd = [str(script)]
    if dest:
        cmd.append(dest)
    ok, out = run_privileged(cmd, timeout=600)
    return {"ok": ok, "output": out, "privilege": root_mode()}


def do_restore_firmware(backup_dir: str | None = None, force: bool = False) -> dict[str, Any]:
    """Copy a firmware archive back to the ESP. Refuses unless the T1 needs it."""
    script = PLUGIN_ROOT / "scripts" / "restore-t1-firmware.sh"
    if not script.is_file():
        return {"ok": False, "error": f"restore script missing at {script}"}

    cmd = [str(script)]
    if backup_dir:
        cmd.append(backup_dir)

    env_prefix_warning = None
    if force:
        env_prefix_warning = "FORCE=1 set; the healthy-T1 guard was bypassed"

    mode = root_mode()
    if mode == "already_root":
        r = _run(cmd, timeout=600)
        out, ok = (r.stdout or "") + (r.stderr or ""), r.returncode == 0
    elif mode in ("escalation_available", "pkexec"):
        runner = ["sudo", "-n"] if mode == "escalation_available" else ["pkexec"]
        r = _run([*runner, *cmd], timeout=600)
        out, ok = (r.stdout or "") + (r.stderr or ""), r.returncode == 0
    else:
        quoted = " ".join(shlex_quote(c) for c in cmd)
        return {
            "ok": False,
            "error": (
                "NOPRIV: privileged work is not available to this process. Run "
                f"this yourself in a terminal:\n\n    sudo {quoted}"
            ),
        }
    result = {"ok": ok, "output": out.strip()}
    if env_prefix_warning:
        result["warning"] = env_prefix_warning
    return result


def _physical_disk(dev: str) -> str:
    """Resolve a device to the physical disk backing it.

    `lsblk -no PKNAME` stops at the first layer, which is not enough here: this
    machine's root is /dev/mapper/root on top of a LUKS partition on the NVMe
    device, and PKNAME on the mapper returns nothing at all. Walk up with
    `lsblk -s` (dependencies, innermost last) and take the last real disk.
    """
    if not shutil.which("lsblk"):
        return Path(dev).name
    r = _run(["lsblk", "-sno", "NAME,TYPE", dev], timeout=30)
    lines = [ln.split() for ln in (r.stdout or "").splitlines() if ln.split()]
    for name, typ in reversed(lines):          # innermost/last is the parent disk
        if typ == "disk":
            # lsblk tree output prefixes the name with box-drawing characters
            # when the device has children; strip them for a clean comparison.
            return name.lstrip("─└├│ ")
    # Fall back to the topmost name if no TYPE=disk line was found.
    return lines[-1][0].lstrip("─└├│ ") if lines else Path(dev).name


def _backup_shares_disk_with_esp(backups: list[dict[str, Any]]) -> bool:
    """True when a backup and the ESP resolve to the same physical disk.

    A copy in $HOME is a copy on a different *partition* of the same device on
    a single-disk Mac, which is the common case. That survives a wiped
    partition and nothing else — so it is worth saying plainly rather than
    letting "backed up" read as "safe".
    """
    esp = esp_mount().get("source")
    if not esp:
        return False

    esp_disk = _physical_disk(esp)
    if not esp_disk:
        return False

    for b in backups:
        path = b.get("path")
        if not path:
            continue
        r = _run(["findmnt", "-no", "SOURCE", "-T", path], timeout=30)
        # SOURCE can carry a btrfs subvolume suffix, e.g.
        # "/dev/mapper/root[/@home]" — strip it before resolving.
        src = (r.stdout or "").strip().split("[")[0]
        if src and _physical_disk(src) == esp_disk:
            return True
    return False


def legacy_stack_note() -> dict[str, Any]:
    """Whether the pre-t1bridge T1 stack is installed here.

    This matters beyond our own operation: t1bridge / t1-revive is the
    maintained T1 stack (Touch Bar, camera, and Touch ID), and its preflight
    refuses to run while the older out-of-tree drivers are present. They bind
    the T1's HID interfaces and their udev rules pin its USB configuration, and
    a run started with them loaded has been reported to wedge partway through
    with `result=error code=5`.

    So we do not just report our own state — we report that we are the thing
    standing in the way, and how to stand down.
    """
    out: dict[str, Any] = {
        "installed": False,
        "modules_loaded": [],
        "dkms": _read_dkms(),
        "conflicts_with": "t1bridge / t1-revive",
        "stand_down": [
            "sudo systemctl disable --now apple-touchbar.service",
            "sudo rm -f /etc/modules-load.d/apple-touchbar.conf",
            "sudo rmmod apple_ib_tb apple_ib_als apple_ibridge 2>/dev/null || true",
            "sudo dkms remove -m appleibridge -v 0.1 --all",
            "sudo dkms remove -m macbook12-spi-driver -v 0+git.315 --all",
        ],
    }
    for m in MODULES:
        if _module_loaded(m):
            out["modules_loaded"].append(m)
    out["installed"] = bool(out["modules_loaded"]) or bool(out["dkms"].get("ours"))
    return out


def status_report() -> dict[str, Any]:
    """Read-only diagnosis. Needs no privilege, changes nothing."""
    cls = model_class()
    t1 = ibridge_state()
    hid = hid_interfaces()
    tb = touchbar_attr_path()
    fw = firmware_files()

    loaded = {m: _module_loaded(m) for m in MODULES}
    on_disk = {m: _module_on_disk(m) for m in MODULES}
    dkms = _read_dkms()
    backups = firmware_backups()
    legacy = legacy_stack_note()
    tb_iface = next((h for h in hid if h["is_touchbar_interface"]), None)

    if cls == "t2":
        verdict = (
            "This is a T2 machine. This plugin does not apply — T2 uses the "
            "mainline hid-appletb-kbd / hid-appletb-bl drivers, and the T1 "
            "modules will never bind here. Do not install linux-t2 on a T1 or "
            "these modules on a T2."
        )
    elif cls == "other":
        verdict = (
            f"{product_name()} is not a T1 MacBook Pro. This plugin targets "
            "MacBookPro13,x and MacBookPro14,x only."
        )
    elif t1["product_id"] == IBRIDGE_RECOVERY:
        verdict = (
            "T1 in RECOVERY MODE (05ac:1281) — the firmware is absent from the "
            "ESP, not merely unbound, so no driver can bring up the Touch Bar. "
            "Install macOS to a partition, boot it once WITH INTERNET so "
            "EmbeddedOSInstallService provisions the chip, then re-check. Back "
            "up /boot/EFI/APPLE/EMBEDDEDOS/ afterwards: the files are bound to "
            "this machine's ECID and are irreplaceable."
        )
    elif t1["product_id"] != IBRIDGE_OK:
        verdict = "No iBridge USB device found; the T1 may be powered down or absent."
    elif tb is not None:
        verdict = (
            "Touch Bar is UP. The interface handover is in place and "
            "appletb_probe() succeeded."
        )
        if dkms.get("conflict"):
            verdict += (
                " NOTE: macbook12-spi-driver is still registered with DKMS, so "
                "both packages will try to build the same three modules on the "
                "next kernel update and whichever finishes last wins. Disable "
                "the distro registration to make this deterministic."
            )
        if not backups:
            verdict += (
                " NO FIRMWARE BACKUP FOUND. The T1 firmware on the ESP is "
                "personalised to this machine's ECID, cannot be downloaded, and "
                "no other Mac's copy will work. If the ESP is ever wiped, only a "
                "macOS reinstall regenerates it. Archive it now with "
                "t1_touchbar_backup_firmware."
            )
        elif not any(b.get("complete") for b in backups):
            verdict += (
                " A firmware backup directory exists but is INCOMPLETE. Re-run "
                "t1_touchbar_backup_firmware to rebuild it."
            )
        elif any(b.get("verified") is False for b in backups):
            verdict += (
                " A firmware backup FAILED its checksum verification — treat it "
                "as corrupt and take a fresh one."
            )
        if legacy.get("installed"):
            verdict += (
                " HEADS UP: this is the pre-t1bridge driver stack. t1bridge is "
                "the maintained alternative and adds Touch ID, but its preflight "
                "refuses to run while these modules are present. Disable this "
                "stack before running t1-revive; see legacy_stack.stand_down."
            )
        if backups and _backup_shares_disk_with_esp(backups):
            verdict += (
                " NOTE: the firmware backup is on the SAME physical disk as the "
                "ESP, so it survives a wiped partition but not disk failure, "
                "repartitioning, or losing the machine. Copy it to separate "
                "hardware."
            )
    elif tb_iface and tb_iface["driver"] != "apple-ibridge-hid":
        verdict = (
            f"The {TB_RDESC_SIZE}-byte Touch Bar interface is held by "
            f"'{tb_iface['driver']}' instead of apple-ibridge-hid, so "
            "appletb_probe() never ran. Firmware is fine; this is the handover "
            "step. Run t1_touchbar_install (or the handover alone) to fix it."
        )
    elif not loaded["apple-ibridge"]:
        verdict = (
            "Firmware is fine but the T1 modules are not loaded. Build and "
            "install them, then the handover runs at boot."
        )
    else:
        verdict = (
            "Modules loaded but the Touch Bar interface is not ready; re-run "
            "after the handover script reports success."
        )

    return {
        "model": product_name(),
        "model_class": cls,
        "verdict": verdict,
        "ibridge": t1,
        "firmware": fw,
        "esp": esp_mount(),
        "firmware_backups": backups,
        "legacy_stack": legacy,
        "hid_interfaces": hid,
        "touchbar_controls_present": tb is not None,
        "touchbar_path": str(tb) if tb else None,
        "fnmode": _read(str(tb / "fnmode")) if tb else None,
        "modules_loaded": loaded,
        "modules_on_disk": on_disk,
        "dkms": dkms,
        "backlight": backlight(),
        "webcam": webcam(),
        "privilege": root_mode(),
    }


def do_install(confirm: bool) -> dict[str, Any]:
    """Build, register with DKMS, install the handover, rebuild the initramfs."""
    if model_class() != "t1":
        return {
            "ok": False,
            "error": status_report()["verdict"],
        }
    if ibridge_state()["product_id"] != IBRIDGE_OK:
        return {"ok": False, "error": status_report()["verdict"]}
    if not confirm:
        return {
            "ok": False,
            "error": (
                "Refusing to install without confirm=true. This registers a "
                "DKMS module, writes a systemd unit, and rebuilds the "
                "initramfs."
            ),
        }

    built = build_modules()
    if not built.get("ok"):
        return built

    work = Path(built["workdir"])
    version = "0.1"
    pkg = "appleibridge"
    srcdir = Path(f"/usr/src/{pkg}-{version}")

    steps: list[str] = []
    mode = root_mode()
    if mode == "none":
        return {
            "ok": False,
            "error": f"NOPRIV: install the built modules yourself:\n\n"
                     f"    sudo cp {' '.join(built['modules'].values())} /usr/src/ && "
                     f"sudo {work}/install-t1-touchbar.sh",
            "build": built,
        }

    # Assemble the DKMS tree and the installer payload.
    payload = Path(tempfile.mkdtemp(prefix="t1-payload-"))
    dkms_dir = payload / f"{pkg}-{version}"
    dkms_dir.mkdir(parents=True)
    for name in ("apple-ibridge.c", "apple-ibridge.h", "apple-ib-tb.c", "apple-ib-als.c"):
        shutil.copy2(work / name, dkms_dir / name)
    (dkms_dir / "dkms.conf").write_text(
        f'PACKAGE_NAME="{pkg}"\n'
        f'PACKAGE_VERSION="{version}"\n'
        f'BUILT_MODULE_NAME[0]="apple-ibridge"\n'
        f'BUILT_MODULE_NAME[1]="apple-ib-tb"\n'
        f'BUILT_MODULE_NAME[2]="apple-ib-als"\n'
        f'DEST_MODULE_LOCATION[0]="/kernel/drivers/misc"\n'
        f'DEST_MODULE_LOCATION[1]="/kernel/drivers/misc"\n'
        f'DEST_MODULE_LOCATION[2]="/kernel/drivers/misc"\n'
        f'AUTOINSTALL="yes"\n'
        f'MAKE[0]="make KDIR=/lib/modules/$kernelver/build"\n'
        f'CLEAN="make clean"\n'
    )
    (dkms_dir / "Makefile").write_text(MAKEFILE)

    install_sh = payload / "install.sh"
    install_sh.write_text(_INSTALL_SCRIPT)
    install_sh.chmod(0o755)
    shutil.copy2(HANDOVER, payload / "apple-touchbar-handover")
    shutil.copy2(SERVICE, payload / "apple-touchbar.service")

    ok, out = run_privileged([str(install_sh), str(payload)])
    steps.append(out)
    if not ok:
        return {"ok": False, "error": out, "build": built, "steps": steps}

    ok2, out2 = run_privileged(["limine-mkinitcpio"]) if shutil.which("limine-mkinitcpio") else (True, "no limine-mkinitcpio; skipped")
    steps.append(out2)

    return {
        "ok": ok and ok2,
        "steps": steps,
        "build": built,
        "next": "Reboot, then run t1_touchbar_status to confirm.",
    }


_INSTALL_SCRIPT = """\
#!/usr/bin/env bash
# Privileged install step. Assumes the driver source has already been patched
# and compile-verified by the plugin; this only wires it into the system.
set -euo pipefail
PAYLOAD="$1"
SRCDIR=/usr/src/appleibridge-0.1

rm -rf "$SRCDIR"
mkdir -p "$SRCDIR"
cp "$PAYLOAD/appleibridge-0.1/"*.c "$PAYLOAD/appleibridge-0.1/"*.h "$SRCDIR"/ 2>/dev/null || true
cp "$PAYLOAD/appleibridge-0.1/dkms.conf" "$PAYLOAD/appleibridge-0.1/Makefile" "$SRCDIR"/

dkms remove -m appleibridge -v 0.1 --all >/dev/null 2>&1 || true
dkms add     -m appleibridge -v 0.1
dkms build   -m appleibridge -v 0.1
dkms install -m appleibridge -v 0.1 --force

# The distro package ships the same three module names. Two owners means
# whichever builds last wins, unpredictably across kernel updates. Keep the
# package (it is the source of this driver) but stop it registering.
if dkms status 2>/dev/null | grep -q '^macbook12-spi-driver/'; then
  for v in $(dkms status | sed -n 's#^macbook12-spi-driver/\\([^,]*\\),.*#\\1#p'); do
    dkms remove -m macbook12-spi-driver -v "$v" --all >/dev/null 2>&1 || true
  done
  for f in /usr/src/macbook12-spi-driver-*/dkms.conf; do
    [ -f "$f" ] || continue
    cp -n "$f" "$f.orig" 2>/dev/null || true
    sed -i 's/^AUTOINSTALL="yes"/AUTOINSTALL="no"/' "$f"
  done
fi

cat > /etc/modules-load.d/apple-touchbar.conf <<'EOF'
apple-ibridge
apple-ib-tb
EOF

install -Dm755 "$PAYLOAD/apple-touchbar-handover" /usr/local/sbin/apple-touchbar-handover
install -Dm644 "$PAYLOAD/apple-touchbar.service" /etc/systemd/system/apple-touchbar.service

mkdir -p /etc/modprobe.d
if [ ! -f /etc/modprobe.d/apple-ib-tb.conf ]; then
  printf '%s\\n' \\
    '# fnmode=1: Esc + media/brightness keys by default, Fn gives F1-F12 (Mac default).' \\
    '# fnmode=2 for the opposite.' \\
    'options apple-ib-tb fnmode=1' > /etc/modprobe.d/apple-ib-tb.conf
fi

systemctl daemon-reload
systemctl enable apple-touchbar.service

# apple-ib-als needs industrialio-triggered-buffer loaded first; without it the
# module fails on an unknown symbol. It only serves the ambient light sensor,
# which hid-sensor-als already covers, so a failure here is harmless.
modprobe industrialio-triggered-buffer 2>/dev/null || true
echo "install step complete"
"""
