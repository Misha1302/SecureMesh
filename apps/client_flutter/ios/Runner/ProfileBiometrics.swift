import CryptoKit
import Flutter
import Foundation
import LocalAuthentication
import Security
import UIKit

private enum UnlockError: Error { case unavailable }

struct BiometricProfileLocation {
  let account: String
  let envelope: URL

  init(path: String) throws {
    let file = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
    let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().standardizedFileURL.path
    guard file.path.hasPrefix(home + "/"), file.pathExtension == "db",
          try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
    else { throw UnlockError.unavailable }
    // Container UUIDs can change on app update. The relative path remains stable.
    let relative = String(file.path.dropFirst(home.count + 1))
    account = SHA256.hash(data: Data(relative.utf8)).map { String(format: "%02x", $0) }.joined()
    envelope = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                           appropriateFor: nil, create: false)
      .appendingPathComponent("SecureMeshBiometricUnlock", isDirectory: true)
      .appendingPathComponent(account)
  }

  var enrolled: Bool { FileManager.default.fileExists(atPath: envelope.path) }

  var query: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: "SecureMesh.profile.biometric.v1",
     kSecAttrAccount as String: account,
     kSecAttrSynchronizable as String: false]
  }

  func forget(context: LAContext) throws {
    var q = query
    q[kSecUseAuthenticationContext as String] = context
    let status = SecItemDelete(q as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw UnlockError.unavailable }
    if enrolled { try FileManager.default.removeItem(at: envelope) }
  }

  func enable(device: String, passphrase: String, context: LAContext) throws {
    guard !enrolled, UUID(uuidString: device)?.uuidString.lowercased() == device,
          !passphrase.isEmpty, passphrase.utf8.count <= 4096
    else { throw UnlockError.unavailable }
    var directory = envelope.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.protectionKey: FileProtectionType.complete])
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try directory.setResourceValues(values)
    let key = SymmetricKey(size: .bits256)
    var plain = try JSONEncoder().encode(["deviceId": device, "passphrase": passphrase])
    defer { plain.resetBytes(in: 0..<plain.count) }
    guard let ciphertext = try AES.GCM.seal(plain, using: key, authenticating: Data(account.utf8)).combined,
          let acl = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                                     .biometryCurrentSet, nil)
    else { throw UnlockError.unavailable }
    // A previous interruption or reinstall can leave a key without its envelope.
    try forget(context: context)
    var record = query
    record[kSecAttrAccessControl as String] = acl
    record[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
    record[kSecUseAuthenticationContext as String] = context
    guard SecItemAdd(record as CFDictionary, nil) == errSecSuccess else { throw UnlockError.unavailable }
    do {
      try ciphertext.write(to: envelope, options: [.atomic, .completeFileProtection])
    } catch {
      try? forget(context: context)
      throw error
    }
  }

  func unlock(context: LAContext) throws -> [String: String] {
    guard enrolled, let size = try envelope.resourceValues(forKeys: [.fileSizeKey]).fileSize,
          (29...8192).contains(size) else { throw UnlockError.unavailable }
    var q = query
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    q[kSecReturnData as String] = true
    q[kSecUseAuthenticationContext as String] = context
    var item: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
          var bytes = item as? Data, bytes.count == 32 else { throw UnlockError.unavailable }
    defer { bytes.resetBytes(in: 0..<bytes.count) }
    let box = try AES.GCM.SealedBox(combined: Data(contentsOf: envelope))
    var plain = try AES.GCM.open(box, using: SymmetricKey(data: bytes), authenticating: Data(account.utf8))
    defer { plain.resetBytes(in: 0..<plain.count) }
    let result = try JSONDecoder().decode([String: String].self, from: plain)
    guard let device = result["deviceId"], UUID(uuidString: device)?.uuidString.lowercased() == device,
          result["passphrase"]?.isEmpty == false else { throw UnlockError.unavailable }
    return result
  }
}

// Flutter dispatches this channel on the platform (main) thread.
final class ProfileBiometrics: NSObject {
  private var current: LAContext?
  private var pending: FlutterResult?

  override init() {
    super.init()
    NotificationCenter.default.addObserver(self, selector: #selector(cancel),
      name: UIApplication.didEnterBackgroundNotification, object: nil)
  }

  @objc private func cancel() {
    let completion = pending
    pending = nil
    current?.invalidate()
    current = nil
    completion?(FlutterError(code: "cancelled", message: nil, details: nil))
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard current == nil else {
      result(FlutterError(code: "busy", message: nil, details: nil)); return
    }
    guard let args = call.arguments as? [String: Any], let path = args["path"] as? String,
          let location = try? BiometricProfileLocation(path: path) else {
      if call.method == "status" { result("unavailable") }
      else { result(FlutterError(code: "unavailable", message: nil, details: nil)) }
      return
    }
    let ctx = LAContext()
    ctx.localizedFallbackTitle = ""
    ctx.touchIDAuthenticationAllowableReuseDuration = 0
    if call.method == "status" {
      let available = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
      if location.enrolled { result(available ? "enrolled" : "recovery") }
      else { result(available ? "available" : "unavailable") }
      return
    }
    if call.method == "forget" {
      ctx.interactionNotAllowed = true
      defer { ctx.invalidate() }
      do { try location.forget(context: ctx); result(nil) }
      catch { result(FlutterError(code: "unavailable", message: nil, details: nil)) }
      return
    }
    guard call.method == "enable" || call.method == "unlock" else { result(FlutterMethodNotImplemented); return }
    let enabling = call.method == "enable"
    guard enabling != location.enrolled, ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    else { result(FlutterError(code: "unavailable", message: nil, details: nil)); return }
    let reason: String
    if args["russian"] as? Bool == true {
      reason = enabling ? "Включите биометрию для этого профиля SecureMesh." : "Откройте профиль SecureMesh."
    } else {
      reason = enabling ? "Enable biometric unlock for this SecureMesh profile." : "Unlock your SecureMesh profile."
    }
    current = ctx
    pending = result
    ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { passed, _ in
      DispatchQueue.main.async {
        guard self.current === ctx else { return }
        self.current = nil
        self.pending = nil
        defer { ctx.invalidate() }
        guard passed, UIApplication.shared.applicationState != .background else {
          result(FlutterError(code: "cancelled", message: nil, details: nil)); return
        }
        // Keychain enforces its own biometric ACL on retrieval. A fresh, just-evaluated
        // context must satisfy it; never replace a rejected read with another source.
        ctx.interactionNotAllowed = true
        do {
          if enabling {
            guard let passphrase = args["passphrase"] as? String, let device = args["deviceId"] as? String
            else { throw UnlockError.unavailable }
            try location.enable(device: device, passphrase: passphrase, context: ctx)
            result(nil)
          } else { result(try location.unlock(context: ctx)) }
        } catch { result(FlutterError(code: "unavailable", message: nil, details: nil)) }
      }
    }
  }
}
