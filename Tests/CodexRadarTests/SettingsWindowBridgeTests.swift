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
}
