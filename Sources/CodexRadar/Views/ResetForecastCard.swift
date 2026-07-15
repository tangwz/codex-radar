import SwiftUI

struct ResetForecastCard: View {
  let forecast: ResetForecast
  @Environment(\.locale) private var locale

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Label("NEXT CODEX RESET", systemImage: "scope")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .tracking(1.2)

        Spacer()

        Text(
          forecast.isActive
            ? LocalizedStringKey("OFFICIAL WINDOW")
            : LocalizedStringKey("MONITORING")
        )
        .font(.caption2.weight(.bold))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(forecast.isActive ? Color.green.opacity(0.18) : Color.secondary.opacity(0.12))
        .foregroundStyle(forecast.isActive ? .green : .secondary)
        .clipShape(Capsule())
      }

      if let predictedAt = forecast.predictedAt {
        TimelineView(.periodic(from: .now, by: 60)) { context in
          VStack(alignment: .leading, spacing: 6) {
            Text(
              DisplayFormatting.countdown(to: predictedAt, from: context.date, locale: locale)
            )
            .font(.system(size: 46, weight: .semibold, design: .rounded))
            .monospacedDigit()
            Text(
              String(
                format: String(localized: "Expected by %@", bundle: .main, locale: locale),
                DisplayFormatting.absoluteDate(predictedAt, locale: locale)
              )
            )
            .font(.title3)
            .foregroundStyle(.secondary)
          }
        }
      } else {
        VStack(alignment: .leading, spacing: 6) {
          Text("No active window")
            .font(.system(size: 40, weight: .semibold, design: .rounded))
          Text("Waiting for the next official signal")
            .font(.title3)
            .foregroundStyle(.secondary)
        }
      }

      Group {
        if forecast.isActive {
          Text("An official reset announcement is active.")
        } else {
          Text("The last announced reset window has ended. Monitoring remains active.")
        }
      }
      .font(.body)
      .foregroundStyle(.secondary)
      .lineLimit(3)

      Divider()

      HStack {
        Label("Prediction source", systemImage: "link")
          .font(.subheadline.weight(.medium))
        Spacer()
        Link(destination: forecast.sourceURL) {
          HStack(spacing: 5) {
            Text("Tibo on X")
            Image(systemName: "arrow.up.right")
          }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
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
}
