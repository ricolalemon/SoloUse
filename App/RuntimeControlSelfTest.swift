#if DEBUG
  import Foundation

  // Explicit development test against our independent Lab fixture. No saved
  // business prompt is run, and no real message/order is submitted.
  @MainActor enum RuntimeControlSelfTest {
    static func run() async {
      guard !PhoneAgentModel.shared.busy, PhoneAgentModel.shared.pendingHandoff == nil,
        !ProbeModel.shared.busy, !SubscriptionModel.shared.busy
      else { return }
      SubscriptionModel.shared.busy = true
      defer { SubscriptionModel.shared.busy = false }
      let driver = NativePhoneDriver.shared
      let diagnostics = TaskDiagnostics.shared
      diagnostics.begin(id: UUID(), kind: "runtime_control_self_test")
      var report: [String: Any] = ["kind": "runtime_control_self_test", "model_calls": 0]
      var actions = 0
      do {
        ProbeModel.shared.presentAgentStatus(
          .connecting, detail: "验证脚本和 Unicode 输入", turns: 0, calls: 0)
        try await driver.start(readOnly: false)
        let dispatcher = PhoneToolDispatcher(
          driver: driver,
          onEvent: { event in
            diagnostics.event(event)
            if case .actionFinished = event { actions += 1 }
          }
        ) { _ in "Test does not require user input" }
        let executor = ScriptExecutor(
          phone: dispatcher, allowsActions: { true }, controlVersion: { 0 })
        let scripts = [
          """
          await phone.openApp({app_id:'\(RuntimeIdentifiers.lab)'});
          await phone.wait({milliseconds:700});
          state.frame=await phone.observe();
          await phone.tap({x:state.frame.width/2,y:state.frame.height*0.35,frame_id:state.frame.frame_id});
          await phone.wait({milliseconds:400});
          state.first='中文🙂 MiXeD 73';
          state.paste=await phone.pasteText({text:state.first,replace_all:true});
          await phone.observe();
          log(state.first);
          """,
          """
          if(state.first!=='中文🙂 MiXeD 73') throw new Error('Persistent state was lost');
          await phone.finishPaste({paste_id:state.paste.paste_id});
          state.final='替换成功🚀 Case42';
          state.paste=await phone.pasteText({text:state.final,replace_all:true});
          await phone.observe();
          log(state.final);
          """,
          "await phone.finishPaste({paste_id:state.paste.paste_id});",
        ]
        var restored = 0
        for (index, code) in scripts.enumerated() {
          let result = try await executor.execute(
            .init(
              id: "runtime-check-\(index)", name: "phone_exec_js",
              arguments: try JSONValue.object(["code": .string(code)]).text()))
          guard !result.needsAttention else {
            throw AgentLoopError.needsAttention("Test action had uncertain effects")
          }
          for part in result.content {
            guard let text = part["text"].string, let data = text.data(using: .utf8),
              let receipt = try? JSONDecoder().decode(JSONValue.self, from: data)
            else { continue }
            if let status = receipt["status"].string, status != "executed" {
              throw AgentLoopError.protocolError(
                receipt["error"]["message"].string ?? "Script test failed")
            }
            if receipt["value"]["clipboard_restored"].bool == true { restored += 1 }
          }
        }
        report["status"] = "passed_driver_checks"
        report["persistent_script_state"] = true
        report["clipboard_restores_verified"] = restored
        report["expected_lab_text"] = "替换成功🚀 Case42"
        report["needs_independent_lab_readback"] = true
      } catch {
        report["status"] = "failed"
        report["error"] = error.localizedDescription
      }
      report["phone_actions"] = actions
      let handoff = TaskHandoffLease()
      await driver.close(reason: "runtime_control_self_test_finished")
      diagnostics.finish(report["status"] as? String ?? "failed")
      handoff.end()
      ProbeModel.shared.log(report)
      if let data = try? JSONSerialization.data(
        withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
      {
        try? data.write(
          to: directory.appendingPathComponent("runtime-control-check.json"), options: .atomic)
      }
    }
  }
#endif
