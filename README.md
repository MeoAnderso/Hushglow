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
| Brightness up / down | `Ctrl+Alt+Up` / `Ctrl+Alt+Down` |
| Volume up / down / mute | The keyboard's own volume keys, when sound is going to the display |
| Mouse | Sliders in the menu bar item |
| Scripts | `DisplayKeys step brightness up`, `DisplayKeys set volume 30`, `DisplayKeys mute` |

The keyboard's volume keys need Accessibility access; the app asks for it. Shortcuts, the
menu and the command line work without it.

### Shortcuts

Any action can have a shortcut: `brightness-up`, `brightness-down`, `volume-up`,
`volume-down`, `mute`. Only the two brightness actions have one by default.

```bash
DisplayKeys shortcut volume-up ctrl+alt+right   # set
DisplayKeys shortcut mute none                  # remove
DisplayKeys shortcut brightness-up default      # reset
DisplayKeys shortcut                            # list
```

A shortcut is any of `ctrl`, `alt`, `shift`, `cmd` plus an arrow, page, Home/End or function
key. The command reports whether the running app could register it.

`DisplayKeys shortcut quarter-steps on` also registers every stepping shortcut with Shift
added, for quarter steps. It is off by default because macOS uses some of those combinations
itself, Ctrl+Alt+Shift+arrows among them.

### When something does not respond

- `DisplayKeys status` shows what the running app sees: the display's values, whether the
  keyboard keys are active, which shortcuts are registered, and how many key presses it has
  received and what the last one was.
- `DisplayKeys doctor` checks the connection to the display; `--write-test` also changes
  brightness and volume by one unit and restores them.
- For a live trace of every key and shortcut the app receives:
  `log stream --level debug --predicate 'subsystem == "local.DisplayKeys"'`

## Build and install

```bash
Scripts/install.sh       # builds, installs into /Applications and starts the app
Scripts/build-app.sh     # only builds build/DisplayKeys.app
swift test               # unit tests
swift format lint --strict --recursive Sources Tests Scripts Package.swift
swift Scripts/make-icon.swift   # redraws the icon, only needed after changing the artwork
```

Requires Xcode's Swift 6 toolchain. There are no third-party dependencies.

### Accessibility access after a rebuild

macOS ties Accessibility access to the app's signature. Without a signing certificate every
rebuild looks like a different app: System Settings still shows the switch as on, but macOS
ignores it. The app handles this itself. The first time a new build runs without access, it
clears its own entry and macOS asks again, so the only step is to switch DisplayKeys on in
System Settings → Privacy & Security → Accessibility. "Enable Keyboard Volume Keys…" in
the menu does the same at any time.

To skip even that, create a signing certificate once: in Keychain Access choose
Certificate Assistant → Create a Certificate, name it `DisplayKeys Dev`, with Identity Type
Self-Signed Root and Certificate Type Code Signing. The build script uses a certificate with
that name automatically, and `CODESIGN_IDENTITY` selects another one.

To uninstall: quit the app, turn off Launch at Login, delete `/Applications/DisplayKeys.app`,
remove it from the Accessibility list, and run `defaults delete local.DisplayKeys`.

## Design

```
keyboard volume keys ──► MediaKeyTap ────┐
global shortcuts ──────► Hotkeys ────────┤                 ┌─► OSD (on-screen indicator)
menu sliders ──────────► StatusMenu ─────┼─► AppDelegate ──┤
command line ─► CLI ───► CommandChannel ─┘        │        └─► Displays ─► CoalescingWriter ─► IOAV ─► display
                                                  ├─ AudioRoute (is sound going to the display?)
                                                  └─ AccessibilityAccess (may the key tap run?)
```

- `DisplayKeysCore` holds the logic, with no AppKit or IOKit dependency: the DDC packet codec,
  step arithmetic, key decoding and routing, commands, the display cache (`Displays`) and the
  coalescing write queue. `Displays` reaches the display through the `DisplayTransport`
  protocol, so it is tested against a fake display.
- `DisplayKeys` is the app: AppKit only, no SwiftUI, no storyboards.
- `IOAV` is the real transport. It talks to the display through the private IOAVService I2C
  functions in IOKit; Apple Silicon has no public DDC API, so every tool of this kind depends
  on them.

