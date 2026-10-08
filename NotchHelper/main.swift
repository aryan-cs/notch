//
//  main.swift
//  NotchHelper
//
//  Created by Alexander on 2025-11-16.
//

import Foundation

class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    /// This method is where the NSXPCListener configures, accepts, and resumes a new incoming NSXPCConnection.
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // Configure the connection.
        // First, set the interface that the exported object implements.
        newConnection.exportedInterface = NSXPCInterface(with: (any NotchHelperProtocol).self)

        // Configure the interface for callbacks from the helper to the app.
        let listenerInterface = NSXPCInterface(with: (any NotchHelperCallbacks).self)
        listenerInterface.setClasses(
            NSSet(array: [LunarBrightnessUpdate.self]) as! Set<AnyHashable>,
            for: #selector(NotchHelperLunarListener.lunarEventDidUpdate(_:)),
            argumentIndex: 0,
            ofReply: false
        )
        newConnection.remoteObjectInterface = listenerInterface

        // Next, set the object that the connection exports. All messages sent on the connection to this service will be sent to the exported object to handle. The connection retains the exported object.
        let exportedObject = NotchHelperService(connection: newConnection)
        newConnection.exportedObject = exportedObject

        // Resuming the connection allows the system to deliver more incoming messages.
        newConnection.resume()

        // Returning true from this method tells the system that you have accepted this connection. If you want to reject the connection for some reason, call invalidate() on the connection and return false.
        return true
    }
}

// Create the delegate for the service.
let delegate = ServiceDelegate()

// Set up the one NSXPCListener for this service. It will handle all incoming connections.
let listener = NSXPCListener.service()
listener.delegate = delegate

// Resuming the serviceListener starts this service. This method does not return.
listener.resume()
