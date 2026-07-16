import AppKit
import Network

@MainActor
final class MonitoringWakeObserver {
  private let pathMonitor = NWPathMonitor()
  private let pathQueue = DispatchQueue(label: "com.codexradar.network-monitor")
  private var wakeToken: NSObjectProtocol?
  private var lastPathSatisfied: Bool?
  private var handler: (@MainActor @Sendable () -> Void)?

  func start(handler: @escaping @MainActor @Sendable () -> Void) {
    guard self.handler == nil else { return }
    self.handler = handler

    wakeToken = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.trigger()
      }
    }

    pathMonitor.pathUpdateHandler = { [weak self] path in
      let isSatisfied = path.status == .satisfied
      Task { @MainActor [weak self] in
        self?.handlePathChange(isSatisfied: isSatisfied)
      }
    }
    pathMonitor.start(queue: pathQueue)
  }

  func stop() {
    if let wakeToken {
      NSWorkspace.shared.notificationCenter.removeObserver(wakeToken)
    }
    wakeToken = nil
    handler = nil
    pathMonitor.cancel()
  }

  private func handlePathChange(isSatisfied: Bool) {
    defer { lastPathSatisfied = isSatisfied }
    guard lastPathSatisfied == false, isSatisfied else { return }
    trigger()
  }

  private func trigger() {
    handler?()
  }
}
