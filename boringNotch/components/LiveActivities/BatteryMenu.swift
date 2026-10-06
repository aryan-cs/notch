//
//  BatteryMenu.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  A copy of the system Battery menu, matched to it by measurement. It's a
//  real NSMenu, so the window and glass are AppKit's own; the rows are
//  custom where the system menu's differ from AppKit's stock items.
//
//  Not wired up yet: the battery button opens the system menu itself. This
//  takes over once the Energy Mode rows can switch modes without asking for
//  a password (changing the mode takes root); until then they lead to
//  Battery settings.
//

import AppKit

@MainActor
enum BatteryMenu {
    /// Measured from the system Battery menu.
    enum Metrics {
        static let width: CGFloat = 308
        /// Where the system menu starts its text and icons.
        static let inset: CGFloat = 14
        static let rowHeight: CGFloat = 32
        static let circle: CGFloat = 26
        static let circleToLabel: CGFloat = 8
        static let glyphPointSize: CGFloat = 12
        /// The hover highlight's inset from the menu's edges.
        static let highlightInset: CGFloat = 5
        static let highlightRadius: CGFloat = 8
    }

    /// Shows the menu under `anchor`, left edges aligned like a menu bar
    /// menu; returns when it closes.
    static func show(below anchor: NSView) async {
        let battery = BatteryStatusViewModel.shared
        let status = await XPCHelperClient.shared.energyModeStatus()
            ?? EnergyModeStatus(mode: ProcessInfo.processInfo.isLowPowerModeEnabled ? .lowPower : .automatic, highPowerSupported: false)
        let menu = makeMenu(level: Int(battery.levelBattery.rounded()), isPluggedIn: battery.isPluggedIn, status: status)
        let origin = NSPoint(x: 0, y: anchor.isFlipped ? anchor.bounds.maxY + 6 : -6)
        menu.popUp(positioning: nil, at: origin, in: anchor)
    }

    static func makeMenu(level: Int, isPluggedIn: Bool, status: EnergyModeStatus) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.showsStateColumn = false
        // The notch is always dark; the system menu follows the system.
        menu.appearance = NSApp.effectiveAppearance

        // The system menu draws most rows itself: its power source line and
        // section header are smaller and brighter than AppKit's, and its
        // separators sit closer to the edges. Heights here are measured.
        let title = NSMenuItem()
        title.view = TextRowView(
            height: 30,
            textCenter: 16,
            text: String(localized: "Battery"),
            font: .boldSystemFont(ofSize: NSFont.systemFontSize),
            color: .labelColor,
            trailingText: (Double(level) / 100).formatted(.percent.precision(.fractionLength(0)))
        )
        menu.addItem(title)

        let source = NSMenuItem()
        source.view = TextRowView(
            height: 20,
            textCenter: 11,
            text: isPluggedIn ? String(localized: "Power Source: Power Adapter") : String(localized: "Power Source: Battery"),
            font: .systemFont(ofSize: 12),
            color: .secondaryLabelColor
        )
        menu.addItem(source)

        menu.addItem(separator())
        let header = NSMenuItem()
        header.view = TextRowView(
            height: 22,
            textCenter: 11,
            text: String(localized: "Energy Mode"),
            font: .systemFont(ofSize: 12, weight: .semibold),
            color: .secondaryLabelColor
        )
        menu.addItem(header)
        for mode in EnergyMode.allCases where mode != .highPower || status.highPowerSupported {
            let item = NSMenuItem()
            item.view = EnergyModeRowView(mode: mode, isSelected: mode == status.mode) {
                // Changing the mode takes root; until there's a way to do
                // that, the row leads to where it can be changed.
                openBatterySettings()
            }
            menu.addItem(item)
        }

        menu.addItem(separator())
        // A stock item, for the stock highlight and keyboard behavior.
        let settings = NSMenuItem(title: String(localized: "Battery Settings…"), action: #selector(MenuActions.openBatterySettings), keyEquivalent: "")
        settings.target = MenuActions.shared
        menu.addItem(settings)
        return menu
    }

    private static func separator() -> NSMenuItem {
        let item = NSMenuItem()
        item.view = SeparatorView()
        return item
    }

    static func openBatterySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// A target for the plain items' actions.
    final class MenuActions: NSObject {
        static let shared = MenuActions()

        @objc func openBatterySettings() {
            MainActor.assumeIsolated { BatteryMenu.openBatterySettings() }
        }
    }
}

