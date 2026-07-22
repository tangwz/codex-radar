import Foundation
import Testing
@preconcurrency import UserNotifications

@testable import CodexRadar

@MainActor
struct UpdateReminderNotificationServiceTests {
  @Test
  func buildsLocalizedPresentation() {
    #expect(
      UpdateReminderNotificationPresentation.localized(
        displayVersion: "1.2.3",
        language: .english,
        bundle: .module
      ) == UpdateReminderNotificationPresentation(
        title: "A new CodexRadar update is available",
        body: "Version 1.2.3 is now available."
      )
    )
    #expect(
      UpdateReminderNotificationPresentation.localized(
        displayVersion: "1.2.3",
        language: .simplifiedChinese,
        bundle: .module
      ) == UpdateReminderNotificationPresentation(
        title: "CodexRadar \u{6709}\u{65B0}\u{7248}\u{672C}\u{53EF}\u{7528}",
        body: "\u{7248}\u{672C} 1.2.3 \u{73B0}\u{5DF2}\u{53EF}\u{7528}\u{3002}"
      )
    )
  }

  @Test
  func postsOneStableReminderWhenAuthorized() async throws {
    var addedRequests: [UNNotificationRequest] = []
    var pendingRemovals: [[String]] = []
    var deliveredRemovals: [[String]] = []
    let service = UpdateReminderNotificationService(
      authorizationStatus: { .authorized },
      addRequest: { addedRequests.append($0) },
      removePending: { pendingRemovals.append($0) },
      removeDelivered: { deliveredRemovals.append($0) }
    )

    await service.post(
      displayVersion: "1.2.3",
      language: .english,
      bundle: .module
    )

    let request = try #require(addedRequests.first)
    #expect(addedRequests.count == 1)
    #expect(request.identifier == UpdateReminderNotification.identifier)
    #expect(request.content.title == "A new CodexRadar update is available")
    #expect(request.content.body == "Version 1.2.3 is now available.")
    #expect(request.content.threadIdentifier == "codex-radar-update")
    #expect(pendingRemovals == [[UpdateReminderNotification.identifier]])
    #expect(deliveredRemovals == [[UpdateReminderNotification.identifier]])
  }

  @Test
  func skipsReminderWithoutAuthorization() async {
    var addCount = 0
    var clearCount = 0
    let service = UpdateReminderNotificationService(
      authorizationStatus: { .denied },
      addRequest: { _ in addCount += 1 },
      removePending: { _ in clearCount += 1 },
      removeDelivered: { _ in clearCount += 1 }
    )

    await service.post(displayVersion: "1.2.3")

    #expect(addCount == 0)
    #expect(clearCount == 0)
  }

  @Test
  func swallowsDeliveryFailureAfterRemovingStaleReminder() async {
    var addCount = 0
    var clearCount = 0
    let service = UpdateReminderNotificationService(
      authorizationStatus: { .provisional },
      addRequest: { _ in
        addCount += 1
        throw NotificationFailure.delivery
      },
      removePending: { _ in clearCount += 1 },
      removeDelivered: { _ in clearCount += 1 }
    )

    await service.post(displayVersion: "1.2.3")

    #expect(addCount == 1)
    #expect(clearCount == 2)
  }

  @Test
  func clearsPendingAndDeliveredReminderIdempotently() {
    var pendingRemovals: [[String]] = []
    var deliveredRemovals: [[String]] = []
    let service = UpdateReminderNotificationService(
      authorizationStatus: { .authorized },
      addRequest: { _ in },
      removePending: { pendingRemovals.append($0) },
      removeDelivered: { deliveredRemovals.append($0) }
    )

    service.clear()
    service.clear()

    let expected = [
      [UpdateReminderNotification.identifier],
      [UpdateReminderNotification.identifier],
    ]
    #expect(pendingRemovals == expected)
    #expect(deliveredRemovals == expected)
  }
}

private enum NotificationFailure: Error {
  case delivery
}
