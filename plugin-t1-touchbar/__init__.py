"""T1 (iBridge) Touch Bar plugin — entry point.

Registers three tools. ``t1_touchbar_status`` is read-only and safe to call
freely; ``t1_touchbar_build`` compiles but changes nothing on the system;
``t1_touchbar_install`` is the only one with side effects and requires an
explicit ``confirm=true``.

A diagnostic skill ships with the plugin so the reasoning behind each check is
available without rediscovering it: ``skill_view('t1-touchbar:macbook-t1-touchbar-linux')``.

Scope is deliberately narrow. On a T2 MacBook or any non-T1 machine every tool
returns an explanation instead of acting, because the correct answer there is a
different driver — and installing these modules on a T2 is a real mistake.
"""

from __future__ import annotations

import json
from pathlib import Path

from . import t1

SKILL_DIR = Path(__file__).resolve().parent / "skills" / "macbook-t1-touchbar-linux"

_STATUS_SCHEMA = {
    "name": "t1_touchbar_status",
    "description": (
        "Diagnose the Apple T1 (iBridge) Touch Bar on this Linux MacBook Pro. "
        "Read-only and safe to call at any time. Reports the T1 USB state "
        "(05ac:8600 iBridge is healthy, 05ac:1281 means firmware is missing), "
        "whether the firmware files are on the ESP, which driver owns each "
        "iBridge HID interface, whether appletb_probe() succeeded, module load "
        "state, keyboard backlight, webcam, and what privilege escalation is "
        "actually available. Use this before any other T1 tool: on a T2 machine "
        "or a machine with missing firmware, the other tools correctly refuse "
        "to act and this explains why."
    ),
    "parameters": {"type": "object", "properties": {}, "required": []},
}

_BUILD_SCHEMA = {
    "name": "t1_touchbar_build",
    "description": (
        "Rebuild the T1 Touch Bar kernel modules (apple-ibridge, apple-ib-tb, "
        "apple-ib-als) against the running kernel. Obtains the driver source, "
        "applies the kernel-API fixes automatically, and compiles. Changes "
        "nothing on the system and needs no privilege — use it to check that a "
        "kernel upgrade has not broken the build before installing. Returns the "
        "path of the built modules."
    ),
    "parameters": {"type": "object", "properties": {}, "required": []},
}

_INSTALL_SCHEMA = {
    "name": "t1_touchbar_install",
    "description": (
        "Install the T1 Touch Bar driver stack: builds the modules, registers "
        "them with DKMS so they survive kernel upgrades, installs the boot-time "
        "HID interface handover (the step that makes the strip actually light "
        "up), and rebuilds the initramfs. Has real side effects and requires "
        "confirm=true. Refuses on any machine whose T1 is not enumerating as "
        "05ac:8600, because in that state the problem is missing firmware and "
        "no driver can help."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "confirm": {
                "type": "boolean",
                "description": (
                    "Must be true. Registers a DKMS module, writes a systemd "
                    "unit, and rebuilds the initramfs."
                ),
            }
        },
        "required": ["confirm"],
    },
}


_BACKUP_FW_SCHEMA = {
    "name": "t1_touchbar_backup_firmware",
    "description": (
        "Archive the Apple T1 (iBridge) firmware from the ESP to a local "
        "directory, verifying every file against the source and recording "
        "SHA256 checksums. This is the single most important thing to do on a "
        "T1 Mac: the firmware is personalised to this machine's ECID, cannot be "
        "downloaded, and no other Mac's copy will work. If the ESP is ever "
        "wiped, only a macOS reinstall regenerates it. Needs privilege (the ESP "
        "is root-only). Refuses if there is nothing to archive, because a "
        "missing EMBEDDEDOS directory means the firmware is already gone and "
        "no backup can be taken."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "dest": {
                "type": "string",
                "description": (
                    "Destination directory. Defaults to "
                    "~/t1-firmware-backup. Remember the result must be copied "
                    "off this disk to be useful."
                ),
            }
        },
        "required": [],
    },
}

