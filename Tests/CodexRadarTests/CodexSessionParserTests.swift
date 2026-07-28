import Foundation
import Testing

@testable import CodexRadar

struct CodexSessionParserTests {
  @Test
  func prefersLastUsageAndIgnoresDuplicateCumulativeSnapshots() {
    let data = Data(
      """
      {"timestamp":"2026-07-14T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10}}}}
      {"timestamp":"2026-07-14T01:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10}}}}
      {"timestamp":"2026-07-14T02:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":160,"cached_input_tokens":30,"output_tokens":25},"last_token_usage":{"input_tokens":60,"cached_input_tokens":10,"output_tokens":15}}}}
      """.utf8
    )

    let events = CodexSessionParser().parse(data: data)

    #expect(events.count == 2)
    #expect(events.reduce(0) { $0 + $1.inputTokens } == 160)
    #expect(events.reduce(0) { $0 + $1.outputTokens } == 25)
    #expect(events.reduce(0) { $0 + $1.cachedInputTokens } == 30)
  }

  @Test
  func derivesDeltasWhenLastUsageIsMissing() {
    let data = Data(
      """
      {"timestamp":"2026-07-14T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":10}}}}
      {"timestamp":"2026-07-14T02:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":140,"output_tokens":18}}}}
      """.utf8
    )

    let events = CodexSessionParser().parse(data: data)

    #expect(events.map(\.totalTokens) == [110, 48])
  }

  @Test
  func containsInterleavedCumulativeCountersWithoutRecountingGaps() {
    let data = Data(
      """
      {"timestamp":"2026-07-14T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":10},"last_token_usage":{"input_tokens":100,"output_tokens":10}}}}
      {"timestamp":"2026-07-14T02:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":160,"output_tokens":20},"last_token_usage":{"input_tokens":60,"output_tokens":10}}}}
      {"timestamp":"2026-07-14T03:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":120,"output_tokens":15},"last_token_usage":{"input_tokens":20,"output_tokens":5}}}}
      {"timestamp":"2026-07-14T04:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":180,"output_tokens":25},"last_token_usage":{"input_tokens":60,"output_tokens":10}}}}
      """.utf8
    )

    let events = CodexSessionParser().parse(data: data)

    #expect(events.reduce(0) { $0 + $1.inputTokens } == 180)
    #expect(events.reduce(0) { $0 + $1.outputTokens } == 25)
  }

  @Test
  func excludesInitialInheritedSnapshotFromForkedSession() {
    let data = Data(
      """
      {"timestamp":"2026-07-14T01:00:00Z","type":"session_meta","payload":{"id":"child","forked_from_id":"parent"}}
      {"timestamp":"2026-07-14T01:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"output_tokens":100},"last_token_usage":{"input_tokens":1000,"output_tokens":100}}}}
      {"timestamp":"2026-07-14T02:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1060,"output_tokens":110},"last_token_usage":{"input_tokens":60,"output_tokens":10}}}}
      """.utf8
    )

    let events = CodexSessionParser().parse(data: data)

    #expect(events.map(\.totalTokens) == [70])
  }

}
