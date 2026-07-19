import Charts
import SwiftUI

struct ResetHistoryView: View {
  @ObservedObject var store: ResetHistoryStore
  let timeZone: TimeZone
  @Environment(\.locale) private var locale

  var body: some View {
    Group {
      if let history = store.history {
        historyContent(ResetHistoryPresentation(history: history, locale: locale))
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
      header(presentation)
      HStack(spacing: 12) {
        ResetCountTile(title: "This week", count: presentation.weekCount)
        ResetCountTile(title: "This month", count: presentation.monthCount)
      }
      monthlyChart(presentation)
      recentList(presentation)
      historyIssue
    }
  }

  private func header(_ presentation: ResetHistoryPresentation) -> some View {
    HStack {
      Text("Reset statistics")
        .font(.title2.weight(.semibold))

      Spacer()

      Picker(
        "Year",
        selection: Binding(
          get: { store.pendingYear ?? presentation.year },
          set: { store.selectYear($0, timeZone: timeZone) }
        )
      ) {
        ForEach(presentation.availableYears, id: \.self) { year in
          Text(String(year)).tag(year)
        }
      }
      .frame(width: 140)
    }
  }

  @ViewBuilder
  private func monthlyChart(_ presentation: ResetHistoryPresentation) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Monthly resets")
        .font(.headline)

      if store.pendingYear != nil {
        ProgressView("Loading reset statistics")
          .frame(maxWidth: .infinity, minHeight: 220)
      } else {
        Chart(presentation.months) { month in
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
        .frame(height: 220)
        .accessibilityLabel(Text("Monthly resets"))
      }
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
