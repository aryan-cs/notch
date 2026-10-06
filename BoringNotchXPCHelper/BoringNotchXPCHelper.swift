//
//  BoringNotchXPCHelper.swift
//  BoringNotchXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import AppKit
import ApplicationServices
import CoreGraphics
import CryptoKit
import IOKit
import OpenDirectory
import Security

class BoringNotchXPCHelper: NSObject, BoringNotchXPCHelperProtocol {
    private weak var connection: NSXPCConnection?

    private let lunarStateQueue = DispatchQueue(label: "BoringNotchXPCHelper.lunar.state")
    private let lunarExecutableURL = URL(fileURLWithPath: "/Applications/Lunar.app/Contents/MacOS/Lunar")
    private var lunarProcess: Process?
    private var lunarPipeHandler: JSONLinesPipeHandler?
    private var lunarStreamTask: Task<Void, Never>?
    private var lunarListener: BoringNotchXPCHelperLunarListener?

    init(connection: NSXPCConnection) {
        self.connection = connection
        super.init()
    }

    override init() {
        super.init()
    }

    deinit {
        var processToTerminate: Process?
        var taskToCancel: Task<Void, Never>?
        var pipeHandlerToClose: JSONLinesPipeHandler?

        lunarStateQueue.sync {
            processToTerminate = self.lunarProcess
            self.lunarProcess = nil

            taskToCancel = self.lunarStreamTask
            self.lunarStreamTask = nil

            pipeHandlerToClose = self.lunarPipeHandler
            self.lunarPipeHandler = nil

            self.lunarListener = nil
        }

        taskToCancel?.cancel()
        if let p = processToTerminate, p.isRunning { p.terminate() }
        if let ph = pipeHandlerToClose {
            Task { await ph.close() }
        }
    }

    @objc func isAccessibilityAuthorized(with reply: @escaping (Bool) -> Void) {
        reply(AXIsProcessTrusted())
    }

    @objc func migrateLegacyAppBundle(
        from sourcePath: String,
        to destinationPath: String,
        with reply: @escaping (Bool) -> Void
    ) {
        let sourceURL = URL(fileURLWithPath: sourcePath).standardizedFileURL
        let destinationURL = URL(fileURLWithPath: destinationPath).standardizedFileURL
        let fileManager = FileManager.default

        guard sourceURL.lastPathComponent == BoringNotchAppBundleNames.legacy,
              destinationURL.lastPathComponent == BoringNotchAppBundleNames.current,
              sourceURL.deletingLastPathComponent() == destinationURL.deletingLastPathComponent(),
              fileManager.fileExists(atPath: sourceURL.path),
              !fileManager.fileExists(atPath: destinationURL.path)
        else {
            NSLog("[boringNotch] refused legacy bundle migration for %@ -> %@", sourcePath, destinationPath)
            reply(false)
            return
        }

        do {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
            NSWorkspace.shared.noteFileSystemChanged(destinationURL.deletingLastPathComponent().path)
            reply(true)
        } catch {
            NSLog("[boringNotch] legacy bundle migration failed for %@: %@", sourcePath, error.localizedDescription)
            reply(false)
        }
    }

