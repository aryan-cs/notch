//
//  FaceLiveness.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Cheap passive liveness on an RGB webcam, in the spirit of Glance's cues: a
//  real face blinks and makes small head movements over a couple of seconds; a
//  held-up photo does neither. This raises the bar against casual photo spoofs.
//  It does NOT stop a video of you — the settings UI says so plainly.
//
//  Pure decision logic lives in `LivenessDecision` so it can be unit-tested
//  without a camera.
//

import Defaults
import Foundation
import QuartzCore
import Vision

enum LivenessLevel: String, CaseIterable, Codable {
    case off          // identity only
    case standard     // a blink OR clear head motion
    case strict       // a blink is required

    var label: String {
        switch self {
        case .off: return "Off"
        case .standard: return "Standard"
        case .strict: return "Strict"
        }
    }
}

extension LivenessLevel: Defaults.Serializable {}

/// Pure liveness math, separated for testing.
enum LivenessDecision {
    /// Eye openness proxy: vertical extent over horizontal extent of the eye
    /// landmark points. ~0.1 closed, ~0.3+ open. 0 if not enough points.
    static func openness(_ points: [CGPoint]) -> Double {
        guard points.count >= 3 else { return 0 }
        let xs = points.map { Double($0.x) }, ys = points.map { Double($0.y) }
        let w = (xs.max()! - xs.min()!), h = (ys.max()! - ys.min()!)
        return w > 1e-6 ? h / w : 0
    }

    /// Openness of both eyes: the mean of each eye's own openness. Measuring the
    /// two eyes as one point set divides by the span across both eyes, which
    /// never reads as open, so a blink could never be seen.
    static func eyeOpenness(left: [CGPoint], right: [CGPoint]) -> Double {
        let values = [left, right].map(openness).filter { $0 > 0 }
        return values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    /// A blink is a dip below `closed` after being above `open`, within the window.
    static func blinkSeen(_ opennessSeries: [Double], open: Double = 0.23, closed: Double = 0.15) -> Bool {
        var sawOpen = false
        for v in opennessSeries {
            if v >= open { sawOpen = true }
            if sawOpen && v <= closed { return true }
        }
        return false
    }

    /// Clear head motion: the yaw or pitch range across the window exceeds a few
    /// degrees (micro-movement a static photo can't fake).
    static func motionSeen(yaw: [Double], pitch: [Double], minRadians: Double = 0.05) -> Bool {
        func range(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.max()! - a.min()! }
        return range(yaw) >= minRadians || range(pitch) >= minRadians
    }

    static func isLive(level: LivenessLevel, blink: Bool, motion: Bool) -> Bool {
        switch level {
        case .off: return true
        case .standard: return blink || motion
        case .strict: return blink
        }
    }
}

/// Accumulates recent samples and answers whether the live cues were met.
final class FaceLiveness {
    private struct Sample { let t: TimeInterval; let openness: Double; let yaw: Double; let pitch: Double }
    private var samples: [Sample] = []
    private let window: TimeInterval

    init(window: TimeInterval = 2.5) { self.window = window }

    func reset() { samples.removeAll() }

    func add(_ detection: FaceDetection, at time: TimeInterval = CACurrentMediaTime()) {
        let openness = LivenessDecision.eyeOpenness(
            left: detection.landmarks?.leftEye?.normalizedPoints ?? [],
            right: detection.landmarks?.rightEye?.normalizedPoints ?? [])
        samples.append(Sample(t: time, openness: openness, yaw: detection.yaw, pitch: detection.pitch))
        samples.removeAll { time - $0.t > window }
    }

    func isLive(level: LivenessLevel) -> Bool {
        let blink = LivenessDecision.blinkSeen(samples.map(\.openness))
        let motion = LivenessDecision.motionSeen(yaw: samples.map(\.yaw), pitch: samples.map(\.pitch))
        return LivenessDecision.isLive(level: level, blink: blink, motion: motion)
    }

    /// The cues behind isLive, for the diagnostic log.
    var summary: String {
        func range(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.max()! - a.min()! }
        let open = samples.map(\.openness)
        return String(format: "blink=%d motion=%d open=%.2f-%.2f yawRange=%.3f pitchRange=%.3f n=%d",
                      LivenessDecision.blinkSeen(open) ? 1 : 0,
                      LivenessDecision.motionSeen(yaw: samples.map(\.yaw), pitch: samples.map(\.pitch)) ? 1 : 0,
                      open.min() ?? 0, open.max() ?? 0,
                      range(samples.map(\.yaw)), range(samples.map(\.pitch)), samples.count)
    }
}
