import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, UIDocumentPickerDelegate {
  private let profileBiometrics = ProfileBiometrics()
  private var pendingExport: (URL, FlutterResult)?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // A previous export may have been interrupted by process termination.
    try? FileManager.default.removeItem(at: exportRoot)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private var exportRoot: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("SecureMeshExports", isDirectory: true)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(name: "securemesh/profile_biometrics",
                                       binaryMessenger: engineBridge.applicationRegistrar.messenger())
    channel.setMethodCallHandler(profileBiometrics.handle)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SecureMeshAttachmentExport") else { return }
    FlutterMethodChannel(name: "securemesh/attachment-export", binaryMessenger: registrar.messenger())
      .setMethodCallHandler { [weak self] call, result in
        guard call.method == "save" else { result(FlutterMethodNotImplemented); return }
        guard let self = self, self.pendingExport == nil,
              let args = call.arguments as? [String: Any],
              let data = args["bytes"] as? FlutterStandardTypedData,
              (1...4194304).contains(data.data.count),
              let name = args["name"] as? String, !name.isEmpty,
              name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              var presenter = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        else { result(FlutterError(code: "EXPORT_UNAVAILABLE", message: nil, details: nil)); return }
        while let presented = presenter.presentedViewController { presenter = presented }
        let directory = self.exportRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
          let url = directory.appendingPathComponent(name)
          try data.data.write(to: url, options: [.atomic, .completeFileProtection])
          let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
          picker.delegate = self
          self.pendingExport = (directory, result)
          presenter.present(picker, animated: true)
        } catch {
          try? FileManager.default.removeItem(at: directory)
          result(FlutterError(code: "EXPORT_FAILED", message: nil, details: nil))
        }
      }
  }

  private func finishExport(_ saved: Bool) {
    guard let (directory, result) = pendingExport else { return }
    pendingExport = nil
    try? FileManager.default.removeItem(at: directory)
    result(saved)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    finishExport(!urls.isEmpty)
  }
  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finishExport(false)
  }
}
