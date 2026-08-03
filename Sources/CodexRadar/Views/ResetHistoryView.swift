import Charts
import SwiftUI

struct ResetHistoryView: View {
  @ObservedObject var store: ResetHistoryStore
  let timeZone: TimeZone
  @Environment(\.locale) private var locale
  @State private var isShowingMonthInfo = false
  @State private var selectedMetric: ResetHistoryMetric = .both
  @State private var hoveredMonthID: String?

  var body: some View {
    Group {
      if let history = store.history {
        historyContent(
          ResetHistoryPresentation(
            history: history,
            selectedRange: store.selectedRange,
            metric: selectedMetric,
            locale: locale
          ),
          radar: ResetRadarPresentation(history: history, locale: locale)
        )
      } else if store.issue != nil && !store.isLoading {
        unavailableContent
      } else {
        loadingContent
      }
    }
    .padding(22)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
  }

  private func historyContent(
    _ presentation: ResetHistoryPresentation,
    radar: ResetRadarPresentation?
  ) -> some View {
    VStack(alignment: .leading, spacing: 18) {
      header
      HStack(spacing: 12) {
        ResetCountTile(title: "This week", count: presentation.weekCount)
        ResetCountTile(title: "This month", count: presentation.monthCount)
      }
      if let radar {
        ResetRadarView(presentation: radar)
      } else {
        ResetRadarUnavailableView()
      }
      monthlyChart(presentation)
      historyIssue
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Text("Reset statistics")
        .font(.title2.weight(.semibold))

      if store.pendingRange != nil {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel(Text("Loading reset statistics"))
      }

      Spacer()

      Picker("Reset type", selection: $selectedMetric) {
        Text("Both")
          .tag(ResetHistoryMetric.both)
        Text("Hard")
          .tag(ResetHistoryMetric.hard)
        Text("Banked")
          .tag(ResetHistoryMetric.banked)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(width: 270)
      .onChange(of: selectedMetric) {
        hoveredMonthID = nil
      }
    }
  }

  @ViewBuilder
  private func monthlyChart(_ presentation: ResetHistoryPresentation) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
          Text(chartTitle(presentation.metric))
            .font(.headline)
          Text(presentation.rangeDescription)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Button {
          isShowingMonthInfo.toggle()
        } label: {
          Image(systemName: "info.circle")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("About monthly reset statistics"))
        .help("About monthly reset statistics")
        .popover(isPresented: $isShowingMonthInfo) {
          Text("Months follow natural boundaries in your selected time zone.")
            .padding()
            .frame(width: 280)
        }

        Spacer()

        Picker(
          "Time range",
          selection: Binding(
            get: { store.pendingRange ?? store.selectedRange },
            set: { store.selectRange($0, timeZone: timeZone) }
          )
        ) {
          ForEach(ResetHistoryRange.allCases) { range in
            Text(rangeLabel(range))
              .accessibilityLabel(Text(rangeAccessibilityLabel(range)))
              .tag(range)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 240)
      }

      chartContent(presentation)
        .opacity(store.pendingRange == nil ? 1 : 0.55)
        .animation(.easeInOut(duration: 0.15), value: store.pendingRange)
    }
  }

  @ViewBuilder
  private func chartContent(_ presentation: ResetHistoryPresentation) -> some View {
    if presentation.selectedRange == .all {
      GeometryReader { proxy in
        ScrollViewReader { scrollProxy in
          ScrollView(.horizontal) {
            monthlyBars(presentation.months, metric: presentation.metric)
              .frame(
                width: max(proxy.size.width, CGFloat(presentation.months.count) * 56),
                height: 220
              )
              .id(presentation.months.last?.id ?? "")
          }
          .onAppear {
            scrollToLatestMonth(in: presentation, with: scrollProxy)
          }
          .onChange(of: presentation.months.last?.id) {
            scrollToLatestMonth(in: presentation, with: scrollProxy)
          }
        }
      }
      .frame(height: 220)
    } else {
      monthlyBars(presentation.months, metric: presentation.metric)
        .frame(height: 220)
    }
  }

  private func monthlyBars(
    _ months: [ResetHistoryPresentation.Month],
    metric: ResetHistoryMetric
  ) -> some View {
    Chart {
      ForEach(months) { month in
        BarMark(
          x: .value("Month", month.id),
          y: .value("Count", month.count)
        )
        .foregroundStyle(Color.accentColor.gradient)
        .cornerRadius(4)
        .accessibilityLabel(Text(monthAccessibilityLabel(month, metric: metric)))
      }

      if let hoveredMonth = months.first(where: { $0.id == hoveredMonthID }) {
        RuleMark(
          x: .value("Month", hoveredMonth.id)
        )
        .foregroundStyle(.clear)
        .annotation(position: .top, spacing: 8) {
          Text(monthSummary(hoveredMonth))
            .font(.caption.weight(.medium))
            .monospacedDigit()
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
              .regularMaterial,
              in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
        }
      }
    }
    .chartXAxis {
      AxisMarks(values: months.map(\.id)) { value in
        AxisValueLabel {
          if let monthID = value.as(String.self),
            let month = months.first(where: { $0.id == monthID })
          {
            Text(month.label)
          }
        }
      }
    }
    .chartOverlay { chartProxy in
      GeometryReader { geometryProxy in
        Color.clear
          .contentShape(Rectangle())
          .onContinuousHover { phase in
            switch phase {
            case .active(let location):
              guard let plotFrame = chartProxy.plotFrame else {
                hoveredMonthID = nil
                return
              }
              let plotRect = geometryProxy[plotFrame]
              let plotX = location.x - plotRect.minX
              guard plotX >= 0, plotX <= plotRect.width else {
                hoveredMonthID = nil
                return
              }
              let monthID: String? = chartProxy.value(atX: plotX)
              hoveredMonthID = months.contains(where: { $0.id == monthID }) ? monthID : nil
            case .ended:
              hoveredMonthID = nil
            }
          }
      }
    }
    .accessibilityLabel(Text(chartTitle(metric)))
  }

  private func scrollToLatestMonth(
    in presentation: ResetHistoryPresentation,
    with proxy: ScrollViewProxy
  ) {
    guard let latestMonthID = presentation.months.last?.id else { return }
    Task { @MainActor in
      await Task.yield()
      proxy.scrollTo(latestMonthID, anchor: .trailing)
    }
  }

  private func rangeLabel(_ range: ResetHistoryRange) -> LocalizedStringKey {
    switch range {
    case .threeMonths: "3M"
    case .sixMonths: "6M"
    case .twelveMonths: "12M"
    case .all: "All"
    }
  }

  private func chartTitle(_ metric: ResetHistoryMetric) -> LocalizedStringKey {
    switch metric {
    case .both: "Hard + banked resets by month"
    case .hard: "Hard resets by month"
    case .banked: "Banked resets by month"
    }
  }

  private func monthSummary(_ month: ResetHistoryPresentation.Month) -> String {
    String(
      format: String(
        localized: "%@, %lld resets",
        bundle: .main,
        locale: locale
      ),
      locale: locale,
      month.label,
      Int64(month.count)
    )
  }

  private func monthAccessibilityLabel(
    _ month: ResetHistoryPresentation.Month,
    metric: ResetHistoryMetric
  ) -> String {
    let localizedMetric: String = switch metric {
    case .both:
      String(localized: "Both", bundle: .main, locale: locale)
    case .hard:
      String(localized: "Hard", bundle: .main, locale: locale)
    case .banked:
      String(localized: "Banked", bundle: .main, locale: locale)
    }
    return "\(localizedMetric): \(monthSummary(month))"
  }

  private func rangeAccessibilityLabel(_ range: ResetHistoryRange) -> LocalizedStringKey {
    switch range {
    case .threeMonths: "3 months"
    case .sixMonths: "6 months"
    case .twelveMonths: "12 months"
    case .all: "All months"
    }
  }

  @ViewBuilder
  private var historyIssue: some View {
    if let issue = store.issue {
      Label(issue, systemImage: "exclamationmark.triangle")
        .font(.caption)
        .foregroundStyle(.orange)
    }
  }

  private var loadingContent: some View {
    ProgressView("Loading reset statistics")
      .frame(maxWidth: .infinity, minHeight: 180)
  }

  private var unavailableContent: some View {
    ContentUnavailableView {
      Label("Reset history unavailable", systemImage: "chart.bar.xaxis")
    } description: {
      if let issue = store.issue {
        Text(issue)
      }
    } actions: {
      Button("Retry") {
        store.refresh(timeZone: timeZone)
      }
    }
    .frame(maxWidth: .infinity, minHeight: 180)
  }
}

private struct ResetCountTile: View {
  let title: LocalizedStringKey
  let count: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(count, format: .number)
        .font(.title3.weight(.semibold))
        .monospacedDigit()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(13)
    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
  }
}
