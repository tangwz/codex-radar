import Charts
import SwiftUI

struct TokenUsageView: View {
  let snapshot: TokenUsageSnapshot?
  @State private var period: TokenUsagePeriod = .day
  @State private var hoverState = TokenUsageHoverState()
  @Environment(\.locale) private var locale

  private var presentation: TokenUsagePresentation {
    TokenUsagePresentation(snapshot: snapshot, period: period)
  }

  private var selectedBucket: TokenUsageChartBucket? {
    guard let selectedBucketID = hoverState.selectedBucketID else { return nil }
    return presentation.buckets.first { $0.id == selectedBucketID }
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
          value: presentation.metrics.totalTokens,
          tint: .accentColor,
          locale: locale
        )
        MetricTile(
          title: "Input",
          value: presentation.metrics.inputTokens,
          tint: .blue,
          locale: locale
        )
        MetricTile(
          title: "Output",
          value: presentation.metrics.outputTokens,
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
        Chart {
          ForEach(presentation.buckets) { bucket in
            BarMark(
              x: .value("Period", bucket.startDate),
              y: .value("Tokens", bucket.totalTokens)
            )
            .foregroundStyle(Color.accentColor.gradient)
            .cornerRadius(4)
            .opacity(
              hoverState.selectedBucketID == nil || hoverState.selectedBucketID == bucket.id
                ? 1 : 0.42
            )
            .accessibilityLabel(
              Text(
                DisplayFormatting.bucketDate(
                  bucket.startDate,
                  period: period,
                  locale: locale
                )
              )
            )
            .accessibilityValue(Text(accessibilityValue(for: bucket)))
          }

          if let selectedBucket {
            RuleMark(
              x: .value("Selected period", selectedBucket.startDate)
            )
            .foregroundStyle(.secondary.opacity(0.55))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .annotation(
              position: .top,
              overflowResolution: .init(
                x: .fit(to: .chart),
                y: .disabled
              )
            ) {
              TokenUsageTooltip(
                bucket: selectedBucket,
                period: period,
                locale: locale
              )
            }
          }
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
        .chartOverlay { proxy in
          GeometryReader { geometry in
            Rectangle()
              .fill(.clear)
              .contentShape(Rectangle())
              .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                  guard
                    let plotFrame = proxy.plotFrame.map({ geometry[$0] }),
                    hoverState.contains(location, in: plotFrame)
                  else {
                    hoverState.clear()
                    return
                  }
                  let x = location.x - plotFrame.minX
                  guard let date = proxy.value(atX: x, as: Date.self)
                  else {
                    hoverState.clear()
                    return
                  }
                  hoverState.selectNearestBucket(
                    at: location,
                    in: plotFrame,
                    date: date,
                    presentation: presentation
                  )
                case .ended:
                  hoverState.clear()
                }
              }
          }
        }
        .frame(height: 230)
      }
    }
    .onAppear {
      hoverState.updateContext(snapshot: snapshot, period: period)
    }
    .onChange(of: snapshot) {
      hoverState.updateContext(snapshot: snapshot, period: period)
    }
    .onChange(of: period) {
      hoverState.updateContext(snapshot: snapshot, period: period)
    }
    .padding(22)
    .background(
      .regularMaterial,
      in: RoundedRectangle(cornerRadius: 20, style: .continuous)
    )
  }

  private func accessibilityValue(
    for bucket: TokenUsageChartBucket
  ) -> String {
    String(
      format: String(
        localized: "Total %@, Input %@, Output %@",
        bundle: .main,
        locale: locale
      ),
      DisplayFormatting.tokenCount(bucket.totalTokens, locale: locale),
      DisplayFormatting.tokenCount(bucket.inputTokens, locale: locale),
      DisplayFormatting.tokenCount(bucket.outputTokens, locale: locale)
    )
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

private struct TokenUsageTooltip: View {
  let bucket: TokenUsageChartBucket
  let period: TokenUsagePeriod
  let locale: Locale

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(
        DisplayFormatting.bucketDate(
          bucket.startDate,
          period: period,
          locale: locale
        )
      )
      .font(.caption.weight(.semibold))

      metric("Total", bucket.totalTokens)
      metric("Input", bucket.inputTokens)
      metric("Output", bucket.outputTokens)
    }
    .padding(10)
    .background(
      .regularMaterial,
      in: RoundedRectangle(cornerRadius: 10, style: .continuous)
    )
    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
  }

  private func metric(
    _ title: LocalizedStringKey,
    _ value: Int
  ) -> some View {
    HStack(spacing: 12) {
      Text(title)
        .foregroundStyle(.secondary)
      Spacer(minLength: 8)
      Text(DisplayFormatting.tokenCount(value, locale: locale))
        .monospacedDigit()
    }
    .font(.caption)
  }
}
