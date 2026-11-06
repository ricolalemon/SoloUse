#if DEBUG
  import Foundation
  import UIKit

  // Real on-phone screenshots, no UI mutations, no inference and no saved task replay.
  @MainActor enum ScriptOutputSelfTest {
    static func run() async {
      for _ in 0..<30 {
        if UIApplication.shared.applicationState == .active { break }
        try? await Task.sleep(for: .milliseconds(100))
      }
      guard UIApplication.shared.applicationState == .active,
        !PhoneAgentModel.shared.busy, PhoneAgentModel.shared.pendingHandoff == nil,
        !ProbeModel.shared.busy, !SubscriptionModel.shared.busy,
        !PhonePreparationModel.shared.busy else { return }
      SubscriptionModel.shared.busy = true
      defer { SubscriptionModel.shared.busy = false }
      let driver = NativePhoneDriver.shared
      TaskDiagnostics.shared.begin(id: UUID(), kind: "script_output_check")
      var report: [String: Any] = [
        "kind": "script_output_check", "model_calls": 0, "phone_mutations": 0,
        "generated_at": ISO8601DateFormatter().string(from: Date()),
      ]
      var observations = 0
      do {
        ProbeModel.shared.presentAgentStatus(.connecting, detail: "检查截图输出与脚本状态", turns: 0, calls: 0)
        try await driver.start(readOnly: true)
        let dispatcher = PhoneToolDispatcher(driver: driver, onEvent: { event in
          TaskDiagnostics.shared.event(event)
          if case .actionFinished(_, let name, let status, _) = event, name == "observe", status == "executed" {
            observations += 1
          }
        }) { _ in "No user question in this test" }
        let executor = ScriptExecutor(phone: dispatcher, allowsActions: { true }, controlVersion: { 0 })
        func run(_ id: String, _ code: String) async throws -> AgentToolResult {
          let result = try await executor.execute(.init(id: id, name: "phone_exec_js",
            arguments: try JSONValue.object(["code": .string(code)]).text()))
          guard !result.needsAttention else { throw AgentLoopError.protocolError("Unexpected uncertain effect") }
          for item in result.content {
            guard let text = item["text"].string, let data = text.data(using: .utf8),
              let receipt = try? JSONDecoder().decode(JSONValue.self, from: data) else { continue }
            if let status = receipt["status"].string, status != "executed" {
              throw AgentLoopError.protocolError(receipt["error"]["message"].string ?? "Script failed")
            }
          }
          return result
        }
        let first = try await run("twelve-frames", "state.frames=0; for(let i=0;i<12;i++){state.frame=await phone.observe();state.frames++;}")
        guard observations == 12 else { throw AgentLoopError.protocolError("Twelve captures did not complete") }
        let verified = try await run("preserved-state", "if(state.frames!==12) throw new Error('Lost state'); log('twelve_frames_preserved');")
        guard verified.content.contains(where: { $0["text"].string == "Script log: twelve_frames_preserved" }) else {
          throw AgentLoopError.protocolError("Persistence check failed")
        }
        let selected = try await run("selected-frames", "for(let i=0;i<3;i++) await phone.observe({emit:false}); await phone.observe();")
        let selectedCount = selected.content.filter { $0["type"].string == "input_image" }.count
        guard selectedCount == 1, observations == 16 else { throw AgentLoopError.protocolError("Selective output check failed") }
        let verbose = try await run("verbose", "log('🙂'.repeat(20000)); state.afterLogs=true;")
        let after = try await run("after-logs", "if(state.afterLogs!==true||state.frames!==12) throw new Error('Lost state after logs'); log('log_state_preserved');")
        guard after.content.contains(where: { $0["text"].string == "Script log: log_state_preserved" }) else {
          throw AgentLoopError.protocolError("Log preservation check failed")
        }
        report["status"] = "passed"
        report["first_script_observations"] = 12
        report["first_script_images_returned"] = first.content.filter { $0["type"].string == "input_image" }.count
        report["selective_images_returned"] = selectedCount
        report["persistent_state_verified"] = true
        report["logs_trimmed_without_reset"] = ScriptToolPresentation.detail(verbose) != nil
        ProbeModel.shared.presentAgentStatus(.completed, detail: "脚本检查通过", turns: 0, calls: observations)
      } catch {
        report["status"] = "failed"; report["error"] = error.localizedDescription
      }
      await driver.close(reason: "script_output_check_finished")
      report["observations"] = observations
      report["driver_closed"] = driver.sessionID == nil
      TaskDiagnostics.shared.finish(report["status"] as? String ?? "finished")
      ProbeModel.shared.log(report)
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? data.write(to: directory.appendingPathComponent("script-output-check.json"), options: .atomic)
      }
    }
  }
#endif
