#if DEBUG
  import UIKit

  // Explicit development launch only. No phone driver or saved business task is executed.
  @MainActor enum ModelSelectionSelfTest {
    static func capturePicker() {
      guard
        let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
          .flatMap({ $0.windows }).first(where: { $0.isKeyWindow }),
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
      else { return }
      let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      }
      try? image.pngData()?.write(
        to: directory.appendingPathComponent("model-picker.png"), options: .atomic)
    }
    static func run(vision: Bool) async {
      guard !PhoneAgentModel.shared.busy, !ProbeModel.shared.busy,
        !SubscriptionModel.shared.busy, !ModelSelection.shared.busy
      else { return }
      SubscriptionModel.shared.busy = true
      let previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
      UIApplication.shared.isIdleTimerDisabled = true
      defer {
        SubscriptionModel.shared.busy = false
        UIApplication.shared.isIdleTimerDisabled = previousIdleTimer
      }
      var report: [String: Any] = [
        "kind": "model_selection_check", "phone_commands": 0,
        "generated_at": ISO8601DateFormatter().string(from: Date()),
        "client_version": ModelCatalog.clientVersion,
        "saved_model_before": ModelSelection.shared.choice.id,
      ]
      var modelCalls = 0
      var stage = "catalog"
      do {
        let catalogClient = SubscriptionClient()
        let models = try await catalogClient.models()
        report["catalog_metadata"] = try catalogClient.catalogMetadata.foundation()
        ModelSelection.shared.accept(models)
        if ProcessInfo.processInfo.arguments.contains("--compare-legacy-catalog") {
          let legacy = try await catalogClient.models(clientVersion: "0.155.0")
          report["legacy_model_ids"] = legacy.map(\.id)
          report["legacy_catalog_metadata"] = try catalogClient.catalogMetadata.foundation()
        }
        report["models"] = models.map {
          [
            "id": $0.id, "name": $0.name, "efforts": $0.efforts,
            "supports_original_images": $0.supportsOriginalImages,
            "supports_fast_mode": $0.supportsFastMode,
            "service_tiers": $0.serviceTiers.map {
              ["id": $0.id, "name": $0.name, "description": $0.description]
            },
            "additional_speed_tiers": $0.additionalSpeedTiers,
            "default_service_tier": $0.defaultServiceTier ?? "unspecified",
          ] as [String: Any]
        }
        if vision {
          stage = "vision"
          let requested =
            ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--test-model=") }
            .map { String($0.dropFirst("--test-model=".count)) } ?? "gpt-6-sol"
          guard let model = models.first(where: { $0.id == requested }) else {
            throw SubscriptionFailure.invalid("测试模型未在账号目录中列出")
          }
          let config = try model.configuration(
            for: .init(
              id: model.id, effort: model.efforts.contains("low") ? "low" : model.defaultEffort,
              fastMode: ProcessInfo.processInfo.arguments.contains("--test-fast")))
          report["requested_model"] = config.choice.id
          report["requested_effort"] = config.choice.effort ?? "unspecified"
          report["requested_service_tier"] = config.requestedServiceTier ?? "omitted"
          let client = SubscriptionClient(modelConfiguration: config)
          let format = UIGraphicsImageRendererFormat()
          format.scale = 1
          format.opaque = true
          let expected = "MODEL 842"
          let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 200), format: format)
            .image { context in
              UIColor.white.setFill()
              context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
              (expected as NSString).draw(
                at: CGPoint(x: 50, y: 75),
                withAttributes: [
                  .font: UIFont.systemFont(ofSize: 40, weight: .bold),
                  .foregroundColor: UIColor.black,
                ])
            }
          guard let png = image.pngData() else {
            throw SubscriptionFailure.invalid("测试图片生成失败")
          }
          let tools: [JSONValue] = [
            .object([
              "type": .string("function"), "name": .string("model_probe_report"),
              "description": .string("Report the exact text seen in the synthetic image."),
              "strict": .bool(true),
              "parameters": .object([
                "type": .string("object"), "additionalProperties": .bool(false),
                "properties": .object(["text": .object(["type": .string("string")])]),
                "required": .array([.string("text")]),
              ]),
            ])
          ]
          var input: [JSONValue] = [
            .object([
              "role": .string("user"),
              "content": .array([
                .textContent(
                  "This is an isolated vision/tool protocol test. Read the text in the supplied image and call model_probe_report with that exact text. After receiving the tool result, reply with the same text. No phone operation is requested or available."
                ),
                .object([
                  "type": .string("input_image"),
                  "image_url": .string("data:image/png;base64," + png.base64EncodedString()),
                  "detail": .string("original"),
                ]),
              ]),
            ])
          ]
          modelCalls += 1
          let turn = try await client.respond(input: input, tools: tools, onMessage: { _ in })
          let calls = turn.calls
          guard calls.count == 1, let call = calls.first, call.name == "model_probe_report",
            let data = call.arguments.data(using: .utf8),
            try JSONDecoder().decode(JSONValue.self, from: data)["text"].string == expected
          else { throw SubscriptionFailure.invalid("识图或工具调用验证未通过") }
          report["actual_model"] = turn.model
          report["actual_effort"] = turn.effort ?? "not_returned"
          report["actual_service_tier"] = turn.serviceTier ?? "not_returned"
          report["image_text_matched"] = true
          report["tool_call_verified"] = true
          stage = "tool_result_replay"
          input += turn.output
          input.append(
            .object([
              "type": .string("function_call_output"), "call_id": .string(call.id),
              "output": .string("Accepted. Now reply with the text you read."),
            ]))
          modelCalls += 1
          let final = try await client.respond(input: input, tools: tools, onMessage: { _ in })
          guard final.calls.isEmpty, final.finalText.contains(expected) else {
            throw SubscriptionFailure.invalid("工具结果回传验证未通过")
          }
          report["tool_result_replay_verified"] = true
          report["final_service_tier"] = final.serviceTier ?? "not_returned"
          report["fast_confirmed_both_rounds"] =
            config.choice.fastMode
            && ["priority", "fast"].contains(turn.serviceTier ?? "")
            && ["priority", "fast"].contains(final.serviceTier ?? "")
          report["metrics"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(client.metrics))
        }
        report["status"] = "passed"
      } catch {
        report["status"] = "failed"
        report["error"] = error.localizedDescription
      }
      report["stage"] = stage
      report["model_calls"] = modelCalls
      report["saved_model_after"] = ModelSelection.shared.choice.id
      ProbeModel.shared.log(report)
      if let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
        .appendingPathComponent("model-selection-check.json"),
        let data = try? JSONSerialization.data(
          withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      {
        try? data.write(to: url, options: .atomic)
      }
    }
  }
#endif
