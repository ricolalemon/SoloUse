#if DEBUG
  import UIKit

  @MainActor enum TransportBenchmark {
    static func run() async {
      guard !PhoneAgentModel.shared.busy, PhoneAgentModel.shared.pendingHandoff == nil,
        !ProbeModel.shared.busy, !SubscriptionModel.shared.busy
      else { return }
      SubscriptionModel.shared.busy = true
      let idle = UIApplication.shared.isIdleTimerDisabled
      UIApplication.shared.isIdleTimerDisabled = true
      defer {
        SubscriptionModel.shared.busy = false
        UIApplication.shared.isIdleTimerDisabled = idle
      }
      var report: [String: Any] = ["kind": "transport_benchmark", "phone_commands": 0]
      do {
        let catalog = try await SubscriptionClient().models()
        let config = try ModelCatalog.resolve(ModelSelection.shared.choice, in: catalog)
        report["model"] = config.choice.id
        report["effort"] = config.choice.effort ?? "unspecified"
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let png = UIGraphicsImageRenderer(size: CGSize(width: 500, height: 250), format: format)
          .image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 500, height: 250))
            ("SPEED 73" as NSString).draw(
              at: CGPoint(x: 60, y: 95),
              withAttributes: [
                .font: UIFont.systemFont(ofSize: 45, weight: .bold),
                .foregroundColor: UIColor.black,
              ])
          }.pngData()!
        let tool = try JSONValue([
          "type": "function", "name": "fixture_report",
          "description": "Report the round number and exact text from the fixture image.",
          "strict": true,
          "parameters": [
            "type": "object",
            "properties": ["round": ["type": "integer"], "text": ["type": "string"]],
            "required": ["round", "text"], "additionalProperties": false,
          ],
        ])
        var trials: [[String: Any]] = []
        let reverse = ProcessInfo.processInfo.arguments.contains("--benchmark-ws-first")
        let order: [(String, ModelTransportPreference)] =
          reverse
          ? [("websocket", .webSocketOnly), ("http_sse", .httpOnly)]
          : [("http_sse", .httpOnly), ("websocket", .webSocketOnly)]
        report["order"] = order.map { $0.0 }
        for (name, preference) in order {
          let client = SubscriptionClient(modelConfiguration: config, transport: preference)
          var trial: [String: Any] = ["transport": name]
          var input: [JSONValue] = [
            .object([
              "role": .string("user"),
              "content": .array([
                .textContent(
                  "This is a controlled transport test. Do not operate any phone or app. For each round call fixture_report exactly once with the requested round number and the exact text from this image. Round 1."
                ),
                .object([
                  "type": .string("input_image"),
                  "image_url": .string("data:image/png;base64," + png.base64EncodedString()),
                  "detail": .string("original"),
                ]),
              ]),
            ])
          ]
          do {
            for round in 1...3 {
              let response = try await client.respond(
                input: input, tools: [tool], onMessage: { _ in })
              guard response.calls.count == 1, let call = response.calls.first,
                call.name == "fixture_report", let data = call.arguments.data(using: .utf8),
                let args = try? JSONDecoder().decode(JSONValue.self, from: data),
                args["round"].number == Double(round), args["text"].string == "SPEED 73"
              else {
                throw AgentLoopError.protocolError("Fixture output mismatch")
              }
              input += response.output
              input.append(
                .object([
                  "type": .string("function_call_output"), "call_id": .string(call.id),
                  "output": .string("Accepted."),
                ]))
              input.append(
                .object([
                  "role": .string("user"),
                  "content": .array([
                    .textContent(
                      "Round \(round+1). Use the same fixture image and call fixture_report once.")
                  ]),
                ]))
            }
            trial["status"] = "passed"
          } catch {
            trial["status"] = "failed"
            trial["error"] = error.localizedDescription
          }
          trial["requests"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(client.metrics))
          trials.append(trial)
        }
        report["trials"] = trials
        report["status"] =
          trials.allSatisfy { $0["status"] as? String == "passed" } ? "passed" : "needs_review"
        report["comparison_limit"] =
          "One sequential fixture per transport; validates protocol and payload reduction, not a general speedup estimate."
      } catch {
        report["status"] = "failed"
        report["error"] = error.localizedDescription
      }
      ProbeModel.shared.log([
        "kind": "transport_benchmark_finished", "status": report["status"] ?? "failed",
      ])
      if let data = try? JSONSerialization.data(
        withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
      {
        try? data.write(
          to: directory.appendingPathComponent(
            ProcessInfo.processInfo.arguments.contains("--benchmark-ws-first")
              ? "transport-benchmark-reverse.json" : "transport-benchmark.json"), options: .atomic)
      }
    }
  }
#endif
