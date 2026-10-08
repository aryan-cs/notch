//
//  FaceIDAnimationView.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The Face ID box animation, extracted from the standalone lock-screen demo
//  (scratchpad/faceid/lockscreen.swift) into a reusable view driven by an
//  external state. The box opens out of nothing, Apple's private
//  face-id-spinner.ca package scans, resolves into a green faceid.circle
//  checkmark, then the box collapses back into nothing.
//
//  The spinner package and the faceid.circle glyph are private system
//  resources; everything here degrades gracefully if they can't be loaded, so
//  the app never crashes on an OS that moved them.
//

import AppKit
import QuartzCore
import SwiftUI

/// What the box is doing. The recognizer drives this; the view owns the timing
/// of the shape and the package's own springs.
enum FaceIDAnimationState: Equatable {
    /// Collapsed to nothing, invisible.
    case hidden
    /// Box open, rings scanning.
    case scanning
    /// Rings resolved into the green checkmark.
    case matched
    /// A rejected attempt — a brief shake, then back to scanning.
    case failed
}

/// SwiftUI wrapper.
struct FaceIDAnimationView: NSViewRepresentable {
    var state: FaceIDAnimationState

    func makeNSView(context: Context) -> FaceIDAnimationLayerView {
        let view = FaceIDAnimationLayerView()
        view.apply(state, animated: false)
        return view
    }

    func updateNSView(_ nsView: FaceIDAnimationLayerView, context: Context) {
        nsView.apply(state, animated: true)
    }
}

/// The AppKit view that hosts the CALayers. Sized for the 144pt box plus room
/// for its shadow; center it in whatever space it's given.
final class FaceIDAnimationLayerView: NSView {
    // MARK: Geometry
    private let side: CGFloat = 144
    private let pill: CGFloat = 0
    private let expandedRadius: CGFloat = 36

    // MARK: Layers
    private let box = CALayer()
    private let boxShadow = CALayer()
    private var spinner: CALayer?

    // MARK: Apple's package (states/transitions copied verbatim from the demo)
    private var circle: CALayer?
    private var check: CALayer?

