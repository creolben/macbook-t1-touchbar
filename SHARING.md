# Sharing this

Three separate audiences, three mechanisms. Pick by what you want to give away.

## 1. Hermes users — the plugin

Anyone with Hermes Agent:

```bash
hermes plugins install creolben/macbook-t1-touchbar/plugin-t1-touchbar --force --no-enable
hermes plugins enable t1-touchbar
```

Or pinned to an exact revision (recommended — it cannot drift under them):

```bash
hermes plugins install creolben/macbook-t1-touchbar/plugin-t1-touchbar \
  --ref <40-char-commit-sha>
```

**Why `--force` is currently needed.** Hermes scans plugins on install. This one
scans to `caution`, not `dangerous`, so it stays installable — but the installer
treats a caution verdict from a *community* source as needing explicit consent.
The findings are all `privilege_escalation` (HIGH) from the word `sudo`
appearing in the code and docs, which is unavoidable for a tool whose job is
installing kernel modules. `--force` is the intended way to record that consent.
An install from `dangerous` cannot be forced at all.

To make the default path clean, get listed in the community index (below) —
packs and index entries carry their own trust posture.

Verify before enabling:

```bash
hermes plugins doctor ~/.hermes/plugins/t1-touchbar
hermes plugins capabilities          # should show no overrides
```

## 2. Community index listing

The index is a plain JSON file. Open a PR against
[NousResearch/hermes-plugin-index](https://github.com/NousResearch/hermes-plugin-index)
adding an entry:

```json
{
  "name": "t1-touchbar",
  "description": "Apple T1 (iBridge) Touch Bar support for Linux MacBook Pro.",
  "author": "creolben",
  "tags": ["macbook", "touchbar", "t1", "ibridge", "apple", "dkms"],
  "repo": "creolben/macbook-t1-touchbar",
  "ref": "<40-char commit SHA>",
  "subdir": "plugin-t1-touchbar",
  "homepage": "https://github.com/creolben/macbook-t1-touchbar",
  "capabilities": ["tools"],
  "api_version": 1,
  "added_at": "2026-09-27"
}
```

Then `hermes plugins install t1-touchbar` works by name. Review covers metadata
only — indexed is not audited, so the install still prompts for consent.

## 3. Sharing a whole setup — the pack

`hermes-pack.yaml` pins plugins to exact SHAs, like a modpack. It is already
pinned to the current commit; update the pin when you publish a revision:

```yaml
plugins:
  - repo: creolben/macbook-t1-touchbar
    ref: <40-char-commit-sha>
    subdir: plugin-t1-touchbar
```

Recipient:

```bash
hermes plugins pack show ./hermes-pack.yaml      # dry-run review
hermes plugins pack install ./hermes-pack.yaml
```

Useful if you bundle this with other T1 machine fixes (5 GHz Wi-Fi, CS8409
audio) into one "my MacBook setup" pack.

## 4. Non-Hermes users — the standalone toolkit

`standalone/` needs no Hermes at all:

```bash
git clone https://github.com/creolben/macbook-t1-touchbar
cd macbook-t1-touchbar/standalone
sudo ./bootstrap-t1-touchbar.sh
```

This is what to hand to someone on plain Arch, Fedora, or Ubuntu. It is also the
simplest thing to link from a forum answer or a blog post, because it has no
dependency on this ecosystem.

## 5. The skill on its own

If you only want the diagnosis knowledge to travel (no tooling), the skill is a
standard SKILL.md:

```bash
hermes skills publish plugin-t1-touchbar/skills/macbook-t1-touchbar-linux --to github
```

Or add the repo as a tap so its skills are discoverable:

```bash
hermes skills tap add creolben/macbook-t1-touchbar
```

## What "done" looks like

After pushing, verify from a clean machine or a throwaway `HERMES_HOME`:

```bash
# 1. installs and validates
hermes plugins install creolben/macbook-t1-touchbar/plugin-t1-touchbar --ref 085cac6056c84f74ffee95415f9e35aa622033b4 --force
hermes plugins doctor ~/.hermes/plugins/t1-touchbar

# 2. registers all three tools
hermes plugins list | grep t1-touchbar

# 3. reports honestly on the target machine
#    (on a T2 machine it must refuse, with an explanation, not silently do nothing)
```

## Honest limitations to state when you share it

- Verified on exactly one machine: MacBookPro14,3, Omarchy/Arch, kernel
  7.2.5-4. It should apply to any T1 model, but that is inference, not testing.
  Say so, and ask for reports.
- Touch ID will not work, before or after. No Linux driver exists.
- The T1 firmware step is not automatable. macOS must boot once, online, to
  provision the chip. If the recipient's ESP lacks `combined.memboot`, nothing
  in this repo helps until they do that.
- `apple-ib-als` may log an unknown-symbol failure. Harmless; documented.
