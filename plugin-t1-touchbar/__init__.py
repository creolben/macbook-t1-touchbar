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

    # The bundled skill carries the diagnosis and the failure modes that are not
    # obvious from the outside (loading is not binding; the 634-byte interface
    # is what identifies the Touch Bar; T1 vs T2).
    if SKILL_DIR.is_dir():
        ctx.register_skill(
            name="macbook-t1-touchbar-linux",
            path=SKILL_DIR,
            description="Fix the Apple T1 Touch Bar and webcam on a Linux MacBook.",
        )
