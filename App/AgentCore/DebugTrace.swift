import Foundation

struct DebugOptions: Codable, Sendable {
  var screenshots = true
  var visibleText = false
}

// Defensive redaction for diagnostics, not for the live model conversation.
// Raw HTTP bodies, headers, pairing records, and reasoning are never supplied.
enum DebugPrivacy {
  static func clean(_ text: String) -> String {
    if [
      "alt_irk", "pairing.plist", "privatekey", "private_key", "sharedsecret", "shared_secret",
      "BEGIN PRIVATE KEY",
    ].contains(where: { text.localizedCaseInsensitiveContains($0) }) {
      return "[sensitive diagnostic omitted]"
    }
    var result = String(text.prefix(4096))
    let patterns = [
      #"(?i)\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]+"#,
      #"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#,
      #"\bsk-[A-Za-z0-9_-]{12,}\b"#,
      #"(?i)(access_token|refresh_token|id_token|password|client_secret|authorization)\s*[\"']?\s*[:=]\s*[\"']?[^\s,\"'}]+"#,
      #"data:[^;\s]+;base64,[A-Za-z0-9+/=]+"#,
    ]
    for pattern in patterns {
      result = result.replacingOccurrences(
        of: pattern, with: "[redacted]", options: .regularExpression)
    }
    return result
  }
  static func value(_ value: JSONValue, visibleText: Bool = false) -> JSONValue {
    switch value {
    case .object(let object):
      var result: [String: JSONValue] = [:]
      for (key, item) in object {
        let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
        let compact = normalized.replacingOccurrences(of: "_", with: "")
        if normalized == "accessibility", !visibleText, let tree = item.object {
          result[key] = .object(tree.filter {
            ["status", "reason", "source", "truncated", "partial", "node_count", "elapsed_ms"].contains($0.key)
          })
        } else if [
          "authorization", "headers", "accesstoken", "refreshtoken", "idtoken", "token", "password",
          "clientsecret", "pairing", "encryptedcontent", "reasoning", "imageurl", "privatekey",
          "apikey",
        ].contains(compact) {
          result[key] = .string("[redacted]")
        } else if normalized == "key", !visibleText, let text = item.string, text.count == 1 {
          result[key] = .string("[character]")
        } else if ["text", "question", "prompt", "answer"].contains(normalized),
          let text = item.string
        {
          result[key + "_original_characters"] = .number(Double(text.count))
          if visibleText && text.count > 4096 { result[key + "_truncated"] = .bool(true) }
          result[key] =
            visibleText
            ? .string(clean(text))
            : .object([
              "redacted": .bool(true), "characters": .number(Double(text.count)),
              "utf8_bytes": .number(Double(text.utf8.count)),
            ])
        } else {
          result[key] = self.value(item, visibleText: visibleText)
        }
      }
      return .object(result)
    case .array(let array):
      return .array(array.prefix(32).map { self.value($0, visibleText: visibleText) })
    case .string(let text): return .string(clean(text))
    default: return value
    }
  }
  static func arguments(_ call: AgentToolCall, visibleText: Bool) -> JSONValue {
    guard let data = call.arguments.data(using: .utf8),
      let object = try? JSONDecoder().decode(JSONValue.self, from: data)
    else {
      return .object([
        "parse_failed": .bool(true), "utf8_bytes": .number(Double(call.arguments.utf8.count)),
      ])
    }
    if call.name == "phone_exec_js", let code = object["code"].string {
      return .object(["code": value(.object(["text": .string(code)]), visibleText: visibleText)])
    }
    return value(object, visibleText: visibleText)
  }
}

struct DebugManifest: Codable, Sendable {
  var schema = 1
  let runID: UUID
  let kind: String
  let version: String
  let build: String
  let options: DebugOptions
  let startedAt: Date
  var endedAt: Date?
  var outcome: String = "running"
  var events = 0
  var droppedEvents = 0
  var savedFrames = 0
  var skippedFrames = 0
  var writeFailures = 0
}

struct DebugRecord: Codable, Sendable {
  let sequence: Int
  let timestampMS: Int64
  let uptimeMS: Int64
  let runID: UUID
  let kind: String
  let fields: JSONValue
}

struct DebugTraceSummary: Identifiable, Sendable {
  var id: UUID { manifest.runID }
  let manifest: DebugManifest
  let directory: URL
}

