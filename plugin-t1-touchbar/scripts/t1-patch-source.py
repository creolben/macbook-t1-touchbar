#!/usr/bin/env python3
"""t1-patch-source.py — make the macbook12-spi-driver T1 modules build on modern kernels.

The distro source dates from Nov 2025 and predates several kernel API changes.
This applies the three fixes idempotently: run it on an already-patched tree and
it reports "already" for each and changes nothing.

    python3 t1-patch-source.py <source-dir>

Exit codes:
    0  all three fixes are present (applied now, or already there)
    2  the source does not look like the expected driver revision
"""
import pathlib
import re
import sys

# (file, what, pattern to find, replacement)
SIMPLE_FIXES = [
    (
        "apple-ibridge.c",
        "report_fixup returns const (kernel 6.x+)",
        "static __u8 *appleib_report_fixup(",
        "static const __u8 *appleib_report_fixup(",
    ),
]

# `.owner` was dropped from struct acpi_driver. Match the line *and* its
# trailing newline so removing it leaves no blank line behind.
OWNER_LINE = re.compile(r"^[ \t]*\.owner[ \t]*=[ \t]*THIS_MODULE,[ \t]*\n", re.M)

# platform_driver.remove became void-returning (kernel 6.11+).
# Replace each whole function, anchored from its signature to the closing brace
# in column 0. The bodies below are the ones verified to compile on 7.2.
REMOVE_FIXES = [
    (
        "apple-ib-tb.c",
        "appletb_platform_remove",
        """static void appletb_platform_remove(struct platform_device *pdev)
{
	struct appleib_device_data *ddata = pdev->dev.platform_data;
	struct appleib_device *ib_dev = ddata->ib_dev;
	struct appletb_device *tb_dev = platform_get_drvdata(pdev);
	int rc;

	rc = appleib_unregister_hid_driver(ib_dev, &appletb_hid_driver);
	if (rc)
		return;

	appletb_free_device(tb_dev);
}
""",
    ),
    (
        "apple-ib-als.c",
        "appleals_platform_remove",
        """static void appleals_platform_remove(struct platform_device *pdev)
{
	struct appleib_device_data *ddata = pdev->dev.platform_data;
	struct appleib_device *ib_dev = ddata->ib_dev;
	struct appleals_device *als_dev = platform_get_drvdata(pdev);
	int rc;

	rc = appleib_unregister_hid_driver(ib_dev, &appleals_hid_driver);
	if (rc)
		return;

	kfree(als_dev);
}
""",
    ),
]


def replace_function(text: str, name: str, new_body: str):
    """Replace a function by name, from its signature through the closing brace."""
    m = re.search(
        rf"^static\s+\w[\w \t*]*\b{re.escape(name)}\s*\([^;]*?\)\s*\n\{{",
        text,
        re.M,
    )
    if not m:
        return None, "signature not found"
    start = m.start()
    end = text.find("\n}\n", m.end())
    if end == -1:
        return None, "closing brace not found"
    return text[:start] + new_body + text[end + 3:], "replaced"


def main():
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 1
    root = pathlib.Path(sys.argv[1])
    if not root.is_dir():
        print(f"not a directory: {root}", file=sys.stderr)
        return 1

    problems = []
    changed = 0

    for fname, label, old, new in SIMPLE_FIXES:
        p = root / fname
        if not p.is_file():
            problems.append(f"{fname}: missing")
            continue
        text = p.read_text()
        if new in text:
            print(f"  already  {fname}: {label}")
            continue
        if old not in text:
            problems.append(f"{fname}: cannot find {old!r} for {label}")
            continue
        p.write_text(text.replace(old, new, 1))
        changed += 1
        print(f"  applied  {fname}: {label}")

    # .owner in struct acpi_driver
    p = root / "apple-ibridge.c"
    if p.is_file():
        text = p.read_text()
        m = OWNER_LINE.search(text)
        if not m:
            print("  already  apple-ibridge.c: .owner removed from struct acpi_driver")
        else:
            p.write_text(OWNER_LINE.sub("", text, count=1))
            changed += 1
            print("  applied  apple-ibridge.c: .owner removed from struct acpi_driver")

    # void-returning platform remove functions
    for fname, name, body in REMOVE_FIXES:
        p = root / fname
        if not p.is_file():
            problems.append(f"{fname}: missing")
            continue
        text = p.read_text()
        if re.search(rf"^static void {re.escape(name)}\(", text, re.M):
            print(f"  already  {fname}: {name} returns void")
            continue
        new_text, status = replace_function(text, name, body)
        if new_text is None:
            problems.append(f"{fname}: {name}: {status}")
            continue
        p.write_text(new_text)
        changed += 1
        print(f"  applied  {fname}: {name} returns void")

    print(f"\n{changed} change(s) applied.")
    if problems:
        print("\nthe source is not the revision this script expects:", file=sys.stderr)
        for pr in problems:
            print(f"  - {pr}", file=sys.stderr)
        print(
            "\nSee README.md ('When the kernel API moves again'). The three fixes\n"
            "and what each kernel change was are documented there.",
            file=sys.stderr,
        )
        return 2

    # A remaining `int ..._platform_remove` would mean the fix silently missed.
    leftover = [
        p.name
        for p in root.glob("apple-ib-*.c")
        if re.search(r"^static int \w+_platform_remove\(", p.read_text(), re.M)
    ]
    if leftover:
        print(f"\nWARNING: still int-returning platform remove in {leftover}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
