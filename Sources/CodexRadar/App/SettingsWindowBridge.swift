import AppKit
import SwiftUI

extension Notification.Name {
  static let codexRadarOpenSettings = Notification.Name("CodexRadar.OpenSettings")
}

@MainActor
final class SettingsOpenRequest {
  var wasHandled = false
}

@MainActor
struct SettingsWindowOpener {
  enum Path: Equatable {
    case notification
    case appKit
  }

  private let notification: () -> Bool
  private let appKit: () -> Bool

  init(
    notification: @escaping () -> Bool,
    appKit: @escaping () -> Bool
  ) {
    self.notification = notification
    self.appKit = appKit
  }

  static func live() -> Self {
    Self(
      notification: {
        let request = SettingsOpenRequest()
        NotificationCenter.default.post(name: .codexRadarOpenSettings, object: request)
        return request.wasHandled
      },
      appKit: {
        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
      }
    )
  }

  func open(preferred: Path) -> Bool {
    let attempts =
      preferred == .notification
      ? [notification, appKit]
      : [appKit, notification]

    return attempts[0]() || attempts[1]()
  }
}

struct SettingsOpenBridgeView: View {
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    Color.clear
      .frame(width: 20, height: 20)
      .background(KeepaliveWindowConfigurator())
      .onReceive(NotificationCenter.default.publisher(for: .codexRadarOpenSettings)) {
        notification in
        (notification.object as? SettingsOpenRequest)?.wasHandled = true
        Task { @MainActor in
          openSettings()
        }
      }
  }
}

@MainActor
struct KeepaliveWindowConfigurator: NSViewRepresentable {
  func makeNSView(context: Context) -> KeepaliveWindowConfiguratorView {
    KeepaliveWindowConfiguratorView()
  }

  func updateNSView(_ nsView: KeepaliveWindowConfiguratorView, context: Context) {}
}

@MainActor
final class KeepaliveWindowConfiguratorView: NSView {
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard let window else { return }

    window.identifier = NSUserInterfaceItemIdentifier("CodexRadarLifecycleKeepalive")
    window.styleMask = [.borderless]
    window.collectionBehavior = [.auxiliary, .ignoresCycle, .transient, .canJoinAllSpaces]
    window.isExcludedFromWindowsMenu = true
    window.level = .floating
    window.isOpaque = false
    window.alphaValue = 0
    window.backgroundColor = .clear
    window.hasShadow = false
    window.ignoresMouseEvents = true
    window.canHide = false
    window.setContentSize(NSSize(width: 1, height: 1))
    window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
  }
}
