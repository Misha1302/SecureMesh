import Flutter
import Foundation
import LocalAuthentication
import UIKit
import XCTest
@testable import Runner

final class RunnerTests: XCTestCase {
  @MainActor func testBackgroundSnapshotHidesPrivateViewAndRestoresIt() throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let delegate = SceneDelegate()
    let window = UIWindow(windowScene: scene)
    delegate.window = window
    let content = UIView(frame: window.bounds)
    window.addSubview(content)
    let center = NotificationCenter.default
    center.post(name: UIScene.willDeactivateNotification, object: scene)
    let cover = try XCTUnwrap(window.subviews.last)
    XCTAssertFalse(cover === content)
    XCTAssertTrue(cover.isOpaque)
    XCTAssertEqual(cover.frame, window.bounds)
    center.post(name: UIScene.didEnterBackgroundNotification, object: scene)
    XCTAssertTrue(window.subviews.last === cover)
    center.post(name: UIScene.didActivateNotification, object: scene)
    XCTAssertTrue(window.subviews.last === content)
    XCTAssertNil(cover.superview)
  }

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
    try FileManager.default.createDirectory(at: location.envelope.deletingLastPathComponent(),
                                           withIntermediateDirectories: true)
    try Data(repeating: 0, count: 64).write(to: location.envelope)
    defer { try? FileManager.default.removeItem(at: location.envelope) }
    var status: String?
    bridge.handle(FlutterMethodCall(methodName: "status", arguments: args)) { reply in
      status = reply as? String
    }
    XCTAssertEqual(status, "recovery")
    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
  }
}
