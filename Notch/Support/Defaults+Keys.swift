//
//  Defaults+Keys.swift
//  Notch
//
//  Created by Richard Kunkli on 2024. 10. 17..
//
//  Every setting Notch saves, as typed `Defaults` keys. The string in each
//  key is what's stored in UserDefaults, so never change it: renaming a key
//  string silently resets that setting for everyone.
//

import SwiftUI
import Defaults

enum PreferenceCompatibility {
    /// Runs before Defaults.Key registers its fallback, so a saved false is
    /// distinguishable from a missing value. Keep the old key for older builds.
    static func migratedKeyName(
        _ name: String,
        from legacyName: String,
        in defaults: UserDefaults = .standard
    ) -> String {
        if defaults.object(forKey: name) == nil,
           let legacyValue = defaults.object(forKey: legacyName) as? Bool {
            defaults.set(legacyValue, forKey: name)
        }
        return name
    }
}

extension Defaults.Keys {
    // MARK: General
    static let appLanguage = Key<AppLanguage>("appLanguage", default: .system)
    static let menubarIcon = Key<Bool>("menubarIcon", default: true)
    static let displayMode = Key<DisplayMode>("displayMode", default: .fallbackIfPreferredUnavailable)

    // Legacy display settings retained only for one-time migration.
    static let showOnAllDisplays = Key<Bool>("showOnAllDisplays", default: false)
    static let automaticallySwitchDisplay = Key<Bool>("automaticallySwitchDisplay", default: true)
    static let followActiveDisplay = Key<Bool>("followActiveDisplay", default: false)

    // MARK: Behavior
    static let minimumHoverDuration = Key<TimeInterval>("minimumHoverDuration", default: 0.3)
    static let enableOpeningAnimation = Key<Bool>("enableOpeningAnimation", default: true)
    static let animationSpeedMultiplier = Key<Double>("animationSpeedMultiplier", default: 1.0)
    static let enableHaptics = Key<Bool>("enableHaptics", default: true)
    static let openNotchOnHover = Key<Bool>("openNotchOnHover", default: true)
    static let notchHeightMode = Key<WindowHeightMode>(
        "notchHeightMode",
        default: WindowHeightMode.matchRealNotchSize
    )
    static let nonNotchHeightMode = Key<WindowHeightMode>(
        "nonNotchHeightMode",
        default: WindowHeightMode.matchMenuBar
    )
    static let nonNotchHeight = Key<CGFloat>("nonNotchHeight", default: 32)
    static let notchHeight = Key<CGFloat>("notchHeight", default: 32)
    // static let openLastTabByDefault = Key<Bool>("openLastTabByDefault", default: false)
    static let showOnLockScreen = Key<Bool>("showOnLockScreen", default: false)
    // Face Unlock
    static let faceUnlockEnabled = Key<Bool>("faceUnlockEnabled", default: false)
    static let faceUnlockThreshold = Key<Double>("faceUnlockThreshold", default: 0.4)
    static let faceUnlockLiveness = Key<LivenessLevel>("faceUnlockLiveness", default: .standard)
    /// Double-tap this modifier at the lock screen to scan again after a give-up.
    static let faceUnlockRetryKey = Key<FaceUnlockRetryKey>("faceUnlockRetryKey", default: .rightShift)
    /// Face Unlock for sudo: after a match, wait for the user to click Allow
    /// (or double-tap the retry key) instead of approving right away.
    static let faceUnlockSudoRequiresConfirmation = Key<Bool>("faceUnlockSudoRequiresConfirmation", default: true)
    static let hideFromScreenRecording = Key<Bool>("hideFromScreenRecording", default: false)

    // MARK: Appearance
    // static let alwaysShowTabs = Key<Bool>("alwaysShowTabs", default: true)
    static let showMirror = Key<Bool>("showMirror", default: false)
    static let isMirrored = Key<Bool>("isMirrored", default: true)
    static let mirrorShape = Key<MirrorShape>("mirrorShape", default: MirrorShape.rectangle)
    static let settingsIconInNotch = Key<Bool>("settingsIconInNotch", default: true)
    static let lightingEffect = Key<Bool>("lightingEffect", default: true)
    static let enableShadow = Key<Bool>("enableShadow", default: true)
    static let cornerRadiusScaling = Key<Bool>("cornerRadiusScaling", default: true)

    static let showNotHumanFace = Key<Bool>("showNotHumanFace", default: false)
    static let showCalendar = Key<Bool>("showCalendar", default: false)
    static let hideCompletedReminders = Key<Bool>("hideCompletedReminders", default: true)
    static let sliderColor = Key<SliderColor>(
        "sliderUseAlbumArtColor",
        default: SliderColor.white
    )
    static let playerColorTinting = Key<Bool>("playerColorTinting", default: true)

