import SwiftUI

struct AboutView: View {
  let metadata: AppMetadata

  init(metadata: AppMetadata = .current) {
    self.metadata = metadata
  }

  var body: some View {
    Form {
      Section {
        hero
          .frame(maxWidth: .infinity)
          .listRowBackground(Color.clear)
      }

      Section {
        ForEach(AboutLink.all) { link in
          AboutLinkRow(link: link)
        }
      } header: {
        Text("Links")
      } footer: {
        Text("© 2026 Terence Tang. All rights reserved.")
          .frame(maxWidth: .infinity)
          .multilineTextAlignment(.center)
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
  }

  private var hero: some View {
    VStack(spacing: 10) {
      ApplicationIcon(size: 92)

      VStack(spacing: 3) {
        Text("Codex Radar")
          .font(.title3.bold())
        Text(String(format: AppLocalization.string("Version %@"), metadata.versionString))
          .foregroundStyle(.secondary)
        Text("Track Codex reset signals and local token usage.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 8)
  }
}

private struct AboutLinkRow: View {
  let link: AboutLink
  @State private var isHovered = false

  var body: some View {
    Link(destination: link.url) {
      HStack(spacing: 10) {
        Image(systemName: link.systemImage)
          .frame(width: 18)
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text(LocalizedStringKey(link.titleKey))
          .foregroundStyle(.primary)
        Spacer()
        Image(systemName: "arrow.up.right")
          .font(.caption)
          .foregroundStyle(isHovered ? Color.accentColor : Color.secondary)
          .accessibilityHidden(true)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text(LocalizedStringKey(link.titleKey)))
    .onHover { isHovered = $0 }
  }
}