### How it stays light

- Everything is event-driven. In the steady state there are no timers and no polling.
- Key presses update a cached value and the indicator immediately; the DDC write happens on
  a background queue.
- The display is read when it is discovered, at the start of a burst of key presses if it has
  not been heard from for 5 seconds, and once more 1.5 seconds after the burst ends. Nothing
  is read while idle.
- Writes are coalesced: while a key is held, only the newest value per control is sent.
- The key tap subscribes to media-key events only, never to ordinary keystrokes.
- Shortcuts use Carbon hot keys, which are delivered by the system only when pressed.
- The indicator window is created on first use.

Measured on an Apple silicon Mac, macOS 27.0.1:

| | |
|---|---|
| Idle CPU | under 0.02% of one core, 0 idle wakeups |
| One key press | about 1.75 ms of CPU, including the indicator and the write to the display |
| Memory | 14 MB; about 38 MB once the menu's sliders have been used |
| Binary | about 360 KB |

The memory growth comes from the first use of the menu: about 6 MB is live and the rest is
freed memory that the system allocator keeps. Asking the allocator to release it has no
effect on macOS 27, so it stays until the app restarts. Dragging a menu slider costs about
5 ms of CPU per mouse event, most of it macOS drawing the slider.

## Lifecycle requirements

| Requirement | How it is met |
|---|---|
| Starts with no setup | Brightness shortcuts, menu and command line need no permission |
| One instance | A second launch exits immediately |
| Accessibility not yet granted | Asks once per build; the menu offers it again; a 3-second check runs only until access is granted |
| Accessibility withdrawn while running | The key tap is removed within half a second, since a tap without access stalls keyboard and mouse input |
| Key tap disabled by macOS | Re-enabled automatically |
| Display sleeps | Unsent writes are dropped and shortcut repeat stops |
| Display wakes | State is re-read after 3 seconds, retrying at 2, 5 and 10 seconds if the display is still waking |
| Display unplugged or replugged | Rediscovered 2 seconds after the reconfiguration burst ends |
| No controllable display | Shortcuts are released and keys pass through to macOS |
| Sound output changes | Volume keys are taken over only while output is a display without its own volume control |
| Value changed with the display's own buttons | Read before the next key press is written, unless the display was heard from in the last 5 seconds |
| Display does not take a write | Noticed by the read-back after each burst; the cache follows the display and the event is logged |
| macOS refuses a shortcut | Reported by `DisplayKeys shortcut`, `status` and `doctor`, and logged |
| A write fails | The displays are rediscovered |
| macOS removes the private functions | The app still launches and reports that display control is unavailable; a test detects it |
| Launch at login | Offered in the menu once the app is in an Applications folder |
| App rebuilt without a certificate | The app clears its stale entry and asks again; switching it on is the only step |
| Diagnostics | `DisplayKeys status` and `doctor`, and log lines under the `local.DisplayKeys` subsystem |

## What is verified

| Area | Status |
|---|---|
| Packet codec, step arithmetic, key decoding and routing, commands, write queue, display cache | Unit tests |
| Reading and writing brightness, volume and mute | Verified against the display by read-back |
| Command line, and commands routed through the running app | Verified against the display |
| Reading the display before writing after an outside change | Verified against the display |
| Brightness and volume shortcuts, menu sliders | Confirmed in use |
| Permission repair after a rebuild | Confirmed: one switch in System Settings, no Terminal |
| On-screen indicator | Rendering covered by tests; window confirmed on screen |
| Display sleep and wake | Both handled, and control works afterwards; a long standby is not yet exercised |
| The keyboard's own volume keys | Not yet confirmed |
| Unplug and replug, switching sound output, launch at login | Not yet exercised |

Not built yet: a settings window, and per-display targeting with several monitors.

## Known limits

- With several external displays, a command goes to all of them.
- On a Mac whose main display is built in, the keyboard's brightness keys are left to macOS.
- macOS's own indicator is not used; it is private and has changed in macOS 26, 27 and 27.2.
