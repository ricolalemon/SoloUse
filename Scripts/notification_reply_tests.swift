import Foundation

private func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
  if !value() { throw AgentLoopError.protocolError(message) }
}
private func call(_ id: String, _ name: String, _ arguments: String = "{}") -> AgentToolCall {
  .init(id: id, name: name, arguments: arguments)
}
private func turn(_ calls: [AgentToolCall]) -> AgentModelTurn {
  .init(
    output: calls.map {
      .object([
        "type": .string("function_call"), "call_id": .string($0.id),
        "name": .string($0.name), "arguments": .string($0.arguments),
      ])
    }, model: "gpt-6-astra", effort: "low")
}
@MainActor private final class Model: AgentModelTransport {
  var input: [JSONValue] = []
  func respond(
    input: [JSONValue], tools: [JSONValue],
    onMessage: @escaping @MainActor (AgentMessageUpdate) -> Void
  ) async throws -> AgentModelTurn {
    self.input = input
    return .init(
      output: [
        .object([
          "type": .string("message"),
          "content": .array([
            .object(["type": .string("output_text"), "text": .string("done")])
          ]),
        ])
      ], model: "gpt-6-astra", effort: "low")
  }
}
@MainActor private final class Executor: AgentToolExecutor {
  var calls = 0
  func execute(_ call: AgentToolCall) async throws -> AgentToolResult {
    calls += 1
    return .init(content: [])
  }
}
@main struct NotificationReplyTests {
  @MainActor static func main() async throws {
    let id = UUID()
    let question = AgentQuestion(text: "Which one?", choices: ["A", "B"])
    let completed = call("completed", "phone_home")
    let asking = call(
      "asking", "phone_ask_user", "{\"question\":\"Which one?\",\"choices\":[\"A\",\"B\"]}")
    let queued = call("queued", "phone_home")
    var conversation = AgentConversation(task: "Fixture task")
    try conversation.append(turn([completed]))
    try conversation.append(.init(content: [.textContent("already executed")]), for: completed)
    try conversation.append(turn([asking, queued]))
    var pending = PendingHandoff(
      runID: id, question: question, call: asking,
      conversation: conversation, model: .initial, accountTag: "fixture", readOnly: true,
      turnLimit: 0, runtimeMinutes: 0, turns: 2, calls: 1)
    try check(
      !pending.accept(runID: UUID(), questionID: question.id, text: "A"), "Wrong task accepted")
    try check(!pending.accept(runID: id, questionID: UUID(), text: "A"), "Old question accepted")
    try check(
      !pending.accept(runID: id, questionID: question.id, text: " \n"), "Blank answer accepted")
    try check(
      pending.accept(runID: id, questionID: question.id, text: " B "), "Valid reply rejected")
    try check(
      !pending.accept(runID: id, questionID: question.id, text: "A"), "Double answer accepted")
    try check(pending.answer == "B", "Answer replaced")
    print("PASS task/question binding, empty reply rejection and exactly one accepted reply")

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "solouse-handoff-\(UUID())")
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = HandoffStore(directory: folder)
    try store.save(pending)
    let restored = store.load()!
    try check(
      restored.answer == "B" && restored.question == question && restored.model == .initial,
      "Persistence changed reply/config")
    let resumed = try restored.answeredConversation()
    try check(
      resumed.cached(completed)?.content == [.textContent("already executed")], "Prior receipt lost"
    )
    try check(resumed.cached(asking)?.userReply == "B", "Question tool not resolved")
    let queuedReceipt = try JSONValue.array(resumed.cached(queued)!.content).text()
    try check(
      queuedReceipt.contains("not_executed") && queuedReceipt.contains("user_handoff"),
      "Queued operation replay risk")
    try resumed.checkSize()
    print(
      "PASS atomic checkpoint round trip, original model, prior receipts and discarded queued actions"
    )

    let model = Model()
    let executor = Executor()
    let loop = PhoneAgentLoop(task: "unused", model: model, executor: executor)
    try loop.restore(restored)
    _ = try await loop.run(maxTurns: 1)
    try check(
      executor.calls == 0 && loop.turns == 3 && loop.toolCalls == 2,
      "Recovery restarted earlier actions/counters")
    try check(
      model.input.contains {
        $0["role"].string == "user" && $0["content"].array?.contains(.textContent("B")) == true
      }, "Answer not sent to model")
    store.remove()
    try check(store.load() == nil, "Consumed checkpoint retained")
    print(
      "PASS recovered loop continues the same model conversation without replaying completed actions"
    )

    let kinds: [(String, String?, Bool, QuestionNotificationAction)] = [
      (QuestionNotificationAction.replyID, "你好", false, .reply("你好")),
      (QuestionNotificationAction.choicePrefix + "1", nil, false, .choice(1)),
      (QuestionNotificationAction.choicePrefix + "2", nil, false, .ignored),
      (QuestionNotificationAction.stopID, nil, false, .stop),
      ("dismiss", nil, false, .ignored), ("default", nil, true, .open),
    ]
    for (identifier, text, isDefault, expected) in kinds {
      try check(
        QuestionNotificationAction.parse(identifier: identifier, text: text, isDefault: isDefault)
          == expected, "Notification routing failed")
    }
    _ = try PhoneTools.parse(asking)
    _ = try PhoneTools.parse(call("legacy", "phone_ask_user", "{\"question\":\"Which?\"}"))
    var rejected = false
    do {
      _ = try PhoneTools.parse(
        call("bad", "phone_ask_user", "{\"question\":\"Which?\",\"choices\":[\"A\",\"A\"]}"))
    } catch { rejected = true }
    try check(rejected, "Ambiguous duplicate options accepted")
    print("PASS notification action routing and generic short-choice tool validation")
  }
}
