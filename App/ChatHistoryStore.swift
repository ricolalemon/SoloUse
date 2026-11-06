import Foundation

struct ChatHistorySummary: Codable, Identifiable, Sendable {
  let id: UUID
  let title: String
  let preview: String
  let updatedAt: Date
  let phase: TaskPhase
  let hasDraft: Bool
  init(snapshot: TaskSnapshot, draft: String) {
    id = snapshot.id
    let first = snapshot.timeline.entries.first { $0.kind == .user }?.text ?? snapshot.prompt
    title = Self.excerpt(first.isEmpty ? draft : first, limit: 64, fallback: "新聊天")
    hasDraft = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let last = snapshot.timeline.entries.last { [.user, .assistant].contains($0.kind) }?.text ?? snapshot.result
    preview = Self.excerpt(hasDraft ? draft : last, limit: 140, fallback: "")
    updatedAt = snapshot.updatedAt
    phase = snapshot.phase
  }
  private static func excerpt(_ text: String, limit: Int, fallback: String) -> String {
    let trimmed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    return trimmed.isEmpty ? fallback : String(trimmed.prefix(limit))
  }
}

struct ChatHistoryRecord: Codable, Sendable {
  var snapshot: TaskSnapshot
  var draft: String
  var handoffID: UUID?
}
struct LoadedChat {
  let record: ChatHistoryRecord
  let context: ConversationCheckpoint?
  let handoff: PendingHandoff?
  let contextUnavailable: Bool
}