    private var currentState: FaceIDAnimationState = .hidden

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        buildLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        buildLayers()
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 180, height: 180) }

    override func layout() {
        super.layout()
        let center = CGPoint(x: bounds.midX.rounded(), y: bounds.midY.rounded())
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        box.position = center
        boxShadow.position = center
        CATransaction.commit()
    }

    // MARK: - Build

    private func buildLayers() {
        guard let root = layer else { return }

        // The notch's shadow lives on a twin layer underneath, because the box
        // clips its contents (and would clip its own shadow).
        let pillBounds = CGRect(x: 0, y: (side - pill) / 2, width: side, height: pill)
        for l in [boxShadow, box] {
            l.bounds = pillBounds
            l.cornerRadius = pill / 2
            l.cornerCurve = .continuous
            l.backgroundColor = NSColor.black.cgColor
            l.opacity = 0
        }
        boxShadow.shadowColor = NSColor.black.cgColor
        boxShadow.shadowOpacity = 0.7
        boxShadow.shadowRadius = 6
        boxShadow.shadowOffset = .zero
        box.masksToBounds = true
        root.addSublayer(boxShadow)
        root.addSublayer(box)

        if let spinner = Self.loadSpinner() {
            self.spinner = spinner
            spinner.position = CGPoint(x: side / 2, y: side / 2)
            spinner.setAffineTransform(CGAffineTransform(scaleX: 1.38, y: 1.38))
            circle = spinner.sublayers?.first { $0.name == "circle" }
            check = spinner.sublayers?.first { $0.name == "checkmark" }
            let faceRounder = spinner.sublayers?.first { $0.name == "face-rounder" }
            faceRounder?.opacity = 0
            tintToGreen()
            box.addSublayer(spinner)
            setValues(states["empty"]!)
        }
    }

    /// Loads Apple's face-id-spinner.ca CAPackage and returns its root layer.
    private static func loadSpinner() -> CALayer? {
        let candidates = [
            "/System/Library/PrivateFrameworks/LocalAuthenticationCoreUI.framework/Versions/A/Resources/face-id-spinner.ca",
            "/System/iOSSupport/System/Library/PrivateFrameworks/LocalAuthenticationCoreUI.framework/Versions/A/Resources/face-id-spinner.ca",
        ]
        guard let packageClass = NSClassFromString("CAPackage"),
              let method = class_getClassMethod(packageClass, NSSelectorFromString("packageWithContentsOfURL:type:options:error:"))
        else { return nil }
        typealias LoadFn = @convention(c) (AnyClass, Selector, NSURL, NSString, NSDictionary?, UnsafeMutablePointer<NSError?>?) -> AnyObject?
        let load = unsafeBitCast(method_getImplementation(method), to: LoadFn.self)
        let sel = NSSelectorFromString("packageWithContentsOfURL:type:options:error:")
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            if let package = load(packageClass, sel, URL(fileURLWithPath: path) as NSURL, "com.apple.coreanimation-bundle" as NSString, nil, nil),
               let root = package.value(forKey: "rootLayer") as? CALayer {
                return root
            }
        }
        return nil
    }

    // MARK: - Green tint + checkmark glyph (from the demo)

    private let green = NSColor(srgbRed: 137 / 255, green: 250 / 255, blue: 150 / 255, alpha: 1)

    private func tintToGreen() {
        for ring in circle?.sublayers ?? [] where (ring.name ?? "").hasPrefix("green circle") {
            if let contents = ring.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID {
                ring.contents = tinted(contents as! CGImage)
            }
        }
        check?.contents = faceidCircle(scale: 4)
    }

    private func tinted(_ image: CGImage) -> CGImage {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.clip(to: rect, mask: image)
        ctx.setFillColor(green.cgColor)
        ctx.fill(rect)
        return ctx.makeImage() ?? image
    }

    private func faceidCircle(scale: CGFloat) -> CGImage? {
        let symbol: NSImage? = Bundle(path: "/System/Library/CoreServices/CoreGlyphsPrivate.bundle")?
            .image(forResource: "faceid.circle")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 72 / 1.175, weight: .regular).applying(.init(paletteColors: [green])))
            ?? NSImage(systemSymbolName: "faceid", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 72 / 1.175, weight: .regular).applying(.init(paletteColors: [green])))
        guard let symbol else { return nil }
        let sideP = 86 * scale
        return NSImage(size: NSSize(width: sideP, height: sideP), flipped: false) { _ in
            let s = symbol.size
            symbol.draw(in: NSRect(x: (86 - s.width) / 2 * scale, y: (86 - s.height) / 2 * scale, width: s.width * scale, height: s.height * scale))
            return true
        }.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    // MARK: - Package states and springs (verbatim from lockscreen.swift)

    private typealias Values = [String: Double]
    private let ringScale = 0.72
    private lazy var states: [String: [CALayer: Values]] = {
        guard let circle, let check else { return [:] }
        return [
            "empty": [circle: ["opacity": 0, "transform.scale.xy": 0.634 * ringScale, "filters.gaussianBlur.inputRadius": 17.3341],
                      check: ["opacity": 0, "transform.scale.xy": 0.634, "filters.gaussianBlur.inputRadius": 17.3341]],
            "faceid": [circle: ["opacity": 1, "transform.scale.xy": 1.123 * ringScale, "filters.gaussianBlur.inputRadius": 1.6583],
                       check: ["opacity": 0, "transform.scale.xy": 0.634, "filters.gaussianBlur.inputRadius": 17.3341]],
            "checkmark": [circle: ["opacity": 0, "transform.scale.xy": 0.883 * ringScale, "filters.gaussianBlur.inputRadius": 15.742],
                          check: ["opacity": 1, "transform.scale.xy": 0.871, "filters.gaussianBlur.inputRadius": 0]],
        ]
    }()

    private struct Spring { var mass = 2.0, stiffness = 300.0, damping = 50.0, duration = 0.8, delay = 0.0 }
    private lazy var transitions: [String: [CALayer: [String: Spring]]] = {
        guard let circle, let check else { return [:] }
        return [
            "faceid": [circle: ["transform.scale.xy": Spring(damping: 30, duration: 2),
                                "opacity": Spring(duration: 0.8, delay: 0.07),
                                "filters.gaussianBlur.inputRadius": Spring(duration: 0.8, delay: 0.07)]],
            "checkmark": [circle: ["transform.scale.xy": Spring(),
                                   "filters.gaussianBlur.inputRadius": Spring(),
                                   "opacity": Spring(delay: 0.1175)],
                          check: ["filters.gaussianBlur.inputRadius": Spring(), "transform.scale.xy": Spring(), "opacity": Spring()]],
            "empty": [circle: ["transform.scale.xy": Spring(), "filters.gaussianBlur.inputRadius": Spring(), "opacity": Spring(delay: 0.1175)],
                      check: ["filters.gaussianBlur.inputRadius": Spring(mass: 1, stiffness: 240, damping: 30, duration: 0.566097),
                              "transform.scale.xy": Spring(mass: 1, stiffness: 240, damping: 30, duration: 0.566097),
                              "opacity": Spring(mass: 1, stiffness: 240, damping: 30, duration: 0.566097)]],
        ]
    }()

    private func setValues(_ values: [CALayer: Values]) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (layer, v) in values { for (k, x) in v { layer.setValue(x, forKeyPath: k) } }
        CATransaction.commit()
    }

    private func go(to state: String) {
        guard let values = states[state] else { return }
        let now = CACurrentMediaTime()
        for (layer, vals) in values {
            for (key, to) in vals {
                let from = (layer.presentation()?.value(forKeyPath: key) as? Double) ?? (layer.value(forKeyPath: key) as? Double) ?? to
                guard from != to else { continue }
                let spec = transitions[state]?[layer]?[key] ?? Spring()
                let a = CASpringAnimation(keyPath: key)
                a.mass = spec.mass; a.stiffness = spec.stiffness; a.damping = spec.damping
                a.duration = spec.duration
                a.beginTime = layer.convertTime(now, from: nil) + spec.delay
                a.fromValue = from; a.toValue = to
                a.fillMode = .backwards
                layer.add(a, forKey: key)
            }
        }
        setValues(values)
    }

    // MARK: - Box open/close (the package's checkmark→* spring)

    private func animateBox(show: Bool) {
        let now = box.convertTime(CACurrentMediaTime(), from: nil)
        let expandedBounds = CGRect(x: 0, y: 0, width: side, height: side)
        let pillBounds = CGRect(x: 0, y: (side - pill) / 2, width: side, height: pill)
        let targetBounds = show ? expandedBounds : pillBounds
        let targetRadius: CGFloat = show ? expandedRadius : pill / 2

        for (key, from, to) in [
            ("bounds", NSValue(rect: box.presentation()?.bounds ?? box.bounds), NSValue(rect: targetBounds)),
            ("cornerRadius", NSNumber(value: Double(box.presentation()?.cornerRadius ?? box.cornerRadius)), NSNumber(value: Double(targetRadius))),
        ] as [(String, Any, Any)] {
            let spring = CASpringAnimation(keyPath: key)
            spring.mass = 1; spring.stiffness = 240; spring.damping = 30; spring.duration = 0.566097
            spring.fromValue = from; spring.toValue = to
            spring.beginTime = now; spring.fillMode = .backwards
            box.add(spring, forKey: key)
            boxShadow.add(spring, forKey: key)
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = box.presentation()?.opacity ?? (show ? 0 : 1)
        fade.toValue = show ? 1 : 0
        fade.duration = show ? 0.1 : 0.08
        fade.beginTime = now + (show ? 0 : 0.34); fade.fillMode = .backwards
        box.add(fade, forKey: "fade")
        boxShadow.add(fade, forKey: "fade")

        CATransaction.begin(); CATransaction.setDisableActions(true)
        for l in [box, boxShadow] {
            l.bounds = targetBounds
            l.cornerRadius = targetRadius
            l.opacity = show ? 1 : 0
        }
        CATransaction.commit()
    }

    private func shake() {
        let shake = CAKeyframeAnimation(keyPath: "position.x")
        let x = box.position.x
        shake.values = [x, x - 8, x + 8, x - 5, x + 5, x]
        shake.duration = 0.4
        box.add(shake, forKey: "shake")
        boxShadow.add(shake, forKey: "shake")
    }

    // MARK: - External state

    func apply(_ state: FaceIDAnimationState, animated: Bool) {
        guard state != currentState else { return }
        let previous = currentState
        currentState = state
        guard spinner != nil else { return }

        switch state {
        case .hidden:
            animateBox(show: false)
            go(to: "empty")
        case .scanning:
            if previous == .hidden { animateBox(show: true) }
            // Leaving the checkmark (re-scan) also resets the rings via "faceid".
            go(to: "faceid")
        case .matched:
            go(to: "checkmark")
        case .failed:
            shake()
            go(to: "faceid")
            // Caller decides when to leave .failed (back to .scanning or .hidden).
        }
    }
}
