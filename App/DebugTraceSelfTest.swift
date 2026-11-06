#if DEBUG
  import CryptoKit
  import UIKit

  @MainActor enum DebugTraceSelfTest {
    static func run() async {
      guard !PhoneAgentModel.shared.busy, !ProbeModel.shared.busy else { return }
      let diagnostics = TaskDiagnostics.shared
      let id = UUID()
      let frameID = UUID().uuidString
      diagnostics.begin(
        id: id, kind: "debug_self_test", prompt: "synthetic diagnostic fixture",
        options: DebugOptions(screenshots: true, visibleText: false))
      diagnostics.bindSession(UUID().uuidString)
      diagnostics.event(.modelStarted(1))
      let call = AgentToolCall(
        id: "fixture-call", name: "phone_type_text",
        arguments: "{\"text\":\"fixture-private-input\"}")
      diagnostics.event(.toolStarted(call))
      diagnostics.event(.actionStarted(id: "fixture-call_0", parent: call.id, name: "type_text"))
      diagnostics.bindCommand(
        id: "fixture-native", actionID: "fixture-call_0",
        action: .object(["op": .string("type_text"), "text": .string("fixture-private-input")]))
      let format = UIGraphicsImageRendererFormat()
      format.scale = 1
      format.opaque = true
      let image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 300), format: format)
        .image { context in
          UIColor.systemIndigo.setFill()
          context.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
          ("DEBUG FIXTURE" as NSString).draw(
            at: CGPoint(x: 16, y: 120),
            withAttributes: [
              .font: UIFont.systemFont(ofSize: 18, weight: .bold), .foregroundColor: UIColor.white,
            ])
        }
      if let data = image.jpegData(compressionQuality: 0.85) {
        diagnostics.frame(
          id: frameID, data: data,
          metadata: .object([
            "width": .number(200), "height": .number(300),
            "synthetic": .bool(true),
            "jpeg_sha256": .string(
              SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()),
          ]))
      }
      diagnostics.record(
        "control_requested",
        ["source": .string("synthetic_foreground_event"), "control": .string("pause")])
      diagnostics.native([
        "kind": "command_failed", "id": "fixture-native", "operation": "type_text",
        "stage": "keyboard_key_down", "cancel_requested": true, "input_started": true,
        "input_reports_sent": 1,
        "raw_error": "fixture_cancelled; Bearer fixture-secret-auth", "cleanup_error": "",
        "code": "driver_error", "mutating": true,
      ])
      diagnostics.finish("self_test")
      do {
        let file = try await diagnostics.export(id)
        ProbeModel.shared.log([
          "kind": "debug_self_test_passed", "run_id": id.uuidString,
          "export_relative_path": "Library/Caches/DebugExports/" + file.lastPathComponent,
          "phone_commands": 0, "model_calls": 0,
        ])
      } catch {
        ProbeModel.shared.log([
          "kind": "debug_self_test_failed", "message": error.localizedDescription,
        ])
      }
    }
  }
#endif
