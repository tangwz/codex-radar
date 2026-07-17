import Testing

@testable import CodexRadar

struct AppMetadataTests {
  @Test
  func formatsVersionAndBuild() {
    let metadata = AppMetadata(
      infoDictionary: [
        "CFBundleShortVersionString": "0.1.0",
        "CFBundleVersion": "1",
      ]
    )

    #expect(metadata.versionString == "0.1.0 (1)")
  }

  @Test
  func degradesWhenVersionFieldsAreMissingOrEmpty() {
    #expect(
      AppMetadata(infoDictionary: ["CFBundleShortVersionString": "0.1.0"])
        .versionString == "0.1.0"
    )
    #expect(
      AppMetadata(infoDictionary: ["CFBundleVersion": "1"])
        .versionString == "—"
    )
    #expect(
      AppMetadata(infoDictionary: ["CFBundleShortVersionString": ""])
        .versionString == "—"
    )
    #expect(AppMetadata(infoDictionary: [:]).versionString == "—")
  }

  @Test
  func exposesTheApprovedLinksInOrder() {
    #expect(AboutLink.all.map(\.id) == [.github, .website, .x, .bilibili])
    #expect(
      AboutLink.all.map(\.url.absoluteString) == [
        "https://github.com/tangwz/codex-radar",
        "https://codex-radar.tangwz.com",
        "https://x.com/shixtang",
        "https://space.bilibili.com/19041535",
      ]
    )
    #expect(AboutLink.all.map(\.titleKey) == ["GitHub", "Website", "X", "Bilibili"])
  }
}
