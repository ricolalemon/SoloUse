import Foundation

private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !value() { throw AgentLoopError.protocolError(message) }
}
private func turn(_ call: AgentToolCall) -> AgentModelTurn {
  .init(output: [.object(["type": .string("function_call"), "call_id": .string(call.id), "name": .string(call.name), "arguments": .string(call.arguments)])], model: "fixture", effort: nil)
}
private let done = AgentModelTurn(output: [.object(["type": .string("message"), "role": .string("assistant"), "content": .array([.object(["type": .string("output_text"), "text": .string("done")])])])], model: "fixture", effort: nil)
@MainActor private final class Model: AgentModelTransport {
  var outputs: [AgentModelTurn]; var requests: [[JSONValue]] = []
  init(_ outputs: [AgentModelTurn]) { self.outputs = outputs }
  func respond(input: [JSONValue], tools: [JSONValue], onMessage: @escaping @MainActor (AgentMessageUpdate) -> Void) async throws -> AgentModelTurn {
    requests.append(input); return outputs.removeFirst()
  }
}
@MainActor private final class Executor: AgentToolExecutor {
  var count = 0
  var action: () throws -> Void = {}
  func execute(_ call: AgentToolCall) async throws -> AgentToolResult {
    count += 1; try action(); return .init(content: [.textContent("completed")])
  }
}
@main struct ContextRecoveryTests {
  @MainActor static func main() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("solouse-context-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID(), store = ConversationStore(directory: root)
    let first = AgentToolCall(id: "call-0", name: "phone_observe", arguments: "{}")
    var original = AgentConversation(task: "Only play the current board; do not submit anything.")
    for index in 0..<60 {
      let call = AgentToolCall(id: "call-\(index)", name: "phone_observe", arguments: "{}")
      try original.append(turn(call))
      let image = JSONValue.object(["type": .string("input_image"), "detail": .string("original"),
        "image_url": .string("data:image/jpeg;base64," + String(repeating: "A", count: 600_000) + String(index))])
      try original.append(.init(content: [.textContent("receipt \(index)"), image]), for: call)
    }
    let legacy = ConversationCheckpoint(runID: id, revision: UUID(), accountTag: "account", conversation: original)
    let legacyBytes = try JSONEncoder().encode(legacy)
    try check(legacyBytes.count > 70_000_000, "Fixture does not exceed both former history limits")
    try ConversationImages.write(legacyBytes, to: store.file)
    let loadedLegacy = try store.load(runID: id, revision: legacy.revision)!
    try await store.saveAsync(loadedLegacy)
    let saved = try store.load(runID: id, revision: legacy.revision)!
    let manifestBytes = try Data(contentsOf: store.file).count
    let assets = try FileManager.default.contentsOfDirectory(at: store.imageDirectory(runID: id), includingPropertiesForKeys: nil)
    try check(assets.count == 60 && manifestBytes < 100_000, "Images duplicated in checkpoint/cache")
    let request = try await saved.conversation.modelInputAsync()
    var imageCount = 0
    for item in request { _ = item.mapImages { image in imageCount += 1; return image } }
    try check(imageCount == 8 && JSONEncoder().encode(request).count < 6_000_000, "Request image window is not bounded")
    let oldID = String(saved.conversation.cached(first)!.content.last!["image_url"].string!.dropFirst(ConversationImages.prefix.count))
    let getImage = AgentToolCall(id: "read", name: "phone_history_image", arguments: "{\"image_id\":\"\(oldID)\"}")
    try check(saved.conversation.historyImage(getImage).content.last == original.cached(first)!.content.last, "Old image not retrieved exactly")
    let wrongID = AgentToolCall(id: "bad", name: "phone_history_image", arguments: "{\"image_id\":\"../other\"}")
    try check(saved.conversation.historyImage(wrongID).content.count == 1, "Arbitrary image path accepted")
    print("PASS legacy \(legacyBytes.count) bytes -> manifest \(manifestBytes) bytes, 60 unique assets, eight-image request and exact old-image retrieval")

    var compacted = saved.conversation
    let opaque = JSONValue.object(["type": .string("compaction"), "encrypted_content": .string("opaque-fixture")])
    try compacted.installCompaction([opaque])
    try check(compacted.items == saved.conversation.items && compacted.cached(first) != nil, "Compaction erased full history/receipts")
    try check(compacted.modelInput().contains(opaque), "Opaque compaction item not preserved")
    let listing = compacted.historyImages(.init(id: "list", name: "phone_history_images", arguments: "{\"offset\":50,\"limit\":20}"))
    let page = try JSONDecoder().decode(JSONValue.self, from: Data(listing.content[0]["text"].string!.utf8))
    try check(page["total"].number == 60 && page["images"].array?.count == 10 && page["next_offset"] == .null, "Compaction hid the old image catalog")
    let continued = try ConversationCheckpoint(runID: id, revision: UUID(), accountTag: "account", conversation: compacted).adding("Continue", accountTag: "account")
    let replayModel = Model([turn(first), done]), replayExecutor = Executor()
    let replayLoop = PhoneAgentLoop(task: "unused", model: replayModel, executor: replayExecutor)
    try replayLoop.continueConversation(continued)
    _ = try await replayLoop.run()
    try check(replayExecutor.count == 0, "Compaction allowed historical action replay")
    var rejected = false
    do { try compacted.installCompaction(turn(first).output) } catch { rejected = true }
    try check(rejected && compacted.items == saved.conversation.items, "Invalid compact response modified history")
    print("PASS opaque compaction preserves original history, instructions, exact receipts and replay protection")

    let history = ChatHistoryStore(directory: root)
    let crashID = UUID(), active = AgentToolCall(id: "in-flight", name: "phone_tap", arguments: "{}")
    var timeline = AgentTimeline(); timeline.note("Run the task", kind: .user)
    let snapshot = TaskSnapshot(id: crashID, prompt: "Run the task", phase: .acting, timeline: timeline, result: "", startedAt: Date(), updatedAt: Date())
    try history.save(snapshot, context: nil, handoff: nil, draft: "draft")
    try history.select(crashID)
    let recovery = RunRecoveryStore(directory: root)
    let executor = Executor()
    executor.action = {
      let recovered = try history.load(crashID)
      try check(recovered.context?.conversation.cached(active)?.needsAttention == true, "Uncertain recovery point not durable before action")
      throw CancellationError() // The action might have happened; no receipt reached the loop.
    }
    let loop = PhoneAgentLoop(task: "Run the task", model: Model([turn(active)]), executor: executor)
    do {
      _ = try await loop.run(persist: { conversation, unfinished, _, _ in
        var value = snapshot; value.updatedAt = Date()
        return try await recovery.save(conversation: conversation, unfinishedCall: unfinished, snapshot: value, accountTag: "account").0
      })
    } catch is CancellationError {}
    let staleContext = ConversationCheckpoint(runID: crashID, revision: UUID(), accountTag: "account", conversation: AgentConversation(task: "Run the task"))
    try store.save(staleContext)
    var newerUI = snapshot; newerUI.conversationRevision = staleContext.revision; newerUI.updatedAt = Date().addingTimeInterval(1)
    try TaskRecordStore(directory: root).save(newerUI)
    let recovered = try history.bootstrap()!
    try check(recovered.context?.conversation.cached(active)?.needsAttention == true, "Crash recovery lost uncertain receipt")
    var view = recovered.record.snapshot; view.restoreForViewing()
    try check(view.phase == .interrupted, "Relaunch would continue an active task")
    let newLoop = PhoneAgentLoop(task: "unused", model: Model([turn(active)]), executor: executor)
    try newLoop.continueConversation(recovered.context!.adding("Resume", accountTag: "account"))
    do { _ = try await newLoop.run() } catch AgentLoopError.needsAttention {}
    try check(executor.count == 1, "Uncertain action replayed after restart")
    print("PASS pre-dispatch durable recovery, simulated process loss, explicit resume and no uncertain replay")

    var longText = AgentConversation(task: "Remember the original instruction")
    let textCall = AgentToolCall(id: "large-receipt", name: "phone_list_apps", arguments: "{}")
    try longText.append(turn(textCall))
    try longText.append(.init(content: [.textContent(String(repeating: "tool-data ", count: 25_000))]), for: textCall)
    let compactModel = Model([.init(output: [opaque], model: "fixture", effort: nil), done])
    let compactExecutor = Executor()
    let compactLoop = PhoneAgentLoop(task: "unused", model: compactModel, executor: compactExecutor)
    try compactLoop.continueConversation(longText)
    _ = try await compactLoop.run()
    try check(compactModel.requests.count == 2 && compactModel.requests[0].last?["type"].string == "compaction_trigger", "Long context did not auto compact")
    try check(compactModel.requests[1].contains(opaque) && compactExecutor.count == 0 && compactLoop.conversation.cached(textCall) != nil, "Compaction dispatched actions or lost history")
    let limitedModel = Model([.init(output: [opaque], model: "fixture", effort: nil), done])
    let limitedLoop = PhoneAgentLoop(task: "unused", model: limitedModel, executor: Executor())
    try limitedLoop.continueConversation(longText)
    do { _ = try await limitedLoop.run(maxTurns: 1); throw AgentLoopError.protocolError("Compaction bypassed the user limit") }
    catch AgentLoopError.turnLimit {}
    try check(limitedModel.requests.count == 1, "Another request was sent beyond the configured limit")
    let largeUserModel = Model([.init(output: [opaque], model: "fixture", effort: nil), done])
    _ = try await PhoneAgentLoop(task: String(repeating: "retain-user-instruction ", count: 12_000), model: largeUserModel, executor: Executor()).run()
    try check(largeUserModel.requests.count == 2, "Compaction immediately repeated without any new context")
    var continuation = ModelContinuation()
    continuation.commit(input: request, tools: PhoneTools.definitions, turn: .init(output: [], model: "fixture", effort: nil, responseID: "old-prefix"))
    try check(continuation.delta(input: compacted.modelInput(), tools: PhoneTools.definitions) == nil, "Compaction reused an invalid incremental prefix")
    let corruptURL = try ConversationImages(directory: store.imageDirectory(runID: id)).file(oldID)
    try Data("damaged".utf8).write(to: corruptURL)
    try check(saved.conversation.historyImage(getImage).content.count == 1, "Damaged image emitted as valid pixels")
    let foreign = AgentConversation(task: "another chat")
    try check(foreign.historyImage(getImage).content.count == 1, "Foreign chat could retrieve image")
    print("PASS automatic compaction, invalid-prefix reset, corrupt-image detection and image isolation")

    let deniedExecutor = Executor(), deniedLoop = PhoneAgentLoop(task: "x", model: Model([turn(active)]), executor: deniedExecutor)
    var saves = 0
    do {
      _ = try await deniedLoop.run(persist: { value, unfinished, _, _ in
        saves += 1
        if unfinished != nil { throw AgentLoopError.protocolError("Disk full") }
        return value
      })
    } catch {}
    try check(deniedExecutor.count == 0 && saves >= 2, "Action ran without a durable write-ahead checkpoint")
    try history.delete(crashID)
    try check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("history/" + crashID.uuidString).path), "Delete left recovery/assets behind")
    try check(history.bootstrap() == nil, "Deleted recovery resurrected chat")
    print("PASS storage failure prevents new actions; deleting a chat removes its recovery and screenshots")
  }
}
