import Foundation

struct ConversationCheckpoint: Codable, Sendable {
  let runID: UUID
  let revision: UUID
  let accountTag: String
  var conversation: AgentConversation
  var recoverySnapshot: TaskSnapshot? = nil

  func adding(_ text: String, accountTag currentAccount: String) throws -> AgentConversation {
    guard accountTag == currentAccount else {
      throw AgentLoopError.protocolError("当前账号与这段聊天不同，请切回原账号或新建聊天。")
    }
    var continued = conversation
    try continued.appendFollowup(text)
    return continued
  }
}

struct ConversationStore: Sendable {
  let directory: URL
  var fileName: String = "conversation.json"
  var file: URL { directory.appendingPathComponent(fileName) }
  static let queue = DispatchQueue(label: "dev.solouse.conversation-store", qos: .utility)
  // Decoder corruption guard, independent of model requests. New manifests have
  // image references; this also admits oversized legacy histories for migration.
  private static let maximumBytes = 512_000_000
  func imageDirectory(runID: UUID) -> URL {
    Self.imageDirectory(directory: directory, runID: runID)
  }
  static func imageDirectory(directory: URL, runID: UUID) -> URL {
    let folder = directory.lastPathComponent == runID.uuidString ? directory
      : directory.appendingPathComponent("history/" + runID.uuidString)
    return folder.appendingPathComponent("images", isDirectory: true)
  }
  func loadAny() throws -> ConversationCheckpoint? {
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Self.maximumBytes
    guard size < Self.maximumBytes else { throw AgentLoopError.protocolError("History manifest is too large to decode") }
    var value = try JSONDecoder().decode(ConversationCheckpoint.self, from: Data(contentsOf: file))
    value.conversation.imageDirectory = imageDirectory(runID: value.runID)
    return value
  }

  func load(runID: UUID, revision: UUID) throws -> ConversationCheckpoint? {
    guard let value = try loadAny() else { return nil }
    guard value.runID == runID, value.revision == revision else { return nil }
    return value
  }
  func save(_ value: ConversationCheckpoint) throws {
    var value = value
    value.conversation = try value.conversation.archivingImages(to: imageDirectory(runID: value.runID))
    let data = try JSONEncoder().encode(value)
    guard data.count < Self.maximumBytes else { throw AgentLoopError.contextLimit(data.count) }
    try ConversationImages.write(data, to: file)
  }
  func saveAsync(_ value: ConversationCheckpoint) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      Self.queue.async {
        do { try save(value); continuation.resume() }
        catch { continuation.resume(throwing: error) }
      }
    }
  }
  func remove() throws {
    if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
  }
}

// A rolling recovery manifest lives beside the chat, independent of UI saves.
// Before dispatch it settles the in-flight call as uncertain; after the receipt
// it replaces that state. Loading never dispatches queued or uncertain calls.
struct RunRecoveryStore: Sendable {
  let directory: URL
  func save(conversation: AgentConversation, unfinishedCall: String?, snapshot: TaskSnapshot,
            accountTag: String) async throws -> (AgentConversation, ConversationCheckpoint) {
    try await withCheckedThrowingContinuation { continuation in
      ConversationStore.queue.async {
        do {
          let tombstone = directory.appendingPathComponent("history/deleted-" + snapshot.id.uuidString)
          guard !FileManager.default.fileExists(atPath: tombstone.path) else { throw AgentLoopError.protocolError("聊天已删除，未重新写入") }
          let folder = directory.appendingPathComponent("history/" + snapshot.id.uuidString)
          let store = ConversationStore(directory: folder, fileName: "recovery.json")
          let normalized = try conversation.archivingImages(to: store.imageDirectory(runID: snapshot.id))
          var record = snapshot
          let revision = UUID(); record.conversationRevision = revision; record.updatedAt = Date()
          let checkpoint = ConversationCheckpoint(runID: snapshot.id, revision: revision,
            accountTag: accountTag, conversation: try normalized.checkpoint(unfinishedCall: unfinishedCall), recoverySnapshot: record)
          try store.save(checkpoint)
          continuation.resume(returning: (normalized, checkpoint))
        } catch { continuation.resume(throwing: error) }
      }
    }
  }
}
