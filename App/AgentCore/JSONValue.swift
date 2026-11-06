import Foundation

indirect enum JSONValue: Codable, Equatable, Sendable {
  case object([String: JSONValue])
  case array([JSONValue])
  case string(String)
  case number(Double)
  case bool(Bool)
  case null
  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let v = try? c.decode(Bool.self) {
      self = .bool(v)
    } else if let v = try? c.decode(String.self) {
      self = .string(v)
    } else if let v = try? c.decode(Double.self) {
      self = .number(v)
    } else if let v = try? c.decode([JSONValue].self) {
      self = .array(v)
    } else {
      self = .object(try c.decode([String: JSONValue].self))
    }
  }
  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .object(let v): try c.encode(v)
    case .array(let v): try c.encode(v)
    case .string(let v): try c.encode(v)
    case .number(let v): try c.encode(v)
    case .bool(let v): try c.encode(v)
    case .null: try c.encodeNil()
    }
  }
  init(_ value: Any) throws {
    self = try JSONDecoder().decode(
      Self.self, from: JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed))
  }
  subscript(_ key: String) -> JSONValue { object?[key] ?? .null }
  var object: [String: JSONValue]? {
    if case .object(let v) = self { return v }
    return nil
  }
  var array: [JSONValue]? {
    if case .array(let v) = self { return v }
    return nil
  }
  var string: String? {
    if case .string(let v) = self { return v }
    return nil
  }
  var number: Double? {
    if case .number(let v) = self { return v }
    return nil
  }
  var bool: Bool? {
    if case .bool(let v) = self { return v }
    return nil
  }
  func data() throws -> Data { try JSONEncoder().encode(self) }
  func text() throws -> String { String(decoding: try data(), as: UTF8.self) }
  func foundation() throws -> Any {
    try JSONSerialization.jsonObject(with: data(), options: .fragmentsAllowed)
  }
  static func textContent(_ text: String) -> Self {
    .object(["type": .string("input_text"), "text": .string(text)])
  }
}
