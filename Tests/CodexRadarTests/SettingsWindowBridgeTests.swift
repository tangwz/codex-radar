import AppKit
import Testing

@testable import CodexRadar

@MainActor
struct SettingsWindowBridgeTests {
  @Test
  func usesThePreferredSettingsPathFirst() {
    var attempts: [SettingsWindowOpener.Path] = []
    let opener = SettingsWindowOpener(
      notification: {
        attempts.append(.notification)
        return true
      },
      appKit: {
        attempts.append(.appKit)
        return true
      }
    )

    #expect(opener.open(preferred: .notification))
    #expect(attempts == [.notification])
  }

  @Test
  func fallsBackWhenThePreferredPathIsUnavailable() {
    var attempts: [SettingsWindowOpener.Path] = []
    let opener = SettingsWindowOpener(
      notification: {
        attempts.append(.notification)
        return true
      },
      appKit: {
        attempts.append(.appKit)
        return false
      }
    )

    #expect(opener.open(preferred: .appKit))
    #expect(attempts == [.appKit, .notification])
  }

  @Test
  func reportsFailureWhenNeitherPathHandlesTheRequest() {
    let opener = SettingsWindowOpener(
      notification: { false },
      appKit: { false }
    )

    #expect(!opener.open(preferred: .notification))
  }

  @Test
  func keepaliveWindowIsOrderedOutAfterScenePresentationAndExcludedFromAccessibility() async {
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    defer { window.close() }
    let hostedContent = NSView(frame: window.contentView?.bounds ?? .zero)
    window.contentView = hostedContent
    let configurator = KeepaliveWindowConfiguratorView()
    hostedContent.addSubview(configurator)

    window.orderFront(nil)
    #expect(window.isVisible)
    await advanceMainQueue()

    #expect(!window.isVisible)
    #expect(window.contentView === hostedContent)
    #expect(configurator.window === window)
    #expect(!window.isAccessibilityElement())
    #expect(window.isAccessibilityHidden())
    #expect(!hostedContent.isAccessibilityElement())
    #expect(hostedContent.isAccessibilityHidden())
    #expect(!configurator.isAccessibilityElement())
    #expect(configurator.isAccessibilityHidden())
  }
}

@MainActor
private func advanceMainQueue() async {
  await withCheckedContinuation { continuation in
    DispatchQueue.main.async {
      continuation.resume()
    }
  }
}
