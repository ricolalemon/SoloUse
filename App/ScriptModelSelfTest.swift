#if DEBUG
  import Foundation

  @MainActor private final class NoPhoneTestExecutor: AgentToolExecutor {
    private(set) var attemptedPhoneCalls = 0
    func execute(_ call: AgentToolCall) async throws -> AgentToolResult {
      attemptedPhoneCalls += 1
      return .error(
        "test_scope", "This test permits pure JavaScript only; no phone control is available")
    }
  }
  @MainActor enum ScriptModelSelfTest {
    static func run() async {
      guard !PhoneAgentModel.shared.busy, PhoneAgentModel.shared.pendingHandoff == nil,
        !ProbeModel.shared.busy, !SubscriptionModel.shared.busy
      else { return }
      SubscriptionModel.shared.busy = true
      defer { SubscriptionModel.shared.busy = false }
      var report: [String: Any] = ["kind": "script_model_self_test", "phone_commands": 0]
      let noPhone = NoPhoneTestExecutor()
      let executor = ScriptExecutor(phone: noPhone, allowsActions: { true }, controlVersion: { 0 })
      var toolCalls = 0
      do {
        let models = try await SubscriptionClient().models()
        let config = try ModelCatalog.resolve(ModelSelection.shared.choice, in: models)
        let marker = "script-" + UUID().uuidString.lowercased().prefix(8)
        let loop = PhoneAgentLoop(
          task:
            "This is an isolated on-device JavaScript protocol test. No phone operation is requested. Use phone_exec_js to set state.marker to '\(marker)' and state.total to the sum of [7,11,24]. Then in a separate phone_exec_js call read those two stored values and log them. Finally reply with the marker and total. Do not call any phone.* method.",
          model: SubscriptionClient(modelConfiguration: config), executor: executor,
          tools: PhoneTools.definitions.filter { $0["name"].string == "phone_exec_js" })
        let final = try await loop.run(
          maxTurns: 5,
          onEvent: { event in
            if case .toolStarted = event { toolCalls += 1 }
          })
        guard final.contains(marker), final.contains("42"), toolCalls >= 2 else {
          throw AgentLoopError.protocolError("Model did not complete the two-call persistence test")
        }
        let checkCode =
          "if(state.marker !== '\(marker)' || state.total !== 42) throw new Error('State mismatch'); log('state_verified');"
        let checked = try await executor.execute(
          .init(
            id: "verify-state", name: "phone_exec_js",
            arguments: try JSONValue.object(["code": .string(checkCode)]).text()))
        guard
          checked.content.contains(where: { $0["text"].string == "Script log: state_verified" }),
          noPhone.attemptedPhoneCalls == 0
        else {
          throw AgentLoopError.protocolError("Interpreter state verification failed")
        }
        report["status"] = "passed"
        report["requested_model"] = config.choice.id
        report["requested_effort"] = config.choice.effort ?? "unspecified"
        report["model_turns"] = loop.turns
        report["script_calls"] = toolCalls
        report["persistent_state_verified"] = true
      } catch {
        report["status"] = "failed"
        report["error"] = error.localizedDescription
      }
      report["attempted_phone_calls"] = noPhone.attemptedPhoneCalls
      ProbeModel.shared.log(report)
      if let data = try? JSONSerialization.data(
        withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
      {
        try? data.write(
          to: directory.appendingPathComponent("script-model-check.json"), options: .atomic)
      }
    }
  }
#endif