    // MARK: Gestures
    static let enableGestures = Key<Bool>("enableGestures", default: true)
    /// Sideways swipes on the closed notch (or the compact player) change songs.
    static let enableHorizontalMediaGestures = Key<Bool>("enableHorizontalMediaGestures", default: true)
    /// Sideways swipes on the open notch move between its tabs.
    static let swipeBetweenTabs = Key<Bool>("swipeBetweenTabs", default: true)
    static let closeGestureEnabled = Key<Bool>("closeGestureEnabled", default: true)
    static let gestureSensitivity = Key<CGFloat>("gestureSensitivity", default: 200.0)

    // MARK: Media playback
    static let coloredSpectrogram = Key<Bool>("coloredSpectrogram", default: true)
    static let realtimeAudioWaveform = Key<Bool>("realtimeAudioWaveform", default: false)
    static let enableSneakPeek = Key<Bool>("enableSneakPeek", default: false)
    static let sneakPeekStyles = Key<SneakPeekStyle>("sneakPeekStyles", default: .standard)
    static let waitInterval = Key<Double>("waitInterval", default: 3)
    static let enableLyrics = Key<Bool>("enableLyrics", default: false)
    static let showRemainingTime = Key<Bool>("showRemainingTime", default: false)
    static let musicControlSlots = Key<[MusicControlButton]>(
        "musicControlSlots",
        default: MusicControlButton.defaultLayout
    )
    static let musicControlSlotLimit = Key<Int>(
        "musicControlSlotLimit",
        default: MusicControlButton.defaultLayout.count
    )

    // MARK: Battery
    static let showPowerStatusNotifications = Key<Bool>("showPowerStatusNotifications", default: true)
    static let showBatteryIndicator = Key<Bool>("showBatteryIndicator", default: true)
    static let showBatteryPercentage = Key<Bool>("showBatteryPercentage", default: true)
    static let showPowerStatusIcons = Key<Bool>("showPowerStatusIcons", default: true)
    static let showChargingWattage = Key<Bool>("showChargingWattage", default: true)

    // MARK: Downloads

    // MARK: OSD
    static let osdReplacement = Key<Bool>(PreferenceCompatibility.migratedKeyName("osdReplacement", from: "hudReplacement"), default: false)
    static let inlineOSD = Key<Bool>(PreferenceCompatibility.migratedKeyName("inlineOSD", from: "inlineHUD"), default: false)

    // MARK: Layout
    /// Swaps the opened notch for a smaller, player-only layout: no tab
    /// bar, calendar or mirror. Off by default so existing users keep the
    /// layout they already have.
    static let compactMode = Key<Bool>("compactMode", default: false)

    // MARK: Notifications
    /// Off by default: mirroring banners needs Accessibility access.
    static let notificationLiveActivity = Key<Bool>("notificationLiveActivity", default: false)
    static let notificationsFromAllApps = Key<Bool>("notificationsFromAllApps", default: false)
    static let notificationAllowedApps = Key<Set<String>>(
        "notificationAllowedApps",
        default: []
    )
    static let enableGradient = Key<Bool>("enableGradient", default: false)
    static let systemEventIndicatorShadow = Key<Bool>("systemEventIndicatorShadow", default: false)
    static let systemEventIndicatorUseAccent = Key<Bool>("systemEventIndicatorUseAccent", default: false)
    static let showOpenNotchOSD = Key<Bool>(PreferenceCompatibility.migratedKeyName("showOpenNotchOSD", from: "showOpenNotchHUD"), default: true)
    static let showOpenNotchOSDPercentage = Key<Bool>(PreferenceCompatibility.migratedKeyName("showOpenNotchOSDPercentage", from: "showOpenNotchHUDPercentage"), default: true)
    static let showClosedNotchOSDPercentage = Key<Bool>(PreferenceCompatibility.migratedKeyName("showClosedNotchOSDPercentage", from: "showClosedNotchHUDPercentage"), default: false)
    // Option key modifier behaviour for media keys
    static let optionKeyAction = Key<OptionKeyAction>("optionKeyAction", default: OptionKeyAction.openSettings)
    // Brightness/volume/keyboard source selection
    static let osdBrightnessSource = Key<OSDControlSource>("osdBrightnessSource", default: .builtin)
    static let osdVolumeSource = Key<OSDControlSource>("osdVolumeSource", default: .builtin)

