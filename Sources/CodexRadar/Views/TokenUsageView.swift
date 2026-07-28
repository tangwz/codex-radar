import Charts
import SwiftUI

struct TokenUsageView: View {
  let snapshot: TokenUsageSnapshot?
  @State private var period: TokenUsagePeriod = .day
  @Environment(\.locale) private var locale

  private var metrics: TokenUsageMetrics {
    snapshot?.metrics(for: period) ?? .zero
  }

  private var buckets: [TokenUsageChartBucket] {
    snapshot?.buckets(for: period) ?? []
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("Token usage")
            .font(.title2.weight(.semibold))
          Text("Local Codex session logs")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }

        Spacer()

        Picker("Period", selection: $period) {
          ForEach(TokenUsagePeriod.allCases) { period in
            Text(LocalizedStringKey(period.rawValue)).tag(period)
          }
        }
        .pickerStyle(.segmented)
        .frame(width: 240)
      }

      HStack(spacing: 12) {
        MetricTile(
          title: "Total",
          value: metrics.totalTokens,
          tint: .accentColor,
          locale: locale
        )
        MetricTile(
          title: "Input",
          value: metrics.inputTokens,
          tint: .blue,
          locale: locale
        )
        MetricTile(
          title: "Output",
          value: metrics.outputTokens,
          tint: .purple,
          locale: locale
        )
      }

      if snapshot?.hasUsageData != true {
        ContentUnavailableView(
          "No token data",
          systemImage: "chart.bar.xaxis",
          description: Text("Codex session logs will appear here after your next run.")
        )
        .frame(maxWidth: .infinity, minHeight: 240)
      } else {
        Chart(buckets) { bucket in
          BarMark(
            x: .value("Period", bucket.startDate),
            y: .value("Tokens", bucket.totalTokens)
          )
          .foregroundStyle(Color.accentColor.gradient)
          .cornerRadius(4)
        }
        .chartYAxis {
          AxisMarks(position: .leading) { value in
            AxisGridLine()
            AxisValueLabel {
              if let count = value.as(Int.self) {
                Text(DisplayFormatting.tokenCount(count, locale: locale))
              }
            }
          }
        }
        .frame(height: 230)
      }
    }
    .padding(22)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
  }
}

private struct MetricTile: View {
  let title: LocalizedStringKey
  let value: Int
  let tint: Color
  let locale: Locale

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(DisplayFormatting.tokenCount(value, locale: locale))
        .font(.title3.weight(.semibold))
        .monospacedDigit()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(13)
    .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
  }
}
