import Foundation
import Testing

@testable import CodexRadar

@MainActor
struct MenuBarPanelActionsTests {
  private enum Event: Equatable {
    case dismiss
    case openURL(URL)
    case select(SettingsPane)
    case activate
    case openSettingsWindow
    case terminate
    case failure(MenuBarPanelActions.Failure)
  }

  private final class Recorder {
    var events: [Event] = []
  }

  @Test
  func dismissesBeforeOpeningSource() {
    let url = URL(string: "https://example.com/source")!
    let recorder = Recorder()
    let actions = makeActions(recorder: recorder)

    actions.openSource(url)

    #expect(recorder.events == [.dismiss, .openURL(url)])
  }

  @Test
  func dismissesBeforeSelectingAndOpeningEverySettingsPane() {
    let recorder = Recorder()
    let actions = makeActions(recorder: recorder)

    for pane in SettingsPane.allCases {
      recorder.events.removeAll()
      actions.openSettings(pane)

      #expect(
        recorder.events
          == [
            .dismiss,
            .select(pane),
            .activate,
            .openSettingsWindow,
          ]
      )
    }
  }

  @Test
  func dismissesBeforeTermination() {
    let recorder = Recorder()
    let actions = makeActions(recorder: recorder)

    actions.quit()

    #expect(recorder.events == [.dismiss, .terminate])
  }

  @Test
  func reportsFailedRoutesWithoutReopeningThePanel() {
    let url = URL(string: "https://example.com/failure")!
    let recorder = Recorder()
    let actions = MenuBarPanelActions(
      dismissPanel: { recorder.events.append(.dismiss) },
      openURL: {
        recorder.events.append(.openURL($0))
        return false
      },
      selectSettingsPane: { recorder.events.append(.select($0)) },
      activateApplication: { recorder.events.append(.activate) },
      openSettingsWindow: {
        recorder.events.append(.openSettingsWindow)
        return false
      },
      terminateApplication: { recorder.events.append(.terminate) },
      reportFailure: { recorder.events.append(.failure($0)) }
    )

    actions.openSource(url)
    #expect(
      recorder.events
        == [.dismiss, .openURL(url), .failure(.openSource(url))]
    )

    recorder.events.removeAll()
    actions.openSettings(.dashboard)
    #expect(
      recorder.events
        == [
          .dismiss,
          .select(.dashboard),
          .activate,
          .openSettingsWindow,
          .failure(.openSettings(.dashboard)),
        ]
    )
  }

  private func makeActions(recorder: Recorder) -> MenuBarPanelActions {
    MenuBarPanelActions(
      dismissPanel: { recorder.events.append(.dismiss) },
      openURL: {
        recorder.events.append(.openURL($0))
        return true
      },
      selectSettingsPane: { recorder.events.append(.select($0)) },
      activateApplication: { recorder.events.append(.activate) },
      openSettingsWindow: {
        recorder.events.append(.openSettingsWindow)
        return true
      },
      terminateApplication: { recorder.events.append(.terminate) },
      reportFailure: { recorder.events.append(.failure($0)) }
    )
  }
}
