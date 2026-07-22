import Testing

@testable import CodexRadar

@MainActor
struct UpdateReminderPolicyTests {
  @Test
  func postsOnlyForScheduledUpdates() {
    #expect(UpdateReminderPolicy.shouldPost(userInitiated: false))
    #expect(UpdateReminderPolicy.shouldPost(userInitiated: true) == false)
  }

  @Test
  func clearsAPostThatCompletesAfterTheReminderSessionFinishes() {
    var lifecycle = UpdateReminderLifecycle()
    let session = lifecycle.beginSession()

    lifecycle.finishSession()

    #expect(lifecycle.shouldClearAfterPost(for: session))
  }

  @Test
  func clearsADelayedPreviousPostBeforeANewerReminderSessionPosts() {
    var lifecycle = UpdateReminderLifecycle()
    let previousSession = lifecycle.beginSession()
    lifecycle.finishSession()

    let currentSession = lifecycle.beginSession()

    #expect(lifecycle.shouldClearAfterPost(for: previousSession))
    #expect(lifecycle.shouldClearAfterPost(for: currentSession) == false)
  }

  @Test
  func serializesOldPostCleanupBeforePostingTheCurrentReminder() async {
    let oldPostStarted = AsyncGate()
    let allowOldPostToFinish = AsyncGate()
    var events: [String] = []
    var currentReminder: String?
    let coordinator = UpdateReminderCoordinator(
      postReminder: { displayVersion in
        if displayVersion == "old" {
          oldPostStarted.open()
          await allowOldPostToFinish.wait()
        }

        events.append("\(displayVersion) post")
        currentReminder = displayVersion
      },
      clearReminder: {
        if let currentReminder {
          events.append("\(currentReminder) clear")
        }
        currentReminder = nil
      }
    )

    let oldPostTask = coordinator.schedulePost(displayVersion: "old")
    await oldPostStarted.wait()
    coordinator.finishSession()
    let currentPostTask = coordinator.schedulePost(displayVersion: "new")

    await Task.yield()
    allowOldPostToFinish.open()
    await oldPostTask.value
    await currentPostTask.value

    #expect(events == ["old post", "old clear", "new post"])
    #expect(currentReminder == "new")
  }
}

@MainActor
private final class AsyncGate {
  private var isOpen = false
  private var continuation: CheckedContinuation<Void, Never>?

  func wait() async {
    guard !isOpen else { return }

    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func open() {
    isOpen = true
    continuation?.resume()
    continuation = nil
  }
}
