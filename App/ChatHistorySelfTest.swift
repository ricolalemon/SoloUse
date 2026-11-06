#if DEBUG
import Foundation

// Explicit diagnostic launch only. Uses the real controller and disk store;
// never starts the model, a phone session, or any saved user task.
@MainActor enum ChatHistorySelfTest {
  private struct Report: Codable {
    var status = "running"
    var original: UUID?
    var a = UUID()
    var b = UUID()
    var draftOnly: UUID? = UUID()
    var sameProcess = false
    var afterRelaunch = false
    var restored = false
    var error: String?
    var modelRequests = 0
    var phoneCommands = 0
  }
  private static let draftA = "历史测试 A 的未发送草稿"
  private static let draftB = "历史测试 B 的未发送草稿"
  private static var directory: URL { ProbeModel.shared.directory.appendingPathComponent("task-records") }
  private static var reportURL: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("chat-history-check.json")
  }
  private static func save(_ report: Report) throws {
    try JSONEncoder().encode(report).write(to: reportURL, options: .atomic)
  }
  private static func check(_ value: Bool, _ reason: String) throws {
    if !value { throw AgentLoopError.protocolError(reason) }
  }
  private static func seed(_ id: UUID, text: String, store: ChatHistoryStore) throws {
    var timeline = AgentTimeline(); timeline.note(text, kind: .user)
    timeline.note("这段聊天已单独保存，打开后可以继续。", kind: .assistant)
    let context = ConversationCheckpoint(runID: id, revision: UUID(), accountTag: "history-fixture",
      conversation: AgentConversation(task: text))
    let snapshot = TaskSnapshot(id: id, prompt: text, phase: .completed, timeline: timeline,
      result: "这段聊天已单独保存，打开后可以继续。", startedAt: Date(), updatedAt: Date(),
      model: .initial, conversationRevision: context.revision)
    try store.save(snapshot, context: context, handoff: nil, draft: "")
  }
  static func run(_ stage: String) {
    let agent = PhoneAgentModel.shared
    guard agent.canSwitchChat, agent.pendingHandoff == nil else { return }
    let store = ChatHistoryStore(directory: directory)
    var report = Report()
    do {
      if stage == "seed" {
        if FileManager.default.fileExists(atPath: reportURL.path) {
          let previous = try JSONDecoder().decode(Report.self, from: Data(contentsOf: reportURL))
          try check(previous.restored, "Previous diagnostic chats still need cleanup")
        }
        agent.refreshHistory()
        report.original = agent.runID
        try save(report) // Persist ownership before creating any fixture files.
        try check(agent.newChat(), "Could not preserve original chat")
        try seed(report.a, text: "帮我整理明天的日程，并按时间排序", store: store)
        try seed(report.b, text: "查看手机上的待办事项，先列出尚未完成的内容", store: store)
        guard let draftID = report.draftOnly else { throw AgentLoopError.protocolError("Missing draft fixture ID") }
        let unsent = TaskSnapshot(id: draftID, prompt: "", phase: .idle, timeline: AgentTimeline(),
          result: "", startedAt: Date(), updatedAt: Date())
        try store.save(unsent, context: nil, handoff: nil, draft: "尚未发送的消息")
        try check(agent.openHistory(draftID), "Draft-only chat did not open")
        try check(agent.phase == .idle && !agent.hasChatHistory && agent.taskText == "尚未发送的消息",
          "Draft-only chat was incorrectly marked interrupted")
        try check(agent.openHistory(report.a), "Open A failed")
        agent.taskText = draftA
        try check(agent.newChat(), "New chat failed")
        try check(try store.load(report.a).record.draft == draftA, "New chat dropped old draft")
        try check(agent.openHistory(report.b), "Open B failed")
        agent.taskText = draftB
        try check(agent.openHistory(report.a), "Return to A failed")
        try check(agent.taskText == draftA && agent.hasFullConversationContext, "A context/draft missing")
        try check(try store.load(report.b).record.draft == draftB, "B draft missing")
        try check(!agent.busy, "History navigation started execution")
        report.sameProcess = true; report.status = "prepared"
      } else {
        report = try JSONDecoder().decode(Report.self, from: Data(contentsOf: reportURL))
        try check(!report.restored && agent.runID == report.a && agent.taskText == draftA,
          "Refusing to replace a changed or unrelated chat")
        try check(agent.timeline.entries.filter { $0.kind == .user }.count == 1,
          "A user has continued the diagnostic chat")
        if stage == "relaunch" {
          try check(report.sameProcess && agent.hasFullConversationContext, "A did not reload")
          try check(agent.openHistory(report.b), "B did not reload")
          try check(agent.taskText == draftB && agent.hasFullConversationContext, "B draft/context mismatch")
          try check(agent.openHistory(report.a), "A did not survive B switch")
          try check(agent.deleteHistory(report.b), "B deletion failed")
          try check(agent.runID == report.a && agent.taskText == draftA && agent.hasFullConversationContext,
            "Deleting B changed A")
          try check(!agent.busy, "Reload started execution")
          report.afterRelaunch = true; report.status = "passed"
        } else if stage == "restore" {
          if let id = report.original { try check(agent.openHistory(id), "Original chat could not be restored") }
          else { try check(agent.newChat(), "Original blank selection could not be restored") }
          try check(agent.deleteHistory(report.a), "A cleanup failed")
          if !store.isDeleted(report.b) { try check(agent.deleteHistory(report.b), "B cleanup failed") }
          if let draftID = report.draftOnly, !store.isDeleted(draftID) {
            try check(agent.deleteHistory(draftID), "Draft cleanup failed")
          }
          report.restored = true
        } else { throw AgentLoopError.protocolError("Unknown history diagnostic stage") }
      }
    } catch { report.status = "failed"; report.error = error.localizedDescription }
    try? save(report)
  }
}
#endif
