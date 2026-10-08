# Security Policy

## Supported Versions

Only the latest release (and the `main` branch) receives security fixes.

## Reporting a Vulnerability

Security bugs in Notch are taken seriously, and responsible disclosure is appreciated.

To report a security issue privately, use **Report a vulnerability** on this repository's [Security tab](https://github.com/aryan-cs/notch/security). Please don't open a public issue for it. You'll get a reply with next steps, and updates as a fix comes together.

Notch is a fork of [boring.notch](https://github.com/TheBoredTeam/boring.notch). If the problem is also in the original app, please report it to them as well.

Report security bugs in third-party dependencies to the person or team maintaining the package or dependency.

## Security notes for contributors

### Private APIs

Notch uses some undocumented macOS APIs: the notch windows live in a private SkyLight window space (`Notch/Core/Window/CGSSpace.swift`), the Now Playing source reads the private `MediaRemote.framework` through the vendored [MediaRemoteAdapter](Vendor/MediaRemoteAdapter/README.md), and brightness control uses private DisplayServices and CoreBrightness symbols. These can change with any macOS update, which is also why Notch isn't on the App Store.

### The helper

The app runs in the App Sandbox (`Notch/App/Notch.entitlements`), but its bundled XPC service, NotchHelper (`NotchHelper/NotchHelper.entitlements`), does not. A sandboxed app can't use the Accessibility API on other apps, load the private frameworks above, read Notification Center, or type at the lock screen, so that work happens in the helper. It exposes one typed protocol (`Shared/NotchHelperProtocol.swift`) and is only reachable by the app it ships in. Treat it as the most trusted part of the code when reviewing: its attack surface is that protocol plus the Accessibility API.

### Face Unlock

The helper stores the Mac password Face Unlock types in `~/Library/Application Support/theboringteam.boringnotch/faceunlock.secret`, readable only by your account. It's scrambled but not encrypted with a secret key, so other code running as you could read it, just as it could read most of your files. The helper only accepts a password after checking it against your account, and only types it when the screen is actually locked. The [guide](GUIDE.md#before-you-rely-on-it) explains the limits to users.

### Bundled binaries

`Vendor/MediaRemoteAdapter/` holds binaries built from [ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter); its [README](Vendor/MediaRemoteAdapter/README.md) has the pinned version and how to rebuild them. `Vendor/AppleDevicesTools/` holds the device battery tool built by `Tools/notch-appledevices/build.sh` from [libimobiledevice](https://libimobiledevice.org).
