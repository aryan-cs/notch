//
//  FaceUnlockCamera.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  A capture path dedicated to face unlock, separate from the mirror's
//  CameraSessionEngine (which has no frame output). Built-in camera ONLY:
//  Continuity, Desk View, external and virtual cameras are rejected, so an
//  attacker can't feed a replayed stream through a UVC dongle (per the research
//  doc's lock-screen threat model). Delivers raw CVPixelBuffer frames on a
//  caller-supplied serial queue; nothing is retained or written.
//

import AVFoundation
import Foundation

final class FaceUnlockCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// Called on `queue` for every delivered frame.
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// Called on `queue` if the camera can't be started.
    var onUnavailable: ((String) -> Void)?

    /// Exposed read-only so a settings preview can mirror the same session.
    let session = AVCaptureSession()

    private let queue: DispatchQueue
    private let output = AVCaptureVideoDataOutput()
    private var isConfigured = false
    /// Reset on each start() so the log shows whether frames actually arrive.
    private var sawFrame = false

    /// `queue` is the single serial queue the owner uses for all face-unlock
    /// work, so frame handling and control never race.
    init(queue: DispatchQueue) {
        self.queue = queue
        super.init()
    }

    static var isAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    static func requestAccess(_ completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: Task { @MainActor in completion(true) }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in completion(granted) }
            }
        default: Task { @MainActor in completion(false) }
        }
    }

    /// The built-in camera, or nil if this Mac has none available to us.
    private static func builtInCamera() -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        ).devices.first
    }

    /// Call on `queue`.
    func start() {
        guard Self.isAuthorized else { onUnavailable?("Camera access is not granted."); return }
        if !isConfigured, !configure() {
            onUnavailable?("No built-in camera is available.")
            return
        }
        let wasRunning = session.isRunning
        if !wasRunning { session.startRunning() }
        sawFrame = false
        Log.faceUnlock.notice("camera start: wasRunning=\(wasRunning) isRunning=\(self.session.isRunning)")
    }

    /// Call on `queue`.
    func stop() {
        if session.isRunning { session.stopRunning() }
    }

    private func configure() -> Bool {
        guard let device = Self.builtInCamera(),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }
        session.beginConfiguration()
        if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }
        guard session.canAddInput(input) else { session.commitConfiguration(); return false }
        session.addInput(input)
        configureExposure(device)
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { session.commitConfiguration(); return false }
        session.addOutput(output)
        session.commitConfiguration()
        isConfigured = true
        observeSessionProblems()
        return true
    }

    /// Diagnostics only: the OS stopping capture under us (e.g. at the lock
    /// screen) otherwise looks like the camera silently delivering nothing.
    private func observeSessionProblems() {
        let center = NotificationCenter.default
        center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            Log.faceUnlock.error("camera runtime error: \(error?.domain ?? "?", privacy: .public) \(error?.code ?? 0) \(error?.localizedDescription ?? "", privacy: .public)")
        }
        center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { _ in
            Log.faceUnlock.error("camera session was interrupted")
        }
        center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { _ in
            Log.faceUnlock.notice("camera interruption ended")
        }
    }

    /// Keep continuous auto-exposure so a dim room is brightened at the sensor.
    /// macOS exposes no low-light boost or manual exposure for built-in cameras,
    /// so the software normalisation in FaceRecognizer carries the rest.
    private func configureExposure(_ device: AVCaptureDevice) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        device.unlockForConfiguration()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if !sawFrame {
            sawFrame = true
            Log.faceUnlock.notice("camera first frame: \(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer))")
        }
        onFrame?(buffer)
    }
}
