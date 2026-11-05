---
name: airdrop-tool
description: Send files or directories from this Mac to a named AirDrop device and verify the AirDrop transfer status, without manual clicking. Use when the user asks to AirDrop something to a specific iPhone, iPad, or Mac, wants scripted or unattended AirDrop sending, or needs to list the devices visible in an open AirDrop panel.
---

# AirDrop Tool

Send files or directories to one named nearby AirDrop device on macOS and report
the transfer status. Two small Swift CLIs cooperate:

- `airdrop` opens the system AirDrop share panel and keeps it open until the
  share finishes.
- `click` finds the target device in the panel through the Accessibility API,
  presses it, watches the transfer status, and dismisses the panel.

## Install

The skill is self-contained: it ships the Swift sources, a `Makefile`, the
`send.sh` wrapper, and this document. Binaries are **not** committed because
they are architecture-specific; they are built into `bin/` on demand.

```bash
# from the repository
cp -R skills/airdrop-tool ~/.claude/skills/airdrop-tool
make -C ~/.claude/skills/airdrop-tool
```

Alternatively symlink the directory instead of copying it. `scripts/send.sh`
also runs `make` automatically, so a separate build step is optional.

Layout:

```
airdrop-tool/
├── SKILL.md
├── Makefile          # builds src/*.swift into bin/
├── src/
│   ├── airdrop.swift
│   └── click.swift
├── scripts/send.sh   # one-command wrapper
└── bin/              # created by make; not committed
```

## Requirements

- macOS with AirDrop enabled and at least one target device nearby.
- Xcode Command Line Tools (`xcode-select --install`) so `swiftc` is available.
- **Accessibility permission** for the process running the commands (Terminal,
  iTerm, or the agent host): System Settings → Privacy & Security →
  Accessibility. `bin/click --check` exits non-zero when permission is missing.

Build from the skill directory:

```bash
make
```

This produces `bin/airdrop` and `bin/click`.

## Quick start

```bash
cd <skill-directory>
bin/airdrop ~/Pictures/photo.jpg &
bin/click --device "Math的iPad"
```

Or the wrapper, which validates inputs, builds incrementally, launches
`airdrop`, runs `click`, and cleans up on failure:

```bash
scripts/send.sh "Math的iPad" ~/Pictures/photo.jpg
```

The `airdrop` process must stay alive while the panel is open, so start it with
`&` and let `click` run in the foreground.

## Commands

### `airdrop <file|dir>...`

Opens the AirDrop share panel for the given paths and exits when the panel
closes. Errors are reported before the panel opens.

| Exit | Meaning |
|---|---|
| `0` | Panel was shown and has closed (share completed or dismissed) |
| `1` | Service unavailable, share failed, no panel appeared, or total timeout |
| `2` | Usage error, missing path, or unreadable path |
| `130` | Share cancelled by the user |

Flags: `--check` (report availability), `--help`.

Environment: `AIRDROP_PANEL_TIMEOUT` (default 30 s before the panel must
appear), `AIRDROP_TOTAL_TIMEOUT` (default 1800 s hard cap).

`airdrop` exit code `0` does **not** prove the receiver got the file. Use
`click`'s `sent` result as the authority.

The binary must stay named `airdrop` for automatic panel discovery; otherwise
pass `--pid` to `click`.

### `click --device <name>`

Finds the device row whose accessibility description matches `<name>` (exact
match first, then a unique substring match), presses it with `AXPress`, polls
the row until its status settles, then presses the panel's dismiss button.

| Flag | Meaning |
|---|---|
| `--wait <sec>` | How long to wait for the device to appear (default 10) |
| `--timeout <sec>` | Transfer timeout once pressed (default 120; raise for large files) |
| `--dry-run` | Locate the device but do not press it |
| `--keep-open` | Do not dismiss the panel afterwards |
| `--pid <pid>` | Use this process as the panel owner instead of auto-detection |

Exit codes: `0` sent, `1` no Accessibility permission, `2` usage error,
`3` device not found or ambiguous, `4` send failed or panel closed early,
`5` timeout.

### `click --list`

Lists the devices visible in an open AirDrop panel. stdout contains only
`device:` lines; diagnostics go to stderr.

```bash
bin/airdrop /tmp/airdrop-probe.txt &   # any existing file opens the panel
bin/click --list
kill $!
```

Exit `3` when no device is visible. `--wait` controls how long to wait
(default 10 s; use `--wait 0` for a single scan).

### `click <x> <y>`

Legacy raw mouse click at screen coordinates. This only works for ordinary
AppKit controls such as the panel's dismiss button; it does **not** work on the
device rows (see below).

## How it works, and why

- Device rows live in a remote view (`AXOpaqueProviderGroup`), and synthetic
  `CGEvent` mouse clicks are silently ignored there. `AXPress` on the
  `AXButton` is the only reliable way to select a device, so `click` never uses
  coordinates for devices.
- The panel animates in: the device row jumps position about 1.3 s after the
  panel appears. Coordinate-based approaches are therefore fragile even without
  the remote-view problem.
- The panel and its dismiss button are detected **structurally**: the panel is
  the process's window containing an `AXScrollArea`; device rows are the
  buttons inside that scroll area; the dismiss button is the only button
  outside it. Localized window titles and button labels are never matched.
- Device descriptions gain a status suffix once a transfer starts, for example
  `Math的iPad, Waiting…` → `Math的iPad, Sent`. `click` reads the pressed row's
  description and classifies the suffix. Known success and failure words are
  recognized in English and Chinese; unknown suffixes are printed and treated
  as pending, so a new status cannot break device-name matching.
- `Sent` is the strongest signal macOS exposes. There is no public end-to-end
  receipt, so a reported success means the system accepted the transfer; it
  does not prove the bytes landed on the receiver.

## Wrapper

`scripts/send.sh <device> <file|dir>...`

- Overrides: `AIRDROP_WAIT` (default 15), `AIRDROP_TIMEOUT` (default 600),
  `AIRDROP_TOOL_ROOT` (skill directory, if the script was moved).
- Runs `make` on every invocation (incremental, so it is cheap).
- Aborts with the real exit code if `airdrop` dies before the click finishes.
- Kills the background `airdrop` on any failure.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `no AirDrop devices found` | Panel not open yet, or the peer is asleep / off AirDrop. Raise `--wait`, wake the device. |
| `device 'X' not found. available: ...` | Name mismatch; device list flapped. Use `--list` to see exact names. |
| `device 'X' is ambiguous` | Two devices share the name or substring; use the full name. |
| Nothing happens when pressing | Accessibility permission missing; run `bin/click --check`. |
| `timed out waiting for transfer` | Receiver never accepted. `Sent` only appears after acceptance. |
| `panel closed before the transfer finished` | The panel was dismissed (Cancel, Escape) or `airdrop` died. |
| Process lingers | The panel is still open; the total timeout eventually exits. Prefer the wrapper, which cleans up. |
| `airdrop-unavailable` | AirDrop is disabled or the sharing service is missing. |
| `swiftc not found` | Install Xcode Command Line Tools: `xcode-select --install`. |

## Notes

- Large files work; measured ~29 MB/s to an iPad and ~14 MB/s to a Mac over
  Wi-Fi (539 MB in 20 s / 40 s).
- Multiple files or directories can be passed to `airdrop` in one invocation.
- An unreadable path fails with exit `2` before the panel opens.
- `click` only considers executables named exactly `airdrop`; the system
  `AirDrop.appex` and Finder's AirDrop window are excluded. If you rename the
  binary, pass `--pid`.
