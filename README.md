# Notch

Notch turns the notch at the top of your Mac's screen into a small control center. Move your pointer up to it and it opens into a panel with your music, your calendar, a shelf for files, your clipboard history, your Bluetooth devices, and more. It also replaces the volume and brightness pop-ups, can snap windows into place, and can unlock your Mac when it sees your face.

It works on Macs without a notch too. On those screens, and on external displays, Notch draws a small notch-shaped pill at the top of the screen instead.

Notch is a fork of [boring.notch](https://github.com/TheBoredTeam/boring.notch) by TheBoredTeam, with a lot of new features on top. A quick note on names: in this guide, **Notch** (capital N) is the app, and **the notch** is the area at the top of your screen.

## Contents

- [What it can do](#what-it-can-do)
- [Requirements](#requirements)
- [Installing](#installing)
- [Your first launch](#your-first-launch)
- [Getting around](#getting-around)
- [Features](#features)
  - [Music and media](#music-and-media)
  - [Volume and brightness](#volume-and-brightness)
  - [Battery](#battery)
  - [Calendar and meetings](#calendar-and-meetings)
  - [Shelf and quick file actions](#shelf-and-quick-file-actions)
  - [Clipboard history](#clipboard-history)
  - [Devices](#devices)
  - [Window snapping](#window-snapping)
  - [Mirror](#mirror)
  - [Notifications](#notifications)
  - [Face Unlock](#face-unlock)
  - [Alert mode](#alert-mode)
- [Displays, full screen, and the lock screen](#displays-full-screen-and-the-lock-screen)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [Privacy](#privacy)
- [Updating](#updating)
- [Troubleshooting](#troubleshooting)
- [Uninstalling](#uninstalling)
- [Building from source](#building-from-source)
- [Credits and license](#credits-and-license)

## What it can do

- **Music:** see what's playing and control it from the notch, with album art, a progress bar, optional lyrics, and controls you can rearrange.
- **Volume and brightness:** a cleaner on-screen display that lives in the notch instead of the middle of your screen.
- **Calendar:** your upcoming events and reminders, with a one-click button to join Zoom, Google Meet, Teams and other calls.
- **Shelf:** drop files on the notch to hold them for later, AirDrop them, or convert, zip and unzip them.
- **Clipboard history:** everything you've copied, ready to copy again. Password managers are skipped.
- **Devices:** battery levels for AirPods, Magic accessories, your iPhone, iPad and Apple Watch, plus one-click connecting and switching sound output.
- **Window snapping:** drag a window up into the notch and drop it on a layout.
- **Face Unlock:** look at your Mac's camera at the lock screen and it signs you in.
- **Alert mode:** notices when other people's Apple devices come close and turns on Do Not Disturb.
- **Mirror, notifications, battery status,** and more.

Every feature can be turned on or off in Settings, and many are off until you turn them on.

## Requirements

- macOS 14 Sonoma or later.
- Any Mac, with or without a notch.
- A few features have extra requirements:
  - **Face Unlock** needs a Mac with a built-in camera, like a MacBook or iMac. It doesn't use external webcams, on purpose (see [Face Unlock](#face-unlock)).
  - **iPhone, iPad and Apple Watch battery levels** need an Apple Silicon Mac.
  - **The live audio waveform** in the music player needs macOS 14.2 or later.

## Installing

1. Download **Notch.dmg** from the [latest release](https://github.com/aryan-cs/notch/releases/latest).
2. Open it and drag **Notch** onto the **Applications** folder.
3. Eject the disk image in Finder, then open Notch from your Applications folder.

Opening the app straight from the disk image doesn't install it, so make sure you copy it first.

### "Notch can't be opened" on first launch

Notch isn't notarized by Apple, so the first time you open it macOS will say it can't verify the app. That's expected, and you only have to get past it once. There are two ways.

**Using Terminal (most reliable).** After copying Notch to Applications, run this, then open the app normally:

```bash
xattr -dr com.apple.quarantine /Applications/Notch.app
```

**Using System Settings.** Try to open Notch and dismiss the warning. Then open **System Settings → Privacy & Security**, scroll to the bottom, and click **Open Anyway** next to the message about Notch. Confirm when asked. This doesn't work for every account (for example, non-admin users), so use Terminal if it doesn't.

### If you already use Boring Notch

Notch uses the same app ID as the original Boring Notch, so macOS treats them as the same app. Running both at once won't work, and they share settings. Quit Boring Notch and delete it before installing Notch.

## Your first launch

The first time Notch opens, it walks you through a short setup. Each screen explains one permission and has **Allow Access** and **Not Now** buttons. You can skip any of them and turn them on later; the feature that needs a permission will offer a button to grant it. When it's done, you'll see "You're All Set!"

Here's what each permission is for, so you can decide what to allow:

| Permission | What uses it |
|---|---|
| Camera | Mirror, Face Unlock, and Alert mode's quick face check |
| Calendars and Reminders | The Calendar tab |
| Accessibility | Replacing the volume and brightness display, window snapping, showing notifications in the notch, pasting from the clipboard history, Face Unlock typing your password, and opening the system Battery menu |
| Bluetooth | The Devices view and Alert mode |
| Audio recording | The live audio waveform in the music player (macOS 14.2 and later) |
| Automation | Controlling Apple Music and Spotify directly, if you choose them as your music source |

Accessibility is the one most features rely on. On the newest versions of macOS it may appear under a different name, such as **Device Control and Data Access**. Notch always shows you the name your Mac uses.

## Getting around

**Opening the notch.** Move your pointer up to the notch and it opens after a short moment. You can also click it, swipe down on it with two fingers, or press **⇧⌘I**.

**Closing it.** Move your pointer away, swipe up with two fingers, or press **⇧⌘I** again.

**Tabs.** The open notch has tabs along the top left. **Home** is always there and shows your music. **Calendar**, **Shelf** and **Clipboard** appear when you turn those features on.

**Buttons.** On the top right of the open notch you'll find, depending on what's turned on:

- a camera button for [Mirror](#mirror)
- a shield for [Alert mode](#alert-mode)
- a gear that opens Settings
- headphones for [Devices](#devices)
- your battery level

**The closed notch.** Even when it's closed, the notch shows things that need your attention: charging changes, the volume or brightness level as you change it, what's playing, and notifications if you've turned them on. When music is showing, swipe left or right on the notch to skip tracks.

**Settings.** Notch doesn't put an icon in the Dock. Open Settings from the sparkle icon in the menu bar, from the gear in the open notch, or by right-clicking the notch. The menu bar icon also has **Check for Updates…**, **Restart Notch** and **Quit**. If you hide the menu bar icon in Settings → General, you can still reach Settings from the notch.

**Settings → General** is also where you'll find **Launch at login**, the language, and which display the notch appears on.

## Features

### Music and media

Notch shows what's playing on your Mac: album art, the song and artist, a progress bar, and playback controls. Click the album art to jump to the app that's playing. When music changes, a "sneak peek" can briefly show the new song under the closed notch.

**Choosing a music source.** In **Settings → Media**, pick a **Music Source**:

- **Now Playing** (the default) works with almost any app that plays audio, including browsers.
- **Apple Music** and **Spotify** control those apps directly, which adds extras like favoriting and volume. macOS will ask for Automation permission the first time.
- **YouTube Music** works with the [YouTube Music desktop app](https://github.com/th-ch/youtube-music), not the website.

**Changing the controls.** Under **Media controls** you can choose which five buttons appear in the player. Drag a control onto a slot, or click it. The choices are Shuffle, Previous, Play/Pause, Next, Repeat, Favorite, Volume, Backward 15s, Forward 15s, and Audio output. **Reset to Defaults** puts things back. Favorite works with Apple Music and YouTube Music. Volume works when you're using Apple Music or Spotify.

**Other options on the same page:**

- **Show lyrics below artist name** shows the current line of the song, fetched from lrclib.net.
- **Show sneak peek on playback changes** turns the song pop-up on or off, and **Sneak Peek Style** chooses whether it appears under the notch or inside it. Press **⇧⌘H** to show it any time.
- **Real-time audio waveform** animates a waveform to the music. It needs macOS 14.2 and the audio recording permission.
- **Full screen behavior** decides whether the notch hides while an app is full screen.
- **Slider color**, **Player tinting** and the blur behind the album art change how the player looks.

### Volume and brightness

Notch can replace macOS's volume, brightness and keyboard backlight pop-ups with a slimmer display in the notch. You can also drag the bar to set the level.

**To turn it on:** go to **Settings → OSD**, turn on **Replace System OSD**, and grant Accessibility if asked. Notch needs Accessibility here so it can see your volume and brightness keys. Turn on **Use inline style** to show the level inside the closed notch instead of below it.

**Good to know:**

- If you use [BetterDisplay](https://betterdisplay.pro) or [Lunar](https://lunar.fyi) for external displays, choose them as the **Brightness Source** (BetterDisplay also works as a **Volume Source**). They need to be installed and running.
- Holding **Option** while pressing a volume or brightness key normally opens the matching System Settings page. You can change that under **Option (⌥) Key Behavior**.
- Hold **Option and Shift** while pressing the keys to change the level in smaller steps.

### Battery

The open notch shows your battery level in the top right. When you plug in, unplug, finish charging, or switch Low Power Mode, the closed notch briefly widens to tell you.

Click the battery icon to open the same Battery menu you'd get from the menu bar. That needs Accessibility, and the system's battery icon has to be visible in your menu bar. If either is missing, Notch shows its own battery panel instead, with the battery's maximum capacity, the time until full or empty, and a button to open Battery settings.

You can hide the indicator, the percentage, the charging wattage, or the power alerts in **Settings → Battery**.

### Calendar and meetings

The Calendar tab shows your upcoming events and reminders, so you can see what's next without opening Calendar.

**To set it up:**

1. Open **Settings → Calendar** and turn on **Show calendar**. It's off by default.
2. Allow calendar and reminders access when macOS asks.
3. Choose a **Layout**:
   - **Up next** shows a card for your next event, with the rest of the week beside it.
   - **Month and agenda** shows a small month view. Click a day to see the week from that day.
   - **Multi-day** shows four days side by side.
4. Under **Calendars** and **Reminders**, turn off any lists you don't want to see.

Notch shows whatever is in the macOS Calendar and Reminders apps, including iCloud, Exchange and Google. To add a Google account, use **System Settings → Internet Accounts**; there's a shortcut button on the Calendar settings page. If you rename a Google account to something like "Work", Notch may stop recognizing it as Google, which mostly matters for opening Meet links in the right account.

**Joining meetings.** If an event has a Zoom, Google Meet, Microsoft Teams, Webex, Whereby or Jitsi link, it gets a green video button. Click it to join. With **Join meeting when tapping an event** turned on, clicking anywhere on the event joins too. Right-click an event for **Open in Calendar** and **Copy Meeting Link**.

Other options let you hide all-day events, declined events and completed reminders, and always show full event titles.

### Shelf and quick file actions

Drag files to the notch and it opens with three drop areas:

- **AirDrop** (or another share service you choose) sends files right away.
- **The shelf** holds files for later. Drag them back out whenever you need them.
- **Quick actions** appear when they make sense for what you're dragging:
  - **Convert:** images to JPEG, PNG, HEIC or TIFF, and video to MP4, MOV or audio-only M4A. Rest on Convert for a moment to pick a format.
  - **Remove BG:** cuts the subject out of a photo.
  - **Zip** and **Unzip**.

Results from quick actions land on the shelf, and your originals are never changed. These results are temporary copies, so drag them out to Finder or another app to keep them; they're deleted when you remove them from the shelf.

Right-click anything on the shelf for more: open, show in Finder, Quick Look, share, rename, copy its path, or convert and compress it.

Shelf options are in **Settings → Shelf**, including whether dragging copies or moves items, and which share service to use.

### Clipboard history

Notch can remember the things you copy, so you can grab something from earlier without copying it again. It keeps text, images, links to files you copied, and colors.

**To set it up:**

1. Open **Settings → Clipboard** and turn on **Enable clipboard history**.
2. Choose a **History size** (50 items by default). Pinned items don't count toward it.
3. Optionally, set a keyboard shortcut in **Settings → Shortcuts → Open Clipboard History**. There's no shortcut by default.

**Using it.** Open the **Clipboard** tab in the notch, or press your shortcut. Click an item to copy it again, then paste with **⌘V**. If you turn on **Paste into the active app when you choose an item** (this needs Accessibility), Notch pastes it for you. Hover an item to pin or delete it, or right-click for more. The eyedropper button picks a color from anywhere on your screen and saves it, and right-clicking a color lets you copy it as hex, RGB, HSL, or SwiftUI and AppKit code.

**Privacy.** Notch never records copies that password managers mark as private, and it ignores anything you copy while Keychain Access, Passwords, 1Password, Bitwarden or KeePassXC is in front. You can add more apps under **Ignored Apps**. History is saved on your Mac only, without encryption, so use **Clear History…** or turn off **Keep history after quitting** if you'd rather not keep it.

### Devices

Click the headphones in the open notch to see your devices as a row of cards with battery rings. It includes:

- Bluetooth devices paired with your Mac, like AirPods, Beats, and Magic Keyboard, Mouse and Trackpad. AirPods show the left bud, the right bud and the case.
- Your Mac's sound outputs. On a MacBook, the built-in speakers card shows your Mac's own battery.
- Your iPhone and iPad, and an Apple Watch paired with that iPhone.

Click a disconnected device to connect it. Audio devices switch your sound to themselves when they connect. Right-click a card to disconnect it, play sound through it, find it in Find My, or open Bluetooth settings. New devices have to be paired in Bluetooth settings first.

**iPhone, iPad and Apple Watch.** These are read over a USB cable or your Wi-Fi network, about once a minute, on Apple Silicon Macs. The first time, plug your iPhone in with a cable and tap **Trust** on the phone if it asks. Notch then turns on the iPhone's "show on Wi-Fi" sync setting, the same one Finder uses, so later readings work without the cable. If a device can't be reached, its card stays dimmed with its last known level for up to a week.

Notch asks for Bluetooth permission the first time you open Devices. Battery levels only appear for devices that report them, which many speakers don't. You can hide the headphones button in **Settings → Devices**.

### Window snapping

Drag a window by its title bar and push your pointer up into the notch. The notch opens into a grid of layouts: halves, thirds, quarters, and full screen. Let go over one and the window fills that part of the screen. Move away from the notch to cancel.

This needs Accessibility, so Notch can move other apps' windows. Turn it on or off with **Snap windows dragged to the notch** in **Settings → Notch**. Windows that can't be resized are moved but keep their size.

### Mirror

Mirror shows a small live view from your camera in the open notch, handy for checking your hair before a call.

Turn on **Enable boring mirror** in **Settings → Mirror** and choose a camera and shape. Then click the camera button in the open notch to start or stop it. Notch asks for camera access the first time.

### Notifications

Notch can show notification banners in the notch instead of the corner of your screen. The app's icon appears in the closed notch with a small pulsing dot, and opening the notch shows the full notification. Click it to open the app, or click × to dismiss it.

**To set it up:** go to **Settings → Notifications**, turn on **Show notifications in the notch**, and grant Accessibility. Then either turn on **From all apps** or use **Add Application…** to choose specific apps. Nothing is shown until you do one or the other.

Notch only copies banners that actually appear on your screen, so notifications hidden by Focus or set to not show banners won't appear here either.

### Face Unlock

Face Unlock signs you in at the lock screen when it sees your face, like Face ID on an iPhone. When your screen locks, the camera turns on and a Face ID box appears. If it recognizes you, it shows a green checkmark and unlocks your Mac.

**How it works.** Notch learns your face from a few camera frames and keeps only a numeric fingerprint of it, never photos. When you unlock, it enters your Mac password for you, the same as typing it. That's why it needs your password and Accessibility permission.

**Setting it up:**

1. Open **Settings → Face Unlock** and turn on **Face Unlock**.
2. Under **Your Face**, click **Set Up Face**. Look at the camera and slowly turn your head a little until the progress bar fills. Do this in the lighting you usually work in.
3. Click **Try It** to check that it recognizes you. If it struggles somewhere darker or brighter, go there and click **Improve Recognition**.
4. Under **Mac Password**, type your Mac login password and click **Save Password**. Notch checks it against your account before saving, so a typo is caught right away.
5. Under **Access**, make sure **Camera** and **Accessibility** both have a green check. Click **Allow** next to either one if not.

If anything is missing, an orange note under the Face Unlock switch tells you what's left.

**Using it.** Lock your Mac (for example with **Control-Command-Q**) and look at the screen. The Face ID box appears once the camera is on, and the camera light turns on with it. It looks for you for about five seconds. If it doesn't recognize you, the box shakes and goes away and the camera turns off, so you can type your password as usual. To have it look again, double-tap **Right Shift**. You can change that key, or turn it off, under **Lock Screen → Try again**.

**Security settings.** Under **Security**:

- **Photo protection** guards against someone holding up a picture of you. **Standard** (the default) waits for a blink or a small head movement. **Strict** waits for a blink. **Off** only checks that the face matches.
- **Matching** slides from **Easier** to **Stricter**. Stricter is harder for someone else to pass, but may need better lighting to recognize you.

**Please read before you rely on it:**

- Face Unlock is a convenience, not extra security. It uses your Mac's regular camera, not a depth sensor like Face ID, so a good video of you could get past it. If that's a concern, don't turn it on.
- Your password is saved on your Mac, in a file only your user account can read. It's scrambled, but not protected the way the macOS Keychain protects passwords, so any program running as you could read it. It's only ever used to unlock your screen.
- If you change your Mac password, update it in **Settings → Face Unlock → Mac Password → Change**. Otherwise Face Unlock will enter your old password and the attempt will fail.
- It only uses your Mac's built-in camera. External webcams, Continuity Camera and virtual cameras are ignored, so that a recording can't be played into it through a fake camera.
- It works at the lock screen while you're logged in. After a restart, or when you log in from scratch, you'll still type your password once, because Notch isn't running yet.

### Alert mode

Alert mode is for when you don't want someone reading your screen. While you're at your Mac, it listens over Bluetooth for nearby Apple devices like iPhones, Watches and AirPods. When more show up than usual, the camera does a quick two- to three-second check for a second face. If it finds one, Notch turns on Do Not Disturb until they leave, so notifications don't pop up for them to read.

macOS doesn't let apps switch Focus directly, so Alert mode uses two shortcuts that you create once in the Shortcuts app.

**Creating the shortcuts:**

1. Open the **Shortcuts** app and create a new shortcut.
2. Name it exactly **Notch Focus On**.
3. Add the **Set Focus** action and set it to turn **Do Not Disturb** **On**.
4. Create a second shortcut named exactly **Notch Focus Off**, with **Set Focus** turning **Do Not Disturb** **Off**.

The names have to match exactly. In **Settings → Alert Mode → Focus Shortcuts**, click the refresh button and both should show as found.

**Turning it on.** Click the shield in the open notch, or turn on **Alert mode** in **Settings → Alert Mode**, and allow Bluetooth and camera access. At first it learns how many devices are normally around you. If your own iPhone, Watch or AirPods are being counted as visitors, click **Recalibrate** while you're alone. **Sensitivity** sets how close a device has to be, from about arm's length on Low to two or three meters on High.

**Good to know:**

- It pauses when you step away (after three minutes with no input), when your screen is locked or asleep, and when Bluetooth is off.
- Do Not Disturb turns off 30 seconds after the extra devices leave. Turning Alert mode off also turns Do Not Disturb off, but only if Alert mode turned it on.
- It can only notice Apple devices, and only ones that are awake or in use.
- The camera is used for at most one short check a minute, and the frames are never saved.

## Displays, full screen, and the lock screen

**Which screen.** In **Settings → General → Display behavior**, choose whether the notch appears on your preferred display, follows whichever display you're using, or shows on all of them. With **Show on all displays**, **⇧⌘I** opens the notch on the screen your pointer is on.

**Screens without a notch.** On external displays and Macs without a notch, Notch draws a pill at the top center. You can match it to the menu bar height or set a custom height in **Settings → Notch → Sizing**. The same page has the size for real notches, hover and animation timing, haptic feedback, gestures, and **Compact mode**, which shows a smaller notch with just the music player.

**Full screen.** **Settings → Media → Full screen behavior** decides whether the notch hides when apps go full screen: for all apps, only for your media app, or never.

**Screenshots.** Turn on **Hide from screen recording** in **Settings → Notch** to keep the notch out of screenshots and screen recordings.

**Lock screen.** Turn on **Show notch on lock screen** in **Settings → Notch** to keep the notch visible while your Mac is locked. Face Unlock's Face ID box appears either way.

## Keyboard shortcuts

You can change any of these in **Settings → Shortcuts**.

| Shortcut | What it does |
|---|---|
| ⇧⌘I | Opens or closes the notch |
| ⇧⌘H | Shows the sneak peek of the current song |
| Not set by default | Opens the notch on the Clipboard tab |
| Double-tap Right Shift (at the lock screen) | Makes Face Unlock look for you again |

## Privacy

Notch doesn't include analytics, tracking or crash reporting, and it doesn't have an account. Almost everything it does stays on your Mac:

- **Camera.** The camera is only on while you use Mirror, during Face Unlock's few seconds at the lock screen or its setup in Settings, and during Alert mode's short face checks. Frames are processed in memory and never saved or sent anywhere.
- **Face Unlock.** It stores a numeric fingerprint of your face, not photos, plus your password in a file only your user account can read (see [Face Unlock](#face-unlock)).
- **Clipboard history** is saved on your Mac only, and password managers are skipped.
- **Calendars, reminders and notifications** are read on your Mac and never uploaded.

Notch connects to the internet only for:

- **Lyrics**, if you turn them on. It asks lrclib.net for the lyrics of the song that's playing.
- **A small animation** used by the music player, downloaded from LottieFiles.
- **Check for Updates…** and the links on the About page, which open GitHub in your browser.

The YouTube Music source talks to the YouTube Music app on your own Mac, not the internet. Reading your iPhone's battery over Wi-Fi turns on the iPhone's Wi-Fi sync setting (see [Devices](#devices)).

## Updating

Notch doesn't update itself. To get a new version, choose **Check for Updates…** from the menu bar icon (or click **View Releases** in **Settings → About**), which opens the [releases page](https://github.com/aryan-cs/notch/releases). Download the new **Notch.dmg**, quit Notch, and replace the app in your Applications folder. Your settings, enrolled face and saved password stay where they are.

Because releases aren't signed with an Apple Developer ID, macOS may treat an update as a new app. It may ask for some permissions again, and you'll need to get past the first-launch warning again using either method from [Installing](#installing). If something that needs a permission stops working after an update, open **System Settings → Privacy & Security**, find the permission (usually Accessibility), and turn Notch off and on again.

## Troubleshooting

**The notch doesn't open when I hover.** Check that **Open notch on hover** is on in **Settings → Notch**. If you turned it off, click the notch or swipe down on it instead. If nothing responds at all, choose **Restart Notch** from the menu bar icon.

**The volume or brightness pop-up is still the macOS one.** Turn on **Replace System OSD** in **Settings → OSD** and make sure Notch has Accessibility. Brightness for external displays needs BetterDisplay or Lunar.

**No music is showing.** Try another **Music Source** in **Settings → Media**. If you picked Apple Music or Spotify, make sure you allowed Automation when asked. You can check in **System Settings → Privacy & Security → Automation**.

**My calendar is empty.** Turn on **Show calendar** in **Settings → Calendar**, allow calendar access, and check that your calendars are turned on in the list. Notch only shows calendars that are in the macOS Calendar app.

**Face Unlock doesn't start when I lock my Mac.** Open **Settings → Face Unlock**. If there's an orange note under the switch, it tells you what's missing: your face, your password, camera access or Accessibility. Face Unlock also needs a built-in camera and won't run with the lid closed.

**Face Unlock has trouble recognizing me.** Click **Improve Recognition** in the lighting where it struggles. Make sure your face is well lit from the front, not just by a window behind you. You can also move **Matching** a little toward **Easier**.

**Face Unlock recognizes me but doesn't unlock.** Check that Accessibility has a green check in **Settings → Face Unlock → Access**. If you changed your Mac password, save the new one under **Mac Password**.

**Alert mode never turns on Do Not Disturb.** Make sure both shortcuts exist with exactly the right names and show as found in **Settings → Alert Mode**, and that camera and Bluetooth have green checks.

**Something stopped working after an update.** See [Updating](#updating). Usually turning the Accessibility permission off and on again fixes it.

**Something else.** Use **Report a Bug** in **Settings → About**, which opens an issue with your app and macOS versions filled in, or [open an issue](https://github.com/aryan-cs/notch/issues) directly.

## Uninstalling

1. Choose **Quit** from the Notch menu bar icon.
2. Drag **Notch** from your Applications folder to the Trash.
3. To also remove its data, delete these folders. In Finder, press **Shift-Command-G** and paste each path:
   - `~/Library/Containers/theboringteam.boringnotch` (settings, clipboard history, your enrolled face)
   - `~/Library/Application Support/theboringteam.boringnotch` (the password saved for Face Unlock)
4. Optionally, remove Notch from the lists in **System Settings → Privacy & Security**, such as Accessibility.

## Building from source

You'll need Xcode 26 or later.

```bash
git clone https://github.com/aryan-cs/notch.git
cd notch
open boringNotch.xcodeproj
```

Choose the **boringNotch** scheme and press **⌘R** to build and run. Xcode signs the app to run locally by default. If you set your own development team under **Signing & Capabilities**, permissions you grant will survive rebuilds.

A couple of things in the repository are worth knowing:

- The Face Unlock model, `boringNotch/components/FaceUnlock/adaface_ir50.mlpackage`, is about 87 MB, so the first clone takes a little longer.
- The iPhone, iPad and Apple Watch battery reader is a small tool built on libimobiledevice, prebuilt in `AppleDevicesTools`. To rebuild it, install `libimobiledevice` with Homebrew and run `Configuration/apple-devices/build.sh`.

## Credits and license

Notch is built on [boring.notch](https://github.com/TheBoredTeam/boring.notch) by TheBoredTeam and its contributors, who created the app this is based on. If you like the original, consider [supporting them](https://www.ko-fi.com/alexander5015).

It also relies on these open-source projects, among others:

- [MediaRemoteAdapter](https://github.com/ungive/mediaremote-adapter), for the Now Playing music source on recent macOS versions.
- [NotchDrop](https://github.com/Lakr233/NotchDrop), which inspired the first version of the shelf.
- [libimobiledevice](https://libimobiledevice.org), for reading iPhone, iPad and Apple Watch batteries. It's licensed under the LGPL 2.1, and its license is included in `AppleDevicesTools`.
- [AdaFace](https://github.com/mk-minchul/AdaFace), the face recognition model behind Face Unlock, converted to Core ML.

See [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES) for the other licenses and attributions.

Notch is free software under the [GNU General Public License v3.0](LICENSE), the same license as boring.notch.
