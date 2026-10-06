# Security Policy

## Supported Versions

Only the latest release (and the `main` branch) receives security fixes.

## Reporting a Vulnerability

Security bugs in Notch are taken seriously, and responsible disclosure is appreciated.

To report a security issue privately, use **Report a vulnerability** on this repository's [Security tab](https://github.com/aryan-cs/notch/security). Please don't open a public issue for it. You'll get a reply with next steps, and updates as a fix comes together.

Notch is a fork of [boring.notch](https://github.com/TheBoredTeam/boring.notch). If the problem is also in the original app, please report it to them as well.

Report security bugs in third-party dependencies to the person or team maintaining the package or dependency.

## Security Notes for Users and Contributors

### Private / undocumented APIs

Boring Notch uses private macOS APIs and frameworks to deliver features not
possible with the public SDK: the notch window lives in a private SkyLight
space (`boringNotch/private/`), media metadata comes from the private
`MediaRemote.framework` (via the vendored
[MediaRemoteAdapter](mediaremote-adapter/README.md)), and OSD display control
uses private DisplayServices/brightness symbols. These interfaces are
undocumented, may change with any macOS update, and the app may lose features
without warning when they do. This usage is also why the app is distributed
outside the App Store.

### XPC helper privilege model

The app is sandboxed (see `boringNotch/boringNotch.entitlements`), but its
bundled XPC service `BoringNotchXPCHelper`
(`BoringNotchXPCHelper/BoringNotchXPCHelper.entitlements`) is **not** —
sandboxed processes cannot drive the Accessibility API on other apps or load
private frameworks the app needs for notification/brightness features. The
helper is intentionally minimal: it exposes a narrow typed protocol
(`Shared/BoringNotchXPCHelperProtocol.swift`) and accepts connections only
from the bundled app. When auditing, treat the helper as the highest-trust
component in the repo: its attack surface is the XPC protocol plus the
Accessibility API.

### MediaRemote adapter binaries

`mediaremote-adapter/` contains vendored binaries built from
[ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter);
see its [README](mediaremote-adapter/README.md) for the pinned version,
rebuild instructions, and verification notes.