/// A line of text at the menu's inset, optionally with a value at the far
/// end ("Battery … 54%").
private final class TextRowView: NSView {
    init(height: CGFloat, textCenter: CGFloat, text: String, font: NSFont, color: NSColor, trailingText: String? = nil) {
        let metrics = BatteryMenu.Metrics.self
        super.init(frame: NSRect(x: 0, y: 0, width: metrics.width, height: height))
        autoresizingMask = [.width]

        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: metrics.inset),
            label.centerYAnchor.constraint(equalTo: topAnchor, constant: textCenter),
        ])

        if let trailingText {
            let value = NSTextField(labelWithString: trailingText)
            value.font = .systemFont(ofSize: font.pointSize, weight: .semibold)
            value.textColor = .secondaryLabelColor
            value.translatesAutoresizingMaskIntoConstraints = false
            addSubview(value)
            NSLayoutConstraint.activate([
                value.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -metrics.inset),
                value.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// A separator at the system menu's inset (AppKit's own sits further in).
private final class SeparatorView: NSView {
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: BatteryMenu.Metrics.width, height: 11))
        autoresizingMask = [.width]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let inset = BatteryMenu.Metrics.inset
        NSColor.labelColor.withAlphaComponent(0.18).setFill()
        NSRect(x: inset, y: 4.5, width: bounds.width - inset * 2, height: 1).fill()
    }
}

/// One Energy Mode choice: the mode's battery glyph in a circle (accent
/// filled when it's the current mode) and its name.
private final class EnergyModeRowView: NSView {
    private let mode: EnergyMode
    private let isSelected: Bool
    private let action: () -> Void

    init(mode: EnergyMode, isSelected: Bool, action: @escaping () -> Void) {
        self.mode = mode
        self.isSelected = isSelected
        self.action = action
        let metrics = BatteryMenu.Metrics.self
        super.init(frame: NSRect(x: 0, y: 0, width: metrics.width, height: metrics.rowHeight))
        autoresizingMask = [.width]

        let label = NSTextField(labelWithString: mode.title)
        label.font = .menuFont(ofSize: 0)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: metrics.inset + metrics.circle + metrics.circleToLabel),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(mode.title)
        setAccessibilityValue(isSelected)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let metrics = BatteryMenu.Metrics.self
        if enclosingMenuItem?.isHighlighted == true {
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(
                roundedRect: bounds.insetBy(dx: metrics.highlightInset, dy: 0),
                xRadius: metrics.highlightRadius,
                yRadius: metrics.highlightRadius
            ).fill()
        }

        let circle = NSRect(x: metrics.inset, y: (bounds.height - metrics.circle) / 2, width: metrics.circle, height: metrics.circle)
        (isSelected ? NSColor.controlAccentColor : NSColor.tertiarySystemFill).setFill()
        NSBezierPath(ovalIn: circle).fill()

        guard let glyph = mode.glyph(color: isSelected ? .white : .secondaryLabelColor) else { return }
        let size = glyph.size
        glyph.draw(in: NSRect(
            x: (circle.midX - size.width / 2).rounded(),
            y: (circle.midY - size.height / 2).rounded(),
            width: size.width,
            height: size.height
        ))
    }

    override func mouseUp(with event: NSEvent) {
        enclosingMenuItem?.menu?.cancelTracking()
        action()
    }
}

private extension EnergyMode {
    var title: String {
        switch self {
        case .automatic: String(localized: "Automatic")
        case .lowPower: String(localized: "Low Power")
        case .highPower: String(localized: "High Power")
        }
    }

    /// The system menu's glyphs. High Power's (a battery with three arrows)
    /// is a private system symbol, read from the system's glyph bundle.
    func glyph(color: NSColor) -> NSImage? {
        let base: NSImage?
        switch self {
        case .automatic:
            base = NSImage(systemSymbolName: "battery.100percent", accessibilityDescription: nil)
        case .lowPower:
            base = NSImage(systemSymbolName: "battery.25percent", accessibilityDescription: nil)
        case .highPower:
            base = Bundle(path: "/System/Library/CoreServices/CoreGlyphsPrivate.bundle")?
                .image(forResource: "arrowtriangle.right.3.battery.0percent")
                ?? NSImage(systemSymbolName: "battery.100percent.bolt", accessibilityDescription: nil)
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: BatteryMenu.Metrics.glyphPointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: color))
        return base?.withSymbolConfiguration(configuration)
    }
}
