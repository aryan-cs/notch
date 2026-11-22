//
//  FaceIDLearnedAnimation.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Shown when Face Unlock took a while to recognize you and learned that look
//  of your face (FaceLearner). A plus lands on the green face's bottom right,
//  spins into the middle as the face fades and only the ring is left, then
//  unwinds into a checkmark drawn inside the ring.
//
//  It's built inside the green face layer from Apple's spinner package, so it
//  moves, blurs and collapses with it. The face's bitmap is split in two for
//  it: the ring stays as the layer's contents and the features fade on a layer
//  of their own. The motion is sampled from springs and curves into keyframes.
//

import AppKit
import QuartzCore

final class FaceIDLearnedAnimation {
    /// From the start until the checkmark is drawn.
    static let duration: CFTimeInterval = Timing.drawn

    private enum Timing {
        static let pop: Double = 0.75            // the plus lands, once the face has settled
        static let travel = pop + 0.5            // it spins to the middle
        static let spin = 0.9
        static let unwind = travel + spin        // it shrinks to where the check starts
        static let unwindTime = 0.33
        static let draw = unwind + unwindTime    // the check draws, left end first
        static let drawTime = 0.4
        static let drawn = draw + drawTime
    }

    // Geometry in the face bitmap's own units (86 across, y down), measured
    // from the faceid.circle glyph as FaceIDAnimationLayerView draws it.
    private enum Face {
        static let side: CGFloat = 86
        static let center = CGPoint(x: 42.72, y: 42.97)
        static let ringRadius: CGFloat = 28.09        // to the middle of the ring's stroke
        static let ringStroke: CGFloat = 5.06
        static let stroke: CGFloat = 4.63              // the eyes, nose and mouth
        /// The black border around the plus and the check, cutting the ring
        /// where they cross it.
        static let gap: CGFloat = 2.33
        static let corner = CGPoint(x: center.x + ringRadius * 0.7071, y: center.y + ringRadius * 0.7071)
        static let arm: CGFloat = 7.07
        static let armGrowth: CGFloat = 7.9
        static let check = [CGPoint(x: 29.82, y: 44.22), CGPoint(x: 38.56, y: 52.95), CGPoint(x: 56.45, y: 34.23)]
        static let featuresBlur: CGFloat = 6.66
    }

    private let container = CALayer()
    private weak var face: CALayer?
    private let wholeFace: Any?

    /// Starts it on `face` (the package's green checkmark layer, already
    /// showing), with `ring` and `features` being its bitmap split in two.
    init(face: CALayer, box: CALayer, ring: CGImage, features: CGImage, green: CGColor) {
        self.face = face
        wholeFace = face.contents

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = face.bounds
        face.addSublayer(container)

        // Which way is down inside the face layer, whatever the package's
        // transforms and flips: the box's own y axis points up.
        let origin = box.convert(CGPoint.zero, from: container)
        let yStep = box.convert(CGPoint(x: 0, y: 1), from: container)
        let yDown = yStep.y < origin.y
        let scaleX = container.bounds.width / Face.side
        let scaleY = container.bounds.height / Face.side
        func point(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x * scaleX, y: (yDown ? p.y : Face.side - p.y) * scaleY)
        }
        // Turning clockwise on screen.
        let clockwise: CGFloat = yDown ? 1 : -1

        let featuresLayer = CALayer()
        featuresLayer.frame = container.bounds
        featuresLayer.contents = features
        featuresLayer.minificationFilter = .trilinear
        let blur = Self.blurFilter()
        if let blur { featuresLayer.filters = [blur] }
        face.contents = ring
        container.addSublayer(featuresLayer)

        let plusLayer = CALayer()
        let plusEdge = Self.stroke(.black, width: Face.stroke + 2 * Face.gap)
        let plus = Self.stroke(green, width: Face.stroke)
        plusLayer.addSublayer(plusEdge)
        plusLayer.addSublayer(plus)
        plusLayer.opacity = 0
        container.addSublayer(plusLayer)

