import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  private let cover = UIView()

  override init() {
    super.init()
    cover.backgroundColor = .systemBackground
    cover.isOpaque = true
    cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    let center = NotificationCenter.default
    for name in [UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification] {
      center.addObserver(self, selector: #selector(conceal(_:)), name: name, object: nil)
    }
    center.addObserver(self, selector: #selector(reveal(_:)), name: UIScene.didActivateNotification, object: nil)
  }

  @objc private func conceal(_ notification: Notification) {
    guard let window = window, let scene = notification.object as? UIWindowScene,
          window.windowScene === scene else { return }
    cover.frame = window.bounds
    window.addSubview(cover)
  }

  @objc private func reveal(_ notification: Notification) {
    guard let scene = notification.object as? UIWindowScene, window?.windowScene === scene else { return }
    cover.removeFromSuperview()
  }
}
