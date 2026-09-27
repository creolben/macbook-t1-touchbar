# Verified diagnosis transcript — MacBookPro14,3, kernel 7.2.5-4-omarchy

Raw evidence from a machine taken from a dead T1 to a working Touch Bar. Useful
for calibrating against a new machine: compare each stage.

## Before: T1 dead (firmware erased by a full-disk Linux install)

```
USB 1-3   05ac:1281  Apple Mobile Device (Recovery Mode)

/boot/EFI/APPLE/
└── LOG/
    └── BOOT-1.LOG            <- only this; no EMBEDDEDOS/

ls /dev/video*                -> no such file
ls -d /sys/bus/hid/devices/0003:05AC:*   -> nothing
backlight: /sys/class/leds/spi::kbd_backlight  -> present and user-writable
```

The backlight LED working is the tell that the fault is **not** backlight
hardware. It is the reachability of the keys (F1-F12 live on the Touch Bar).

## After: macOS booted once, firmware provisioned

```
USB 1-3   05ac:8600  iBridge

/boot/EFI/APPLE/EMBEDDEDOS/
  combined.memboot   30725398 B
  FDRData              209888 B
  version.plist           360 B

/dev/video0, /dev/video1          <- webcam works, no driver needed

0003:05AC:8600.0001              <- both interfaces enumerated
0003:05AC:8600.0002
```

Firmware alone is not enough — the Touch Bar was still dark at this point.

## The blocking state, after modules were built and loaded

```
applespi               61440  0      <- in-tree, keyboard/touchpad, fine
(hid_appletb_kbd, hid_appletb_bl, appletbdrm NOT loaded and irrelevant)

0003:05AC:8600.0001   83 bytes  -> hid-generic
0003:05AC:8600.0002  634 bytes  -> hid-sensor-hub     <- STOLEN

ls /sys/bus/hid/devices/0003:05AC:8600.0001/fnmode   -> no such file
```

No `fnmode` attribute = `appletb_probe()` never ran. `lsmod` and `dmesg` both
looked clean; there was no error anywhere.

## After the handover

```
apple_ib_tb      32768  0
apple_ibridge    32768  1 apple_ib_tb

0003:05AC:8600.0001   83 bytes  -> apple-ibridge-hid
0003:05AC:8600.0002  634 bytes  -> apple-ibridge-hid

cat .../0003:05AC:8600.0001/fnmode        -> 1
cat .../0003:05AC:8600.0001/idle_timeout  -> 300
cat .../0003:05AC:8600.0001/dim_timeout   -> -2
```

The three attributes appearing is the success criterion.

## Module aliases (why only one module is the right one)

```
hid_appletb_kbd   alias hid:b0003g*v000005ACp00008302    <- T2
hid_appletb_bl    alias hid:b0003g*v000005ACp00008102    <- T2
appletbdrm        alias usb:v05ACp8302...                <- T2
applespi          alias acpi*:APP000D:*                  <- keyboard/touchpad
action-ibridge    alias acpi*:APP7777:*                  <- T1 Touch Bar, this one
```

`APP7777:00` must exist under `/sys/bus/acpi/devices/` and be unbound for
`apple-ibridge` to probe. Check it before blaming the HID layer.

## Kernel API errors encountered (the patch targets)

```
apple-ibridge.c:752: error: initialization of 'const __u8 * (*)(struct hid_device *, ...)'
  from incompatible pointer type '__u8 * (*)(...)'
    -> report_fixup must return const __u8 *

apple-ibridge.c:901: error: 'struct acpi_driver' has no member named 'owner'
    -> delete .owner = THIS_MODULE,

apple-ib-tb.c:1293: error: initialization of 'void (*)(struct platform_device *)'
  from incompatible pointer type 'int (*)(struct platform_device *)'
apple-ib-als.c:679: same
    -> platform_driver.remove is void-returning since 6.11
```

## Harmless noise

```
apple_ibridge: loading out-of-tree module taints kernel.
apple_ibridge: module verification failed: signature and/or required key missing
    -> expected for any out-of-tree module; not a failure

apple_ib_als: Unknown symbol iio_triggered_buffer_setup_ext (err -2)
apple_ib_als: Unknown symbol iio_triggered_buffer_cleanup (err -2)
    -> module load ordering; only the ambient light sensor, which
       hid-sensor-als already handles. Does not affect the Touch Bar.
```

## Backlight: same fault class as the Touch Bar

`applespi`'s top-row translation table, from the driver source:

```c
{ KEY_F1, KEY_BRIGHTNESSDOWN, APPLE_FLAG_FKEY },
{ KEY_F2, KEY_BRIGHTNESSUP,   APPLE_FLAG_FKEY },
{ KEY_F5, KEY_KBDILLUMDOWN,   APPLE_FLAG_FKEY },
{ KEY_F6, KEY_KBDILLUMUP,     APPLE_FLAG_FKEY },
```

With `fnmode=1` (fkeyslast) and no Fn held, `do_translate` is true, so F1 emits
`KEY_BRIGHTNESSDOWN` (224) and F5 emits `KEY_KBDILLUMDOWN` (229).

Those raw codes do **not** land on `XF86KbdBrightnessUp/Down`, which is what
Omarchy binds:

```
key <I229>  -> XF86Shop            (not a backlight key)
key <I230>  -> not in the keymap at all
key <I237>  -> XF86KbdBrightnessDown    (a different code entirely)
key <I238>  -> XF86KbdBrightnessUp
```

So even with a working Touch Bar, the default Omarchy backlight bindings may not
fire. Confirm which keysym a key actually produces before assuming the binding
is the problem. On a machine with no physical function row, the practical fix is
explicit `SUPER + -` / `SUPER + =` bindings.
