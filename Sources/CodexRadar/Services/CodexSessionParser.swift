import Foundation

struct CodexSessionParser: Sendable {
  struct State {
    fileprivate var countedTotal: TokenTotals?
    fileprivate var rawBaseline: TokenTotals?
    fileprivate var watermark: TokenTotals?
    fileprivate var seenTotals = Set<TokenTotals>()
    fileprivate var hasInterleavedTotals = false
    fileprivate var isForkedSession = false
    fileprivate var hasTokenSnapshot = false
    fileprivate(set) var sessionID: String?
    fileprivate var currentTurnID: String?
    fileprivate var currentModel: String?
    fileprivate var usageRowIndex = 0
  }

  func parse(data: Data) -> [TokenUsageEvent] {
    var state = State()
    return data.split(separator: 0x0A).compactMap { line in
      parse(line: line, state: &state)
    }
  }

  func parse(line: Data, state: inout State) -> TokenUsageEvent? {
    let prefix = line.prefix(1_024)
    if prefix.range(of: Self.sessionMetaMarker) != nil {
      parseSessionMetadata(line: line, state: &state)
      return nil
    }
    if prefix.range(of: Self.taskStartedMarker) != nil {
      parseTaskStarted(line: line, state: &state)
      return nil
    }
    if prefix.range(of: Self.turnContextMarker) != nil {
      parseTurnContext(line: line, state: &state)
      return nil
    }

    guard prefix.range(of: Self.tokenCountMarker) != nil,
      let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
      object["type"] as? String == "event_msg",
      let payload = object["payload"] as? [String: Any],
      payload["type"] as? String == "token_count",
      let info = payload["info"] as? [String: Any],
      let timestampText = object["timestamp"] as? String,
      let timestamp = parseTimestamp(timestampText)
    else {
      return nil
    }

    let total = totals(from: info["total_token_usage"])
    if let total, state.seenTotals.contains(total) {
      return nil
    }

    let last = totals(from: info["last_token_usage"])
    if let total {
      if let watermark = state.watermark, !total.isAtLeast(watermark) {
        state.hasInterleavedTotals = true
      }
    }

    if state.isForkedSession, !state.hasTokenSnapshot, let total {
      state.hasTokenSnapshot = true
      state.rawBaseline = total
      state.countedTotal = .zero
      state.watermark = total
      state.seenTotals.insert(total)
      return nil
    }

    let usage = usage(last: last, total: total, state: state)
    state.hasTokenSnapshot = true

    if let usage {
      state.countedTotal = (state.countedTotal ?? .zero).adding(usage)
    }
    if let total {
      state.rawBaseline = total
      state.watermark = state.watermark.map { $0.componentwiseMaximum(with: total) } ?? total
      state.seenTotals.insert(total)
    }

    guard let usage, usage.input > 0 || usage.output > 0 else {
      return nil
    }
    let eventIndex = state.usageRowIndex
    state.usageRowIndex += 1

    return TokenUsageEvent(
      timestamp: timestamp,
      inputTokens: usage.input,
      cachedInputTokens: usage.cached,
      outputTokens: usage.output,
      turnID: turnID(from: payload) ?? state.currentTurnID,
      model: model(from: info) ?? model(from: payload) ?? model(from: object)
        ?? state.currentModel,
      eventIndex: eventIndex
    )
  }

