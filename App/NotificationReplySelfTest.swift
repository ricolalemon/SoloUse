#if DEBUG
  import Foundation
  import UserNotifications

  @MainActor enum NotificationReplySelfTest {
    private static var folder: URL {
      ProbeModel.shared.directory.appendingPathComponent("notification-reply-test")
    }
    static func prepare() throws -> PendingHandoff {
      let question = AgentQuestion(
        text: "通知回复测试：请选择一个选项，或回复一句话。这个测试不会操作手机。", choices: ["收到", "稍后"])
      let call = AgentToolCall(
        id: "notification-fixture", name: "phone_ask_user",
        arguments: "{\"question\":\"fixture\",\"choices\":[]}")
      var conversation = AgentConversation(task: "Synthetic notification test; no phone operations")
      try conversation.append(
        .init(
          output: [
            .object([
              "type": .string("function_call"), "call_id": .string(call.id),
              "name": .string(call.name), "arguments": .string(call.arguments),
            ])
          ], model: "gpt-6-astra", effort: "low"))
      let pending = PendingHandoff(
        runID: UUID(), question: question, call: call,
        conversation: conversation, model: .initial, accountTag: "synthetic", readOnly: true,
        turnLimit: 0, runtimeMinutes: 0, turns: 0, calls: 0)
      try HandoffStore(directory: folder).save(pending)
      report(["status": "waiting", "model_calls": 0, "phone_commands": 0], runID: pending.runID)
      return pending
    }
    @discardableResult
    static func handle(_ action: QuestionNotificationAction, runID: UUID, questionID: UUID?) -> String? {
      let store = HandoffStore(directory: folder)
      guard var pending = store.load(), pending.runID == runID, pending.question.id == questionID
      else { return nil }
      let answer: String
      switch action {
      case .reply(let text): answer = text
      case .choice(let index):
        guard pending.question.choices.indices.contains(index) else { return nil }
        answer = pending.question.choices[index]
      case .stop:
        store.remove()
        report(["status": "stopped", "model_calls": 0, "phone_commands": 0], runID: runID)
        return "stopped"
      case .open: return pending.answer == nil ? "waiting" : "passed"
      default: return nil
      }
      guard pending.accept(runID: runID, questionID: pending.question.id, text: answer) else {
        return nil
      }
      do {
        try store.save(pending)
        _ = try pending.answeredConversation()
        report([
          "status": "passed", "reply_kind": action == .reply(answer) ? "text" : "choice",
          "model_calls": 0, "phone_commands": 0,
        ], runID: runID)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [
          "solouse.notification-test"
        ])
        return "passed"
      } catch {
        report(["status": "failed", "error": error.localizedDescription], runID: runID)
        return "failed"
      }
    }
    static func latestResult() -> [String: Any]? {
      guard let data = try? Data(contentsOf: folder.appendingPathComponent("result.json")), data.count < 64000 else { return nil }
      return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    private static func report(_ value: [String: Any], runID: UUID) {
      var value = value
      value["kind"] = "notification_reply_self_test"
      value["run_id"] = runID.uuidString
      value["generated_at"] = ISO8601DateFormatter().string(from: Date())
      ProbeModel.shared.log(value)
      if let data = try? JSONSerialization.data(
        withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
      {
        try? data.write(to: folder.appendingPathComponent("result.json"), options: .atomic)
      }
    }
  }
#endif
