# Contributing to Notch

Thanks for helping out. Bug reports, ideas and code are all welcome. This page covers how to build Notch, how to run the tests, and how to send a change. [ARCHITECTURE.md](ARCHITECTURE.md) explains how the code fits together, so read that before making larger changes.

## Reporting bugs and ideas

Open an [issue](https://github.com/aryan-cs/notch/issues/new/choose) and pick the bug report or feature request form. For bugs, the easiest way to start is **Report a Bug** in Notch's **Settings → About**, which fills in your app and macOS versions for you.

Please report security problems privately instead, as described in [SECURITY.md](SECURITY.md).

## Building

You'll need a Mac running macOS 14 or later and Xcode 26 or later.

```bash
git clone https://github.com/aryan-cs/notch.git
cd notch
open Notch.xcodeproj
```

Choose the **Notch** scheme and press **⌘R**. Swift packages download on the first build.

By default the app is signed to run locally. macOS remembers permissions like Accessibility and the camera by the app's signature, so with local signing you may be asked again after a rebuild. To avoid that, set your own team under **Signing & Capabilities** for both the Notch and NotchHelper targets.

If you already use Notch or the original Boring Notch, quit it before running your build. They share an app ID and settings, and only one copy should run at a time.

From the command line:

```bash
xcodebuild -project Notch.xcodeproj -scheme Notch -configuration Debug build
```

## Running the tests

Run them with **⌘U** in Xcode, or:

```bash
xcodebuild -project Notch.xcodeproj -scheme Notch test
```

The tests run inside a copy of the app, so quit any running Notch first. Tests that touch settings use their own temporary storage and leave yours alone.

New logic that doesn't need a window or the network, like parsing, matching rules or layout math, should come with a test in `NotchTests/`.

The sudo module is plain C and has its own tests, which don't install anything:

```bash
Tools/pam_notch-tests/run.sh
```

## Writing code

- Put new files in the folder for their feature. The folders are synchronized with Xcode, so there's no project file to edit. Don't put notes or scripts inside `Notch/`, because everything there is copied into the app.
- Name files after the main type inside them, and name types after what they do.
- Match the style of the code around you. A [SwiftLint](https://github.com/realm/SwiftLint) configuration is included if you want to run it: `swiftlint --config .swiftlint.yml`.
- Comments should explain why something is done, especially when it works around a macOS quirk. Skip comments that repeat what the code says.
- Log with `Log` (see `Shared/Log.swift`), not `print` or `NSLog`, and never log anything private.
- Write interface text the way the rest of the app does: short, plain and friendly. New strings are added to `Localizable.xcstrings` when you build in Xcode.
- Never change a settings key's string, a bundle ID or a saved file's location. [ARCHITECTURE.md](ARCHITECTURE.md#things-that-must-not-change) lists what would break.

## Sending a change

1. Fork the repository and create a branch from `main`.
2. Keep each commit focused on one thing, with a message that says what changed and why, like "Show the join button next to the event title".
3. Build, run and test your change on your own Mac.
4. Open a pull request against `main` and fill in the template. Screenshots or a short recording help a lot for anything visible.

## Making a release

This part is for maintainers.

1. Update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the project's build settings (select the Notch project, not a target). The build number must go up with every release.
2. Commit, then run:

   ```bash
   Scripts/release.sh
   ```

   It builds a universal, ad-hoc signed app, checks it, and writes `build/release/Notch.dmg`.
3. Open the disk image on a Mac and make sure the app launches.
4. Publish the release, with notes written for people who use the app:

   ```bash
   gh release create v1.2.3 build/release/Notch.dmg --target main --title "Notch 1.2.3" --notes-file notes.md
   ```

Releases are signed ad hoc, not with an Apple Developer ID, so the guide explains how to open Notch the first time.

## Code of conduct

Everyone taking part is expected to follow the [code of conduct](CODE_OF_CONDUCT.md).