  private static let tokenCountMarker = Data(#""token_count""#.utf8)
  private static let sessionMetaMarker = Data(#""session_meta""#.utf8)
  private static let taskStartedMarker = Data(#""task_started""#.utf8)
  private static let turnContextMarker = Data(#""turn_context""#.utf8)

  private func parseSessionMetadata(line: Data, state: inout State) {
    guard
      let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
      object["type"] as? String == "session_meta",
      let payload = object["payload"] as? [String: Any]
    else {
      return
    }
    state.isForkedSession =
      payload["forked_from_id"] != nil
      || payload["forkedFromId"] != nil
      || payload["parent_session_id"] != nil
      || payload["parentSessionId"] != nil
    state.sessionID =
      payload["session_id"] as? String
      ?? payload["sessionId"] as? String
      ?? payload["id"] as? String
  }

  private func parseTaskStarted(line: Data, state: inout State) {
    guard
      let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
      object["type"] as? String == "event_msg",
      let payload = object["payload"] as? [String: Any],
      payload["type"] as? String == "task_started"
    else {
      return
    }
    state.currentTurnID = turnID(from: payload)
  }

  private func parseTurnContext(line: Data, state: inout State) {
    guard
      let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
      object["type"] as? String == "turn_context",
      let payload = object["payload"] as? [String: Any]
    else {
      return
    }
    state.currentModel =
      model(from: payload)
      ?? (payload["info"] as? [String: Any]).flatMap(model(from:))
  }

  private func model(from value: [String: Any]) -> String? {
    value["model"] as? String ?? value["model_name"] as? String
  }

  private func turnID(from payload: [String: Any]) -> String? {
    payload["turn_id"] as? String
      ?? payload["turnId"] as? String
      ?? payload["id"] as? String
      ?? (payload["info"] as? [String: Any]).flatMap {
        $0["turn_id"] as? String ?? $0["turnId"] as? String ?? $0["id"] as? String
      }
  }

  private func usage(last: TokenTotals?, total: TokenTotals?, state: State) -> TokenTotals? {
    guard let total else { return last }

    if state.hasInterleavedTotals {
      let contained = total.containedDelta(
        watermark: state.watermark ?? state.rawBaseline ?? .zero,
        counted: state.countedTotal ?? .zero
      )
      return last.map { $0.componentwiseMinimum(with: contained) } ?? contained
    }

    guard let last else {
      return total.delta(from: state.rawBaseline ?? .zero)
    }
    guard let rawBaseline = state.rawBaseline else { return last }

    let totalDelta = total.delta(from: rawBaseline)
    if total.isAtLeast(rawBaseline), totalDelta.isAtMost(last) {
      return totalDelta
    }
    return last
  }

  private func totals(from value: Any?) -> TokenTotals? {
    guard let usage = value as? [String: Any] else { return nil }
    return TokenTotals(
      input: integer(usage["input_tokens"]),
      cached: integer(usage["cached_input_tokens"] ?? usage["cache_read_input_tokens"]),
      output: integer(usage["output_tokens"])
    )
  }

  private func integer(_ value: Any?) -> Int {
    max(0, (value as? NSNumber)?.intValue ?? 0)
  }

  private func parseTimestamp(_ value: String) -> Date? {
    let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    let regular = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
    if let date = try? Date(value, strategy: fractional) {
      return date
    }
    return try? Date(value, strategy: regular)
  }
}

private struct TokenTotals: Equatable, Hashable {
  let input: Int
  let cached: Int
  let output: Int

  static let zero = TokenTotals(input: 0, cached: 0, output: 0)

  func delta(from previous: TokenTotals) -> TokenTotals {
    TokenTotals(
      input: input >= previous.input ? input - previous.input : input,
      cached: cached >= previous.cached ? cached - previous.cached : cached,
      output: output >= previous.output ? output - previous.output : output
    )
  }

  func adding(_ other: TokenTotals) -> TokenTotals {
    TokenTotals(
      input: input + other.input,
      cached: cached + other.cached,
      output: output + other.output
    )
  }

  func isAtLeast(_ other: TokenTotals) -> Bool {
    input >= other.input && cached >= other.cached && output >= other.output
  }

  func isAtMost(_ other: TokenTotals) -> Bool {
    input <= other.input && cached <= other.cached && output <= other.output
  }

  func componentwiseMaximum(with other: TokenTotals) -> TokenTotals {
    TokenTotals(
      input: max(input, other.input),
      cached: max(cached, other.cached),
      output: max(output, other.output)
    )
  }

  func componentwiseMinimum(with other: TokenTotals) -> TokenTotals {
    TokenTotals(
      input: min(input, other.input),
      cached: min(cached, other.cached),
      output: min(output, other.output)
    )
  }

  func containedDelta(watermark: TokenTotals, counted: TokenTotals) -> TokenTotals {
    func component(current: Int, watermark: Int, counted: Int) -> Int {
      if current >= watermark {
        return max(0, current - max(watermark, counted))
      }
      return max(0, current - counted)
    }

    return TokenTotals(
      input: component(current: input, watermark: watermark.input, counted: counted.input),
      cached: component(current: cached, watermark: watermark.cached, counted: counted.cached),
      output: component(current: output, watermark: watermark.output, counted: counted.output)
    )
  }
}
