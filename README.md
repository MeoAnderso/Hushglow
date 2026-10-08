# DisplayKeys

<img src="docs/app-icon.png" width="96" alt="DisplayKeys icon">

A small native macOS menu bar app that controls an external monitor's brightness and volume
over DDC/CI, from the keyboard, with an on-screen indicator. Written for an external display on
an Apple Silicon Mac; it should work with any display that speaks DDC/CI over USB-C or
DisplayPort.

![On-screen indicator](docs/osd-preview.png)

## Using it

| Action | How |
|---|---|
| Brightness up / down | `Ctrl+Alt+Up` / `Ctrl+Alt+Down` (add `Shift` for quarter steps) |
| Volume up / down / mute | The keyboard's own volume keys, when sound is going to the display |
| Mouse | Sliders in the menu bar item |
| Scripts | `DisplayKeys step brightness up`, `DisplayKeys set volume 30`, `DisplayKeys mute` |

The volume keys need Accessibility access (System Settings → Privacy & Security →
Accessibility). The brightness shortcuts, the menu and the command line work without it.

Change a shortcut with `DisplayKeys shortcut <action> <keys>`, for example
`DisplayKeys shortcut brightness-up f15`. Actions: `brightness-up`, `brightness-down`,
`volume-up`, `volume-down`, `mute`. Use `none` to remove one and `default` to reset it.

`DisplayKeys doctor` checks the connection; `DisplayKeys doctor --write-test` also changes
brightness and volume by one unit and restores them.

## Build and install

```bash
Scripts/build-app.sh     # builds build/DisplayKeys.app
Scripts/install.sh       # copies it to /Applications and starts it
swift test               # unit tests
swift Scripts/make-icon.swift   # redraws Resources/AppIcon.icns, only needed after changing the artwork
```

Requires Xcode's Swift 6 toolchain. There are no third-party dependencies.

### Keeping the permission across rebuilds

macOS ties Accessibility access to the app's signature. Without a certificate the app is
ad-hoc signed, so every rebuild looks like a different app: the switch in System Settings
still shows as on, but macOS ignores it. To fix that state, remove the stale entry and grant
again:

```bash
tccutil reset Accessibility local.DisplayKeys
```

To avoid it for good, create a signing certificate once: open Keychain Access, choose
Keychain Access → Certificate Assistant → Create a Certificate, name it `DisplayKeys Dev`,
set Identity Type to Self-Signed Root and Certificate Type to Code Signing. The build script
uses a certificate with that name automatically; `CODESIGN_IDENTITY` selects another one.

To uninstall: quit the app, turn off Launch at Login, delete `/Applications/DisplayKeys.app`,
remove it from the Accessibility list, and run `defaults delete local.DisplayKeys`.

## Design

```
keyboard volume keys ──► MediaKeyTap ─┐
global shortcuts ──────► Hotkeys ─────┤                 ┌─► OSD (on-screen indicator)
menu sliders ──────────► StatusMenu ──┼─► AppDelegate ──┤
command line ──────────► CLI ─────────┘        │        └─► Displays ─► CoalescingWriter ─► IOAV ─► display
                                               └─ AudioRoute (is sound going to the display?)
```

- `DisplayKeysCore` holds the logic, with no AppKit or IOKit dependency: the DDC packet codec,
  step arithmetic, key decoding and routing, commands, the per-display state machine and the
  coalescing write queue. It is unit-tested.
- `DisplayKeys` is the app: AppKit only, no SwiftUI, no storyboards.
- `IOAV` talks to the display through the private IOAVService I2C functions in IOKit. Apple
  Silicon has no public DDC API, so every tool of this kind depends on them.

### How it stays light

- Everything is event-driven. In the steady state there are no timers and no polling.
- The display is read once when it is discovered. Key presses update a cached value and the
  indicator immediately; the DDC write happens on a background queue.
- Writes are coalesced: while a key is held, only the newest value per control is sent.
- The key tap subscribes to media-key events only, never to ordinary keystrokes.
- Shortcuts use Carbon hot keys, which are delivered by the system only when pressed.
- The indicator window is created on first use.

Measured on an Apple silicon Mac, macOS 27.0.1:

| | |
|---|---|
| Idle CPU | 0.01% of one core, 0 idle wakeups |
| One key press | about 1.75 ms of CPU, including the indicator and the write to the display |
| Memory | 14 MB; about 38 MB once the menu's sliders have been used |
| Binary | about 240 KB |

The memory growth comes from the first use of the menu: about 6 MB is live and the rest is
freed memory that the system allocator keeps. Asking the allocator to release it has no
effect on macOS 27, so it stays until the app restarts. Dragging a menu slider costs about
5 ms of CPU per mouse event, most of it macOS drawing the slider.

## Lifecycle requirements

| Requirement | How it is met |
|---|---|
| Starts with no setup | Brightness shortcuts, menu and command line need no permission |
| One instance | A second launch exits immediately |
| Accessibility not yet granted | Asks once on first launch; the menu offers it again; a 3-second check runs only until access is granted |
| Accessibility withdrawn while running | The key tap is removed within half a second, since a tap without access stalls keyboard and mouse input |
| Key tap disabled by macOS | Re-enabled automatically |
| Display sleeps | Unsent writes are dropped and shortcut repeat stops |
| Display wakes | State is re-read after 3 seconds, retrying at 2, 5 and 10 seconds if the display is still waking |
| Display unplugged or replugged | Rediscovered 2 seconds after the reconfiguration burst ends |
| No controllable display | Shortcuts are released and keys pass through to macOS |
| Sound output changes | Volume keys are taken over only while output is a display without its own volume control |
| Value changed with the display's own buttons | Picked up when the menu is opened, and on wake or reconnect |
| A write fails | The displays are rediscovered |
| macOS removes the private functions | The app still launches and reports that display control is unavailable; a test detects it |
| Launch at login | Offered in the menu once the app is in an Applications folder |
| App rebuilt without a certificate | Access must be reset and granted again; see "Keeping the permission across rebuilds" |
| Diagnostics | `DisplayKeys doctor`, and log lines under the `local.DisplayKeys` subsystem |

## What is verified

| Area | Status |
|---|---|
| Packet codec, step arithmetic, key decoding, key routing, commands, write coalescing | Unit tests |
| Reading and writing brightness, volume and mute | Verified against the display by read-back |
| Command line, and commands routed through the running app | Verified against the display |
| Brightness shortcuts, menu sliders | Confirmed in use |
| On-screen indicator | Rendering covered by tests; window confirmed on screen |
| Keyboard volume keys | Not yet confirmed |
| Sleep, wake, unplug and replug handling | Not yet exercised |
| Install script and launch at login | Not yet run |

Not built yet: a settings window, and per-display targeting with several monitors.

## Known limits

- With several external displays, a command goes to all of them.
- On a Mac whose main display is built in, the keyboard's brightness keys are left to macOS.
- macOS's own indicator is not used; it is private and has changed in macOS 26, 27 and 27.2.
