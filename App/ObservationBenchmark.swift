#if DEBUG
  import UIKit

  @MainActor enum ObservationBenchmark {
    static func run() async {
      guard !PhoneAgentModel.shared.busy, PhoneAgentModel.shared.pendingHandoff == nil,
        !ProbeModel.shared.busy, !SubscriptionModel.shared.busy
      else { return }
      SubscriptionModel.shared.busy = true
      defer { SubscriptionModel.shared.busy = false }
      let driver = NativePhoneDriver.shared
      var report: [String: Any] = [
        "kind": "observation_benchmark", "fixture": "SoloUse Lab", "transport": "http_sse",
      ]
      var trials: [[String: Any]] = []
      do {
        let catalog = try await SubscriptionClient().models()
        let config = try ModelCatalog.resolve(ModelSelection.shared.choice, in: catalog)
        report["model"] = config.choice.id
        report["effort"] = config.choice.effort ?? "unspecified"
        TaskDiagnostics.shared.begin(id: UUID(), kind: "observation_benchmark")
        ProbeModel.shared.presentAgentStatus(.connecting, detail: "Lab 观察合并对照", turns: 0, calls: 0)
        try await driver.start(readOnly: false)
        for automatic in [false, true] {
          let name = automatic ? "automatic" : "separate"
          var trial: [String: Any] = ["mode": name]
          TaskDiagnostics.shared.record("benchmark_mode", ["mode": .string(name)])
          do {
            ProbeModel.shared.presentAgentStatus(
              .connecting, detail: "观察合并对照 · " + name, turns: 0, calls: 0)
            let setup = PhoneToolDispatcher(driver: driver, automaticallyObserve: false) { _ in
              "fixture"
            }
            func command(_ suffix: String, _ tool: String, _ args: [String: JSONValue] = [:])
              async throws -> AgentToolResult
            {
              let result = try await setup.execute(
                .init(
                  id: "setup_" + name + suffix, name: tool,
                  arguments: try JSONValue.object(args).text()))
              guard !result.needsAttention else {
                throw AgentLoopError.needsAttention("Fixture setup was uncertain")
              }
              for item in result.content {
                if let text = item["text"].string, let data = text.data(using: .utf8),
                  let value = try? JSONDecoder().decode(JSONValue.self, from: data),
                  let status = value["status"].string, status != "executed"
                {
                  throw AgentLoopError.protocolError(
                    "Fixture setup \(suffix) failed: "
                      + (value["error"]["code"].string ?? "unknown"))
                }
              }
              return result
            }
            _ = try await command("open", "phone_open_app", ["app_id": .string(RuntimeIdentifiers.lab)])
            _ = try await command("wait", "phone_wait", ["milliseconds": .number(600)])
            let observation = try await command("observe", "phone_observe")
            guard let text = observation.content.first?["text"].string,
              let bytes = text.data(using: .utf8)
            else { throw AgentLoopError.protocolError("Fixture frame missing") }
            let frame = try JSONDecoder().decode(JSONValue.self, from: bytes)["value"]
            _ = try await command(
              "focus", "phone_tap",
              [
                "x": .number(frame["width"].number! / 2),
                "y": .number(frame["height"].number! * 0.35), "frame_id": frame["frame_id"],
              ])
            _ = try await command("select", "phone_press_key", ["key": .string("cmd+a")])
            _ = try await command("clear", "phone_press_key", ["key": .string("Backspace")])
            var counts: [String: Int] = [:]
            var lastEdit = 0
            var lastObserve = 0
            var actionSequence = 0
            let executor = PhoneToolDispatcher(
              driver: driver, automaticallyObserve: automatic,
              onEvent: { event in
                TaskDiagnostics.shared.event(event)
                if case .actionFinished(_, let operation, let status, _) = event,
                  status == "executed"
                {
                  actionSequence += 1
                  counts[operation, default: 0] += 1
                  if operation == "type_text" { lastEdit = actionSequence }
                  if operation == "observe" { lastObserve = actionSequence }
                }
              }
            ) { _ in "This fixture needs no user input" }
            let client = SubscriptionClient(modelConfiguration: config, transport: .httpOnly)
            let tools = PhoneTools.definitions.filter {
              ["phone_observe", "phone_tap", "phone_type_text"].contains($0["name"].string ?? "")
            }
            let loop = PhoneAgentLoop(
              task:
                "Controlled Lab test. Only use the already-open SoloUse Lab. Enter exactly speed73 into its already-cleared text field. Use the available hardware typing tool. Do not press Return or leave this app. Tools may or may not attach a new screenshot: inspect an attached image when available, otherwise call phone_observe. Finish only after an image captured after your last edit shows exactly that text, then reply done. No other phone task is requested.",
              model: client, executor: executor, tools: tools)
            ProbeModel.shared.presentAgentStatus(
              .acting, detail: "Lab 观察合并对照 · " + name, turns: 0, calls: 0)
            let started = ProcessInfo.processInfo.systemUptime
            _ = try await loop.run(maxTurns: 10, onEvent: { TaskDiagnostics.shared.event($0) })
            trial["elapsed_ms"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
            trial["model_turns"] = loop.turns
            trial["tool_calls"] = loop.toolCalls
            trial["phone_actions"] = counts
            trial["post_edit_image_returned"] = lastEdit > 0 && lastObserve > lastEdit
            trial["requests"] = try JSONSerialization.jsonObject(
              with: JSONEncoder().encode(client.metrics))
            trial["status"] = "model_completed_needs_image_review"
            _ = try await command("verify", "phone_observe")
            let destination = FileManager.default.urls(
              for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(
                "speed-lab-" + name + ".png")
            try Data(
              contentsOf: ProbeModel.shared.directory.appendingPathComponent("session-frame.png")
            ).write(to: destination, options: .atomic)
          } catch {
            trial["status"] = "failed"
            trial["error"] = error.localizedDescription
          }
          trials.append(trial)
          report["trials"] = trials
          save(report)
          if driver.sessionID == nil { break }
        }
        report["status"] = "finished_needs_independent_review"
        report["limitation"] =
          "One sequential Lab trial per mode, same model/effort and HTTP transport; not a general task speedup guarantee."
      } catch {
        report["status"] = "failed"
        report["error"] = error.localizedDescription
      }
      let lease = TaskHandoffLease()
      ProbeModel.shared.presentAgentStatus(.completed, detail: "Lab 对照结束", turns: 0, calls: 0)
      await driver.close(reason: "observation_benchmark_finished")
      TaskDiagnostics.shared.finish(report["status"] as? String ?? "failed")
      save(report)
      lease.end()
    }
    private static func save(_ report: [String: Any]) {
      if let data = try? JSONSerialization.data(
        withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
      {
        try? data.write(
          to: directory.appendingPathComponent("observation-benchmark.json"), options: .atomic)
      }
    }
  }
#endif
