import Foundation

enum UpdateInstallationLocation: Equatable, Sendable {
  case supported
  case readOnly
  case translocated
  case unsupportedLocation

  static func evaluate(
    bundleURL: URL,
    homeURL: URL,
    isWritable: (URL) -> Bool
  ) -> Self {
    let standardizedBundleURL = bundleURL.standardizedFileURL

    if standardizedBundleURL.pathComponents.contains("AppTranslocation") {
      return .translocated
    }

    guard isWritable(standardizedBundleURL) else {
      return .readOnly
    }

    let installationDirectory = standardizedBundleURL.deletingLastPathComponent()
    let systemApplicationsURL = URL(
      fileURLWithPath: "/Applications",
      isDirectory: true
    ).standardizedFileURL
    let userApplicationsURL = homeURL
      .appendingPathComponent("Applications", isDirectory: true)
      .standardizedFileURL

    guard installationDirectory == systemApplicationsURL
      || installationDirectory == userApplicationsURL
    else {
      return .unsupportedLocation
    }

    return .supported
  }
}
