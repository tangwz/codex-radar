import Foundation

enum APIJSONCoding {
  static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let value = try container.decode(String.self)
      guard
        let date = ISO8601DateFormatter.withFractionalSeconds.date(from: value)
          ?? ISO8601DateFormatter.withoutFractionalSeconds.date(from: value)
      else {
        throw DecodingError.dataCorruptedError(
          in: container,
          debugDescription: "Expected an ISO-8601 timestamp."
        )
      }
      return date
    }
    return decoder
  }
}

extension ISO8601DateFormatter {
  fileprivate static var withFractionalSeconds: ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }

  fileprivate static var withoutFractionalSeconds: ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }
}
