import SwiftUI

struct AboutView: View {
  @ObservedObject var updaterSettings: UpdaterSettingsModel
  let metadata: AppMetadata

  init(updaterSettings: UpdaterSettingsModel, metadata: AppMetadata = .current) {
    self.updaterSettings = updaterSettings
    self.metadata = metadata
  }

  var body: some View {
    Form {
      Section {
        hero
          .frame(maxWidth: .infinity)
          .listRowBackground(Color.clear)
      }

      updateSection

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
    .onAppear {
      updaterSettings.refresh()
    }
  }

  @ViewBuilder
  private var updateSection: some View {
    Section {
      if updaterSettings.isAvailable {
        Toggle("Automatically check for updates", isOn: automaticUpdatesBinding)
          .accessibilityLabel(Text("Automatically check for updates"))

        LabeledContent("App Version") {
          HStack(spacing: 12) {
            Text(metadata.versionString)
              .foregroundStyle(.secondary)

            Button("Check for Updates…") {
              updaterSettings.checkForUpdates()
            }
            .disabled(!updaterSettings.canCheckForUpdates)
            .accessibilityLabel(Text("Check for Updates…"))
          }
        }
      } else {
        Text(
          LocalizedStringKey(
            updaterSettings.unavailableReasonKey
              ?? "Updates are available in release builds only."
          )
        )
        .foregroundStyle(.secondary)
      }
    } header: {
      Text("Updates")
    }
  }

  private var automaticUpdatesBinding: Binding<Bool> {
    Binding(
      get: { updaterSettings.automaticUpdatesEnabled },
      set: { updaterSettings.setAutomaticUpdatesEnabled($0) }
    )
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