// Each chat owns immutable context revisions and a small atomic record pointing
// to the current revision. Listing reads only summaries, never image histories.
struct ChatHistoryStore {
  let directory: URL
  private var root: URL { directory.appendingPathComponent("history", isDirectory: true) }
  private var selection: URL { root.appendingPathComponent("selection.json") }
  private struct Selection: Codable { let id: UUID? }
  private func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
  private func tombstone(_ id: UUID) -> URL { root.appendingPathComponent("deleted-" + id.uuidString) }
  func isDeleted(_ id: UUID) -> Bool { FileManager.default.fileExists(atPath: tombstone(id).path) }
  private func contextStore(_ id: UUID, _ revision: UUID) -> ConversationStore {
    ConversationStore(directory: folder(id), fileName: "context-\(revision.uuidString).json")
  }
  private func handoffStore(_ id: UUID, _ question: UUID) -> HandoffStore {
    HandoffStore(directory: folder(id), fileName: "handoff-\(question.uuidString).json")
  }
  private func write<T: Encodable>(_ value: T, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(value)
    guard data.count < 40_000_000 else { throw AgentLoopError.contextLimit(data.count) }
    try data.write(to: url, options: .atomic)
    #if os(iOS)
      try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
    #endif
    var target = url
    var values = URLResourceValues(); values.isExcludedFromBackup = true
    try target.setResourceValues(values)
  }
  private func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 40_000_000
    guard size < 40_000_000 else { throw AgentLoopError.contextLimit(size) }
    return try JSONDecoder().decode(type, from: Data(contentsOf: url))
  }
  func selectedID() throws -> UUID? {
    guard FileManager.default.fileExists(atPath: selection.path) else { return nil }
    return try read(Selection.self, from: selection).id
  }
  func select(_ id: UUID?) throws {
    if let id {
      guard !FileManager.default.fileExists(atPath: tombstone(id).path),
        FileManager.default.fileExists(atPath: folder(id).appendingPathComponent("record.json").path)
      else { throw AgentLoopError.protocolError("聊天记录已不存在") }
    }
    try write(Selection(id: id), to: selection)
  }
  func save(_ snapshot: TaskSnapshot, context: ConversationCheckpoint?, handoff: PendingHandoff?, draft: String) throws {
    guard !FileManager.default.fileExists(atPath: tombstone(snapshot.id).path) else {
      throw AgentLoopError.protocolError("聊天已删除，未重新写入")
    }
    if let context, let revision = snapshot.conversationRevision {
      guard context.runID == snapshot.id, context.revision == revision else {
        throw AgentLoopError.protocolError("聊天上下文与记录不匹配")
      }
      let store = contextStore(snapshot.id, revision)
      if !FileManager.default.fileExists(atPath: folder(snapshot.id).appendingPathComponent(store.fileName).path) {
        try store.save(context)
      }
    }
    if let handoff {
      guard handoff.runID == snapshot.id else { throw AgentLoopError.protocolError("问题属于另一段聊天") }
      try handoffStore(snapshot.id, handoff.question.id).save(handoff)
    }
    let record = ChatHistoryRecord(snapshot: snapshot, draft: draft, handoffID: handoff?.question.id)
    try write(record, to: folder(snapshot.id).appendingPathComponent("record.json"))
    try write(ChatHistorySummary(snapshot: snapshot, draft: draft), to: folder(snapshot.id).appendingPathComponent("summary.json"))
    // Commit the record before pruning superseded revisions. A crash cannot
    // make an old record point at a different conversation's context.
    let keep = Set(["context-\(snapshot.conversationRevision?.uuidString ?? "").json", "handoff-\(handoff?.question.id.uuidString ?? "").json"])
    for file in (try? FileManager.default.contentsOfDirectory(at: folder(snapshot.id), includingPropertiesForKeys: nil)) ?? [] {
      let obsoleteContext = snapshot.conversationRevision != nil && file.lastPathComponent.hasPrefix("context-")
      if (obsoleteContext || file.lastPathComponent.hasPrefix("handoff-")), !keep.contains(file.lastPathComponent) {
        try? FileManager.default.removeItem(at: file)
      }
    }
  }
  func load(_ id: UUID) throws -> LoadedChat {
    guard !FileManager.default.fileExists(atPath: tombstone(id).path) else { throw AgentLoopError.protocolError("聊天已删除") }
    var record = try read(ChatHistoryRecord.self, from: folder(id).appendingPathComponent("record.json"))
    guard record.snapshot.id == id else { throw AgentLoopError.protocolError("聊天编号不匹配") }
    var context: ConversationCheckpoint?
    if let revision = record.snapshot.conversationRevision { context = try? contextStore(id, revision).load(runID: id, revision: revision) }
    if let recovery = try? ConversationStore(directory: folder(id), fileName: "recovery.json").loadAny(),
      recovery.runID == id, let snapshot = recovery.recoverySnapshot, snapshot.id == id,
      snapshot.updatedAt > record.snapshot.updatedAt {
      record.snapshot = snapshot
      context = recovery
    }
    var handoff: PendingHandoff?
    if let question = record.handoffID,
      let value = handoffStore(id, question).load(), value.runID == id, value.question.id == question { handoff = value }
    return LoadedChat(record: record, context: context, handoff: handoff,
      contextUnavailable: record.snapshot.conversationRevision != nil && context == nil)
  }
  func summaries() throws -> [ChatHistorySummary] {
    guard FileManager.default.fileExists(atPath: root.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).compactMap { url in
      guard let id = UUID(uuidString: url.lastPathComponent), !FileManager.default.fileExists(atPath: tombstone(id).path) else { return nil }
      let summaryURL = url.appendingPathComponent("summary.json")
      let recordURL = url.appendingPathComponent("record.json")
      let recordDate = try? recordURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
      let summaryDate = try? summaryURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
      if let recordDate, let summaryDate, summaryDate >= recordDate,
        let summary = try? read(ChatHistorySummary.self, from: summaryURL), summary.id == id { return summary }
      // Repair only missing/stale summaries; normal listing never decodes full histories.
      if let record = try? read(ChatHistoryRecord.self, from: url.appendingPathComponent("record.json")),
        record.snapshot.id == id {
        let summary = ChatHistorySummary(snapshot: record.snapshot, draft: record.draft)
        try? write(summary, to: summaryURL)
        return summary
      }
      return nil
    }.sorted { $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt }
  }
  func delete(_ id: UUID) throws {
    // Persist a tombstone before removing files so stale legacy/current files
    // cannot resurrect a deleted chat after interruption or relaunch.
    try write(Selection(id: id), to: tombstone(id))
    if try selectedID() == id { try select(nil) }
    if FileManager.default.fileExists(atPath: folder(id).path) { try FileManager.default.removeItem(at: folder(id)) }
  }
  func bootstrap() throws -> LoadedChat? {
    let hasSelection = FileManager.default.fileExists(atPath: selection.path)
    let current = TaskRecordStore(directory: directory).load()
    let selected = try selectedID()
    if let current, !FileManager.default.fileExists(atPath: tombstone(current.id).path),
      (!hasSelection || selected == current.id) {
      let archived = try? load(current.id)
      if archived == nil || current.updatedAt > archived!.record.snapshot.updatedAt {
        var context = current.conversationRevision.flatMap { revision in
          (try? ConversationStore(directory: directory).load(runID: current.id, revision: revision))
            ?? (archived?.context?.revision == revision ? archived?.context : nil)
        }
        // A newer UI save can still reference an older model revision if the
        // process ended between committing recovery and publishing its revision.
        if let durable = archived?.context,
          context == nil || durable.conversation.items.count > context!.conversation.items.count { context = durable }
        let pending = HandoffStore(directory: directory).load()
        var safeCurrent = current
        safeCurrent.conversationRevision = context?.revision
        try save(safeCurrent, context: context, handoff: pending?.runID == current.id ? pending : nil, draft: archived?.record.draft ?? "")
      }
      if !hasSelection { try select(current.id) }
    } else if !hasSelection { try select(nil) }
    guard let id = try selectedID() else { return nil }
    if FileManager.default.fileExists(atPath: tombstone(id).path) { try select(nil); return nil }
    return try load(id)
  }
  func answer(runID: UUID, questionID: UUID, text: String) throws -> Bool {
    let chat = try load(runID)
    guard var pending = chat.handoff, pending.accept(runID: runID, questionID: questionID, text: text) else { return false }
    var snapshot = chat.record.snapshot
    snapshot.phase = .paused; snapshot.updatedAt = Date()
    try save(snapshot, context: chat.context, handoff: pending, draft: chat.record.draft)
    return true
  }
}
