#if DEBUG
import UIKit

// Explicit developer-only text fixture. It uses the ordinary app send path and
// protects the user's starting record with an on-device backup restored afterward.
@MainActor enum ChatContinuationSelfTest {
  private static var directory: URL { ProbeModel.shared.directory.appendingPathComponent("task-records") }
  private static var backup: URL { ProbeModel.shared.directory.appendingPathComponent("chat-check-backup") }
  private static var reportURL: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("chat-continuation-check.json")
  }
  private static func saveReport(_ report: [String: Any]) throws {
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
  }
  static func run(afterRelaunch: Bool, marker: String) async {
    let agent = PhoneAgentModel.shared
    guard !agent.busy, agent.pendingHandoff == nil, !ProbeModel.shared.busy,
      marker.count >= 12, marker.count <= 80, marker.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return }
    var report: [String: Any] = ["stage": afterRelaunch ? "after_relaunch" : "same_process", "status": "running"]
    do {
      report["full_context_loaded_before_test"] = agent.hasFullConversationContext
      if afterRelaunch, !agent.hasFullConversationContext {
        throw AgentLoopError.protocolError("Full conversation did not reload")
      }
      if !afterRelaunch {
        guard !FileManager.default.fileExists(atPath: backup.path) else {
          throw AgentLoopError.protocolError("Previous diagnostic backup still exists")
        }
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        var backupURL = backup
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try backupURL.setResourceValues(resourceValues)
        // Keep the user's chat in the history store. Diagnostics run in their
        // own new chat, so cleanup never overwrites another chat or its replies.
        agent.refreshHistory()
        let original = ["id": agent.runID?.uuidString ?? ""]
        try JSONEncoder().encode(original).write(
          to: backup.appendingPathComponent("original-selection.json"), options: .atomic)
        guard agent.newChat() else { throw AgentLoopError.protocolError(agent.storageStatus) }

      }
      for _ in 0..<30 {
        if UIApplication.shared.applicationState == .active { break }
        try await Task.sleep(for: .milliseconds(100))
      }
      let before = agent.timeline.entries.filter { $0.kind == .user }.count
      if !afterRelaunch {
        try await send("这是一次续聊验证。请记住代号「\(marker)」。只回复“已记住”，不要操作手机。")
      }
      let id = agent.runID
      try await send("请说出之前让我记住的代号，只回复代号，不要操作手机。")
      let after = agent.timeline.entries.filter { $0.kind == .user }.count
      let snapshot = TaskRecordStore(directory: directory).load()
      let correct = agent.result.trimmingCharacters(in: .whitespacesAndNewlines) == marker
      report["status"] = correct && agent.runID == id && after == before + (afterRelaunch ? 1 : 2) && snapshot?.conversationRevision != nil ? "passed" : "failed"
      report["run_id"] = agent.runID?.uuidString
      report["revision"] = snapshot?.conversationRevision?.uuidString
      report["remembered_marker"] = correct
      report["user_messages_before"] = before
      report["user_messages_after"] = after
      report["tool_calls"] = agent.calls
      report["phase"] = agent.phase.rawValue
    } catch {
      report["status"] = "failed"
      report["error"] = error.localizedDescription
    }
    try? saveReport(report)
  }
  private static func send(_ text: String) async throws {
    let agent = PhoneAgentModel.shared
    let previousReadOnly = agent.readOnly
    agent.readOnly = true
    agent.taskText = text
    agent.start()
    agent.readOnly = previousReadOnly
    guard agent.busy else { throw AgentLoopError.protocolError("Diagnostic message was not accepted: \(agent.status)") }
    let deadline = Date().addingTimeInterval(120)
    while agent.busy, Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
    guard !agent.busy, agent.phase == .completed, agent.calls == 0 else {
      throw AgentLoopError.protocolError("Text-only check did not finish without tools")
    }
  }
  static func restore() throws {
    let agent = PhoneAgentModel.shared
    guard !agent.busy, agent.pendingHandoff == nil,
      let report = try JSONSerialization.jsonObject(with: Data(contentsOf: reportURL)) as? [String: Any],
      let current = TaskRecordStore(directory: directory).load(), current.phase.terminal,
      current.id.uuidString == report["run_id"] as? String,
      current.conversationRevision?.uuidString == report["revision"] as? String,
      FileManager.default.fileExists(atPath: backup.path) else {
      throw AgentLoopError.protocolError("Refusing to restore over a different or active chat")
    }
    let original = try JSONDecoder().decode([String: String].self,
      from: Data(contentsOf: backup.appendingPathComponent("original-selection.json")))
    if let id = original["id"].flatMap(UUID.init(uuidString:)) {
      guard agent.openHistory(id) else { throw AgentLoopError.protocolError(agent.storageStatus) }
    } else {
      guard agent.newChat() else { throw AgentLoopError.protocolError(agent.storageStatus) }
    }
    guard agent.deleteHistory(current.id) else { throw AgentLoopError.protocolError(agent.storageStatus) }
    try FileManager.default.removeItem(at: backup)
    var updated = report
    updated["original_chat_restored"] = true
    try saveReport(updated)
  }
}
#endif
