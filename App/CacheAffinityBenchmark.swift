#if DEBUG
import UIKit

@MainActor enum CacheAffinityBenchmark {
  static func run() async {
    guard !PhoneAgentModel.shared.busy, PhoneAgentModel.shared.pendingHandoff == nil,
      !ProbeModel.shared.busy, !SubscriptionModel.shared.busy else { return }
    SubscriptionModel.shared.busy = true
    let idle = UIApplication.shared.isIdleTimerDisabled
    UIApplication.shared.isIdleTimerDisabled = true
    defer { SubscriptionModel.shared.busy = false; UIApplication.shared.isIdleTimerDisabled = idle }
    var report: [String: Any] = ["kind": "cache_affinity_benchmark", "phone_commands": 0,
      "generated_at": ISO8601DateFormatter().string(from: Date())]
    do {
      let catalog = try await SubscriptionClient().models()
      let config = try ModelCatalog.resolve(ModelSelection.shared.choice, in: catalog)
      report["model"] = config.choice.id
      report["effort"] = config.choice.effort ?? "unspecified"
      report["fast_requested"] = config.choice.fastMode
      let fixture = (0..<160).map { "Fixture row \($0): red=\(($0*17)%997), green=\(($0*31)%991), blue=\(($0*43)%983)." }.joined(separator: "\n")
      var trials: [[String: Any]] = []
      for legacy in [true, false] {
        let client = SubscriptionClient(modelConfiguration: config)
        client.omitSessionRoutingForBenchmark = legacy
        var trial: [String: Any] = ["mode": legacy ? "legacy_cache_key_only" : "session_affinity"]
        var input: [JSONValue] = [.object(["role": .string("user"), "content": .array([
          .textContent("This is a read-only model transport fixture. No phone actions or tools are available. Retain this fixed data; do not summarize it. For each request respond with exactly CACHE_OK.\n" + fixture)
        ])])]
        do {
          for round in 1...3 {
            let response = try await client.respond(input: input, tools: [], onMessage: { _ in })
            guard response.calls.isEmpty, response.finalText.trimmingCharacters(in: .whitespacesAndNewlines) == "CACHE_OK" else {
              throw AgentLoopError.protocolError("Cache fixture response mismatch")
            }
            input += response.output
            input.append(.object(["role": .string("user"), "content": .array([.textContent("Round \(round+1). Reply CACHE_OK.")])]))
          }
          trial["status"] = "passed"
        } catch { trial["status"] = "failed"; trial["error"] = error.localizedDescription }
        trial["requests"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(client.metrics))
        trials.append(trial)
      }
      report["trials"] = trials
      report["status"] = trials.allSatisfy { $0["status"] as? String == "passed" } ? "passed" : "needs_review"
      report["limitation"] = "Six sequential text-fixture requests. Checks cache receipts and compatibility, not a general task-speed estimate."
    } catch { report["status"] = "failed"; report["error"] = error.localizedDescription }
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
      let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      try? data.write(to: documents.appendingPathComponent("cache-affinity-benchmark.json"), options: .atomic)
    }
  }
}
#endif
