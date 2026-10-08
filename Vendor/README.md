# Vendor

Prebuilt third-party binaries that ship inside Notch. They're checked in so the app builds without extra tools.

- **MediaRemoteAdapter/** lets the Now Playing music source read what's playing system-wide. Apple blocks apps from using `MediaRemote.framework` directly, so this adapter runs it through a bundled Perl script. See its [README](MediaRemoteAdapter/README.md) for the version and how to rebuild it. BSD 3-Clause license.
- **AppleDevicesTools/** contains `notch-appledevices`, a small tool that reads battery levels from nearby iPhones, iPads and Apple Watches, plus the libimobiledevice libraries it needs. It ships inside NotchHelper. Its source and build script are in [Tools/notch-appledevices](../Tools/notch-appledevices). LGPL 2.1 license, included as `COPYING.libimobiledevice`.
