# DisplayKeys

<img src="docs/app-icon.png" width="96" alt="DisplayKeys icon">

A small native macOS menu bar app that controls an external monitor's brightness and volume
over DDC/CI, from the keyboard, with an on-screen indicator. Written for an external display on
an Apple Silicon Mac; it should work with any display that speaks DDC/CI over USB-C or
DisplayPort.

![On-screen indicator](docs/osd-preview.png)

How it is built, and what has been verified, is in [docs/DESIGN.md](docs/DESIGN.md).

## Using it

| Action | Shortcut |
|---|---|
| Brightness up / down | `Ctrl+Alt+Up` / `Ctrl+Alt+Down` |
| Volume up / down | `Ctrl+Alt+Right` / `Ctrl+Alt+Left` |
| Mute | `Ctrl+Alt+End` |

Holding a shortcut keeps stepping. The menu bar item has sliders with a mute button for the
mouse, and an indicator appears under it as you change a level. The indicator also tells
you when there is nothing to control, and when the display refuses a change (some picture
modes lock brightness).

A keyboard's own volume and brightness keys work too, if it has them and macOS receives
them. That needs the app to be switched on in System Settings → Privacy & Security, in the
list macOS 27 calls Device Control and Data Access and earlier versions call Accessibility.
The app walks you there; the shortcuts, the menu and the command line work without it.

### Settings

Choose Settings… in the menu.

- **Indicator.** Its style is Glass (the system's Liquid Glass, which follows the Liquid Glass
  setting in System Settings → Appearance), See-through glass (the same at reduced strength,
  so what is behind shows through) or Plain tint (no blur at all). It can appear under the
  menu bar icon or in the top-right corner, and can show the level as a percentage.
- **Shortcuts.** Click a field, or focus it and press Space, then press the keys. A shortcut
  is any of Ctrl, Alt, Shift and Cmd with an arrow, page, Home, End or function key; a
  function key can also stand alone. Delete removes a shortcut. The window says why when a
  shortcut cannot be used, and shortcuts are paused while it is open. Keys that macOS has a
  shortcut of its own on, such as Ctrl+Up for Mission Control, are turned down with a note
  saying so; to use them, switch macOS's shortcut off in System Settings → Keyboard →
  Keyboard Shortcuts. "Also register each with Shift, for quarter steps" is off by default
  because macOS uses some of those combinations itself, Ctrl+Alt+Shift+arrows among them;
  when it is on, the window names the ones that clash.
- **The keyboard's own volume keys.** Shows whether they are on, and turns them on.
- **Launch at login.**

The indicator follows the system's accessibility settings: a solid capsule with Reduce
Transparency, a strong outline with Increase Contrast, and no movement with Reduce Motion.
VoiceOver is told the new level once it settles.

Shortcuts can also be set from the command line:

```bash
DisplayKeys shortcut                            # list
DisplayKeys shortcut volume-up ctrl+alt+right   # set
DisplayKeys shortcut mute none                  # remove
DisplayKeys shortcut brightness-up default      # reset
DisplayKeys shortcut quarter-steps on
```

Actions are `brightness-up`, `brightness-down`, `volume-up`, `volume-down` and `mute`. The
command reports whether the running app could register the shortcut.

### Scripts

```bash
DisplayKeys step brightness up      # or down; add --fine for a quarter step
DisplayKeys set volume 30           # percent
DisplayKeys mute                    # toggle; or: mute on, mute off
DisplayKeys get brightness
```

`DisplayKeys` here is `/Applications/DisplayKeys.app/Contents/MacOS/DisplayKeys`.

### When something does not respond

- `DisplayKeys status` shows what the running app sees: its version and build, the display's
  values, whether the keyboard's own keys are active, which shortcuts are registered, and
  how many key presses it has received and what the last one was.
- `DisplayKeys watch-keys` shows, for ten seconds, which special keys reach the app. Use it
  to find out what a keyboard's volume keys actually send. Ordinary typing is not recorded.
- `DisplayKeys doctor` checks the connection to the display. `--write-test` also changes
  brightness and volume by one unit and restores them; `--key-test` sends a simulated volume
  key through the system to prove that such keys reach the app.
- For a live trace of every key and shortcut the app receives:
  `log stream --level debug --predicate 'subsystem == "local.DisplayKeys"'`

## Build and install

```bash
Scripts/install.sh       # builds, installs into /Applications and starts the app
Scripts/build-app.sh     # only builds build/DisplayKeys.app
swift test               # unit tests
swift format lint --strict --recursive Sources Tests Scripts Package.swift
swift Scripts/make-icon.swift   # redraws both forms of the icon, only needed after changing the artwork
```

Requires Xcode's Swift 6 toolchain. There are no third-party dependencies.

### Turning on the keyboard's keys, and again after a rebuild

Choosing "Turn On Keyboard Keys…" opens that list in System Settings and puts a small helper
under the window with the app's icon. Drag the icon into the list and the keys work. The
helper's "?" button offers "Add Without Dragging", which has macOS ask with its own alert
and add the app switched off.

macOS ties this access to the app's signature. Without a signing certificate every rebuild
looks like a different app: System Settings still shows the switch as on, but macOS ignores
it. The app handles this itself. The first time a new build runs without access, it explains
what happened, and "Turn On Keyboard Keys…" first clears the stale entry, so the list is
ready for the app to be dragged in again. The menu and Settings offer the same at any time,
and "Don't ask again after updates" stops new builds from raising it.

To skip even that, create a signing certificate once: in Keychain Access choose
Certificate Assistant → Create a Certificate, name it `DisplayKeys Dev`, with Identity Type
Self-Signed Root and Certificate Type Code Signing. The build script uses a certificate with
that name automatically, and `CODESIGN_IDENTITY` selects another one.

### Uninstalling

Quit the app, turn off Launch at Login, delete `/Applications/DisplayKeys.app`, remove it
from that list in System Settings, and run `defaults delete local.DisplayKeys`.
