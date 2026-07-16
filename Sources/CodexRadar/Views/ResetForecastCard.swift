import SwiftUI

struct ResetForecastCard: View {
  let forecast: ResetForecast
  @Environment(\.locale) private var locale

  private var presentation: ResetForecastPresentation {
    ResetForecastPresentation(forecast: forecast)
  }

  private var badgeKey: String {
    if presentation.stale { return "SOURCE UNAVAILABLE" }
    return switch presentation.status {
    case .monitoring: "MONITORING"
    case .candidate: "WATCHING"
    case .announced: "RESET ANNOUNCED"
    case .completed: "RESET COMPLETED"
    }
  }

  private var statusColor: Color {
    if presentation.stale { return .orange }
    return switch presentation.status {
    case .monitoring: .secondary
    case .candidate: .yellow
    case .announced: .red
    case .completed: .green
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Label("NEXT CODEX RESET", systemImage: "scope")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .tracking(1.2)

        Spacer()

        Text(LocalizedStringKey(badgeKey))
          .font(.caption2.weight(.bold))
          .padding(.horizontal, 10)
          .padding(.vertical, 5)
          .background(statusColor.opacity(0.16))
          .foregroundStyle(statusColor)
          .clipShape(Capsule())
      }

      timeContent

      Text(LocalizedStringKey(summaryKey))
        .font(.body)
        .foregroundStyle(.secondary)
        .lineLimit(3)

      if let sourceURL = presentation.sourceURL {
        Divider()

        HStack {
          Label("Signal source", systemImage: "link")
            .font(.subheadline.weight(.medium))
          Spacer()
          Link(destination: sourceURL) {
            HStack(spacing: 5) {
              Text("Tibo on X")
              Image(systemName: "arrow.up.right")
            }
          }
          .buttonStyle(.plain)
          .foregroundStyle(.tint)
        }
      }
    }
    .padding(24)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .strokeBorder(
          LinearGradient(
            colors: [.accentColor.opacity(0.65), .purple.opacity(0.18), .clear],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          ),
          lineWidth: 1.5
        )
    }
    .shadow(color: .accentColor.opacity(0.08), radius: 18, y: 8)
  }

  @ViewBuilder
  private var timeContent: some View {
    switch presentation.timeDisplay {
    case .exact(let at):
      TimelineView(.periodic(from: .now, by: 60)) { context in
        VStack(alignment: .leading, spacing: 6) {
          Text(DisplayFormatting.countdown(to: at, from: context.date, locale: locale))
            .font(.system(size: 46, weight: .semibold, design: .rounded))
            .monospacedDigit()
          Text(
            String(
              format: String(localized: "Expected at %@", bundle: .main, locale: locale),
              DisplayFormatting.absoluteDate(at, locale: locale)
            )
          )
          .font(.title3)
          .foregroundStyle(.secondary)
        }
      }
    case .estimated(let from, let to):
      VStack(alignment: .leading, spacing: 6) {
        Text("Estimated reset window")
          .font(.system(size: 34, weight: .semibold, design: .rounded))
        Text(
          String(
            format: String(
              localized: "Between %@ and %@",
              bundle: .main,
              locale: locale
            ),
            DisplayFormatting.absoluteDate(from, locale: locale),
            DisplayFormatting.absoluteDate(to, locale: locale)
          )
        )
        .font(.title3)
        .foregroundStyle(.secondary)
      }
    case .imminent:
      VStack(alignment: .leading, spacing: 6) {
        Text("Reset expected soon")
          .font(.system(size: 40, weight: .semibold, design: .rounded))
        Text("No precise reset time is available")
          .font(.title3)
          .foregroundStyle(.secondary)
      }
    case .none:
      VStack(alignment: .leading, spacing: 6) {
        Text(LocalizedStringKey(emptyStateTitleKey))
          .font(.system(size: 40, weight: .semibold, design: .rounded))
        Text(LocalizedStringKey(emptyStateDetailKey))
          .font(.title3)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var emptyStateTitleKey: String {
    if presentation.stale { return "Source unavailable" }
    return switch presentation.status {
    case .monitoring: "No reset signal"
    case .candidate: "Possible reset signal"
    case .announced: "Reset announced"
    case .completed: "Ready to use"
    }
  }

  private var emptyStateDetailKey: String {
    if presentation.stale { return "Showing the last verified reset state" }
    return switch presentation.status {
    case .monitoring: "Waiting for Tibo's next reset signal"
    case .candidate: "Watching for a confirmed reset announcement"
    case .announced: "A reset is expected soon"
    case .completed: "The announced reset has completed"
    }
  }

  private var summaryKey: String {
    if presentation.stale { return "The reset source cannot be verified right now." }
    return switch presentation.status {
    case .monitoring: "Monitoring for the next reset signal."
    case .candidate: "Tibo is discussing a possible reset."
    case .announced: "Tibo has announced a reset."
    case .completed: "Tibo has confirmed the reset is complete."
    }
  }
}
