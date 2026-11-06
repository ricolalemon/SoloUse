import CryptoKit
import Foundation

// Content-addressed, app-private image assets. A reference is never a path or URL
// supplied by the model. Manifests are committed only after their assets exist.
struct ConversationImages: Sendable {
  let directory: URL
  static let prefix = "solouse-image:"
  static func validID(_ id: String) -> Bool {
    id.count == 64 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
  static func id(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  func file(_ id: String) throws -> URL {
    guard Self.validID(id) else { throw AgentLoopError.protocolError("Invalid history image identifier") }
    return directory.appendingPathComponent(id + ".image")
  }
  func put(_ value: String) throws -> String {
    let data = Data(value.utf8)
    guard value.hasPrefix("data:image/"), data.count <= 16_000_000 else {
      throw AgentLoopError.protocolError("Invalid history image")
    }
    let id = Self.id(data), url = try file(id)
    if (try? Data(contentsOf: url, options: .mappedIfSafe)) != data {
      try Self.write(data, to: url)
    }
    return id
  }
  func read(_ id: String) throws -> String {
    let url = try file(id)
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
    guard size <= 16_000_000 else { throw AgentLoopError.protocolError("Invalid history image size") }
    let data = try Data(contentsOf: url)
    guard Self.id(data) == id, let value = String(data: data, encoding: .utf8), value.hasPrefix("data:image/") else {
      throw AgentLoopError.protocolError("History image is damaged")
    }
    return value
  }
  static func write(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    #if os(iOS)
      try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    #else
      try data.write(to: url, options: .atomic)
    #endif
    var target = url
    var values = URLResourceValues(); values.isExcludedFromBackup = true
    try target.setResourceValues(values)
  }
}

extension JSONValue {
  // Only structured image parts are transformed; opaque reasoning and user text
  // (including strings resembling asset IDs) are left byte-for-byte unchanged.
  func mapImages(_ transform: (JSONValue) throws -> JSONValue) rethrows -> JSONValue {
    if self["type"].string == "input_image" { return try transform(self) }
    switch self {
    case .array(let values): return .array(try values.map { try $0.mapImages(transform) })
    case .object(let values):
      var result = values
      for key in values.keys.sorted() { result[key] = try values[key]!.mapImages(transform) }
      return .object(result)
    default: return self
    }
  }
}
