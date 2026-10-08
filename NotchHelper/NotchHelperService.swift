//
//  NotchHelperService.swift
//  NotchHelper
//
//  Created by Alexander on 2025-11-16.
//
//  The object the app talks to over XPC. Each area of work lives in its
//  own extension: NotchHelperService+Accessibility, +AppleDevices,
//  +Brightness, +FaceUnlock, +FocusShortcuts and +Notifications.
//

import AppKit
import Foundation

class NotchHelperService: NSObject, NotchHelperProtocol {
    weak var connection: NSXPCConnection?

    let lunarStateQueue = DispatchQueue(label: "NotchHelper.lunar.state")
    let lunarExecutableURL = URL(fileURLWithPath: "/Applications/Lunar.app/Contents/MacOS/Lunar")
    var lunarProcess: Process?
    var lunarPipeHandler: JSONLinesPipeHandler?
    var lunarStreamTask: Task<Void, Never>?
    var lunarListener: NotchHelperLunarListener?

    init(connection: NSXPCConnection) {
        self.connection = connection
        super.init()
    }

    override init() {
        super.init()
    }

    deinit {
        var processToTerminate: Process?
        var taskToCancel: Task<Void, Never>?
        var pipeHandlerToClose: JSONLinesPipeHandler?

        lunarStateQueue.sync {
            processToTerminate = self.lunarProcess
            self.lunarProcess = nil

            taskToCancel = self.lunarStreamTask
            self.lunarStreamTask = nil

            pipeHandlerToClose = self.lunarPipeHandler
            self.lunarPipeHandler = nil

            self.lunarListener = nil
        }

        taskToCancel?.cancel()
        if let p = processToTerminate, p.isRunning { p.terminate() }
        if let ph = pipeHandlerToClose {
            Task { await ph.close() }
        }
    }
}