// All writes and exports are ordered on one queue, including model-image files.
// A per-task store cannot accidentally append late events to the next task.
final class DebugTraceStore: @unchecked Sendable {
  static let maximumRuns = 5
  static let eventBudget = 4 * 1024 * 1024
  static let frameBudget = 20 * 1024 * 1024
  private let queue = DispatchQueue(label: "dev.solouse.debug-trace", qos: .utility)
  let directory: URL
  private var manifest: DebugManifest
  private var handle: FileHandle?
  private var eventBytes = 0
  private var frameBytes = 0
  private var sealed = false
  init(root: URL, runID: UUID, kind: String, version: String, build: String, options: DebugOptions)
    throws
  {
    directory = root.appendingPathComponent(runID.uuidString, isDirectory: true)
    manifest = DebugManifest(
      runID: runID, kind: kind, version: version, build: build, options: options, startedAt: Date())
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Self.protect(directory)
    let events = directory.appendingPathComponent("events.jsonl")
    guard FileManager.default.createFile(atPath: events.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    try Self.protect(events)
    handle = try FileHandle(forWritingTo: events)
    try saveManifest()
    try Self.prune(root: root, keeping: runID)
  }
  deinit { try? handle?.close() }
  func append(_ kind: String, _ fields: JSONValue) {
    let wall = Int64(Date().timeIntervalSince1970 * 1000)
    let uptime = Int64(ProcessInfo.processInfo.systemUptime * 1000)
    queue.async { self.write(kind, fields, wall: wall, uptime: uptime) }
  }
  private func write(_ kind: String, _ fields: JSONValue, wall: Int64, uptime: Int64) {
    guard !sealed else { return }
    do {
      let record = DebugRecord(
        sequence: manifest.events + 1, timestampMS: wall, uptimeMS: uptime, runID: manifest.runID,
        kind: kind, fields: DebugPrivacy.value(fields, visibleText: manifest.options.visibleText))
      let data = try JSONEncoder().encode(record) + Data([10])
      guard eventBytes + data.count <= Self.eventBudget, manifest.events < 8000, data.count < 64_000
      else {
        manifest.droppedEvents += 1
        return
      }
      try handle?.write(contentsOf: data)
      eventBytes += data.count
      manifest.events += 1
    } catch { manifest.writeFailures += 1 }
  }
  func needsFrameData() async -> Bool {
    await withCheckedContinuation { continuation in
      queue.async {
        continuation.resume(returning: !self.sealed && self.manifest.options.screenshots
          && self.manifest.savedFrames < 24 && self.frameBytes < Self.frameBudget)
      }
    }
  }
  func frame(id: String, data: Data?, metadata: JSONValue) {
    let wall = Int64(Date().timeIntervalSince1970 * 1000)
    let uptime = Int64(ProcessInfo.processInfo.systemUptime * 1000)
    queue.async {
      guard !self.sealed else { return }
      var fields = metadata.object ?? [:]
      fields["frame_id"] = .string(id)
      let uuid = UUID(uuidString: id)
      if self.manifest.options.screenshots, let data, let uuid, self.manifest.savedFrames < 24,
        self.frameBytes + data.count <= Self.frameBudget
      {
        do {
          let folder = self.directory.appendingPathComponent("frames", isDirectory: true)
          try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
          try Self.protect(folder)
          let file = folder.appendingPathComponent(uuid.uuidString + ".jpg")
          guard !FileManager.default.fileExists(atPath: file.path) else {
            fields["saved"] = .bool(true)
            fields["file"] = .string("frames/" + file.lastPathComponent)
            self.write("observation", .object(fields), wall: wall, uptime: uptime)
            return
          }
          try data.write(to: file, options: .atomic)
          try Self.protect(file)
          self.manifest.savedFrames += 1
          self.frameBytes += data.count
          fields["saved"] = .bool(true)
          fields["file"] = .string("frames/" + file.lastPathComponent)
        } catch {
          self.manifest.writeFailures += 1
          fields["saved"] = .bool(false)
          fields["reason"] = .string("write_failed")
        }
      } else {
        self.manifest.skippedFrames += 1
        fields["saved"] = .bool(false)
        fields["reason"] = .string(
          self.manifest.options.screenshots ? "limit_or_invalid_id" : "screenshots_disabled")
      }
      self.write("observation", .object(fields), wall: wall, uptime: uptime)
    }
  }
  func finish(_ outcome: String) {
    queue.async {
      guard !self.sealed else { return }
      self.write(
        "trace_finished", .object(["outcome": .string(outcome)]),
        wall: Int64(Date().timeIntervalSince1970 * 1000),
        uptime: Int64(ProcessInfo.processInfo.systemUptime * 1000))
      self.manifest.outcome = outcome
      self.manifest.endedAt = Date()
      self.sealed = true
      try? self.handle?.synchronize()
      try? self.saveManifest()
    }
  }
  func flush() throws {
    try queue.sync {
      try handle?.synchronize()
      try saveManifest()
    }
  }
  func export(to destination: URL) throws {
    try queue.sync {
      try handle?.synchronize()
      try saveManifest()
      try DebugArchive.export(directory: directory, to: destination)
    }
  }
  private func saveManifest() throws {
    let file = directory.appendingPathComponent("manifest.json")
    try JSONEncoder().encode(manifest).write(to: file, options: .atomic)
    try Self.protect(file)
  }
  static func summaries(root: URL) -> [DebugTraceSummary] {
    let urls =
      (try? FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []
    return urls.compactMap { url in
      guard UUID(uuidString: url.lastPathComponent) != nil,
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
        let data = try? Data(contentsOf: url.appendingPathComponent("manifest.json")),
        data.count < 64_000,
        let manifest = try? JSONDecoder().decode(DebugManifest.self, from: data),
        manifest.runID.uuidString == url.lastPathComponent
      else { return nil }
      return DebugTraceSummary(manifest: manifest, directory: url)
    }.sorted { $0.manifest.startedAt > $1.manifest.startedAt }
  }
  private static func prune(root: URL, keeping: UUID) throws {
    let old = summaries(root: root).filter { $0.id != keeping }
    for summary in old.dropFirst(maximumRuns - 1) {
      try FileManager.default.removeItem(at: summary.directory)
    }
  }
  static func protect(_ url: URL) throws {
    #if os(iOS)
      try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: url.path)
    #endif
    var file = url
    var attributes = URLResourceValues()
    attributes.isExcludedFromBackup = true
    try file.setResourceValues(attributes)
  }
}

// Small standard ZIP writer using the STORE method. JPEG files are already
// compressed; the archive needs no third-party runtime dependency.
enum DebugArchive {
  static func export(directory: URL, to destination: URL) throws {
    let fm = FileManager.default
    var files = ["manifest.json", "events.jsonl"]
    let frames = directory.appendingPathComponent("frames")
    if (try? frames.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
      throw CocoaError(.fileReadNoPermission)
    }
    for url in (try? fm.contentsOfDirectory(at: frames, includingPropertiesForKeys: nil)) ?? [] {
      if url.pathExtension == "jpg",
        UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
      {
        files.append("frames/" + url.lastPathComponent)
      }
    }
    files = files.sorted()
    var archive = Data()
    var central = Data()
    var count: UInt16 = 0
    for name in files {
      let url = directory.appendingPathComponent(name)
      let attributes = try url.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ])
      guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
        (attributes.fileSize ?? Int.max) < DebugTraceStore.frameBudget + DebugTraceStore.eventBudget
      else { throw CocoaError(.fileReadNoPermission) }
      let body = try Data(contentsOf: url)
      guard archive.count + body.count < 28 * 1024 * 1024 else {
        throw CocoaError(.fileReadTooLarge)
      }
      let nameData = Data(name.utf8)
      let size = UInt32(body.count)
      let crc = crc32(body)
      let offset = UInt32(archive.count)
      archive.u32(0x0403_4b50)
      archive.u16(20)
      archive.u16(0x0800)
      archive.u16(0)
      archive.u16(0)
      archive.u16(0x21)
      archive.u32(crc)
      archive.u32(size)
      archive.u32(size)
      archive.u16(UInt16(nameData.count))
      archive.u16(0)
      archive.append(nameData)
      archive.append(body)
      central.u32(0x0201_4b50)
      central.u16(20)
      central.u16(20)
      central.u16(0x0800)
      central.u16(0)
      central.u16(0)
      central.u16(0x21)
      central.u32(crc)
      central.u32(size)
      central.u32(size)
      central.u16(UInt16(nameData.count))
      central.u16(0)
      central.u16(0)
      central.u16(0)
      central.u16(0)
      central.u32(0)
      central.u32(offset)
      central.append(nameData)
      count += 1
    }
    let offset = UInt32(archive.count)
    archive.append(central)
    archive.u32(0x0605_4b50)
    archive.u16(0)
    archive.u16(0)
    archive.u16(count)
    archive.u16(count)
    archive.u32(UInt32(central.count))
    archive.u32(offset)
    archive.u16(0)
    try archive.write(to: destination, options: .atomic)
    try DebugTraceStore.protect(destination)
  }
  private static let crcTable: [UInt32] = (0..<256).map { item in
    var value = UInt32(item)
    for _ in 0..<8 { value = value & 1 == 1 ? 0xedb8_8320 ^ (value >> 1) : value >> 1 }
    return value
  }
  private static func crc32(_ data: Data) -> UInt32 {
    var value: UInt32 = 0xffff_ffff
    for byte in data { value = crcTable[Int((value ^ UInt32(byte)) & 0xff)] ^ (value >> 8) }
    return value ^ 0xffff_ffff
  }
}
extension Data {
  fileprivate mutating func u16(_ number: UInt16) {
    var value = number.littleEndian
    Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
  }
  fileprivate mutating func u32(_ number: UInt32) {
    var value = number.littleEndian
    Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
  }
}