_RESTORE_FW_SCHEMA = {
    "name": "t1_touchbar_restore_firmware",
    "description": (
        "Copy an archived T1 firmware set back to the ESP, for when an "
        "installer has wiped EFI/APPLE and the T1 has dropped to 05ac:1281 "
        "recovery mode. Writes atomically (stage, sync, rename) and verifies "
        "afterwards. Refuses to touch a healthy T1 whose ESP already matches "
        "the archive, and refuses a corrupt or incomplete archive. This "
        "restores files you already have — it cannot regenerate firmware."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "backup_dir": {
                "type": "string",
                "description": "Archive directory. Defaults to ~/t1-firmware-backup.",
            },
            "force": {
                "type": "boolean",
                "description": (
                    "Bypass the healthy-T1 guard. Only for the case where the T1 "
                    "is up but the ESP copy is known to be wrong."
                ),
            },
        },
        "required": [],
    },
}


def _handle_status(params, **kwargs):
    del params, kwargs
    try:
        return json.dumps({"success": True, **t1.status_report()}, indent=1, default=str)
    except Exception as exc:  # never let a probe failure look like agent failure
        return json.dumps({"success": False, "error": f"{type(exc).__name__}: {exc}"})


def _handle_build(params, **kwargs):
    del params, kwargs
    try:
        return json.dumps({"success": True, **t1.build_modules()}, indent=1, default=str)
    except Exception as exc:
        return json.dumps({"success": False, "error": f"{type(exc).__name__}: {exc}"})


def _handle_install(params, **kwargs):
    del kwargs
    try:
        confirm = bool(params.get("confirm"))
        result = t1.do_install(confirm)
        return json.dumps(
            {"success": bool(result.get("ok")), **result}, indent=1, default=str
        )
    except Exception as exc:
        return json.dumps({"success": False, "error": f"{type(exc).__name__}: {exc}"})


def _handle_backup_firmware(params, **kwargs):
    del kwargs
    try:
        result = t1.do_backup_firmware(params.get("dest"))
        return json.dumps(
            {"success": bool(result.get("ok")), **result}, indent=1, default=str
        )
    except Exception as exc:
        return json.dumps({"success": False, "error": f"{type(exc).__name__}: {exc}"})


def _handle_restore_firmware(params, **kwargs):
    del kwargs
    try:
        result = t1.do_restore_firmware(
            params.get("backup_dir"), bool(params.get("force"))
        )
        return json.dumps(
            {"success": bool(result.get("ok")), **result}, indent=1, default=str
        )
    except Exception as exc:
        return json.dumps({"success": False, "error": f"{type(exc).__name__}: {exc}"})


def register(ctx) -> None:
    ctx.register_tool(
        name="t1_touchbar_status",
        toolset="t1_touchbar",
        schema=_STATUS_SCHEMA,
        handler=_handle_status,
        emoji="🖥️",
        description="Diagnose the Apple T1 Touch Bar on Linux",
    )
    ctx.register_tool(
        name="t1_touchbar_build",
        toolset="t1_touchbar",
        schema=_BUILD_SCHEMA,
        handler=_handle_build,
        emoji="🔨",
        description="Build the T1 Touch Bar kernel modules",
    )
    ctx.register_tool(
        name="t1_touchbar_install",
        toolset="t1_touchbar",
        schema=_INSTALL_SCHEMA,
        handler=_handle_install,
        emoji="📦",
        description="Install the T1 Touch Bar driver stack via DKMS",
    )
    ctx.register_tool(
        name="t1_touchbar_backup_firmware",
        toolset="t1_touchbar",
        schema=_BACKUP_FW_SCHEMA,
        handler=_handle_backup_firmware,
        emoji="💾",
        description="Archive the T1 firmware from the ESP (do this first)",
    )
    ctx.register_tool(
        name="t1_touchbar_restore_firmware",
        toolset="t1_touchbar",
        schema=_RESTORE_FW_SCHEMA,
        handler=_handle_restore_firmware,
        emoji="♻️",
        description="Restore T1 firmware to the ESP after it was wiped",
    )

    # The bundled skill carries the diagnosis and the failure modes that are not
    # obvious from the outside (loading is not binding; the 634-byte interface
    # is what identifies the Touch Bar; T1 vs T2).
    if SKILL_DIR.is_dir():
        ctx.register_skill(
            name="macbook-t1-touchbar-linux",
            path=SKILL_DIR,
            description="Fix the Apple T1 Touch Bar and webcam on a Linux MacBook.",
        )
