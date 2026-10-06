//
//  ClipboardHistoryManager.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Watches the general pasteboard and keeps a history of what was copied.
//
//  macOS has no pasteboard-changed notification, so this polls
//  `changeCount` — one integer read per tick, the same approach Maccy and
//  every other clipboard manager uses. Contents are only read when the count
//  moves. Lifecycle is owned by BoringViewCoordinator, which starts and
//  stops this with the `clipboardHistory` setting.
//

import AppKit
import Carbon.HIToolbox
import Combine
import Defaults

@MainActor
final class ClipboardHistoryManager: ObservableObject {
    static let shared = ClipboardHistoryManager()

    static let pollInterval: TimeInterval = 0.5

    @Published private(set) var history = ClipboardHistory() {
        didSet { schedulePersistence() }
    }

    /// The entry just chosen from the notch, for a brief confirmation.
    @Published private(set) var recentlySelectedID: UUID?

    /// True while the system color loupe is up.
    @Published private(set) var isPickingColor = false

    var entries: [ClipboardEntry] { history.displayOrder }
    var isEmpty: Bool { history.isEmpty }
    var isRunning: Bool { timer != nil }

    private let pasteboard: NSPasteboard
    private let storage: ClipboardStorage
    private let frontmostBundleID: () -> String?

    private var timer: Timer?
    private var lastChangeCount: Int
    private var persistenceTask: Task<Void, Never>?
    private var selectionFeedbackTask: Task<Void, Never>?
    private var settingsCancellables: Set<AnyCancellable> = []
    private let thumbnails = NSCache<NSString, NSImage>()

    /// Internal rather than private so tests can supply a private pasteboard
    /// and a throwaway storage directory.
    init(
        pasteboard: NSPasteboard = .general,
        storage: ClipboardStorage = ClipboardStorage(),
        frontmostBundleID: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    ) {
        self.pasteboard = pasteboard
        self.storage = storage
        self.frontmostBundleID = frontmostBundleID
        self.lastChangeCount = pasteboard.changeCount

        if Defaults[.clipboardPersistHistory] {
            let entries = storage.load().filter(storage.hasFiles(for:))
            storage.removeUnreferencedImages(keeping: entries)
            history = ClipboardHistory(entries: entries)
        } else {
            storage.deleteHistoryFile()
            storage.removeUnreferencedImages(keeping: [])
        }

        Defaults.publisher(.clipboardHistoryLimit, options: [])
            .sink { [weak self] change in
                Task { @MainActor in
                    guard let self else { return }
                    self.discard(self.history.trim(to: change.newValue))
                }
            }
            .store(in: &settingsCancellables)

        Defaults.publisher(.clipboardPersistHistory, options: [])
            .sink { [weak self] change in
                Task { @MainActor in
                    guard let self else { return }
                    if change.newValue {
                        self.schedulePersistence()
                    } else {
                        self.persistenceTask?.cancel()
                        self.storage.deleteHistoryFile()
                    }
                }
            }
            .store(in: &settingsCancellables)
    }

    // MARK: - Monitoring

