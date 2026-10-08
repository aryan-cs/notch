//
//  FaceUnlockEngine.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The off-main worker: owns the camera, recognizer and liveness, and runs the
//  whole pipeline on one serial queue (mirroring CameraSessionEngine's
//  queue-isolation pattern). It reports small Sendable results back on the main
//  actor; no camera frame or landmark ever crosses to the UI.
//

import AVFoundation
import Foundation
import QuartzCore

final class FaceUnlockEngine: @unchecked Sendable {
    /// One frame's worth of result. During a run, `similarity` is the cosine
    /// match; during enrollment it carries capture progress in 0...1.
    struct Frame: Sendable {
        let faceFound: Bool
        let similarity: Float
        let isLive: Bool
    }

    /// Set once by the owner before any work starts; read on the queue.
    var onFrame: (@MainActor @Sendable (Frame) -> Void)?
    var onEnrolled: (@MainActor @Sendable ([[Float]]) -> Void)?
    var onError: (@MainActor @Sendable (String) -> Void)?

    private enum Job { case idle, enroll(target: Int), run }

    private let queue = DispatchQueue(label: "Notch.FaceUnlock.engine", qos: .userInitiated)
    private lazy var camera = FaceUnlockCamera(queue: queue)
    private let recognizer = FaceRecognizer()
    private let liveness = FaceLiveness()

    private var job: Job = .idle
    private var template: FaceTemplate?
    private var level: LivenessLevel = .standard
    private var enrollAcc: [[Float]] = []
    private var lastCapture: TimeInterval = 0
    private var lastProcess: TimeInterval = 0
    /// Processed frames in the current run (for the diagnostic log).
    private var runFrames = 0
    private let minInterval: TimeInterval = 0.1

    /// The capture session, for a settings-time mirror preview.
    var previewSession: AVCaptureSession { camera.session }

    init() {
        camera.onUnavailable = { [weak self] msg in self?.emitError(msg) }
        camera.onFrame = { [weak self] buffer in self?.handle(buffer) }  // delivered on `queue`
    }

    // MARK: - Control

    /// Stop recognition but keep the camera running (so the preview stays
    /// live, e.g. under a checkmark).
    func idle() {
        queue.async { [weak self] in self?.job = .idle }
    }

    func startEnroll(target: Int) {
        queue.async { [weak self] in
            guard let self, self.ensureModel() else { return }
            self.enrollAcc = []
            self.lastCapture = 0
            self.liveness.reset()
            self.job = .enroll(target: target)
            self.camera.start()
        }
    }

    func startRun(template: FaceTemplate?, level: LivenessLevel) {
        queue.async { [weak self] in
            guard let self, self.ensureModel() else { return }
            self.template = template
            self.level = level
            self.liveness.reset()
            self.runFrames = 0
            Log.faceUnlock.notice("engine run: \(template?.embeddings.count ?? 0) enrolled embeddings, liveness=\(level.rawValue, privacy: .public)")
            self.job = .run
            self.camera.start()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.job = .idle
            self.camera.stop()
        }
    }

    // MARK: - Pipeline (queue only)

    private func ensureModel() -> Bool {
        do { try recognizer.loadModelIfNeeded(); return true }
        catch { emitError("Face model could not be loaded."); return false }
    }

    private var isIdle: Bool { if case .idle = job { return true } else { return false } }

    private func handle(_ buffer: CVPixelBuffer) {
        let now = CACurrentMediaTime()
        guard now - lastProcess >= minInterval, !isIdle else { return }
        lastProcess = now

        let detection = recognizer.process(pixelBuffer: buffer)
        if let detection { liveness.add(detection, at: now) }

        switch job {
        case .idle: break
        case .enroll(let target): handleEnroll(detection, target: target, now: now)
        case .run: handleRun(detection)
        }
    }

    private func handleEnroll(_ detection: FaceDetection?, target: Int, now: TimeInterval) {
        guard let detection, let embedding = detection.embedding,
              isGoodForEnroll(detection), now - lastCapture > 0.35 else {
            emitFrame(Frame(faceFound: detection != nil,
                            similarity: Float(enrollAcc.count) / Float(target), isLive: false))
            return
        }
        lastCapture = now
        enrollAcc.append(embedding)
        emitFrame(Frame(faceFound: true, similarity: Float(enrollAcc.count) / Float(target), isLive: true))
        if enrollAcc.count >= target {
            let acc = enrollAcc
            job = .idle   // keep the camera running for the live preview
            if let cb = onEnrolled { Task { @MainActor in cb(acc) } }
        }
    }

    private func handleRun(_ detection: FaceDetection?) {
        runFrames += 1
        guard let detection, let embedding = detection.embedding else {
            logRun(detection, similarity: nil)
            emitFrame(Frame(faceFound: detection != nil, similarity: 0, isLive: false))
            return
        }
        let sim = template?.bestSimilarity(to: embedding) ?? -1
        logRun(detection, similarity: sim)
        emitFrame(Frame(faceFound: true, similarity: sim, isLive: liveness.isLive(level: level)))
    }

    /// Diagnostics: the first frames of a run (a match can come within a
    /// second), then every ~2 s, of what recognition actually saw.
    private func logRun(_ d: FaceDetection?, similarity: Float?) {
        guard runFrames <= 10 || runFrames % 20 == 0 else { return }
        guard let d else {
            Log.faceUnlock.notice("run frame \(self.runFrames): no face")
            return
        }
        let area = Double(d.boundingBox.width * d.boundingBox.height)
        Log.faceUnlock.notice("run frame \(self.runFrames): area=\(area, format: .fixed(precision: 3)) yaw=\(d.yaw, format: .fixed(precision: 2)) pitch=\(d.pitch, format: .fixed(precision: 2)) roll=\(d.roll, format: .fixed(precision: 2)) \(d.diagnostics, privacy: .public) embedded=\(d.embedding != nil) similarity=\(similarity ?? -1, format: .fixed(precision: 2)) \(self.liveness.summary, privacy: .public)")
    }

    /// Big, roughly-frontal face — good enough to enroll a clean embedding.
    private func isGoodForEnroll(_ d: FaceDetection) -> Bool {
        let area = d.boundingBox.width * d.boundingBox.height
        return area > 0.05 && abs(d.roll) < 0.4 && abs(d.yaw) < 0.5
    }

    private func emitFrame(_ f: Frame) {
        if let cb = onFrame { Task { @MainActor in cb(f) } }
    }

    private func emitError(_ msg: String) {
        if let cb = onError { Task { @MainActor in cb(msg) } }
    }
}
