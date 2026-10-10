# How Notch is built

This is a map of the code for anyone who wants to change Notch. It covers how the project is laid out, how the pieces talk to each other, and the few rules that keep existing installs working. For how to use the app, see the [guide](GUIDE.md). For building, testing and sending changes, see [CONTRIBUTING.md](CONTRIBUTING.md).

## The targets

`Notch.xcodeproj` has four targets.

- **Notch** is the app itself. It runs in the App Sandbox, draws the notch, and holds every feature.
- **NotchHelper** is an XPC service bundled inside the app. It is not sandboxed, because a few things can't be done from the sandbox: driving other apps through the Accessibility API, loading private frameworks for brightness, reading Notification Center's banners, running the Shortcuts command line tool, and typing the password for Face Unlock. The app starts it on demand and talks to it over XPC.
- **NotchTests** holds the unit tests. They run inside the app, so they can use its internal types.
- **NotchSudo** builds `pam_notch.so`, the small C module that lets sudo ask Notch to approve a command. It ships inside the app and is installed into the system only when the user turns the feature on (see [Face Unlock for sudo](#face-unlock-for-sudo)).

Code in `Shared/` is compiled into both the app and the helper: the XPC protocol, the logger, and a few small types both sides need.

Every target is a synchronized folder in Xcode. Drop a file into the right folder and it's part of the build, with no project file edits. The flip side is that anything you put inside `Notch/` ends up in the app, so keep notes and scripts outside it.

## Where things live

```
Notch/                  The app
  App/                  Entry point, app delegate, demo mode, Info.plist, entitlements
  Core/                 The notch itself: windows, sizing, view model, coordinator
    Views/              The notch's root view, shape, header and tab bar
    Window/             Notch windows, the private window space, drag detection
  Features/             One folder per feature
    AlertMode/          Alert mode (named PresenceGuard in code)
    Battery/            Battery status in the notch
    Calendar/           Calendar tab, events and meeting links
    Clipboard/          Clipboard history
    Devices/            Bluetooth and Apple device batteries
    FaceUnlock/         Face Unlock, including its Core ML model
    Mirror/             The camera mirror
    Music/              Now playing, music sources, lyrics, visualizer
    Notifications/      Notification banners in the notch
    OSD/                Volume and brightness display
    Onboarding/         First-launch walkthrough
    Settings/           The Settings window and its pages
    Shelf/              The shelf and its drop actions
    WindowSnapping/     Snapping windows into layouts from the notch
  Services/             System services several features share (helper client, audio routing)
  UI/                   Reusable SwiftUI views and modifiers
  Support/              Settings keys, extensions and other small helpers
  Resources/            Asset catalog, app icon, strings, sounds
NotchHelper/            The XPC helper
NotchSudo/              The sudo PAM module
Shared/                 Code compiled into both the app and the helper
NotchTests/             Unit tests
Vendor/                 Prebuilt third-party binaries the app ships
Tools/                  Source for the bundled device tool, and the sudo module's tests
Scripts/                Release script
docs/                   Screenshots used by the README and guide
```

Larger features split their folder further into `Models/`, `Views/`, `Services/` or `Controllers/` when it helps. Smaller ones keep everything side by side.

## How the notch works

`AppDelegate` sets the app up at launch and hands the windows to `NotchWindowManager`. The manager creates a `NotchWindow` for the display the notch should appear on, or one per display if you choose all displays. Each window has its own `NotchViewModel`, which knows whether that notch is open, how big it is, and which screen it belongs to. The windows live in a private window space (`CGSSpace`, managed by `NotchSpaceManager`) so they stay above full-screen apps and can show on the lock screen.

State that every notch shares lives in `NotchCoordinator.shared`: the selected tab, sneak peeks for volume, brightness and music, and the first-launch flag.

`NotchView` is the root SwiftUI view inside each window. When the notch is closed, it shows live activities: the music player, battery, notifications and so on, stacked by `LiveActivityStack`. When it's open, it shows `NotchHeader` with the tabs, and below it the current tab: the music player (`NotchHomeView`), calendar, shelf, clipboard or devices. Sizes and corner radii come from `NotchMetrics.swift`, and animations from `StandardAnimations`.

Most features have one long-lived object that does the work and publishes state for the views, usually a `shared` singleton:

| Feature | Start reading at |
|---|---|
| Music | `MusicManager`, which picks a source from `Features/Music/Controllers` |
| Calendar | `CalendarManager` (calendars and permissions) and `UpcomingEventsModel` (events) |
| Shelf | `ShelfStateViewModel` |
| Clipboard | `ClipboardHistoryManager` |
| Devices | `NotchDevicesModel` |
| Face Unlock | `FaceUnlockManager` |
| Alert mode | `PresenceGuard` |
| Window snapping | `WindowSnapController` |
| Notifications | `SystemNotificationManager` |
| Volume and brightness | `VolumeManager`, `BrightnessManager` and `MediaKeyInterceptor` |

Hardware and system events that should show something in the notch go through `NotchUIEventBus`, so managers don't need to know about views.

## Talking to the helper

The XPC interface is the `NotchHelperProtocol` in `Shared/NotchHelperProtocol.swift`. The app calls it through `NotchHelperClient.shared`, which wraps each call in an async function and reconnects if the helper goes away. On the other side, `NotchHelperService` implements it, split into one extension file per area: accessibility, Apple devices, brightness, Face Unlock, Focus shortcuts and notifications. The helper calls back into the app through `NotchHelperCallbacks`, for Notification Center banners and Lunar brightness changes.

To add a helper call, add it to the protocol, implement it in the matching `NotchHelperService+…` file, and add an async wrapper to `NotchHelperClient`. Both sides are built from the same source, so they always agree.

The helper's `Info.plist` sets `JoinExistingSession`. Without it, the helper would run in a separate security session where it can't see the lock screen or post keystrokes to it, and Face Unlock would break.

## Face Unlock for sudo

Four pieces work together when something runs sudo:

1. **sudo** reads `/etc/pam.d/sudo_local`, which macOS keeps for local changes. When the feature is on, its first line loads `/usr/local/lib/pam/pam_notch.so.2`, built from `NotchSudo/pam_notch.c`.
2. **The PAM module** connects to a Unix socket at `~/Library/Application Support/theboringteam.boringnotch/sudo.sock`. Before saying anything, it checks the code signature of the process on the other end against `/usr/local/etc/notch-sudo.requirement`, which holds NotchHelper's designated requirement and only root can change. Then it sends the command line and waits for "allow" or "deny". Anything unexpected returns `PAM_IGNORE`, and sudo carries on to the password prompt.
3. **NotchHelper** (`SudoRequestListener`) accepts only `/usr/bin/sudo` running as root in the same login session, so SSH sessions and other users are refused. (Debug builds also answer processes running as you, for testing; an answer is worthless to anything but sudo.) It works out who ran sudo from the parent processes and passes the request to the app.
4. **The app** (`Features/FaceUnlock/Sudo/SudoApproval`) runs a scan through `FaceUnlockManager.startSudoScan`, which shows the lock screen's Face ID overlay, waits for a double tap of the Try again key if `faceUnlockSudoRequiresConfirmation` is on, and replies.

The socket lives outside the app's container because sudo would otherwise have to reach into another app's data, and macOS answers that with an "access data from other apps" prompt.

`NotchHelper/sudo-integration.sh` installs and removes the module. The helper runs it as root behind the macOS administrator prompt. Installing checks that only root can write to the module's folders, then makes sure sudo still starts, and undoes everything if it doesn't. A PAM module sudo can't load would stop sudo from working, and this is the one change in Notch that could do that. Removing the feature doesn't use sudo, so it works even when sudo is broken.

`Tools/pam_notch-tests/run.sh` tests the module against a fake helper, including one with the wrong signature, without installing anything. Run it after any change to `pam_notch.c`.

## Settings

Every saved setting is a typed key in `Support/Defaults+Keys.swift`, using the [Defaults](https://github.com/sindresorhus/Defaults) package. Views read them with `@Default(.someKey)`, and other code with `Defaults[.someKey]`. Settings pages live in `Features/Settings/Pages`, one per sidebar item.

## Things that must not change

Notch inherited these names from boring.notch. They identify the app to macOS and to data already on people's Macs, so renaming any of them would reset permissions or lose settings:

- The bundle IDs `theboringteam.boringnotch` and `theboringteam.boringnotch.BoringNotchXPCHelper`. macOS ties camera, Accessibility and other permissions to them, and the helper's ID is also the XPC service name.
- The strings inside settings keys, such as `"boringShelf"`. The Swift name of a key can change freely; the string is what's stored.
- `@AppStorage` keys in `NotchCoordinator`, such as `"firstLaunch"`.
- The `boringNotch` folders in Application Support, where the shelf, clipboard history and face data are saved, and the helper's `theboringteam.boringnotch/faceunlock.secret` file.
- The `/auth/boringNotch` app ID that YouTube Music asked the user to approve.

## Logging

Use `Log` from `Shared/Log.swift` instead of `print` or `NSLog`. It has one logger per area (`Log.music`, `Log.faceUnlock`, `Log.helper` and so on), all under the app's bundle ID, so you can follow both processes at once:

```bash
log stream --predicate 'subsystem == "theboringteam.boringnotch"'
```

Never log passwords, clipboard contents or anything else private. Interpolated strings are hidden in the system log by default, which is usually what you want.

## Private APIs

Some features rely on undocumented macOS APIs, which can change with any macOS update:

- The notch windows use SkyLight window spaces (`CGSSpace.swift`, `NotchWindow.swift`).
- The Now Playing source reads `MediaRemote.framework` through the vendored [MediaRemoteAdapter](Vendor/MediaRemoteAdapter/README.md), because Apple blocks direct use from apps.
- The helper uses `DisplayServices` and `CoreBrightness` for screen and keyboard brightness.
- Both the app (`ScreenLock`) and the helper read the undocumented `CGSSessionScreenIsLocked` session key. The helper checks it before Face Unlock types anything, so it only ever types at the real lock screen.

When something breaks after a macOS update, these are the first places to look.

## Demo mode

Debug builds have a demo mode that fills the real views with made-up music, events, files and devices, so screenshots don't show anyone's own data. It's driven from the command line with distributed notifications. `App/DemoMode.swift` lists the commands. Nothing is saved while it's on, and it doesn't exist in release builds.