    func start() {
        guard timer == nil else { return }
        // Only record copies made from now on. Capturing whatever is already
        // on the pasteboard would bump it to the front on every launch.
        lastChangeCount = pasteboard.changeCount
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkForChanges()
            }
        }
        timer.tolerance = 0.2
        // .common so copies made while a menu is tracking are still seen.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Log.clipboard.debug("Clipboard monitoring started")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        Log.clipboard.debug("Clipboard monitoring stopped")
    }

    func checkForChanges() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount

        let source = frontmostBundleID()
        if let source, isExcluded(source) { return }
        guard let capture = ClipboardReader.read(pasteboard) else { return }
        ingest(capture, source: source)
    }

    private func isExcluded(_ bundleID: String) -> Bool {
        ClipboardReader.passwordManagerBundleIDs.contains(bundleID)
            || Defaults[.clipboardIgnoredApps].contains(bundleID)
    }

    /// Image captures finish asynchronously; the returned task lets tests
    /// wait for them.
    @discardableResult
    func ingest(_ capture: ClipboardCapture, source: String?, date: Date = Date()) -> Task<Void, Never>? {
        switch capture {
        case .text(let string, let rtf):
            record(ClipboardEntry(
                content: .text(string, rtf: rtf),
                fingerprint: ClipboardEntry.fingerprint(text: string),
                date: date,
                sourceBundleID: source
            ))
            return nil

        case .files(let urls):
            record(ClipboardEntry(
                content: .files(urls),
                fingerprint: ClipboardEntry.fingerprint(files: urls),
                date: date,
                sourceBundleID: source
            ))
            return nil

        case .image(let data):
            let storage = storage
            let id = UUID()
            return Task {
                let stored = await Task.detached(priority: .userInitiated) { () -> (ClipboardContent, String)? in
                    guard let image = ProcessedClipboardImage.process(data) else { return nil }
                    guard let content = try? storage.writeImage(image, id: id) else { return nil }
                    return (content, ClipboardEntry.fingerprint(imageData: image.png))
                }.value

                guard let (content, fingerprint) = stored else {
                    Log.clipboard.error("Couldn't store copied image")
                    return
                }
                let entry = ClipboardEntry(
                    id: id, content: content, fingerprint: fingerprint, date: date, sourceBundleID: source
                )
                // Same picture copied again: keep the files we already have.
                if let existing = history.entries.first(where: { $0.fingerprint == fingerprint }) {
                    storage.removeFiles(for: [entry])
                    history.promote(id: existing.id, date: date)
                    return
                }
                record(entry)
            }
        }
    }

    private func record(_ entry: ClipboardEntry) {
        discard(history.record(entry, limit: Defaults[.clipboardHistoryLimit]))
    }

    private func discard(_ entries: [ClipboardEntry]) {
        guard !entries.isEmpty else { return }
        for entry in entries {
            if case .image(_, let thumbnailFileName, _, _) = entry.content {
                thumbnails.removeObject(forKey: thumbnailFileName as NSString)
            }
        }
        storage.removeFiles(for: entries)
    }

    // MARK: - Actions

    /// Puts an entry back on the pasteboard and moves it to the front. With
    /// "paste on select" on, also pastes into the frontmost app — the notch
    /// panel never takes focus, so that's still the app the user came from.
    ///
    /// `text` puts that on the pasteboard in place of the entry: a color
    /// card's menu copies the same color as rgb(), hsl() or code.
    func select(_ entry: ClipboardEntry, as text: String? = nil) {
        if let text {
            write(text: text)
        } else if !write(entry) {
            Log.clipboard.notice("Clipboard entry no longer available; removing it")
            remove(entry)
            return
        }
        history.promote(id: entry.id)
        showCopied(entry.id)

        if Defaults[.clipboardPasteOnSelect] {
            pasteIntoFrontmostApp()
        }
    }

    func remove(_ entry: ClipboardEntry) {
        if let removed = history.remove(id: entry.id) {
            discard([removed])
        }
    }

    func togglePin(_ entry: ClipboardEntry) {
        history.togglePin(id: entry.id)
        // Unpinning can push the unpinned count past the limit.
        discard(history.trim(to: Defaults[.clipboardHistoryLimit]))
    }

    func clear(keepingPinned: Bool) {
        discard(history.clear(keepingPinned: keepingPinned))
    }

    /// Shows the system color loupe, which needs no screen recording
    /// permission. Returns the picked color's entry, or nil if the user
    /// pressed Escape.
    func pickColor() async -> ClipboardEntry? {
        guard !isPickingColor else { return nil }
        isPickingColor = true
        defer { isPickingColor = false }

        guard let sampled = await NSColorSampler().sample(),
              let color = ClipboardColor(sampled)
        else { return nil }
        return copy(color)
    }

    /// Copies a color as hex text and records it like any other copy —
    /// which is what makes it a color card.
    @discardableResult
    func copy(_ color: ClipboardColor) -> ClipboardEntry? {
        let hex = color.hex
        guard write(text: hex) else { return nil }
        record(ClipboardEntry(content: .text(hex, rtf: nil), fingerprint: ClipboardEntry.fingerprint(text: hex)))
        // A color already in the history was moved to the front instead.
        guard let entry = history.entries.first else { return nil }
        showCopied(entry.id)
        return entry
    }

    private func showCopied(_ id: UUID) {
        recentlySelectedID = id
        selectionFeedbackTask?.cancel()
        selectionFeedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            self?.recentlySelectedID = nil
        }
    }

    func thumbnail(for entry: ClipboardEntry) -> NSImage? {
        guard case .image(_, let thumbnailFileName, _, _) = entry.content else { return nil }
        let key = thumbnailFileName as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: storage.imageURL(thumbnailFileName)) else { return nil }
        thumbnails.setObject(image, forKey: key)
        return image
    }

    private func write(_ entry: ClipboardEntry) -> Bool {
        let objects: [any NSPasteboardWriting]
        switch entry.content {
        case .text(let string, let rtf):
            let item = NSPasteboardItem()
            item.setString(string, forType: .string)
            if let rtf {
                item.setData(rtf, forType: .rtf)
            }
            objects = [item]

        case .image(let fileName, _, _, _):
            guard let png = try? Data(contentsOf: storage.imageURL(fileName)) else { return false }
            let item = NSPasteboardItem()
            item.setData(png, forType: .png)
            // Older apps only read TIFF.
            if let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation {
                item.setData(tiff, forType: .tiff)
            }
            objects = [item]

        case .files(let urls):
            let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !existing.isEmpty else { return false }
            objects = existing.map { $0 as NSURL }
        }

        return write(objects)
    }

    @discardableResult
    private func write(text: String) -> Bool {
        write([text as NSString])
    }

    private func write(_ objects: [any NSPasteboardWriting]) -> Bool {
        pasteboard.clearContents()
        guard pasteboard.writeObjects(objects) else { return false }
        // Our own write isn't a new copy — don't record it on the next tick.
        lastChangeCount = pasteboard.changeCount
        return true
    }

    private func pasteIntoFrontmostApp() {
        // Posting keystrokes needs Accessibility. Without it the entry is
        // still on the pasteboard; the settings page offers the grant.
        guard AXIsProcessTrusted() else {
            Log.clipboard.notice("Paste on select needs Accessibility access; copied only")
            return
        }
        Task {
            // Give the notch a moment to start closing so the paste lands
            // after the click that triggered it has fully finished.
            try? await Task.sleep(for: .milliseconds(80))
            let source = CGEventSource(stateID: .combinedSessionState)
            let keyCode = CGKeyCode(kVK_ANSI_V)
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
            keyDown?.flags = .maskCommand
            keyUp?.flags = .maskCommand
            keyDown?.post(tap: .cgSessionEventTap)
            keyUp?.post(tap: .cgSessionEventTap)
        }
    }

    // MARK: - Persistence

    private func schedulePersistence() {
        guard Defaults[.clipboardPersistHistory] else { return }
        persistenceTask?.cancel()
        let entries = history.entries
        let storage = storage
        persistenceTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await storage.saveAsync(entries)
        }
    }

    /// Called on quit: saves pending changes, or — when history shouldn't
    /// outlive the session — deletes the images captured during it.
    func flushSync() {
        persistenceTask?.cancel()
        persistenceTask = nil
        if Defaults[.clipboardPersistHistory] {
            storage.save(history.entries)
        } else {
            storage.removeUnreferencedImages(keeping: [])
        }
    }
}
