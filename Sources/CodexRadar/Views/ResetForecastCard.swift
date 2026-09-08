import SwiftUI

struct ResetForecastCard: View {
  let forecast: ResetForecast
  @Environment(\.locale) private var locale

  private var presentation: ResetForecastPresentation {
    ResetForecastPresentation(forecast: forecast)
  }

  private var detailKey: String {
    if forecast.stale { return "unavailable" }
    return forecast.status == .candidate ? "forecastDisclaimer"
      : forecast.status == .announced ? "announcementDisclaimer" : "waiting"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Label(CodexResetsCopy.text("title", locale: locale), systemImage: "scope")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        if forecast.stale {
          Label("Source unavailable", systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
        }
      }
      Text(CodexResetsCopy.text(detailKey, locale: locale))
        .font(.title3)
        .fixedSize(horizontal: false, vertical: true)
      if forecast.schemaVersion == CodexResetsAPI.schema {
        Text(forecast.message)
          .font(.body)
          .lineLimit(6)
          .textSelection(.enabled)
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(CodexResetsCopy.text("lastAnnouncement", locale: locale))
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(presentation.recentResetText(isInitialLoad: false, locale: locale))
          .font(.body)
      }
      if let sourceURL = presentation.sourceURL {
        Divider()
        Link(destination: sourceURL) {
          Label(CodexResetsCopy.text("source", locale: locale), systemImage: "arrow.up.right")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
      }
      Text(CodexResetsCopy.text("attribution", locale: locale))
        .font(.caption)
        .foregroundStyle(.secondary)
      if forecast.monitoredAt != .distantPast {
        Text(CodexResetsCopy.text("updated", locale: locale) + ": "
          + DisplayFormatting.absoluteDate(forecast.monitoredAt, locale: locale))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(24)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1)
    }
  }
}
