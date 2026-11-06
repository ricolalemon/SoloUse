#if DEBUG
import Foundation

/// Explicit development-console trials. Never used by normal chats. All timed
/// reasoning and phone control still run in SoloUse; the Mac collects results.
@MainActor enum WeChatTreeBenchmark {
  private static var configuration: ModelRunConfiguration?
  static func run(task: String, tree: Bool, id: String, driver: NativePhoneDriver,
                  progress: @escaping ([String: Any]) -> Void) async -> [String: Any] {
    var report: [String: Any] = ["id": id, "tree_available": tree, "started_at": ISO8601DateFormatter().string(from: Date())]
    // Historical full-tree comparisons require the older experimental build.
    // Never label a screenshot-only model run as a tree-enabled trial.
    guard !tree else {
      report["status"] = "failed"
      report["error"] = "The agent tree tool is disabled in this build. Use a historical experimental build for tree comparisons."
      return report
    }
    do {
      if configuration == nil {
        let models = try await SubscriptionClient().models()
        configuration = try ModelCatalog.resolve(ModelSelection.shared.choice, in: models)
      }
      let config = configuration!
      report["model"] = config.choice.id
      report["effort"] = config.choice.effort ?? "unspecified"
      report["fast_requested"] = config.choice.fastMode
      let measured = TrialDriver(base: driver, tree: tree)
      var started: Double = 0
      var actions: [[String: Any]] = []
      var messages: [[String: Any]] = []
      var toolErrors: [[String: Any]] = []
      func collect(_ event: AgentEvent) {
        TaskDiagnostics.shared.event(event)
        switch event {
        case .actionFinished(_, let name, let status, let detail):
          actions.append(["op": name, "status": status, "detail": detail,
            "at_ms": (ProcessInfo.processInfo.systemUptime - started) * 1000])
        case .message(let message) where message.complete:
          messages.append(["text": message.text, "phase": message.phase ?? "final"])
        case .toolFinished(let call, let result):
          for item in result.content {
            if let text = item["text"].string, let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let status = value["status"].string, status != "executed" {
              toolErrors.append(["tool": call.name, "status": status, "code": value["error"]["code"].string ?? ""])
            }
          }
        default: break
        }
      }
      let dispatcher = PhoneToolDispatcher(driver: measured, onEvent: { event in
        collect(event)
      }) { _ in throw AgentLoopError.protocolError("Trial needs user input; stop instead of guessing") }
      let executor = ScriptExecutor(phone: dispatcher, allowsActions: { driver.sessionID != nil }, controlVersion: { 0 }, onEvent: collect)
      let client = SubscriptionClient(modelConfiguration: config, transport: .httpOnly)
      let tools = PhoneTools.definitions
      report["tree_mentioned_in_instructions"] = (client.benchmarkInstructions ?? PhoneTools.instructions).contains("phone_read_tree")
      let loop = PhoneAgentLoop(task: task, model: client, executor: executor, tools: tools)
      started = ProcessInfo.processInfo.systemUptime
      var result: String?
      let operation = Task { @MainActor in
        try await loop.run(maxTurns: 20, onEvent: { collect($0)
        }, onTurn: { turns, calls in
          progress(["status": "running", "id": id, "tree_available": tree, "turns": turns, "calls": calls,
            "elapsed_ms": (ProcessInfo.processInfo.systemUptime - started) * 1000])
        })
      }
      // Bound this controlled experiment, not user tasks or production defaults.
      let timeout = Task { @MainActor in
        do { try await Task.sleep(for: .seconds(180)) } catch { return }
        operation.cancel()
      }
      do {
        result = try await operation.value
        report["status"] = "model_finished_needs_verification"
      } catch {
        report["status"] = "failed"
        report["error"] = error.localizedDescription
      }
      timeout.cancel()
      report["elapsed_ms"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
      report["turns"] = loop.turns
      report["tool_calls"] = loop.toolCalls
      report["actions"] = actions
      report["driver_calls"] = measured.calls
      report["messages"] = messages
      report["tool_errors"] = toolErrors
      report["result"] = result
      report["requests"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(client.metrics))
      if let jpeg = measured.lastJPEG { try saveJPEG(jpeg, id: id, suffix: "model-final") }
      // Independent post-timing observation, not delivered back to the model.
      if driver.sessionID != nil {
        let check = try await driver.perform(action: .object(["op": .string("read_tree")]), id: id + "_audit")
        report["verification"] = try check.value.foundation()
        if let jpeg = TrialDriver.jpeg(check) { try saveJPEG(jpeg, id: id, suffix: "audit") }
      }
    } catch {
      report["status"] = "failed"
      report["error"] = error.localizedDescription
    }
    return report
  }
  private static func saveJPEG(_ data: Data, id: String, suffix: String) throws {
    let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    try data.write(to: folder.appendingPathComponent("wechat-benchmark-\(id)-\(suffix).jpg"), options: .atomic)
  }

  @MainActor private final class TrialDriver: PhoneDriver {
    let base: NativePhoneDriver
    let tree: Bool
    var calls: [[String: Any]] = []
    var lastJPEG: Data?
    init(base: NativePhoneDriver, tree: Bool) { self.base = base; self.tree = tree }
    func perform(action: JSONValue, id: String) async throws -> PhoneDriverReply {
      try await invoke(action: action, id: id, includeImage: true)
    }
    func observe(id: String, includeImage: Bool) async throws -> PhoneDriverReply {
      try await invoke(action: .object(["op": .string("observe")]), id: id, includeImage: includeImage)
    }
    private func invoke(action: JSONValue, id: String, includeImage: Bool) async throws -> PhoneDriverReply {
      let op = action["op"].string ?? ""
      if op == "read_tree", !tree {
        return .init(status: "not_executed", value: .null,
          error: .object(["code": .string("not_available"), "message": .string("This trial has screenshot observation only.")]))
      }
      let started = ProcessInfo.processInfo.systemUptime
      let reply = op == "observe" ? try await base.observe(id: id, includeImage: includeImage)
        : try await base.perform(action: action, id: id)
      calls.append(["op": op, "status": reply.status,
        "elapsed_ms": (ProcessInfo.processInfo.systemUptime - started) * 1000,
        "error_code": reply.error["code"].string ?? "",
        "tree_status": reply.value["accessibility"]["status"].string ?? ""])
      if let jpeg = Self.jpeg(reply) { lastJPEG = jpeg }
      guard !tree, op == "observe" else { return reply }
      var fields = reply.value.object ?? [:]
      fields.removeValue(forKey: "accessibility_status")
      fields.removeValue(forKey: "accessibility")
      fields["accessibility_available"] = .bool(false)
      return .init(status: reply.status, value: .object(fields), error: reply.error, images: reply.images)
    }
    static func jpeg(_ reply: PhoneDriverReply) -> Data? {
      guard let url = reply.images.last?["image_url"].string,
        let encoded = url.split(separator: ",", maxSplits: 1).last else { return nil }
      return Data(base64Encoded: String(encoded))
    }
  }
}
#endif
