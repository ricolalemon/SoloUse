import Foundation

private func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
  if !value() { throw AgentLoopError.protocolError(message) }
}
private func output(_ text: String) -> AgentModelTurn {
  .init(output: [.object(["type": .string("message"), "role": .string("assistant"), "id": .string("message"),
    "content": .array([.object(["type": .string("output_text"), "text": .string(text)])])])], model: "fixture", effort: nil)
}
private func callTurn(_ calls: [AgentToolCall]) -> AgentModelTurn {
  .init(output: calls.map { .object(["type": .string("function_call"), "call_id": .string($0.id),
    "name": .string($0.name), "arguments": .string($0.arguments)]) }, model: "fixture", effort: nil)
}
@MainActor private final class Model: AgentModelTransport {
  var requests: [[JSONValue]] = []
  var script: [AgentModelTurn]
  init(_ script: [AgentModelTurn]) { self.script = script }
  func respond(input: [JSONValue], tools: [JSONValue], onMessage: @escaping @MainActor (AgentMessageUpdate) -> Void) async throws -> AgentModelTurn {
    requests.append(input); return script.removeFirst()
  }
}
@MainActor private final class Executor: AgentToolExecutor {
  var dispatched = 0
  func execute(_ call: AgentToolCall) async throws -> AgentToolResult {
    dispatched += 1
    return .init(content: [.textContent("executed")])
  }
}
@main struct ConversationContinuationTests {
  @MainActor static func main() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("solouse-conversation-\(UUID())")
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = ConversationStore(directory: folder)
    let records = TaskRecordStore(directory: folder)
    let id = UUID()
    let action = AgentToolCall(id: "already-executed", name: "phone_home", arguments: "{}")
    var conversation = AgentConversation(task: "Remember blue-lake-73")
    try conversation.append(.init(output: [.object(["type": .string("reasoning"), "encrypted_content": .string("opaque-fixture")])], model: "fixture", effort: nil))
    try conversation.append(callTurn([action]))
    let image = JSONValue.object(["type": .string("input_image"), "image_url": .string("data:image/png;base64,fixture")])
    try conversation.append(.init(content: [.textContent("previous action receipt"), image]), for: action)
    try conversation.append(output("I remember blue-lake-73"))
    let checkpoint = ConversationCheckpoint(runID: id, revision: UUID(), accountTag: "account-a", conversation: conversation)
    try await store.saveAsync(checkpoint)
    let loaded = try store.load(runID: id, revision: checkpoint.revision)!
    let hydrated = try loaded.conversation.modelInput()
    try check(hydrated == conversation.items, "Saved history lost model output/images")
    try check(loaded.conversation.cached(action)?.content.first == .textContent("previous action receipt") && loaded.conversation.cached(action)?.content.last?["image_url"].string?.hasPrefix(ConversationImages.prefix) == true, "Receipt cache lost")
    let otherChat = try store.load(runID: UUID(), revision: checkpoint.revision)
    try check(otherChat == nil, "Another chat checkpoint leaked")
    let stale = try store.load(runID: id, revision: UUID())
    try check(stale == nil, "Stale revision accepted")
    var denied = false
    do { _ = try loaded.adding("followup", accountTag: "account-b") } catch { denied = true }
    try check(denied, "Different account received conversation")
    print("PASS durable exact history, images, opaque output, cached receipts and account/revision isolation")

    let continued = try loaded.adding("What was the marker?", accountTag: "account-a")
    try check(Array(continued.items.prefix(conversation.items.count)) == loaded.conversation.items, "Followup replaced old context")
    let model = Model([callTurn([action]), output("blue-lake-73")])
    let executor = Executor()
    let loop = PhoneAgentLoop(task: "unused", model: model, executor: executor)
    try loop.continueConversation(continued)
    let answer = try await loop.run(maxTurns: 2)
    try check(answer == "blue-lake-73" && executor.dispatched == 0, "Historical action replayed")
    try check(model.requests[0].contains { $0["content"].array?.contains(.textContent("What was the marker?")) == true }, "Followup missing from request")
    print("PASS followup sent with prior context, historical call cache reused without action replay")

    let active = AgentToolCall(id: "in-flight", name: "phone_tap", arguments: "{}")
    let queued = AgentToolCall(id: "queued", name: "phone_home", arguments: "{}")
    var interrupted = conversation
    try interrupted.append(callTurn([active, queued]))
    let settled = try interrupted.checkpoint(unfinishedCall: active.id)
    try check(settled.cached(active)?.needsAttention == true, "Uncertain in-flight action described as unexecuted")
    try check(settled.cached(queued)?.needsAttention == false, "Queued action incorrectly dispatched")
    _ = try ConversationCheckpoint(runID: id, revision: UUID(), accountTag: "account-a", conversation: settled).adding("Continue carefully", accountTag: "account-a")
    print("PASS interrupted calls settled conservatively and queued calls discarded")

    var timeline = AgentTimeline()
    timeline.note("Remember visible-73", kind: .user)
    for epoch in ["first", "second"] {
      timeline.accept(AgentEvent.message(.init(id: "same", text: epoch, phase: nil, complete: true)).namespaced(epoch), turn: 1)
      timeline.accept(AgentEvent.toolStarted(action).namespaced(epoch), turn: 1)
      timeline.accept(AgentEvent.actionStarted(id: "child", parent: action.id, name: "home").namespaced(epoch), turn: 1)
    }
    try check(timeline.entries.filter { $0.kind == .assistant }.count == 2, "Followup overwrote earlier assistant bubble")
    try check(Set(timeline.entries.map(\.id)).count == timeline.entries.count, "UI identifiers collided across executions")
    var snapshot = TaskSnapshot(id: id, prompt: "Remember visible-73", phase: .completed, timeline: timeline,
      result: "second", startedAt: Date(), updatedAt: Date(), model: .initial)
    let oldJSON = try JSONEncoder().encode(snapshot)
    let oldDecoded = try JSONDecoder().decode(TaskSnapshot.self, from: oldJSON)
    try check(oldDecoded.conversationRevision == nil, "Legacy record migration failed")
    let legacy = try AgentConversation.recoveringVisibleHistory(oldDecoded)
    let legacyText = legacy.items.flatMap { $0["content"].array ?? [] }.compactMap { $0["text"].string }.joined(separator: "\n")
    try check(legacyText.contains("visible-73") && legacyText.contains("exact tool arguments/results and screenshots were not saved"), "Legacy recovery fabricated full context")
    snapshot.conversationRevision = checkpoint.revision
    try records.save(snapshot)
    try check(records.load()?.conversationRevision == checkpoint.revision, "Record lost continuation reference")
    try records.remove(); try store.remove()
    let cleared = try store.load(runID: id, revision: checkpoint.revision)
    try check(records.load() == nil && cleared == nil, "New chat resurrected old history after restart")
    print("PASS visible-history migration, stable UI history and durable new-chat reset")
  }
}
