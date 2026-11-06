import Foundation

struct TaskRecordStore {
  let directory: URL
  private var file: URL { directory.appendingPathComponent("latest-task.json") }
  func save(_ snapshot: TaskSnapshot) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(snapshot)
    try data.write(to: file, options: .atomic)
    #if os(iOS)
      try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: file.path)
    #endif
    var url = file
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try url.setResourceValues(values)
  }
  func load() -> TaskSnapshot? {
    guard let data = try? Data(contentsOf: file), data.count < 40_000_000 else { return nil }
    return try? JSONDecoder().decode(TaskSnapshot.self, from: data)
  }
  func remove() throws {
    if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
  }
}

struct HandoffStore {
  let directory: URL
  var fileName: String = "pending-handoff.json"
  private var file: URL { directory.appendingPathComponent(fileName) }
  func save(_ value: PendingHandoff) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var value = value
    value.conversation = try value.conversation.archivingImages(to:
      ConversationStore.imageDirectory(directory: directory, runID: value.runID))
    let data = try JSONEncoder().encode(value)
    guard data.count < 512_000_000 else { throw AgentLoopError.contextLimit(data.count) }
    try data.write(to: file, options: .atomic)
    #if os(iOS)
      try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: file.path)
    #endif
    var url = file
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try url.setResourceValues(values)
  }
  func load() -> PendingHandoff? {
    guard let data = try? Data(contentsOf: file), data.count < 512_000_000 else { return nil }
    guard var value = try? JSONDecoder().decode(PendingHandoff.self, from: data) else { return nil }
    value.conversation.imageDirectory = ConversationStore.imageDirectory(directory: directory, runID: value.runID)
    return value
  }
  func consume() throws {
    if FileManager.default.fileExists(atPath: file.path) {
      try FileManager.default.removeItem(at: file)
    }
  }
  func remove() { try? consume() }
}
