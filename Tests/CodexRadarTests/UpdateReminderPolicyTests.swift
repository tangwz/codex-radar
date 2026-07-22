import Testing

@testable import CodexRadar

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
}
