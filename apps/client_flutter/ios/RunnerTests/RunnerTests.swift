import Flutter
import Foundation
import LocalAuthentication
import XCTest
@testable import Runner

final class RunnerTests: XCTestCase {
  func testPrivatePathAndIndependentEnvelopes() throws {
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = root.appendingPathComponent("a.db"), b = root.appendingPathComponent("b.db")
    try Data().write(to: a)
    try Data().write(to: b)
    let first = try BiometricProfileLocation(path: a.path)
    let second = try BiometricProfileLocation(path: b.path)
    XCTAssertNotEqual(first.account, second.account)
    XCTAssertThrowsError(try BiometricProfileLocation(path: "/etc/passwd"))
    XCTAssertThrowsError(try BiometricProfileLocation(path: root.appendingPathComponent("missing.db").path))
    try FileManager.default.createDirectory(at: first.envelope.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: first.envelope)
      try? FileManager.default.removeItem(at: second.envelope)
    }
    try Data(repeating: 1, count: 64).write(to: first.envelope)
    try Data(repeating: 2, count: 64).write(to: second.envelope)
    let context = LAContext()
    context.interactionNotAllowed = true
    defer { context.invalidate() }
    XCTAssertThrowsError(try first.unlock(context: context))
    try first.forget(context: context)
    XCTAssertFalse(first.enrolled)
    XCTAssertTrue(second.enrolled)
    XCTAssertThrowsError(try second.unlock(context: context))
    XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
  }

  @MainActor func testFreshSimulatorLeavesManualUnlockAvailable() throws {
    // This CI device is freshly created, without a passcode or enrolled biometrics.
    XCTAssertFalse(LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil))
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".db")
    try Data().write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let bridge = ProfileBiometrics()
    let args: [String: Any] = ["path": file.path, "deviceId": UUID().uuidString.lowercased(),
                               "passphrase": "disposable fixture", "russian": false]
    var answered = false
    bridge.handle(FlutterMethodCall(methodName: "enable", arguments: args)) { reply in
      answered = true
      XCTAssertEqual((reply as? FlutterError)?.code, "unavailable")
    }
    XCTAssertTrue(answered)
    let location = try BiometricProfileLocation(path: file.path)
    XCTAssertFalse(location.enrolled)
    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
  }
}
