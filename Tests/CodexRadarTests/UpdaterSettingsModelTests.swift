import Foundation
import Testing

@testable import CodexRadar

@MainActor
@Suite("UpdaterSettingsModelTests")
struct UpdaterSettingsModelTests {
  @Test("initializes from the provider state")
  func initializesFromProviderState() {
    let provider = FakeUpdaterProvider(
      isAvailable: true,
      unavailableReasonKey: nil,
      automaticallyChecksForUpdates: true,
      automaticallyDownloadsUpdates: true,
      canCheckForUpdates: true
    )

    let model = UpdaterSettingsModel(provider: provider)

    #expect(model.isAvailable)
    #expect(model.unavailableReasonKey == nil)
    #expect(model.automaticUpdatesEnabled)
    #expect(model.canCheckForUpdates)
  }

  @Test("one toggle synchronizes both persisted automatic settings")
  func synchronizesAutomaticSettings() {
    let provider = FakeUpdaterProvider(
      automaticallyChecksForUpdates: true,
      automaticallyDownloadsUpdates: true
    )
    let model = UpdaterSettingsModel(provider: provider)

    model.setAutomaticUpdatesEnabled(false)

    #expect(provider.automaticallyChecksForUpdates == false)
    #expect(provider.automaticallyDownloadsUpdates == false)
    #expect(model.automaticUpdatesEnabled == false)

    let reconstructedModel = UpdaterSettingsModel(provider: provider)
    #expect(reconstructedModel.automaticUpdatesEnabled == false)
  }

  @Test("performs exactly one user-driven check and refreshes availability")
  func checksOnceAndRefreshesAvailability() {
    let provider = FakeUpdaterProvider(canCheckForUpdates: true)
    provider.canCheckAfterUserCheck = false
    let model = UpdaterSettingsModel(provider: provider)

    model.checkForUpdates()

    #expect(provider.checkForUpdatesCallCount == 1)
    #expect(model.canCheckForUpdates == false)
  }

  @Test("does not invoke a disabled provider")
  func doesNotInvokeDisabledProvider() {
    let provider = FakeUpdaterProvider(isAvailable: false, canCheckForUpdates: true)
    let model = UpdaterSettingsModel(provider: provider)

    model.checkForUpdates()

    #expect(provider.checkForUpdatesCallCount == 0)
  }

  @Test("disabled controller exposes no interactive update path")
  func disablesUpdatesWithoutAFeedPath() {
    let controller = DisabledUpdaterController()
    let model = UpdaterSettingsModel(provider: controller)

    model.setAutomaticUpdatesEnabled(true)
    model.checkForUpdates()

    #expect(model.isAvailable == false)
    #expect(model.automaticUpdatesEnabled == false)
    #expect(model.canCheckForUpdates == false)
  }

  @Test("configuration accepts only a Boolean enable flag")
  func parsesOnlyStrictBooleanEnableFlag() {
    #expect(
      UpdateConfiguration(
        infoDictionary: [UpdateConfiguration.enabledKey: true]
      ).updatesEnabled
    )
    #expect(
      UpdateConfiguration(
        infoDictionary: [UpdateConfiguration.enabledKey: false]
      ).updatesEnabled == false
    )
    #expect(
      UpdateConfiguration(
        infoDictionary: [UpdateConfiguration.enabledKey: "true"]
      ).updatesEnabled == false
    )
    #expect(
      UpdateConfiguration(
        infoDictionary: [UpdateConfiguration.enabledKey: 1]
      ).updatesEnabled == false
    )
    #expect(UpdateConfiguration(infoDictionary: [:]).updatesEnabled == false)
  }

  @Test("test bundle receives the feed-free disabled controller")
  func disablesUpdaterForTestBundle() {
    let provider = UpdaterFactory.make(bundle: .module)

    #expect(provider is DisabledUpdaterController)
    #expect(provider.isAvailable == false)
  }
}

@MainActor
private final class FakeUpdaterProvider: UpdaterProviding {
  var isAvailable: Bool
  var unavailableReasonKey: String?
  var automaticallyChecksForUpdates: Bool
  var automaticallyDownloadsUpdates: Bool
  var canCheckForUpdates: Bool
  var canCheckAfterUserCheck: Bool?
  private(set) var checkForUpdatesCallCount = 0

  init(
    isAvailable: Bool = true,
    unavailableReasonKey: String? = nil,
    automaticallyChecksForUpdates: Bool = false,
    automaticallyDownloadsUpdates: Bool = false,
    canCheckForUpdates: Bool = false
  ) {
    self.isAvailable = isAvailable
    self.unavailableReasonKey = unavailableReasonKey
    self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
    self.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
    self.canCheckForUpdates = canCheckForUpdates
  }

  func checkForUpdates() {
    checkForUpdatesCallCount += 1
    if let canCheckAfterUserCheck {
      canCheckForUpdates = canCheckAfterUserCheck
    }
  }
}
