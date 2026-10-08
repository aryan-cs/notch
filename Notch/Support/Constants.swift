//
//  Constants.swift
//  boringNotch
//
//  Created by Richard Kunkli on 2024. 10. 17..
//

import SwiftUI
import Defaults

// MARK: - File System Paths
let bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "theboringteam.boringnotch"

let temporaryDirectory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    ?? URL(fileURLWithPath: NSTemporaryDirectory())
let spacing: CGFloat = 16

/// Which calendars (keyed by `calendarIdentifier`) the notch shows.
enum CalendarSelectionState: Codable, Equatable, Defaults.Serializable {
    case all
    /// Legacy allow-list. Calendars that appear later (e.g. a newly added Google
    /// account) stay hidden, so it's migrated to `.excluded` once calendars load.
    case selected(Set<String>)
    /// Everything except these calendars, so new accounts and calendars show up
    /// without a trip to Settings.
    case excluded(Set<String>)
}

enum HideNotchOption: String, Defaults.Serializable {
    case always
    case nowPlayingOnly
    case never
}

struct AppLanguage: RawRepresentable, Hashable, Identifiable, Defaults.Serializable {
    static let system = AppLanguage(rawValue: "system")

    var id: String { rawValue }
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static var allCases: [AppLanguage] {
        let languages = Bundle.main.localizations
            .filter(isSelectableLocalization)
            .map(AppLanguage.init(rawValue:))
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }

        return [.system] + languages
    }

    var displayName: String {
        if self == .system {
            return NSLocalizedString(
                "System default",
                comment: "Language picker option: follow the system app language"
            )
        }

        let displayName = nativeLocale.localizedString(forIdentifier: rawValue) ?? rawValue
        return displayName.capitalized(with: nativeLocale)
    }

    private var nativeLocale: Locale {
        Locale(identifier: rawValue)
    }

    private static func isSelectableLocalization(_ identifier: String) -> Bool {
        guard identifier != "Base" else { return false }
        guard let url = Bundle.main.url(
            forResource: "Localizable",
            withExtension: "strings",
            subdirectory: nil,
            localization: identifier
        ) else {
            return false
        }

        guard
            let data = try? Data(contentsOf: url),
            let strings = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: String]
        else {
            return false
        }

        return strings.values.contains { !$0.isEmpty }
    }

    func applyAppleLanguagesOverride() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
        UserDefaults.standard.synchronize()
    }
}

enum DisplayMode: String, Codable, CaseIterable, Identifiable, Defaults.Serializable {
    case preferredDisplay
    case fallbackIfPreferredUnavailable
    case activeDisplay
    case allDisplays

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .preferredDisplay:
            "Use preferred display"
        case .fallbackIfPreferredUnavailable:
            "Automatically switch display if preferred is unavailable"
        case .activeDisplay:
            "Always follow active display"
        case .allDisplays:
            "Show on all displays"
        }
    }
}

// macOS 27 renamed the "Accessibility" privacy pane to "Device Control and
// Data Access". Read the name from Apple's private UniversalAccess auth-warn
// prompt bundle so it matches what the user sees in System Settings, falling
// back to the localized catalog strings.
enum AccessibilityPermission {
    static var displayName: String {
        if let appleName = appleLocalizedAccessibilityName() {
            return appleName
        }
        if #available(macOS 27, *) {
            return String(localized: "Device Control and Data Access")
        } else {
            return String(localized: "Accessibility")
        }
    }

    static var systemImageName: String {
        if #available(macOS 27, *) {
            return "folder.badge.gearshape"
        } else {
            return "accessibility"
        }
    }

    private static let osLocalizationPath =
        "/System/Library/PrivateFrameworks/UniversalAccess.framework/Versions/A/Resources/universalAccessAuthWarn.app/Contents/Resources/Localizable.loctable"

    private static let osPermissionKey = "window.title.accessibility"

    private static let osLocalizedNameTables: [String: [String: String]]? = {
        guard let plist = NSDictionary(contentsOfFile: osLocalizationPath) else {
            return nil
        }
        var tables: [String: [String: String]] = [:]
        for (key, value) in plist {
            guard let locale = key as? String, let entries = value as? [String: Any] else {
                continue
            }
            tables[locale] = entries.compactMapValues { $0 as? String }
        }
        return tables
    }()

    private static func appleLocalizedAccessibilityName() -> String? {
        guard let tables = osLocalizedNameTables else {
            return nil
        }
        for locale in preferredLocaleCandidates {
            if let name = tables[locale]?[osPermissionKey] {
                return name
            }
        }
        return tables["en"]?[osPermissionKey]
    }

    private static var preferredLocaleCandidates: [String] {
        let preferred = Bundle.main.preferredLocalizations + Locale.preferredLanguages
        var candidates: [String] = []
        for preference in preferred {
            let identifier = preference.replacingOccurrences(of: "-", with: "_")
            candidates.append(identifier)
            if identifier.hasPrefix("zh_Hans") {
                candidates.append("zh_CN")
            } else if identifier.hasPrefix("zh_Hant") {
                candidates.append("zh_TW")
                candidates.append("zh_HK")
            }
            if let language = identifier.split(separator: "_", maxSplits: 1).first {
                candidates.append(String(language))
            }
        }
        return candidates
    }
}

// Define notification names at file scope
extension Notification.Name {
    // MARK: - Display
    static let selectedScreenChanged = Notification.Name("SelectedScreenChanged")
    static let notchHeightChanged = Notification.Name("NotchHeightChanged")
    static let showOnAllDisplaysChanged = Notification.Name("showOnAllDisplaysChanged")
    static let automaticallySwitchDisplayChanged = Notification.Name("automaticallySwitchDisplayChanged")

