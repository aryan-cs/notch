// Shows a system Touch ID prompt (from LocalAuthentication, like a browser's)
// for a few seconds, for testing Face Unlock's Touch ID approvals. Prints
// whether it was answered, then cancels it.
//
//   swiftc prompt.swift -o prompt && ./prompt [seconds]
import Foundation
import LocalAuthentication

let context = LAContext()
context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "test Notch (it closes by itself)") { ok, error in
    print("prompt result:", ok, error?.localizedDescription ?? "")
}
DispatchQueue.main.asyncAfter(deadline: .now() + Double(CommandLine.arguments.dropFirst().first ?? "5")!) {
    context.invalidate()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
}
RunLoop.main.run()
