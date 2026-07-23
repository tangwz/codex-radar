import Charts
import SwiftUI

struct ResetHistoryView: View {
  @ObservedObject var store: ResetHistoryStore
  let timeZone: TimeZone
  @Environment(\.locale) private var locale
  @State private var isShowingMonthInfo = false

  var body: some View {
    Group {
      if let history = store.history {
        historyContent(
          ResetHistoryPresentation(
            history: history,
            selectedRange: store.selectedRange,
            locale: locale
          )
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

  private func historyContent(_ presentation: ResetHistoryPresentation) -> some View {
    VStack(alignment: .leading, spacing: 18) {
      header
      HStack(spacing: 12) {
        ResetCountTile(title: "This week", count: presentation.weekCount)
        ResetCountTile(title: "This month", count: presentation.monthCount)
      }
      monthlyChart(presentation)
      recentList(presentation)
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
    }
  }

  @ViewBuilder
  private func monthlyChart(_ presentation: ResetHistoryPresentation) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Resets by month")
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
            Text(rangeLabel(range)).tag(range)
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
            monthlyBars(presentation.months)
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
      monthlyBars(presentation.months)
        .frame(height: 220)
    }
  }

  private func monthlyBars(_ months: [ResetHistoryPresentation.Month]) -> some View {
    Chart(months) { month in
      BarMark(
        x: .value("Month", month.label),
        y: .value("Count", month.count)
      )
      .foregroundStyle(Color.accentColor.gradient)
      .cornerRadius(4)
      .annotation(position: .top) {
        Text(month.count, format: .number)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityLabel(Text("Resets by month"))
  }

  private func scrollToLatestMonth(
    in presentation: ResetHistoryPresentation,
    with proxy: ScrollViewProxy
  ) {
    guard let latestMonthID = presentation.months.last?.id else { return }
    proxy.scrollTo(latestMonthID, anchor: .trailing)
  }

  private func rangeLabel(_ range: ResetHistoryRange) -> LocalizedStringKey {
    switch range {
    case .threeMonths: "3M"
    case .sixMonths: "6M"
    case .twelveMonths: "12M"
    case .all: "All"
    }
  }

  private func recentList(_ presentation: ResetHistoryPresentation) -> some View {
    let recent = Array(presentation.recent.prefix(5))

    return VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Recent resets")
          .font(.headline)
        Spacer()
        Text("Latest 5")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if presentation.recent.isEmpty {
        Text("No reset history")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
      } else {
        VStack(spacing: 0) {
          ForEach(recent) { event in
            HStack(spacing: 10) {
              Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
              Text(event.dateTime)
                .monospacedDigit()
              Spacer()
            }
            .padding(.vertical, 10)

            if event.id != recent.last?.id {
              Divider()
            }
          }
        }
        .padding(.horizontal, 14)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
      }
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
