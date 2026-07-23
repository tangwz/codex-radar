import Foundation
import Testing

@testable import CodexRadar

@Suite("UpdateInstallationLocationTests")
struct UpdateInstallationLocationTests {
  private let homeURL = URL(fileURLWithPath: "/Users/test", isDirectory: true)

  @Test("supports an app installed in the system Applications directory")
  func supportsSystemApplicationsDirectory() {
    #expect(evaluate("/Applications/CodexRadar.app", writable: true) == .supported)
  }

  @Test("supports an app installed in the user Applications directory")
  func supportsUserApplicationsDirectory() {
    #expect(evaluate("/Users/test/Applications/CodexRadar.app", writable: true) == .supported)
  }

  @Test("rejects an app installed on a read-only volume")
  func rejectsReadOnlyVolume() {
    #expect(evaluate("/Volumes/ReadOnly/CodexRadar.app", writable: false) == .readOnly)
  }

  @Test("rejects a translocated app")
  func rejectsTranslocatedApp() {
    #expect(
      evaluate(
        "/private/var/folders/a/AppTranslocation/x/CodexRadar.app",
        writable: true
      ) == .translocated
    )
  }

  @Test("rejects an app outside an Applications directory")
  func rejectsUnsupportedLocation() {
    #expect(
      evaluate("/Users/test/Downloads/CodexRadar.app", writable: true)
        == .unsupportedLocation
    )
  }

  private func evaluate(
    _ path: String,
    writable: Bool
  ) -> UpdateInstallationLocation {
    UpdateInstallationLocation.evaluate(
      bundleURL: URL(fileURLWithPath: path, isDirectory: true),
      homeURL: homeURL,
      isWritable: { _ in writable }
    )
  }
}
