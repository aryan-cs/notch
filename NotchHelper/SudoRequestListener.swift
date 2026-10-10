//
//  SudoRequestListener.swift
//  NotchHelper
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The helper's end of Face Unlock for sudo. sudo's PAM module (NotchSudo)
//  connects to a Unix socket in ~/Library/Application Support and waits;
//  this listener checks who connected, passes the request to the app, and
//  writes back "allow" or "deny".
//
//  The socket isn't in the app's container on purpose: sudo would have to
//  reach into another app's data to get there, and macOS answers that with
//  an "access data from other apps" prompt for the terminal.
//

import Darwin
import Foundation

/// One sudo waiting for an answer.
struct SudoRequest {
    let id: String
    /// The full command line, e.g. "sudo rm -rf build".
    let command: String
    /// The app or tool that ran sudo, e.g. "Ghostty" or "Claude Code".
    let requester: String?
}

/// Its state is only touched on `queue`, which is what makes it safe to
/// share between the XPC connection and the per-request work.
final class SudoRequestListener: @unchecked Sendable {
    static var socketURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/theboringteam.boringnotch", isDirectory: true)
            .appendingPathComponent("sudo.sock")
    }

    typealias RequestHandler = (SudoRequest, @escaping (Bool) -> Void) -> Void

    /// Asks the app. Called on a background queue; `answer` may be called
    /// from any queue, and only the first call counts.
    private var onRequest: RequestHandler?
    /// The sudo behind a request went away before it was answered.
    private var onCancel: ((String) -> Void)?

    private let queue = DispatchQueue(label: "Notch.sudo.listener")
    private var listenSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    /// Waiting requests by ID. Only touched on `queue`.
    private var waiting: [String: Connection] = [:]

    /// Opens the socket if it isn't open already. The handlers replace any
    /// earlier ones, so requests go to the app connection that asked last.
    func start(onRequest: @escaping RequestHandler, onCancel: @escaping (String) -> Void) -> Bool {
        queue.sync {
            self.onRequest = onRequest
            self.onCancel = onCancel
            if listenSocket >= 0 { return true }
            let url = Self.socketURL
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            unlink(url.path)

            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return false }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = Array(url.path.utf8)
            guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
                close(fd)
                Log.helper.error("sudo socket path is too long")
                return false
            }
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                buffer.copyBytes(from: pathBytes)
            }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, listen(fd, 8) == 0 else {
                Log.helper.error("Couldn't open the sudo socket: \(String(cString: strerror(errno)), privacy: .public)")
                close(fd)
                return false
            }
            chmod(url.path, 0o600)
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptPending() }
            source.setCancelHandler { close(fd) }
            source.resume()
            listenSocket = fd
            acceptSource = source
            Log.helper.notice("Listening for sudo requests")
            return true
        }
    }

    func stop() {
        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil
            listenSocket = -1
            unlink(Self.socketURL.path)
            for connection in waiting.values { connection.finish(allowed: false) }
            waiting.removeAll()
        }
    }

    /// Lets the waiting sudo print its "look at the camera" line.
    func sendScanning(_ requestID: String) {
        queue.async { self.waiting[requestID]?.send("scanning\n") }
    }

    // MARK: - Connections

    private func acceptPending() {
        while true {
            let fd = accept(listenSocket, nil, nil)
            guard fd >= 0 else { return }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handle(fd)
            }
        }
    }

    private func handle(_ fd: Int32) {
        guard let client = SudoClient.verify(fd) else {
            Log.helper.error("Refused a sudo request from an unexpected process")
            close(fd)
            return
        }
        guard let command = Self.readRequest(fd) else {
            close(fd)
            return
        }
        let request = SudoRequest(id: UUID().uuidString, command: command, requester: client.requester)
        let connection = Connection(fd: fd)
        connection.onClose = { [weak self] in
            guard let self else { return }
            self.queue.async {
                guard self.waiting.removeValue(forKey: request.id) != nil else { return }
                self.onCancel?(request.id)
            }
        }
        queue.async {
            self.waiting[request.id] = connection
            connection.watchForHangUp()
        }
        Log.helper.notice("sudo request from \(request.requester ?? "unknown", privacy: .public)")

        guard let onRequest = queue.sync(execute: { self.onRequest }) else {
            finish(request.id, connection, allowed: false)
            return
        }
        onRequest(request) { [weak self] allowed in
            self?.finish(request.id, connection, allowed: allowed)
        }
        // Never keep sudo waiting past its own timeout.
        DispatchQueue.global().asyncAfter(deadline: .now() + 65) { [weak self] in
            self?.finish(request.id, connection, allowed: false)
        }
    }

    private func finish(_ id: String, _ connection: Connection, allowed: Bool) {
        queue.async {
            self.waiting.removeValue(forKey: id)
            connection.finish(allowed: allowed)
        }
    }

    /// The PAM module sends "notch-sudo 1", then the command, one per line.
    private static func readRequest(_ fd: Int32) -> String? {
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var byte: UInt8 = 0
        while data.count < 2048 {
            guard read(fd, &byte, 1) == 1 else { return nil }
            data.append(byte)
            let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            if lines.count == 3 {
                guard String(decoding: lines[0], as: UTF8.self) == "notch-sudo 1" else { return nil }
                return String(decoding: lines[1], as: UTF8.self)
            }
        }
        return nil
    }
}

