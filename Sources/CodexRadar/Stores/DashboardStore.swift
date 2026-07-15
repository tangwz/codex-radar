import Foundation

@MainActor
final class DashboardStore: ObservableObject {
  @Published private(set) var forecast = ResetForecast.placeholder
  @Published private(set) var tokenEvents: [TokenUsageEvent] = []
  @Published private(set) var isRefreshing = false
  @Published private(set) var lastUpdated: Date?
  @Published private(set) var issues: [String] = []

  private let sessionScanner: CodexSessionScanner
  private let forecastService: ResetForecastService
  private let notificationService: ResetNotificationService
  private var monitorTask: Task<Void, Never>?
  private var expirationTask: Task<Void, Never>?

  init(
    sessionScanner: CodexSessionScanner = CodexSessionScanner(),
    forecastService: ResetForecastService = ResetForecastService(),
    notificationService: ResetNotificationService = ResetNotificationService()
  ) {
    self.sessionScanner = sessionScanner
    self.forecastService = forecastService
    self.notificationService = notificationService
  }

  func startMonitoring() {
    guard monitorTask == nil else { return }
    monitorTask = Task { [weak self] in
      guard let self else { return }
      await self.notificationService.prepare()
      await self.refresh()

      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(600))
        guard !Task.isCancelled else { return }
        await self.refreshForecast()
      }
    }
  }

  func refreshForecast() async {
    guard !isRefreshing else { return }
    isRefreshing = true
    defer {
      isRefreshing = false
      lastUpdated = .now
    }

    do {
      await applyForecast(try await forecastService.fetch())
      let forecastIssuePrefix = AppLocalization.string("Reset forecast: %@")
        .replacingOccurrences(of: "%@", with: "")
      issues.removeAll { $0.hasPrefix(forecastIssuePrefix) }
    } catch {
      expireForecastIfNeeded()
      let forecastIssuePrefix = AppLocalization.string("Reset forecast: %@")
        .replacingOccurrences(of: "%@", with: "")
      issues.removeAll { $0.hasPrefix(forecastIssuePrefix) }
      issues.append(
        String(
          format: AppLocalization.string("Reset forecast: %@"),
          error.localizedDescription
        )
      )
    }
  }

  func refresh() async {
    guard !isRefreshing else { return }
    isRefreshing = true
    issues = []
    defer {
      isRefreshing = false
      lastUpdated = .now
    }

    let scanner = sessionScanner
    let usageTask = Task.detached(priority: .userInitiated) {
      try scanner.scan()
    }

    do {
      await applyForecast(try await forecastService.fetch())
    } catch {
      expireForecastIfNeeded()
      issues.append(
        String(
          format: AppLocalization.string("Reset forecast: %@"),
          error.localizedDescription
        )
      )
    }

    switch await usageTask.result {
    case .success(let events):
      tokenEvents = events
    case .failure(let error):
      issues.append(
        String(
          format: AppLocalization.string("Token usage: %@"),
          error.localizedDescription
        )
      )
    }
  }

  private func applyForecast(_ newForecast: ResetForecast) async {
    forecast = newForecast.expired(at: .now)
    scheduleExpiration()
    await notificationService.notifyIfNeeded(for: forecast)
  }

  private func scheduleExpiration() {
    expirationTask?.cancel()
    guard forecast.isActive, let predictedAt = forecast.predictedAt else { return }

    let delay = max(0, predictedAt.timeIntervalSinceNow)
    expirationTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled, let self else { return }
      self.expireForecastIfNeeded()
    }
  }

  private func expireForecastIfNeeded() {
    forecast = forecast.expired(at: .now)
  }
}
