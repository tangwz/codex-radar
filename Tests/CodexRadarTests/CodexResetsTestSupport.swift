import Foundation
import Testing

@testable import CodexRadar

let publicAPINow = ISO8601DateFormatter().date(from: "2026-09-07T08:00:00Z")!

func publicRecord(
  id: String = "observed-a", kind: String = "banked", at: String = "2026-09-07T07:00:00Z"
) -> String {
  """
  {"id":"\(id)","reset_type":"\(kind)","announced_at":"\(at)","text":"Synthetic announcement","source":{"type":"observed"}}
  """
}

func publicStatus(
  record: String = "null", watch: String = "null", version: String = "v1",
  generatedAt: String = "2026-09-07T08:00:00Z", total: Int = 0
) -> Data {
  Data(
    """
    {"data":{"latest_reset":\(record),"active_watch":\(watch),"stats":{"total":\(total),"last_reset_at":null,"days_since_last":null,"avg_interval_days":null}},"meta":{"api_version":"\(version)","generated_at":"\(generatedAt)"}}
    """.utf8)
}

func publicPage(records: [String] = [], more: Bool = false, cursor: String? = nil) -> Data {
  let cursorJSON = cursor.map { "\"\($0)\"" } ?? "null"
  return Data(
    """
    {"data":[\(records.joined(separator: ","))],"pagination":{"has_more":\(more),"next_cursor":\(cursorJSON)},"meta":{"api_version":"v1","generated_at":"2026-09-07T08:00:00Z"}}
    """.utf8)
}

func publicWatch(expires: String = "2026-09-07T09:00:00Z", probability: Int = 45) -> String {
  """
  {"level":"elevated","reset_chance_percent":\(probability),"forecast_window":"within 24 hours","observed_at":"2026-09-07T07:30:00Z","expires_at":"\(expires)","text":"Synthetic forecast","source":{"type":"x_post","author":"example","url":"https://x.com/example/status/123"}}
  """
}

func publicResponse(_ request: URLRequest, status: Int = 200, headers: [String: String] = [:])
  -> HTTPURLResponse
{
  HTTPURLResponse(
    url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
}

actor PublicAPIRequests {
  private(set) var requests: [URLRequest] = []
  func record(_ request: URLRequest) { requests.append(request) }
}

/// Test clock guarded by a lock because production's clock closure is Sendable.
final class PublicAPIClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date
  init(_ value: Date = publicAPINow) { self.value = value }
  func now() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
  func advance(_ seconds: TimeInterval) {
    lock.lock()
    defer { lock.unlock() }
    value.addTimeInterval(seconds)
  }
}
