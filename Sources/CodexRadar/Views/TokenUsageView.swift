import Charts
import SwiftUI

struct TokenUsageView: View {
  let events: [TokenUsageEvent]
  @State private var period: TokenUsagePeriod = .day
  @Environment(\.locale) private var locale

  private var buckets: [TokenUsageBucket] {
    TokenUsageAggregator.aggregate(events, by: period)
  }

  private var visibleBuckets: [TokenUsageBucket] {
    let limit =
      switch period {
      case .day: 14
      case .month: 12
      case .year: 6
      }
    return Array(buckets.suffix(limit))
  }

  private var totals: (input: Int, cached: Int, output: Int) {
    events.reduce(into: (input: 0, cached: 0, output: 0)) { result, event in
      result.input += event.inputTokens
      result.cached += event.cachedInputTokens
      result.output += event.outputTokens
    }
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
          title: "Total", value: totals.input + totals.output, tint: .accentColor,
          locale: locale)
        MetricTile(title: "Input", value: totals.input, tint: .blue, locale: locale)
        MetricTile(title: "Output", value: totals.output, tint: .purple, locale: locale)
        MetricTile(title: "Cached", value: totals.cached, tint: .green, locale: locale)
      }

      if visibleBuckets.isEmpty {
        ContentUnavailableView(
          "No token data",
          systemImage: "chart.bar.xaxis",
          description: Text("Codex session logs will appear here after your next run.")
        )
        .frame(maxWidth: .infinity, minHeight: 240)
      } else {
        Chart(visibleBuckets) { bucket in
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

        VStack(spacing: 0) {
          ForEach(Array(visibleBuckets.reversed())) { bucket in
            UsageRow(bucket: bucket, period: period, locale: locale)
            if bucket.id != visibleBuckets.first?.id {
              Divider()
            }
          }
        }
        .padding(.horizontal, 14)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
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

private struct UsageRow: View {
  let bucket: TokenUsageBucket
  let period: TokenUsagePeriod
  let locale: Locale

  var body: some View {
    HStack(spacing: 16) {
      Text(DisplayFormatting.bucketDate(bucket.startDate, period: period, locale: locale))
        .font(.subheadline.weight(.medium))
        .frame(width: 95, alignment: .leading)

      Spacer()

      tokenLabel("In", bucket.inputTokens)
      tokenLabel("Out", bucket.outputTokens)
      tokenLabel("Cached", bucket.cachedInputTokens)

      Text(DisplayFormatting.tokenCount(bucket.totalTokens, locale: locale))
        .font(.body.weight(.semibold))
        .monospacedDigit()
        .frame(width: 72, alignment: .trailing)
    }
    .padding(.vertical, 11)
  }

  private func tokenLabel(_ title: LocalizedStringKey, _ value: Int) -> some View {
    (Text(title) + Text(" \(DisplayFormatting.tokenCount(value, locale: locale))"))
      .font(.caption)
      .foregroundStyle(.secondary)
      .frame(width: 82, alignment: .trailing)
  }
}