    // MARK: - Shelf
    static let expandedDragDetectionChanged = Notification.Name("expandedDragDetectionChanged")

    // MARK: - System
    static let accessibilityAuthorizationChanged = Notification.Name("accessibilityAuthorizationChanged")

    // MARK: - Sharing
    static let sharingDidFinish = Notification.Name("com.boringNotch.sharingDidFinish")

    // MARK: - UI
    static let accentColorChanged = Notification.Name("AccentColorChanged")
}

// Media controller types for selection in settings
enum MediaControllerType: String, CaseIterable, Identifiable, Defaults.Serializable {
    case nowPlaying
    case appleMusic
    case spotify
    case youtubeMusic

    var id: String { self.rawValue }

    init?(rawValue: String) {
        switch rawValue {
        case "nowPlaying", "Now Playing": self = .nowPlaying
        case "appleMusic", "Apple Music": self = .appleMusic
        case "spotify", "Spotify": self = .spotify
        case "youtubeMusic", "YouTube Music": self = .youtubeMusic
        default: return nil
        }
    }

    init?(nowPlayingBundleIdentifier bundleIdentifier: String) {
        switch bundleIdentifier {
        case "com.apple.Music":
            self = .appleMusic
        case "com.spotify.client":
            self = .spotify
        case YouTubeMusicConfiguration.default.bundleIdentifier:
            self = .youtubeMusic
        default:
            return nil
        }
    }

    var localizedResource: LocalizedStringResource {
        switch self {
        case .nowPlaying:
            "Now Playing"
        case .appleMusic:
            "Apple Music"
        case .spotify:
            "Spotify"
        case .youtubeMusic:
            "YouTube Music"
        }
    }

    var localizedString: String {
        String(localized: localizedResource)
    }
}

// Sneak peek styles for selection in settings
enum SneakPeekStyle: String, CaseIterable, Identifiable, Defaults.Serializable {
    case standard
    case inline

    var id: String { self.rawValue }

    init?(rawValue: String) {
        switch rawValue {
        case "standard", "Default": self = .standard
        case "inline", "Inline": self = .inline
        default: return nil
        }
    }

    var localizedString: String {
        switch self {
        case .standard:
            return String(localized: "Default", comment: "Sneak Peek style: Default")
        case .inline:
            return String(localized: "Inline", comment: "Sneak Peek style: Inline")
        }
    }
}

// Action to perform when Option (⌥) is held while pressing media keys
enum OptionKeyAction: String, CaseIterable, Identifiable, Defaults.Serializable {
    case openSettings
    case showOSD
    case none

    var id: String { self.rawValue }

    init?(rawValue: String) {
        switch rawValue {
        case "openSettings", "Open System Settings": self = .openSettings
        case "showOSD", "Show HUD": self = .showOSD
        case "none", "No Action": self = .none
        default: return nil
        }
    }

    var localizedString: String {
        switch self {
        case .openSettings:
            return String(localized: "Open System Settings", comment: "Option (⌥) key behavior: Open System Settings")
        case .showOSD:
            return String(localized: "Show OSD", comment: "Option (⌥) key behavior: Show OSD")
        case .none:
            return String(localized: "No action", comment: "Option (⌥) key behavior: No action")
        }
    }
}

// Source/provider for OSD control (user-facing: "Source")
enum OSDControlSource: String, CaseIterable, Identifiable, Defaults.Serializable {
    case builtin
    case betterDisplay = "BetterDisplay"
    case lunar = "Lunar"

    var id: String { self.rawValue }

    var localizedString: String {
        switch self {
        case .builtin:
            return String(localized: "Built-in", comment: "OSD Sources: Built-in")
        case .betterDisplay:
            return "BetterDisplay"
        case .lunar:
            return "Lunar"
        }
    }
}

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
    static let hideFromScreenRecording = Key<Bool>("hideFromScreenRecording", default: false)

    // MARK: Appearance
    // static let alwaysShowTabs = Key<Bool>("alwaysShowTabs", default: true)
    static let showMirror = Key<Bool>("showMirror", default: false)
    static let isMirrored = Key<Bool>("isMirrored", default: true)
    static let mirrorShape = Key<MirrorShapeEnum>("mirrorShape", default: MirrorShapeEnum.rectangle)
    static let settingsIconInNotch = Key<Bool>("settingsIconInNotch", default: true)
    static let lightingEffect = Key<Bool>("lightingEffect", default: true)
    static let enableShadow = Key<Bool>("enableShadow", default: true)
    static let cornerRadiusScaling = Key<Bool>("cornerRadiusScaling", default: true)

    static let showNotHumanFace = Key<Bool>("showNotHumanFace", default: false)
    static let showCalendar = Key<Bool>("showCalendar", default: false)
    static let hideCompletedReminders = Key<Bool>("hideCompletedReminders", default: true)
    static let sliderColor = Key<SliderColorEnum>(
        "sliderUseAlbumArtColor",
        default: SliderColorEnum.white
    )
    static let playerColorTinting = Key<Bool>("playerColorTinting", default: true)

    // MARK: Gestures
    static let enableGestures = Key<Bool>("enableGestures", default: true)
    static let enableHorizontalMediaGestures = Key<Bool>("enableHorizontalMediaGestures", default: true)
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
    static let boringShelf = Key<Bool>("boringShelf", default: true)
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
