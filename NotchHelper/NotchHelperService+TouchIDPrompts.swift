//
//  NotchHelperService+TouchIDPrompts.swift
//  NotchHelper
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Face Unlock for the system's Touch ID prompts: tells the app when one
//  appears, and fills it in when the app approves it.
//

import ApplicationServices
import Foundation

extension NotchHelperService {
    private static let touchIDPrompts = TouchIDPromptWatcher()

    @objc func startTouchIDPromptWatching(with reply: @escaping (Bool) -> Void) {
        guard AXIsProcessTrusted() else {
            reply(false)
            return
        }
        // Prompts go to the app on the connection that asked, which is only
        // valid inside this call, so it's captured now.
        weak let connection = NSXPCConnection.current()
        Self.touchIDPrompts.start(onPrompt: { [weak self] prompt in
            // Without a saved password there's nothing to fill in.
            guard self?.hasStoredPassword == true else { return }
            let proxy = connection?.remoteObjectProxyWithErrorHandler { error in
                Log.helper.error("Couldn't ask the app about a Touch ID prompt: \(error.localizedDescription, privacy: .public)")
            } as? NotchHelperCallbacks
            proxy?.approveTouchIDPrompt(prompt.dictionary) { allowed in
                // Only if the very same prompt is still up.
                guard allowed, Self.touchIDPrompts.isOpen(prompt.id) else { return }
                self?.fillTouchIDPrompt(prompt)
            }
        }, onClose: { id in
            (connection?.remoteObjectProxy as? NotchHelperCallbacks)?.touchIDPromptDidClose(id)
        })
        reply(true)
    }

    @objc func stopTouchIDPromptWatching() {
        Self.touchIDPrompts.stop()
    }
}