// MARK: - One waiting sudo

/// Guarded by its lock: sudo's hang-up arrives on one queue while the
/// answer is written from another.
private final class Connection: @unchecked Sendable {
    let fd: Int32
    var onClose: (() -> Void)?
    private let lock = NSLock()
    private var isOpen = true
    private var hangUpSource: DispatchSourceRead?

    init(fd: Int32) {
        self.fd = fd
    }

    /// sudo sends nothing after its request, so the socket turning readable
    /// means it closed: Control-C, or it gave up waiting.
    func watchForHangUp() {
        lock.lock()
        defer { lock.unlock() }
        guard isOpen else { return }
        let fd = self.fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        source.setEventHandler { [weak self] in
            var byte: UInt8 = 0
            if recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT) <= 0 {
                self?.closeOnce(notify: true)
            }
        }
        // The descriptor is closed only once the source has stopped using it.
        source.setCancelHandler { close(fd) }
        hangUpSource = source
        source.resume()
    }

    func send(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        guard isOpen else { return }
        _ = text.withCString { write(fd, $0, strlen($0)) }
    }

    func finish(allowed: Bool) {
        send(allowed ? "allow\n" : "deny\n")
        closeOnce(notify: false)
    }

    private func closeOnce(notify: Bool) {
        lock.lock()
        let wasOpen = isOpen
        isOpen = false
        let source = hangUpSource
        hangUpSource = nil
        lock.unlock()
        guard wasOpen else { return }
        if let source {
            source.cancel()
        } else {
            close(fd)
        }
        if notify { onClose?() }
    }
}

// MARK: - Who's asking

/// The process on the other end of a sudo connection.
private struct SudoClient {
    let requester: String?

    /// Only sudo itself, running as root in this login session, may ask.
    /// That keeps out other users, SSH sessions (a different audit session,
    /// so nobody can get approvals from a face at the Mac while they're
    /// remote), and anything that isn't /usr/bin/sudo.
    static func verify(_ fd: Int32) -> SudoClient? {
        var cred = xucred()
        var credLength = socklen_t(MemoryLayout<xucred>.size)
        var token = audit_token_t()
        var tokenLength = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &cred, &credLength) == 0,
              getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &tokenLength) == 0,
              let ownSession = ownAuditSession()
        else { return nil }

        let pid = pid_t(bitPattern: token.val.5)
        let session = token.val.6
        guard session == ownSession else { return nil }

        let path = executablePath(of: pid)
        var trusted = cred.cr_uid == 0 && path == "/usr/bin/sudo"
        #if DEBUG
        // Development builds also answer the PAM module's test harness,
        // which runs as you. An approval means nothing to anyone but sudo.
        trusted = trusted || cred.cr_uid == getuid()
        #endif
        guard trusted else { return nil }
        return SudoClient(requester: requester(above: pid))
    }

    private static func ownAuditSession() -> UInt32? {
        var token = audit_token_t()
        var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &token) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? token.val.6 : nil
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 1 ? parent : nil
    }

    /// Names whoever ran sudo: Claude Code if it's somewhere in the chain of
    /// parent processes, otherwise the nearest app (the terminal).
    private static func requester(above pid: pid_t) -> String? {
        var current = parent(of: pid)
        var app: String?
        var depth = 0
        while let pid = current, depth < 32 {
            if let path = executablePath(of: pid) {
                if (path as NSString).lastPathComponent == "claude" { return "Claude Code" }
                if app == nil, let range = path.range(of: ".app/") {
                    app = ((String(path[..<range.lowerBound]) as NSString).lastPathComponent)
                }
            }
            current = parent(of: pid)
            depth += 1
        }
        return app
    }
}
