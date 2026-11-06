#if DEBUG
  import Foundation
  import UIKit

  // Short, interleaved inference comparison using only this phone's existing login.
  // No phone driver, historical task, tool execution or saved preference changes.
  @MainActor enum FastModeBenchmark {
    static func run() async {
      guard !PhoneAgentModel.shared.busy, !ProbeModel.shared.busy,
        !SubscriptionModel.shared.busy, !ModelSelection.shared.busy,
        !PhonePreparationModel.shared.busy else { return }
      let account = SubscriptionModel.shared
      let savedChoice = ModelSelection.shared.choice
      account.busy = true
      let oldStatus = account.status
      let oldIdle = UIApplication.shared.isIdleTimerDisabled
      UIApplication.shared.isIdleTimerDisabled = true
      defer {
        account.busy = false; account.status = oldStatus
        UIApplication.shared.isIdleTimerDisabled = oldIdle
      }
      var report: [String: Any] = [
        "kind": "fast_mode_benchmark", "model": "gpt-6.1-sol", "effort": "low",
        "generated_at": ISO8601DateFormatter().string(from: Date()),
        "phone_commands": 0,
      ]
      var runs: [[String: Any]] = []
      TaskDiagnostics.shared.begin(id: UUID(), kind: "fast_mode_benchmark")
      do {
        let models = try await SubscriptionClient().models()
        guard let model = models.first(where: { $0.id == "gpt-6.1-sol" }), model.supportsFastMode else {
          throw SubscriptionFailure.invalid("账号目录未提供 GPT-6.1 Sol Fast")
        }
        for (index, fast) in [false, true, true, false].enumerated() {
          try Task.checkCancellation()
          guard UIApplication.shared.applicationState == .active else { throw CancellationError() }
          account.status = "速度对照 \(index + 1)/4"
          let config = try model.configuration(for: .init(id: model.id, effort: "low", fastMode: fast))
          let client = SubscriptionClient(modelConfiguration: config)
          let started = ProcessInfo.processInfo.systemUptime
          let turn = try await client.respond(input: [.object([
            "role": .string("user"), "content": .array([.textContent(
              "This is a text generation timing test; no phone operation is requested. Output integers 1 through 200 in order, separated by single spaces. No commentary, no code fences, no tools."
            )]),
          ])], tools: [], onMessage: { _ in })
          let expected = (1...200).map(String.init)
          let matched = turn.calls.isEmpty && turn.finalText.split(whereSeparator: { $0.isWhitespace }).map(String.init) == expected
          runs.append([
            "index": index + 1, "fast_requested": fast,
            "requested_tier": config.requestedServiceTier ?? "omitted",
            "receipt_tier": turn.serviceTier ?? "not_returned",
            "actual_model": turn.model, "actual_effort": turn.effort ?? "not_returned",
            "expected_output_matched": matched,
            "elapsed_ms": (ProcessInfo.processInfo.systemUptime - started) * 1000,
            "metrics": try JSONSerialization.jsonObject(with: JSONEncoder().encode(client.metrics)),
          ])
          guard matched else { throw SubscriptionFailure.invalid("测试输出格式不匹配，停止后续对照") }
        }
        report["status"] = "passed"
      } catch {
        report["status"] = Task.isCancelled ? "cancelled" : "failed"
        report["error"] = error.localizedDescription
      }
      report["runs"] = runs
      report["completed_requests"] = runs.count
      report["saved_choice_unchanged"] = ModelSelection.shared.choice == savedChoice
      TaskDiagnostics.shared.finish(report["status"] as? String ?? "finished")
      ProbeModel.shared.log(report)
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
          .appendingPathComponent("fast-mode-benchmark.json")
        try? data.write(to: url, options: .atomic)
      }
    }
  }
#endif