        let start = point(Face.check[0])
        let dotEdge = Self.dot(.black, diameter: Face.ringStroke + 2 * Face.gap, at: start)
        let dot = Self.dot(green, diameter: Face.ringStroke, at: start)
        container.addSublayer(dotEdge)
        container.addSublayer(dot)

        let checkPath = CGMutablePath()
        checkPath.addLines(between: Face.check.map(point))
        let checkEdge = Self.stroke(.black, width: Face.ringStroke + 2 * Face.gap)
        let check = Self.stroke(green, width: Face.ringStroke)
        for layer in [checkEdge, check] {
            layer.frame = container.bounds
            layer.path = checkPath
            layer.strokeEnd = 0
            container.addSublayer(layer)
        }
        CATransaction.commit()

        // Sample the motion.
        let steps = Int((Timing.drawn * 120).rounded(.up))
        var times: [NSNumber] = []
        var plusPositions: [Any] = [], plusTransforms: [Any] = [], plusOpacities: [Any] = []
        var plusPaths: [Any] = [], plusWidths: [Any] = [], edgeWidths: [Any] = []
        var dotOpacities: [Any] = []
        var featureOpacities: [Any] = [], featureTransforms: [Any] = [], featureBlurs: [Any] = []
        var checkEnds: [Any] = [], checkOpacities: [Any] = []
        for step in 0...steps {
            let t = Timing.drawn * Double(step) / Double(steps)
            times.append(NSNumber(value: Double(step) / Double(steps)))
            let pop = Spring.pop(t - Timing.pop)
            let travel = Spring.box(t - Timing.travel)
            let u = Curve.progress(t, from: Timing.unwind, over: Timing.unwindTime)
            let m = Curve.easeInOut(u)
            let draw = Curve.progress(t, from: Timing.draw, over: Timing.drawTime)

            let mid = Curve.lerp(Face.corner, Face.center, travel)
            plusPositions.append(NSValue(point: point(Curve.lerp(mid, Face.check[0], m))))
            let turns = 675 * Curve.easeInOut(Curve.progress(t, from: Timing.travel, over: Timing.spin)) + 168.75 * m
            var transform = CATransform3DMakeRotation(clockwise * turns * .pi / 180, 0, 0, 1)
            transform = CATransform3DScale(transform, max(0, pop), max(0, pop), 1)
            plusTransforms.append(NSValue(caTransform3D: transform))
            let shown = t >= Timing.pop && u < 1
            plusOpacities.append(shown ? Curve.progress(t, from: Timing.pop, over: 0.06) : 0)
            let arm = (Face.arm + Face.armGrowth * travel) * (1 - m)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: -arm, y: 0)); path.addLine(to: CGPoint(x: arm, y: 0))
            path.move(to: CGPoint(x: 0, y: -arm)); path.addLine(to: CGPoint(x: 0, y: arm))
            plusPaths.append(path)
            let width = Curve.lerp(Face.stroke, Face.ringStroke, travel)
            plusWidths.append(width)
            edgeWidths.append(width + 2 * Face.gap)

            dotOpacities.append(u > 0.9 && draw <= 0 ? 1 : 0)
            featureOpacities.append(1 - travel)
            featureTransforms.append(NSValue(caTransform3D: CATransform3DMakeScale(1 - 0.2 * travel, 1 - 0.2 * travel, 1)))
            featureBlurs.append(Face.featuresBlur * travel)
            checkEnds.append(Curve.easeInOut(draw))
            checkOpacities.append(draw > 0 ? 1 : 0)
        }

        func animate(_ layer: CALayer, _ keyPath: String, _ values: [Any], final: Any) {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = values
            animation.keyTimes = times
            animation.duration = Timing.drawn
            animation.calculationMode = .linear
            layer.add(animation, forKey: "learned." + keyPath)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.setValue(final, forKeyPath: keyPath)
            CATransaction.commit()
        }
        animate(plusLayer, "position", plusPositions, final: plusPositions.last!)
        animate(plusLayer, "transform", plusTransforms, final: plusTransforms.last!)
        animate(plusLayer, "opacity", plusOpacities, final: 0)
        for layer in [plus, plusEdge] { animate(layer, "path", plusPaths, final: plusPaths.last!) }
        animate(plus, "lineWidth", plusWidths, final: plusWidths.last!)
        animate(plusEdge, "lineWidth", edgeWidths, final: edgeWidths.last!)
        for layer in [dot, dotEdge] { animate(layer, "opacity", dotOpacities, final: 0) }
        animate(featuresLayer, "opacity", featureOpacities, final: 0)
        animate(featuresLayer, "transform", featureTransforms, final: featureTransforms.last!)
        if blur != nil { animate(featuresLayer, "filters.gaussianBlur.inputRadius", featureBlurs, final: featureBlurs.last!) }
        for layer in [check, checkEdge] {
            animate(layer, "strokeEnd", checkEnds, final: 1)
            animate(layer, "opacity", checkOpacities, final: 1)
        }
    }

    /// Takes it all away and puts the whole face back.
    func remove() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.removeFromSuperlayer()
        face?.contents = wholeFace
        CATransaction.commit()
    }

    // MARK: - Parts

    private static func stroke(_ color: CGColor, width: CGFloat) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.fillColor = nil
        layer.strokeColor = color
        layer.lineWidth = width
        layer.lineCap = .round
        layer.lineJoin = .round
        return layer
    }

    private static func dot(_ color: CGColor, diameter: CGFloat, at center: CGPoint) -> CALayer {
        let layer = CALayer()
        layer.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        layer.position = center
        layer.cornerRadius = diameter / 2
        layer.backgroundColor = color
        layer.opacity = 0
        return layer
    }

    /// The same private blur filter the package's own layers animate, if
    /// it's there.
    private static func blurFilter() -> NSObject? {
        guard let type = NSClassFromString("CAFilter") as? NSObject.Type,
              let made = type.perform(NSSelectorFromString("filterWithType:"), with: "gaussianBlur"),
              let filter = made.takeUnretainedValue() as? NSObject
        else { return nil }
        filter.setValue("gaussianBlur", forKey: "name")
        filter.setValue(0, forKey: "inputRadius")
        return filter
    }
}