    /// Opens one of macOS's own menu bar menus (battery, Wi-Fi, …) by pressing
    /// its menu bar item, so the app can show the real menu instead of a copy.
    /// The menu appears under that item, where macOS anchors it.
    ///
    /// Only Apple's `com.apple.menuextra.*` items can be pressed. Those live in
    /// MenuBarAgent on macOS 26 and later, and in ControlCenter before that.
    /// Replies false when the item isn't in the menu bar (the user hid it) or
    /// Accessibility isn't granted.
    @objc func openSystemMenuExtra(_ identifier: String, with reply: @escaping (Bool) -> Void) {
        guard AXIsProcessTrusted(), identifier.hasPrefix("com.apple.menuextra.") else {
            reply(false)
            return
        }
        for bundleID in ["com.apple.MenuBarAgent", "com.apple.controlcenter"] {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                let appElement = AXUIElementCreateApplication(app.processIdentifier)
                var extras: CFTypeRef?
                let root = AXUIElementCopyAttributeValue(appElement, "AXExtrasMenuBar" as CFString, &extras) == .success
                    ? extras as! AXUIElement
                    : appElement
                if let item = Self.element(withIdentifier: identifier, in: root),
                   AXUIElementPerformAction(item, kAXPressAction as CFString) == .success {
                    reply(true)
                    return
                }
            }
        }
        reply(false)
    }

    /// The energy mode for the power source in use, and whether this Mac has
    /// High Power, as JSON-encoded EnergyModeStatus. Nil if pmset failed.
    @objc func energyModeStatus(with reply: @escaping (Data?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            reply(EnergyModeService.status().flatMap { try? JSONEncoder().encode($0) })
        }
    }

    /// Battery levels for trusted iPhones and iPads (USB or Wi-Fi) and their
    /// paired watches, as JSON from the bundled `notch-appledevices` tool
    /// (libimobiledevice; see Configuration/apple-devices). It runs here
    /// because the sandboxed app can't reach usbmuxd. Nil if it fails — the
    /// tool gives up on its own after 25 seconds.
    @objc func fetchAppleDevices(with reply: @escaping (Data?) -> Void) {
        guard let tool = Bundle.main.resourceURL?.appendingPathComponent("AppleDevicesTools/bin/notch-appledevices"),
              FileManager.default.isExecutableFile(atPath: tool.path)
        else {
            reply(nil)
            return
        }
        let process = Process()
        process.executableURL = tool
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            NSLog("[boringNotch] couldn't run notch-appledevices: %@", error.localizedDescription)
            reply(nil)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            reply(process.terminationStatus == 0 ? data : nil)
        }
    }

    /// Window snapping: moves and resizes another app's window to `frame`
    /// (see WindowSnapService). False if the window couldn't be found or
    /// moved, or Accessibility isn't granted.
    @objc func snapWindow(_ windowID: UInt32, ownerPID: Int32, to frame: CGRect, with reply: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInteractive).async {
            reply(WindowSnapService.snap(windowID: windowID, pid: ownerPID, to: frame))
        }
    }

    /// Presence guard: turns Focus on or off through the user's shortcut
    /// (see ShortcutsService). False for any other name, or if it failed.
    @objc func runFocusShortcut(_ name: String, with reply: @escaping (Bool) -> Void) {
        guard let shortcut = FocusShortcut(rawValue: name) else {
            reply(false)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            reply(ShortcutsService.run(shortcut))
        }
    }

    @objc func installedFocusShortcuts(with reply: @escaping ([String]?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            reply(ShortcutsService.installed())
        }
    }

    /// Presses Spotify's Playback ▸ Repeat or Shuffle menu command, the same
    /// as its own buttons. Repeat cycles off → all → one, which Spotify's
    /// AppleScript (repeat on/off only) can't do. Only those two items, only
    /// in Spotify; works with Spotify in the background.
    @objc func pressSpotifyPlaybackItem(_ item: String, with reply: @escaping (Bool) -> Void) {
        // Title → its key equivalent (⌘R, ⌘S), for a Spotify running in
        // another language.
        let keyEquivalents = ["Repeat": "R", "Shuffle": "S"]
        guard AXIsProcessTrusted(),
              let keyEquivalent = keyEquivalents[item],
              let spotify = NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").first,
              let menuBar = Self.axElement(AXUIElementCreateApplication(spotify.processIdentifier), kAXMenuBarAttribute)
        else {
            reply(false)
            return
        }
        let menus = Self.axChildren(menuBar).compactMap { Self.axChildren($0).first }
        let entries = menus.flatMap { Self.axChildren($0) }
        let byTitle = entries.first { Self.axString($0, kAXTitleAttribute) == item }
        // Otherwise the ⌘-key item in the menu that has both ⌘R and ⌘S.
        let byKey: AXUIElement? = byTitle != nil ? nil : menus.lazy.compactMap { menu -> AXUIElement? in
            let items = Self.axChildren(menu)
            let commandKeys = items.filter { Self.axNumber($0, kAXMenuItemCmdModifiersAttribute) == 0 }
            let keys = Set(commandKeys.compactMap { Self.axString($0, kAXMenuItemCmdCharAttribute)?.uppercased() })
            guard keys.isSuperset(of: Set(keyEquivalents.values)) else { return nil }
            return commandKeys.first { Self.axString($0, kAXMenuItemCmdCharAttribute)?.uppercased() == keyEquivalent }
        }.first
        guard let target = byTitle ?? byKey else {
            reply(false)
            return
        }
        reply(AXUIElementPerformAction(target, kAXPressAction as CFString) == .success)
    }

    private static func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func axChildren(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func axNumber(_ element: AXUIElement, _ attribute: String) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.intValue
    }

    private static func element(withIdentifier identifier: String, in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXIdentifier" as CFString, &value) == .success,
           value as? String == identifier {
            return element
        }
        guard depth < 4,
              AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement]
        else { return nil }
        for child in children {
            if let match = self.element(withIdentifier: identifier, in: child, depth: depth + 1) {
                return match
            }
        }
        return nil
    }

    @objc func requestAccessibilityAuthorization() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    @objc func ensureAccessibilityAuthorization(_ promptIfNeeded: Bool, with reply: @escaping (Bool) -> Void) {
        if AXIsProcessTrusted() {
            reply(true)
            return
        }

        guard promptIfNeeded else {
            reply(false)
            return
        }

        requestAccessibilityAuthorization()

        let deadline = DispatchTime.now() + .seconds(15)
        func waitForAuthorization() {
            if AXIsProcessTrusted() {
                reply(true)
            } else if DispatchTime.now() >= deadline {
                reply(false)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    waitForAuthorization()
                }
            }
        }
        waitForAuthorization()
    }

    // MARK: - Notification Center banners

    private static let watcher = NotificationWatcher()

    @objc func startNotificationWatching(with reply: @escaping (Bool) -> Void) {
        // Capture the delegate for this connection before hopping queues —
        // NSXPCConnection.current() is only valid inside the incoming call.
        //
        // Cast to BoringNotchXPCAppDelegate, not its parent protocol: the
        // proxy's conformance is built from the exact interface the
        // connection was configured with, so casting to the parent can
        // return nil and silently swallow every callback.
        let connection = NSXPCConnection.current()
        let proxy = connection?.remoteObjectProxyWithErrorHandler { error in
            NSLog("[boringNotch] notification callback failed: \(error.localizedDescription)")
        }
        let delegate = proxy as? BoringNotchXPCAppDelegate

        if delegate == nil {
            NSLog("[boringNotch] could not obtain notification delegate proxy — banners will not reach the app")
        }

        DispatchQueue.main.async {
            let watcher = Self.watcher
            watcher.onBanner = { notification in
                delegate?.notificationDidAppear([
                    "token": notification.token,
                    "appName": notification.appName ?? "",
                    "bundleID": notification.bundleID ?? "",
                    "title": notification.title ?? "",
                    "subtitle": notification.subtitle ?? "",
                    "body": notification.body ?? ""
                ])
            }
            let started = watcher.start()
            NSLog("[boringNotch] notification watcher start -> \(started), AX trusted: \(AXIsProcessTrusted())")
            reply(started)
        }
    }

    @objc func stopNotificationWatching() {
        DispatchQueue.main.async { Self.watcher.stop() }
    }

    @objc func setNotificationFilter(_ bundleIDs: [String], allApps: Bool) {
        DispatchQueue.main.async {
            Self.watcher.configureFilter(bundleIDs: Set(bundleIDs), allApps: allApps)
        }
    }
    private class KeyboardBrightnessClient {
        private static let keyboardID: UInt64 = 1
        private var clientInstance: NSObject?
        private let getSelector = NSSelectorFromString("brightnessForKeyboard:")
        private let setSelector = NSSelectorFromString("setBrightness:forKeyboard:")

        init() {
            var loaded = false
            let bundlePaths = [
                "/System/Library/PrivateFrameworks/CoreBrightness.framework",
                "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
            ]
            for path in bundlePaths where !loaded {
                if let bundle = Bundle(path: path) {
                    loaded = bundle.load()
                }
            }
            if loaded, let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type {
                clientInstance = cls.init()
            }
        }

        func currentBrightness() -> Float? {
            guard let clientInstance,
                  let fn: BrightnessGetter = methodIMP(on: clientInstance, selector: getSelector, as: BrightnessGetter.self)
            else { return nil }
            return fn(clientInstance, getSelector, Self.keyboardID)
        }

        func setBrightness(_ value: Float) -> Bool {
            guard let clientInstance,
                  let fn: BrightnessSetter = methodIMP(on: clientInstance, selector: setSelector, as: BrightnessSetter.self)
            else { return false }
            return fn(clientInstance, setSelector, value, Self.keyboardID).boolValue
        }

        private typealias BrightnessGetter = @convention(c) (NSObject, Selector, UInt64) -> Float
        private typealias BrightnessSetter = @convention(c) (NSObject, Selector, Float, UInt64) -> ObjCBool

        private func methodIMP<T>(on object: NSObject, selector: Selector, as type: T.Type) -> T? {
            guard let cls = object_getClass(object),
                  let method = class_getInstanceMethod(cls, selector)
            else { return nil }
            let imp = method_getImplementation(method)
            return unsafeBitCast(imp, to: type)
        }
    }

    private static let keyboardClient = KeyboardBrightnessClient()

    @objc func currentKeyboardBrightness(with reply: @escaping (NSNumber?) -> Void) {
        reply(Self.keyboardClient.currentBrightness().map { NSNumber(value: $0) })
    }

    @objc func setKeyboardBrightness(_ value: Float, with reply: @escaping (Bool) -> Void) {
        reply(Self.keyboardClient.setBrightness(value))
    }
    // MARK: - Screen Brightness (moved from client app into helper)

    private func brightnessDisplayID() -> CGDirectDisplayID {
        let mainDisplayID = CGMainDisplayID()
        var tmp: Float = 0

        if displayServicesGetBrightness(displayID: mainDisplayID, out: &tmp) || ioServiceFor(displayID: mainDisplayID) != nil {
            return mainDisplayID
        }

        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        let allocated = Int(count)
        var ids = [CGDirectDisplayID](repeating: 0, count: allocated)
        CGGetOnlineDisplayList(count, &ids, &count)
        for id in ids {
            if CGDisplayIsBuiltin(id) != 0 {
                return id
            }
        }

        return mainDisplayID
    }

    @objc func currentScreenBrightness(with reply: @escaping (NSNumber?) -> Void) {
        let displayID = brightnessDisplayID()
        var b: Float = 0
        if displayServicesGetBrightness(displayID: displayID, out: &b) {
            reply(NSNumber(value: b))
            return
        }
        if let io = ioServiceFor(displayID: displayID) {
            var level: Float = 0
            if IODisplayGetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, &level) == kIOReturnSuccess {
                IOObjectRelease(io)
                reply(NSNumber(value: level))
                return
            }
            IOObjectRelease(io)
        }
        reply(nil)
    }

    @objc func setScreenBrightness(_ value: Float, with reply: @escaping (Bool) -> Void) {
        let clamped = max(0, min(1, value))
        let displayID = brightnessDisplayID()
        if displayServicesSetBrightness(displayID: displayID, value: clamped) {
            reply(true)
            return
        }
        if let io = ioServiceFor(displayID: displayID) {
            let ok = IODisplaySetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, clamped) == kIOReturnSuccess
            IOObjectRelease(io)
            reply(ok)
            return
        }
        reply(false)
    }

    @objc func adjustScreenBrightness(by value: Float, with reply: @escaping (NSNumber?) -> Void) {
        let displayID = brightnessDisplayID()
        if displayServicesSetBrightnessSmooth(displayID: displayID, value: value) {
            // Read back inside the helper so the client pays for one RPC
            // instead of two (adjust + currentScreenBrightness).
            var b: Float = 0
            if displayServicesGetBrightness(displayID: displayID, out: &b) {
                reply(NSNumber(value: b))
                return
            }
            reply(nil)
            return
        }
        if let io = ioServiceFor(displayID: displayID) {
            var ioCurrent: Float = 0
            if IODisplayGetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, &ioCurrent) == kIOReturnSuccess {
                let target = max(0, min(1, ioCurrent + value))
                let ok = IODisplaySetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, target) == kIOReturnSuccess
                IOObjectRelease(io)
                reply(ok ? NSNumber(value: target) : nil)
                return
            }
            IOObjectRelease(io)
        }
        reply(nil)
    }

    // MARK: - Lunar Events

    @objc func displayIDForBrightness(with reply: @escaping (NSNumber?) -> Void) {
        let id = brightnessDisplayID()
        reply(NSNumber(value: id))
    }

    @objc func isLunarAvailable(with reply: @escaping (Bool) -> Void) {
        reply(FileManager.default.isExecutableFile(atPath: lunarExecutableURL.path))
    }

    @objc func startLunarEventStream(with reply: @escaping (Bool) -> Void) {
        lunarStateQueue.async { [weak self] in
            guard let self else {
                reply(false)
                return
            }

            if let lunarProcess = self.lunarProcess, lunarProcess.isRunning {
                reply(true)
                return
            }

            guard FileManager.default.isExecutableFile(atPath: self.lunarExecutableURL.path) else {
                reply(false)
                return
            }

            guard let connection = self.connection else {
                reply(false)
                return
            }

            let listenerProxy = connection.remoteObjectProxyWithErrorHandler { _ in
                self.stopLunarEventStream()
            } as? BoringNotchXPCHelperLunarListener

            guard let listenerProxy else {
                reply(false)
                return
            }

            let process = Process()
            process.executableURL = self.lunarExecutableURL
            process.arguments = ["@", "listen", "--only-user-adjustments", "-j"]

            let pipeHandler = JSONLinesPipeHandler()
            process.standardOutput = pipeHandler.outputPipe
            process.standardError = FileHandle.nullDevice

            process.terminationHandler = { [weak self] _ in
                self?.stopLunarEventStream(reason: "Lunar stream ended")
            }

            do {
                try process.run()
            } catch {
                reply(false)
                return
            }

            self.lunarProcess = process
            self.lunarPipeHandler = pipeHandler
            self.lunarListener = listenerProxy

            let currentPipeHandler = pipeHandler
            self.lunarStreamTask = Task { [weak self] in
                await self?.readLunarEvents(pipeHandler: currentPipeHandler)
            }

            reply(true)
        }
    }

    @objc func stopLunarEventStream() {
        stopLunarEventStream(reason: nil)
    }

    private func stopLunarEventStream(reason: String?) {
        lunarStateQueue.async { [weak self] in
            guard let self else { return }

            self.lunarStreamTask?.cancel()
            self.lunarStreamTask = nil

            if let lunarProcess = self.lunarProcess, lunarProcess.isRunning {
                lunarProcess.terminate()
            }

            self.lunarProcess = nil

            if let pipeHandler = self.lunarPipeHandler {
                pipeHandler.close()
            }

            self.lunarPipeHandler = nil

            if let reason {
                self.lunarListener?.lunarStreamDidStop(reason)
            }

            self.lunarListener = nil
        }
    }

    private func readLunarEvents(pipeHandler: JSONLinesPipeHandler) async {
        await pipeHandler.readJSONLines(as: LunarBrightnessEvent.self) { [weak self] event in
            self?.emitLunarEvent(event)
        }
    }

    private func emitLunarEvent(_ event: LunarBrightnessEvent) {
        let payload = BNLunarBrightnessEvent(
            brightness: event.brightness,
            display: event.display
        )
        lunarStateQueue.async { [weak self] in
            self?.lunarListener?.lunarEventDidUpdate(payload)
        }
    }

    // MARK: - Lunar OSD preference (hideOSD)

    private static let lunarBundleID = "fyi.lunar.Lunar"
    private static let lunarHideOSDKey = "hideOSD"

    @objc func setLunarOSDHidden(_ hide: Bool, with reply: @escaping (Bool) -> Void) {
        let appID = Self.lunarBundleID as CFString
        let key = Self.lunarHideOSDKey as CFString
        let value = hide as CFBoolean
        NSLog("Hide OSD in Lunar: \(hide)")
        CFPreferencesSetValue(key, value, appID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let ok = CFPreferencesSynchronize(appID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        reply(ok)
    }

    // MARK: - Private helpers for DisplayServices / IOKit access
    private func displayServicesGetBrightness(displayID: CGDirectDisplayID, out: inout Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesGetBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        var tmp: Float = 0
        let r = fn(displayID, &tmp)
        if r == 0 { out = tmp; return true }
        return false
    }

    private func displayServicesSetBrightness(displayID: CGDirectDisplayID, value: Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesSetBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, Float) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        return fn(displayID, value) == 0
    }

    private func displayServicesSetBrightnessSmooth(displayID: CGDirectDisplayID, value: Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesSetBrightnessSmooth") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, Float) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        return fn(displayID, value) == 0
    }

    private func ioServiceFor(displayID: CGDirectDisplayID) -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            let info = IODisplayCreateInfoDictionary(service, 0).takeRetainedValue() as NSDictionary
            if let vendorID = info[kDisplayVendorID] as? UInt32,
               let productID = info[kDisplayProductID] as? UInt32,
               vendorID == CGDisplayVendorNumber(displayID),
               productID == CGDisplayModelNumber(displayID) {
                return service
            }
            IOObjectRelease(service)
        }
        return nil
    }

    // MARK: - Helper handle for private framework
    private enum DisplayServicesHandle {
        static let handle: UnsafeMutableRawPointer? = {
            let paths = [
                "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
                "/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/Current/DisplayServices"
            ]
            for p in paths {
                if let h = dlopen(p, RTLD_LAZY) { return h }
            }
            return nil
        }()
    }

    // MARK: - Face Unlock: stored password + lock-screen keystrokes

    // Stored as an obfuscated 0600 file written by this (non-sandboxed) helper,
    // not the keychain: an on-demand, ad-hoc-signed XPC service can't silently
    // write the login keychain (SecItemAdd → errSecInteractionNotAllowed, -25308),
    // and a self-ACL keychain item would break on every rebuild and on keychain
    // auto-lock. A file is the same practical security as the plain login keychain
    // for this threat model — any code running as the user can read either while
    // you're logged in — and it survives rebuilds and reads reliably while locked.
    private var unlockSecretURL: URL {
        let dir = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/theboringteam.boringnotch")
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return URL(fileURLWithPath: dir).appendingPathComponent("faceunlock.secret")
    }

    /// Obfuscation only (the key is embedded) — keeps the password out of literal
    /// plaintext on disk and in backups. It is NOT protection against code that
    /// already runs as you; see the storage note above.
    private static func unlockObfuscationKey() -> SymmetricKey {
        SymmetricKey(data: SHA256.hash(data: Data("theboringteam.boringnotch.faceunlock.v1".utf8)))
    }

    /// Diagnostics to a readable file (the helper's stderr/NSLog isn't visible).
    /// Never logs the password itself — only lengths and error details.
    private static func unlockDebug(_ message: String) {
        let path = ("~/Library/Caches/boringnotch-faceunlock.log" as NSString).expandingTildeInPath
        let line = "\(Date()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    @objc func storeUnlockPassword(_ password: String, with reply: @escaping (_ verified: Bool, _ saved: Bool) -> Void) {
        Self.unlockDebug("storeUnlockPassword called, user=\(NSUserName()) len=\(password.count)")
        // Never store a wrong password — typing it at the lock screen would trip
        // failed-attempt lockout delays. Verify against the account first.
        guard !password.isEmpty else {
            Self.unlockDebug("-> empty password")
            reply(false, false); return
        }
        guard verifyLoginPassword(password) else { reply(false, false); return }
        let saved = saveUnlockPassword(password)
        Self.unlockDebug("-> verified OK, saved=\(saved)")
        reply(true, saved)
    }

    @objc func hasUnlockPassword(with reply: @escaping (Bool) -> Void) {
        reply(loadUnlockPassword() != nil)
    }

    @objc func clearUnlockPassword() {
        try? FileManager.default.removeItem(at: unlockSecretURL)
    }

    @objc func unlockScreenWithStoredPassword(dryRun: Bool, with reply: @escaping (Bool) -> Void) {
        guard let password = loadUnlockPassword() else {
            NSLog("[FaceUnlock] no stored password")
            reply(false); return
        }
        if dryRun {
            NSLog("[FaceUnlock] DRY RUN — would type the stored password (%d chars) + Return at the lock screen", password.count)
            // Whether a real run would get past its own guards below.
            Self.unlockDebug("dry run: len=\(password.count) accessibility=\(AXIsProcessTrusted()) screenLocked=\(Self.isScreenLocked())")
            reply(true); return
        }
        guard AXIsProcessTrusted() else {
            NSLog("[FaceUnlock] Accessibility not granted; cannot post keystrokes")
            reply(false); return
        }
        // Only ever type into the actual lock screen, never a focused app field.
        guard Self.isScreenLocked() else {
            NSLog("[FaceUnlock] screen is not locked; refusing to type")
            reply(false); return
        }
        reply(typePasswordAtLockScreen(password))
    }

    // MARK: Secret storage (obfuscated 0600 file — readable while the screen is locked)

    private func saveUnlockPassword(_ password: String) -> Bool {
        do {
            let sealed = try AES.GCM.seal(Data(password.utf8), using: Self.unlockObfuscationKey())
            guard let combined = sealed.combined else { return false }
            try combined.write(to: unlockSecretURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unlockSecretURL.path)
            Self.unlockDebug("saveUnlockPassword: file written OK")
            return true
        } catch {
            Self.unlockDebug("saveUnlockPassword: file write failed: \(error)")
            return false
        }
    }

    private func loadUnlockPassword() -> String? {
        guard let data = try? Data(contentsOf: unlockSecretURL),
              let box = try? AES.GCM.SealedBox(combined: data),
              let opened = try? AES.GCM.open(box, using: Self.unlockObfuscationKey()) else { return nil }
        return String(data: opened, encoding: .utf8)
    }

    // MARK: Password verification (OpenDirectory — no unlock, just a check)

    private func verifyLoginPassword(_ password: String) -> Bool {
        let user = NSUserName()
        do {
            let node = try ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeAuthentication))
            let record = try node.record(withRecordType: kODRecordTypeUsers, name: user, attributes: nil)
            try record.verifyPassword(password)
            return true
        } catch let error as NSError {
            Self.unlockDebug("verify FAILED user=\(user) len=\(password.count) domain=\(error.domain) code=\(error.code) msg=\(error.localizedDescription)")
            return false
        }
    }

    // MARK: Lock state + keystroke injection

    static func isScreenLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Int) == 1
    }
    /// Clears the field, types the password, presses Return. Re-checks the lock
    /// state before every keystroke and aborts if it changes, so the password
    /// can never land in a window that stole focus mid-type.
    private func typePasswordAtLockScreen(_ password: String) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }

        // Clear any pre-filled text: Cmd+A, then Delete.
        postKey(source, virtualKey: 0x00, flags: .maskCommand)   // A
        postKey(source, virtualKey: 0x33)                        // Delete

        for character in password {
            guard Self.isScreenLocked() else { return false }
            postUnicode(source, String(character))
        }
        guard Self.isScreenLocked() else { return false }
        postKey(source, virtualKey: 0x24)                        // Return
        return true
    }

    private func postUnicode(_ source: CGEventSource, _ string: String) {
        var utf16 = Array(string.utf16)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown) else { continue }
            event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            event.post(tap: .cghidEventTap)
            usleep(1500)
        }
    }

    private func postKey(_ source: CGEventSource, virtualKey: CGKeyCode, flags: CGEventFlags = []) {
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: isDown) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
            usleep(1500)
        }
    }
}

// MARK: - Lunar Parsing

private struct LunarBrightnessEvent: Decodable, Sendable {
    let brightness: Double
    let display: Int
}
