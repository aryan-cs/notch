//
//  NotchHelperService+Sudo.swift
//  NotchHelper
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Face Unlock for sudo: answering sudo's PAM module, and turning the
//  feature on and off.
//

import Foundation

extension NotchHelperService {
    private static let sudoListener = SudoRequestListener()

    @objc func startSudoListener(with reply: @escaping (Bool) -> Void) {
        // Requests go back to the app on the connection that asked, which is
        // only valid inside this call, so it's captured now.
        weak let connection = NSXPCConnection.current()
        let started = Self.sudoListener.start(onRequest: { request, answer in
            let proxy = connection?.remoteObjectProxyWithErrorHandler { error in
                Log.helper.error("Couldn't ask the app about sudo: \(error.localizedDescription, privacy: .public)")
                answer(false)
            } as? NotchHelperCallbacks
            guard let proxy else {
                answer(false)
                return
            }
            proxy.approveSudoRequest([
                "id": request.id,
                "command": request.command,
                "requester": request.requester ?? ""
            ]) { allowed in
                answer(allowed)
            }
        }, onCancel: { id in
            (connection?.remoteObjectProxy as? NotchHelperCallbacks)?.cancelSudoRequest(id)
        })
        reply(started)
    }

    @objc func stopSudoListener() {
        Self.sudoListener.stop()
    }

    @objc func sudoRequestDidStartScanning(_ requestID: String) {
        Self.sudoListener.sendScanning(requestID)
    }

    @objc func sudoIntegrationStatus(with reply: @escaping (Int) -> Void) {
        reply(SudoIntegration.status().rawValue)
    }

    @objc func setSudoIntegrationEnabled(_ enabled: Bool, with reply: @escaping @Sendable (Bool, String?) -> Void) {
        // NSAppleScript, which shows the administrator prompt, needs the main thread.
        DispatchQueue.main.async {
            let result = SudoIntegration.setEnabled(enabled)
            reply(result.succeeded, result.message)
        }
    }
}
