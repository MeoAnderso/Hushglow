# DisplayKeys

<img src="docs/app-icon.png" width="96" alt="DisplayKeys icon">

A small native macOS menu bar app that controls an external monitor's brightness and volume
over DDC/CI, from the keyboard, with an on-screen indicator. Written for an external display on
an Apple Silicon Mac; it should work with any display that speaks DDC/CI over USB-C or
DisplayPort.

![On-screen indicator](docs/osd-preview.png)

How it is built, and what has been verified, is in [docs/DESIGN.md](docs/DESIGN.md).

## Using it

| Action | Shortcut | With Rectangle or Magnet installed |
|---|---|---|
| Brightness up / down | `Ctrl+Alt+Up` / `Ctrl+Alt+Down` | `Ctrl+Alt+F2` / `Ctrl+Alt+F1` |
| Volume up / down | `Ctrl+Alt+Right` / `Ctrl+Alt+Left` | `Ctrl+Alt+F12` / `Ctrl+Alt+F11` |
| Mute | `Ctrl+Alt+End` | `Ctrl+Alt+F10` |

Rectangle and Magnet use Ctrl+Alt with the arrows themselves, and macOS lets both apps take
the same keys without telling either, so when one of them is installed a new install starts
on the function keys instead, where Apple's keyboards have these functions. On an Apple
keyboard whose top row sends brightness and volume, hold fn with them. The choice is made
once, the first time the app runs; Restore Defaults in Settings makes it again.

Holding a shortcut keeps stepping, at the pace of the keyboard's own key repeat (System
Settings → Keyboard). Scrolling over the menu bar icon changes the brightness. The menu bar
item has sliders with a mute button for the mouse, which also move when you scroll over
them, and an indicator appears under it as you change a level. With "Play feedback when
volume is changed" on in System Settings → Sound, the volume keys and shortcuts play macOS's
feedback sound. The indicator also tells you when there is nothing to control, and when the
display refuses a change (some picture modes lock brightness).

With more than one display that answers DDC, the menu has a group of rows for each, under
its name, and the keys and shortcuts change the display under the pointer; the volume keys
change the display that sound plays through. The indicator appears on the display that
changed. Settings → General can have the keys change every display at once instead. A
display that has contrast gets a slider for it, and one that reports its input gets its
inputs in a submenu, to switch it to another source.

A keyboard's own volume and brightness keys work too, if it has them and macOS receives
them. That needs the app to be switched on in System Settings → Privacy & Security, in the
list macOS 27 calls Device Control and Data Access and macOS 26 calls Accessibility.
The app walks you there; the shortcuts, the menu and the command line work without it.

### Settings

Choose Settings… in the menu.

- **Indicator.** Its style is Glass (the system's Liquid Glass, which follows the Liquid Glass
  setting in System Settings → Appearance), See-through glass (the same at reduced strength,
  so what is behind shows through) or Plain tint (no blur at all). It can appear under the
  menu bar icon or in the top-right corner, and can show the level as a percentage.
- **Shortcuts.** Click a field, or focus it and press Space, then press the keys. A shortcut
  is any of Ctrl, Alt, Shift and Cmd with an arrow, page, Home, End or function key; a
  function key can also stand alone. The field shows the modifiers as you hold them. Delete
  removes a shortcut; so does the ✕ beside the field, and the arrow beside it puts back the
  default. Both show while the pointer is over the field or the field has the focus. The
  window says why when a shortcut cannot be used. The app's shortcuts are paused only while a field is waiting for
  keys, so that what you press is taken down and not acted on. Keys that macOS has a
  shortcut of its own on, such as Ctrl+Up for Mission Control, are turned down with a note
  saying so; to use them, switch macOS's shortcut off in System Settings → Keyboard →
  Keyboard Shortcuts. "Quarter steps" registers each stepping shortcut a second time with a
  modifier added, Cmd unless you choose another, for steps a quarter of the size. It is off by
  default. Shift is a poor choice with the default shortcuts, since macOS uses
  Ctrl+Alt+Shift+arrows itself; the window names any that clash.
- **Brightness and volume keys**, the keyboard's own. Shows whether they are on, and turns
  them on.
- **Keys change** the display under the pointer, or every display; this matters only with
  more than one display that answers DDC.
- **Dim the screen below the display's lowest brightness.** On by default: once a display is
  at its lowest, the brightness keys go on darkening its screen, in six steps of a tenth,
  with a black layer over it that clicks go through and screenshots leave out. Brightness up
  takes it off first, and so does moving the slider.
- **Launch at login.**
- **Check for updates automatically**, in a build that can update itself (see Updates).

The indicator follows the system's accessibility settings: a solid capsule with Reduce
Transparency, a strong outline with Increase Contrast, and no movement with Reduce Motion.
VoiceOver is told the new level once it settles.

Shortcuts can also be set from the command line:

```bash
DisplayKeys shortcut                            # list
DisplayKeys shortcut volume-up ctrl+alt+right   # set
DisplayKeys shortcut mute none                  # remove
DisplayKeys shortcut brightness-up default      # reset
DisplayKeys shortcut quarter-steps on           # or off, or cmd, shift, alt or ctrl
```

Actions are `brightness-up`, `brightness-down`, `volume-up`, `volume-down` and `mute`. The
command reports whether the running app could register the shortcut.

### Updates

