//
//  FaceCheck.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The presence guard's camera check: a few seconds of low-resolution video,
//  Vision's face detector on a handful of frames, and a yes or no on whether
//  a second person is in view. Frames go straight from the capture output to
//  Vision and are dropped — never kept, written, logged or sent. Separate
//  from the mirror's CameraSessionEngine, which has no frame output, and
//  only started when the mirror isn't using the camera.
//

import AVFoundation
import Vision

/// Counts frames during a check and decides when there's an answer.
struct FaceCheckTally {
    /// The whole check, camera start-up included.
    static let duration: TimeInterval = 3
    /// Frames closer together than this are skipped, so the ones analyzed
    /// are actually different moments.
    static let frameSpacing: TimeInterval = 0.2
    static let maximumFrames = 8
    /// Frames that need two or more faces: one could be a fluke.
    static let requiredFrames = 2
    /// Fewer frames than this by the deadline isn't enough to say "alone".
    static let minimumFramesForAlone = 4

    private(set) var analyzed = 0
    private(set) var framesWithCompany = 0

    /// Nil until there's an answer.
    mutating func add(faceCount: Int) -> FaceCheckResult? {
        analyzed += 1
        if faceCount >= 2 { framesWithCompany += 1 }
        if framesWithCompany >= Self.requiredFrames { return .confirmed }
        let remaining = Self.maximumFrames - analyzed
        if framesWithCompany + remaining < Self.requiredFrames { return .alone }
        return nil
    }

    /// The answer when time runs out.
    var resultAtDeadline: FaceCheckResult {
        if framesWithCompany >= Self.requiredFrames { return .confirmed }
        return analyzed >= Self.minimumFramesForAlone ? .alone : .unavailable
    }
}

/// Which of Vision's detections count as a person.
enum PresenceFaces {
    /// Of the frame's height: about 3.5 m away on a MacBook camera. Further
    /// away isn't someone reading your screen.
    static let minimumHeight: CGFloat = 0.06
    static let minimumConfidence: Float = 0.5

    static func count(_ faces: [(box: CGRect, confidence: Float)]) -> Int {
        faces.filter { $0.box.height >= minimumHeight && $0.confidence >= minimumConfidence }.count
    }
}

// MARK: - Live camera

/// Runs one check at a time on its own queue; everything below is confined
/// to it.
final class CameraFaceChecker: NSObject, FaceChecking, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "Notch.PresenceGuard.camera", qos: .userInitiated)
    private var session: AVCaptureSession?
    private var tally = FaceCheckTally()
    private var completion: (@MainActor @Sendable (FaceCheckResult) -> Void)?
    private var deadline: DispatchWorkItem?
    private var lastAnalyzed: CMTime = .invalid

    var isAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    func start(completion: @escaping @MainActor @Sendable (FaceCheckResult) -> Void) {
        queue.async { [self] in
            finish(nil)
            self.completion = completion
            tally = FaceCheckTally()
            lastAnalyzed = .invalid

            // Another app on a call would have its video reconfigured under it.
            guard isAuthorized,
                  let device = Self.camera(),
                  !device.isInUseByAnotherApplication,
                  let input = try? AVCaptureDeviceInput(device: device)
            else {
                finish(.unavailable)
                return
            }

            let session = AVCaptureSession()
            session.beginConfiguration()
            if session.canSetSessionPreset(.vga640x480) {
                session.sessionPreset = .vga640x480
            } else if session.canSetSessionPreset(.low) {
                session.sessionPreset = .low
            }
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            // The camera's native format; Vision reads it without a conversion.
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ]
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddInput(input), session.canAddOutput(output) else {
                session.commitConfiguration()
                finish(.unavailable)
                return
            }
            session.addInput(input)
            session.addOutput(output)
            session.commitConfiguration()
            self.session = session

            let deadline = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.finish(self.tally.resultAtDeadline)
            }
            self.deadline = deadline
            queue.asyncAfter(deadline: .now() + FaceCheckTally.duration, execute: deadline)

            session.startRunning()
            if !session.isRunning { finish(.unavailable) }
        }
    }

    func cancel() {
        queue.async { [self] in finish(nil) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard completion != nil else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if lastAnalyzed.isValid, (time - lastAnalyzed).seconds < FaceCheckTally.frameSpacing { return }
        lastAnalyzed = time

        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up)
        guard (try? handler.perform([request])) != nil else { return }
        let faces = PresenceFaces.count((request.results ?? []).map { ($0.boundingBox, $0.confidence) })
        if let result = tally.add(faceCount: faces) {
            finish(result)
        }
    }

    /// Stops the camera — the light goes out — and reports `result`, if any.
    private func finish(_ result: FaceCheckResult?) {
        deadline?.cancel()
        deadline = nil
        if let session {
            session.stopRunning()
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            session.outputs.forEach(session.removeOutput)
            session.commitConfiguration()
        }
        session = nil
        guard let completion else { return }
        self.completion = nil
        if let result {
            Task { @MainActor in completion(result) }
        }
    }

    /// The built-in camera, else an external one. Never a Continuity Camera
    /// (that would wake the user's iPhone) or Desk View.
    private static func camera() -> AVCaptureDevice? {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices
        return devices.first { $0.deviceType == .builtInWideAngleCamera } ?? devices.first
    }
}