// MARK: - Motion

/// CASpringAnimation's curve, from 0 to 1 at rest.
private enum Spring {
    /// The box's spring (FaceIDAnimationLayerView).
    static let box = curve(mass: 1, stiffness: 240, damping: 30)
    /// A livelier one for the plus landing.
    static let pop = curve(mass: 1, stiffness: 300, damping: 20)

    static func curve(mass: Double, stiffness: Double, damping: Double) -> (Double) -> Double {
        let w0 = (stiffness / mass).squareRoot()
        let zeta = damping / (2 * (stiffness * mass).squareRoot())
        return { t in
            guard t > 0 else { return 0 }
            if zeta < 1 {
                let wd = w0 * (1 - zeta * zeta).squareRoot()
                return 1 - exp(-zeta * w0 * t) * (cos(wd * t) + zeta * w0 / wd * sin(wd * t))
            }
            if zeta == 1 { return 1 - exp(-w0 * t) * (1 + w0 * t) }
            let s = (zeta * zeta - 1).squareRoot()
            let r1 = -w0 * (zeta - s), r2 = -w0 * (zeta + s)
            return 1 + r2 / (r1 - r2) * exp(r1 * t) - r1 / (r1 - r2) * exp(r2 * t)
        }
    }
}

private enum Curve {
    static func progress(_ t: Double, from start: Double, over length: Double) -> Double {
        min(1, max(0, (t - start) / length))
    }

    static func easeInOut(_ x: Double) -> Double {
        x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }

    static func lerp(_ a: CGFloat, _ b: CGFloat, _ p: Double) -> CGFloat {
        a + (b - a) * CGFloat(p)
    }

    static func lerp(_ a: CGPoint, _ b: CGPoint, _ p: Double) -> CGPoint {
        CGPoint(x: lerp(a.x, b.x, p), y: lerp(a.y, b.y, p))
    }
}