A build that carries the key its updates are signed with looks for a new release of this
repository once a day, if you say yes when it asks on its second launch, and its menu has
Check for Updates…. The updater is [Sparkle](https://sparkle-project.org). Each update is
signed with a key only the maintainer holds, and the app installs only what that key signed.
A build without the key, such as one you make yourself, never looks for updates.

### Scripts

```bash
DisplayKeys step brightness up      # or down; add --fine for a quarter step
DisplayKeys set volume 30           # percent
DisplayKeys mute                    # toggle; or: mute on, mute off
DisplayKeys set brightness 70 --display 2   # one display, numbered as status lists them
DisplayKeys set contrast 60
DisplayKeys input hdmi1             # or dp1, dp2, hdmi2, usbc: the display then shows that input
DisplayKeys get brightness
```

`DisplayKeys` here is `/Applications/DisplayKeys.app/Contents/MacOS/DisplayKeys`, and
`DisplayKeys help` lists every command. A command it does not know gets the same list and
does not start the app. While the app is running these commands go through it, `get`
included, so that only one program talks to the display at a time. The running app answers
its own command line only: the one inside the same app, or from a build signed with the same
certificate. Another build of the app, such as one run from `.build`, is turned down.

### When something does not respond

- `DisplayKeys status` shows what the running app sees: its version and build, the display's
  values, how much memory the app uses, whether the keyboard's own keys are active, which
  shortcuts are registered, and how many key presses it has received and what the last one
  was.
- `DisplayKeys watch-keys` shows, for ten seconds, which special keys reach the app. Use it
  to find out what a keyboard's volume keys actually send. Ordinary typing is not recorded,
  and the indicator says on screen that a watch is running for as long as it runs.
- `DisplayKeys doctor` checks the connection to the display. `--write-test` also changes
  brightness and volume by one unit and restores them; `--key-test` sends a simulated volume
  key through the system to prove that such keys reach the app.
- For a live trace of every key and shortcut the app receives:
  `log stream --level debug --predicate 'subsystem == "local.DisplayKeys"'`

## Build and install

```bash
Scripts/install.sh       # builds, installs into /Applications and starts the app
Scripts/build-app.sh     # only builds build/DisplayKeys.app
Scripts/release.sh       # also packs and signs it for an update, and writes the feed; --publish releases it
swift test               # unit tests
swift format lint --strict --recursive Sources Tests Scripts Package.swift
swift Scripts/make-icon.swift   # redraws the icon's layers, only needed after changing the artwork
```

The app runs on macOS 26 or later. Building it requires Xcode's Swift 6.2 toolchain or
later. The one third-party dependency is Sparkle, the updater, which Swift Package Manager
fetches at an exact version.

Every build runs with the hardened runtime. With a Developer ID certificate, the build script
also has Apple notarize the app and staples the ticket to it:

```bash
CODESIGN_IDENTITY="Developer ID Application: <name> (<team>)" NOTARY_PROFILE=<profile> Scripts/build-app.sh
```

The profile holds the notarization credentials in the keychain; create it once with
`xcrun notarytool store-credentials <profile>`.

Every push to GitHub is built without warnings, tested, linted and built into the app by
[continuous integration](.github/workflows/ci.yml); only the pictures are left to a person.

Running the tests with `PREVIEW_DIR` set to a folder also writes pictures of the indicator,
the menu, Settings, the notices and the helper there. That puts windows and a menu on screen
for a few seconds.

### Turning on the brightness and volume keys, and again after a rebuild

Choosing "Turn On Brightness and Volume Keys…" opens that list in System Settings and puts a small helper
under the window with the app's icon. Drag the icon into the list and the keys work. The
helper's "?" button offers "Add Without Dragging", which has macOS ask with its own alert
and add the app switched off.

macOS ties this access to the app's signature. Without a signing certificate every rebuild
looks like a different app: System Settings still shows the switch as on, but macOS ignores
it. The app handles this itself. The first time a new build runs without access, it explains
what happened, and "Turn On Brightness and Volume Keys…" first clears the stale entry, so
the list is ready for the app to be dragged in again. The menu and Settings offer the same at
any time, and unticking "Ask again after updates", in that notice or in Settings, stops new
builds from raising it. A build signed with a certificate keeps its access across updates
signed with the same certificate, and raises the subject only when the certificate changes.

To skip even that, create a signing certificate once: in Keychain Access choose
Certificate Assistant → Create a Certificate, name it `DisplayKeys Dev`, with Identity Type
Self-Signed Root and Certificate Type Code Signing. The build script uses a certificate with
that name automatically, and `CODESIGN_IDENTITY` selects another one.

### Releasing

Once, create the update key and give the app its public half:

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys
```

It keeps the private key in your login keychain and prints the public key; put that in
`Resources/Info.plist` as `SUPublicEDKey`. Keep the private key safe (`generate_keys -x`
exports it): without it no installed copy can be updated again.

For each release, raise `CFBundleShortVersionString` and `CFBundleVersion` in
`Resources/Info.plist`, commit, and run `Scripts/release.sh`. It builds the app, signs the
archive with the key from the keychain and writes `build/appcast.xml`; `--publish` then
creates the release on GitHub with both files, and the app's feed address points at the
latest release. Until the app is notarized, macOS refuses to open a downloaded copy at first;
in System Settings → Privacy & Security, choose Open Anyway.

### Uninstalling

Quit the app, turn off Launch at Login, delete `/Applications/DisplayKeys.app`, remove it
from that list in System Settings, and run `defaults delete local.DisplayKeys`.

## Licence

MIT. See [LICENSE](LICENSE).