    // MARK: Shelf
    static let shelfEnabled = Key<Bool>("boringShelf", default: true)
    static let openShelfByDefault = Key<Bool>("openShelfByDefault", default: true)
    static let quickShareProvider = Key<String>("quickShareProvider", default: QuickShareProvider.defaultProvider.id)
    static let copyOnDrag = Key<Bool>("copyOnDrag", default: false)
    static let autoRemoveShelfItems = Key<Bool>("autoRemoveShelfItems", default: false)
    static let expandedDragDetection = Key<Bool>("expandedDragDetection", default: true)
    static let reverseShelfOrdering = Key<Bool>("reverseShelfOrdering", default: false)
    /// Convert, Remove BG, Zip and Unzip targets beside the shelf while files are dragged over it.
    static let shelfDropActions = Key<Bool>("shelfDropActions", default: true)

    // MARK: Devices
    /// Bluetooth devices and audio outputs, with battery where reported.
    static let showDevicesTab = Key<Bool>("showDevicesTab", default: true)
    /// JSON-encoded KnownAppleDevices: last readings of iPhones, iPads and watches.
    static let knownAppleDevices = Key<Data?>("knownAppleDevices", default: nil)
    /// Alert mode, toggled from the header: the presence guard only watches
    /// (Bluetooth, and the camera on suspicion) while this is on.
    static let alertMode = Key<Bool>("alertMode", default: false)
    /// How close a device has to come to count (a Bluetooth signal threshold).
    static let presenceSensitivity = Key<PresenceSensitivity>("presenceSensitivity", default: .medium)
    /// Focus is on because the presence guard turned it on. Kept across
    /// quits so the guard only ever turns off a Focus it turned on.
    static let presenceGuardTurnedFocusOn = Key<Bool>("presenceGuardTurnedFocusOn", default: false)

    // MARK: Window Snapping
    /// Drag a window into the notch to pick a layout for it. Moving the
    /// window needs Accessibility; with this off nothing watches the mouse.
    static let windowSnapping = Key<Bool>("windowSnapping", default: true)

    // MARK: Clipboard
    /// Off by default: it records everything you copy.
    static let clipboardHistory = Key<Bool>("clipboardHistory", default: false)
    /// Unpinned entries kept; pinned entries don't count toward it.
    static let clipboardHistoryLimit = Key<Int>("clipboardHistoryLimit", default: 50)
    static let clipboardPersistHistory = Key<Bool>("clipboardPersistHistory", default: true)
    /// Needs Accessibility to post ⌘V into the frontmost app.
    static let clipboardPasteOnSelect = Key<Bool>("clipboardPasteOnSelect", default: false)
    static let clipboardIgnoredApps = Key<Set<String>>("clipboardIgnoredApps", default: [])

    // MARK: Calendar
    static let calendarLayout = Key<CalendarLayout>("calendarLayout", default: .upNext)
    static let calendarSelectionState = Key<CalendarSelectionState>("calendarSelectionState", default: .all)
    static let hideAllDayEvents = Key<Bool>("hideAllDayEvents", default: false)
    static let hideDeclinedEvents = Key<Bool>("hideDeclinedEvents", default: true)
    static let showFullEventTitles = Key<Bool>("showFullEventTitles", default: false)
    static let weekStartDay = Key<WeekStartDay>("weekStartDay", default: .system)
    static let joinMeetingOnEventTap = Key<Bool>("joinMeetingOnEventTap", default: true)

    // MARK: Fullscreen Media Detection
    static let hideNotchOption = Key<HideNotchOption>("hideNotchOption", default: .nowPlayingOnly)

    // MARK: Media Controller
    static let mediaController = Key<MediaControllerType>("mediaController", default: defaultMediaController)
    static let didChooseMediaController = Key<Bool>("didChooseMediaController", default: false)
    static let didMigrateMediaControllerChoice = Key<Bool>("didMigrateMediaControllerChoice", default: false)
    static let lastSupportedNowPlayingBundleIdentifier = Key<String?>(
        "lastSupportedNowPlayingBundleIdentifier",
        default: nil
    )

    // MARK: Advanced Settings
    static let useCustomAccentColor = Key<Bool>("useCustomAccentColor", default: false)
    static let customAccentColorData = Key<Data?>("customAccentColorData", default: nil)
    // Show or hide the title bar
    static let hideTitleBar = Key<Bool>("hideTitleBar", default: true)
    static let hideNonNotchedFromMissionControl = Key<Bool>("hideNonNotchedFromMissionControl", default: true)
    // Normalize scroll/gesture direction so when macOS "Natural scrolling" is disabled, it doesn't invert gestures
    static let normalizeGestureDirection = Key<Bool>("normalizeGestureDirection", default: true)

    // Keep the default stable. Runtime availability is handled by MusicManager.
    static var defaultMediaController: MediaControllerType {
        .nowPlaying
    }

    static let didClearLegacyURLCacheV1 = Key<Bool>("didClearLegacyURLCache_v1", default: false)
}
