#if DEBUG
import UIKit

// Explicit diagnostics only, in an isolated store. Never controls the phone or
// changes chat selection. Reports contain counts/status, never opaque context.
@MainActor enum ContextRecoverySelfTest {
  private static var consumed = false
  static func run(_ stage: String) async {
    guard !consumed, !PhoneAgentModel.shared.busy, !SubscriptionModel.shared.busy else { return }
    consumed = true
    SubscriptionModel.shared.busy = true
    let idle = UIApplication.shared.isIdleTimerDisabled
    UIApplication.shared.isIdleTimerDisabled = true
    defer { SubscriptionModel.shared.busy = false; UIApplication.shared.isIdleTimerDisabled = idle }
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let reportURL = docs.appendingPathComponent("context-recovery-check.json")
    let folder = ProbeModel.shared.directory.appendingPathComponent("context-recovery-check")
    let store = ConversationStore(directory: folder)
    var report: [String: Any] = ["status": "running", "stage": stage, "phone_commands": 0]
    func save() { if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: reportURL, options: .atomic) } }
    save()
    do {
      if stage == "relaunch" {
        guard let saved = try store.loadAny() else { throw AgentLoopError.protocolError("Checkpoint not found") }
        let input = try saved.conversation.modelInput()
        guard input.contains(where: { $0["type"].string == "compaction" }), saved.conversation.cached(.init(id: "fixture", name: "phone_observe", arguments: "{}")) != nil else {
          throw AgentLoopError.protocolError("Checkpoint lost compact state or receipts")
        }
        report["reloaded_items"] = saved.conversation.items.count
        report["reloaded_compaction"] = true
      } else {
        let choice = ModelSelection.shared.choice
        let models = try await SubscriptionClient().models()
        guard let model = models.first(where: { $0.id == choice.id }) else { throw AgentLoopError.protocolError("Selected model unavailable") }
        let config = try model.configuration(for: choice)
        let client = SubscriptionClient(modelConfiguration: config)
        var conversation = AgentConversation(task: "This is an isolated compaction protocol test. Remember the code in the supplied completed tool receipt. No phone operations are requested.")
        let call = AgentToolCall(id: "fixture", name: "phone_observe", arguments: "{}")
        try conversation.append(.init(output: [.object(["type": .string("function_call"), "call_id": .string(call.id), "name": .string(call.name), "arguments": .string(call.arguments)])], model: choice.id, effort: choice.effort))
        try conversation.append(.init(content: [.textContent("Synthetic completed tool receipt. Remember the code: amber-river-9462.")]), for: call)
        let input = try await conversation.modelInputAsync()
        let result = try await client.respond(input: input + [.object(["type": .string("compaction_trigger")])], tools: PhoneTools.definitions, onMessage: { _ in })
        report["model"] = result.model
        report["output_types"] = result.output.compactMap { $0["type"].string }
        try conversation.installCompaction(result.output)
        try await store.saveAsync(.init(runID: UUID(), revision: UUID(), accountTag: "synthetic-test", conversation: conversation))
        report["compaction_saved"] = true
        save()
        try conversation.appendFollowup("Reply only with the remembered code from the completed tool receipt.")
        let answer = try await client.respond(input: conversation.modelInput(), tools: [], onMessage: { _ in })
        guard answer.calls.isEmpty, answer.finalText.contains("amber-river-9462") else { throw AgentLoopError.protocolError("Compacted context did not preserve the synthetic code") }
        report["recall_verified"] = true
        report["request_bytes"] = client.metrics.map(\.requestBytes)
      }
      report["status"] = "passed"
    } catch { report["status"] = "failed"; report["error"] = error.localizedDescription }
    save()
  }
}
#endif
