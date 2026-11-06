import Foundation
private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !value() { throw AgentLoopError.protocolError(message) }
}
private func fixture(_ id: UUID, _ name: String, _ date: Date) -> (TaskSnapshot, ConversationCheckpoint) {
  var timeline = AgentTimeline(); timeline.note(name, kind: .user)
  timeline.note("reply to " + name, kind: .assistant)
  let context = ConversationCheckpoint(runID: id, revision: UUID(), accountTag: name,
    conversation: AgentConversation(task: name))
  return (.init(id: id, prompt: name, phase: .completed, timeline: timeline, result: "reply to " + name,
    startedAt: date, updatedAt: date, conversationRevision: context.revision), context)
}
@main struct HistoryTests {
  static func main() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("solouse-history-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let history = ChatHistoryStore(directory: directory)
    let records = TaskRecordStore(directory: directory)
    let contexts = ConversationStore(directory: directory)
    let a = UUID(), b = UUID()
    let (one, contextA) = fixture(a, "第一段聊天", Date(timeIntervalSince1970: 100))
    let (two, contextB) = fixture(b, "Second conversation", Date(timeIntervalSince1970: 200))
    try records.save(one); try contexts.save(contextA)
    let migrated = try history.bootstrap()!
    try check(migrated.context?.conversation.items == contextA.conversation.items, "Migration lost full context")
    try check(try tryValue(history.selectedID) == a, "Current selection not migrated")
    try history.select(nil)
    try check(try tryValue(history.bootstrap) == nil, "New chat resurrected stale current files")
    try check(try history.summaries().count == 1, "New chat removed old history")
    print("PASS existing-chat migration and durable blank selection without deleting history")

    try history.save(two, context: contextB, handoff: nil, draft: "unsent B")
    try history.select(b); try records.save(two); try contexts.save(contextB)
    let loadedA = try history.load(a), loadedB = try history.load(b)
    try check(loadedA.context?.accountTag == "第一段聊天" && loadedB.context?.accountTag == "Second conversation", "Contexts mixed")
    try check(loadedB.record.draft == "unsent B", "Draft lost")
    var denied = false
    do { _ = try loadedA.context!.adding("followup", accountTag: "Second conversation") } catch { denied = true }
    try check(denied, "Cross-account continuation accepted")
    denied = false
    do { try history.save(one, context: contextB, handoff: nil, draft: "") } catch { denied = true }
    try check(denied, "Other chat context was attached")
    let summaries = try history.summaries()
    try check(summaries.map(\.id) == [b,a] && summaries[0].hasDraft, "Recency/draft summary wrong")
    print("PASS separate histories/contexts/drafts, account isolation and stable recency")

    // A selected archive survives a switch interrupted before the current cache
    // was refreshed. A newer cache for the same chat still recovers live events.
    try history.select(a)
    try check(try history.bootstrap()?.record.snapshot.id == a, "Stale B cache replaced selected A")
    var newer = one; newer.updatedAt = Date(timeIntervalSince1970: 300)
    newer.timeline.note("later visible activity")
    try records.save(newer); try contexts.save(contextA)
    try check(try history.bootstrap()?.record.snapshot.timeline.entries.count == newer.timeline.entries.count,
      "Latest current activity was lost on restart")
    try history.select(b)
    try check(try history.bootstrap()?.record.draft == "unsent B", "Relaunch lost selected draft")
    print("PASS interrupted-switch cache isolation and recovery of newer current activity")

    let question = AgentQuestion(text: "Which?", choices: ["A", "B"])
    let call = AgentToolCall(id: "ask", name: "phone_ask_user", arguments: "{}")
    var pendingConversation = AgentConversation(task: "history question")
    try pendingConversation.append(.init(output: [.object(["type": .string("function_call"), "call_id": .string(call.id), "name": .string(call.name), "arguments": .string(call.arguments)])], model: "fixture", effort: nil))
    let pending = PendingHandoff(runID: a, question: question, call: call, conversation: pendingConversation,
      model: .initial, accountTag: "第一段聊天", readOnly: true, turnLimit: 0, runtimeMinutes: 0, turns: 1, calls: 0)
    var waiting = one; waiting.phase = .waiting
    try history.save(waiting, context: contextA, handoff: pending, draft: "draft A")
    try check(try history.answer(runID: a, questionID: question.id, text: "A"), "Inactive reply not saved")
    try check(try tryValue(history.selectedID) == b, "Inactive reply switched active chat")
    let answered = try history.load(a)
    try check(answered.handoff?.answer == "A" && answered.record.draft == "draft A", "Inactive handoff/draft lost")
    try check(!(try history.answer(runID: a, questionID: question.id, text: "B")), "Reply accepted twice")
    print("PASS inactive notification reply stays attached to its own chat without activation")

    try history.delete(b)
    try check(try tryValue(history.bootstrap) == nil, "Deleted selected chat resurrected from current cache")
    try check(!(try history.summaries().contains { $0.id == b }), "Deleted chat remains in list")
    denied = false
    do { try history.save(two, context: contextB, handoff: nil, draft: "") } catch { denied = true }
    try check(denied, "Late write resurrected deleted chat")
    try check(try history.load(a).context?.conversation.items == contextA.conversation.items, "Deleting B changed A")
    print("PASS deletion/tombstone isolation and no resurrection after relaunch")

    let summary = directory.appendingPathComponent("history/\(a.uuidString)/summary.json")
    try FileManager.default.removeItem(at: summary)
    try check(try history.summaries().count == 1 && FileManager.default.fileExists(atPath: summary.path), "Missing summary not repaired")
    var missing = one; missing.conversationRevision = UUID()
    try history.save(missing, context: nil, handoff: nil, draft: "")
    let partial = try history.load(a)
    try check(partial.context == nil && partial.contextUnavailable && !partial.record.snapshot.timeline.entries.isEmpty,
      "Missing context silently attached another chat or hid transcript")
    print("PASS partial-write summary repair and visible transcript survives missing context")

    var unsent = TaskSnapshot(id: UUID(), prompt: "", phase: .idle, timeline: AgentTimeline(),
      result: "", startedAt: Date(), updatedAt: Date())
    try history.save(unsent, context: nil, handoff: nil, draft: "尚未发送的消息")
    unsent = try history.load(unsent.id).record.snapshot
    unsent.restoreForViewing()
    try check(unsent.phase == .idle && unsent.timeline.entries.isEmpty, "Unsent draft became an interrupted task")
    print("PASS draft-only history reload keeps an empty timeline and does not invent an interrupted task")
  }
  static func tryValue<T>(_ work: () throws -> T) rethrows -> T { try work() }
}
