#if DEBUG
import Foundation

@MainActor enum TreeToolSelfTest {
  static func run() async {
    guard !PhoneAgentModel.shared.busy, PhoneAgentModel.shared.pendingHandoff == nil,
      !ProbeModel.shared.busy else { return }
    let driver = NativePhoneDriver.shared
    var report: [String: Any] = ["kind": "tree_tool_check", "model_calls": 0]
    TaskDiagnostics.shared.begin(id: UUID(), kind: "tree_tool_check")
    do {
      try await driver.start(readOnly: false)
      // Explicit native diagnostic only; tree is not an agent/JS capability.
      var index = 0
      func call(_ name: String, _ args: [String: JSONValue] = [:]) async throws -> JSONValue {
        index += 1
        var action = args
        action["op"] = .string(name)
        let result = try await driver.perform(action: .object(action), id: "treecheck_\(index)")
        guard result.status == "executed" else {
          throw AgentLoopError.protocolError(result.error["message"].string ?? "Fixture operation failed")
        }
        if name == "read_tree", !result.content.contains(where: { $0["type"].string == "input_image" }) {
          throw AgentLoopError.protocolError("Tree tool did not emit its screenshot")
        }
        return result.value
      }
      func field(_ frame: JSONValue) throws -> JSONValue {
        func find(_ node: JSONValue) -> JSONValue? {
          if node["identifier"].string == "solouse.lab.input" { return node }
          for child in node["children"].array ?? [] { if let match = find(child) { return match } }
          return nil
        }
        for app in frame["accessibility"]["applications"].array ?? [] where app["app_id"].string == RuntimeIdentifiers.lab {
          if let node = find(app["root"]) { return node }
        }
        throw AgentLoopError.protocolError("Lab input field missing from real tree")
      }
      _ = try await call("open_app", ["app_id": .string(RuntimeIdentifiers.lab)])
      let before = try await call("read_tree")
      let rect = try field(before)["pixel_rect"]
      guard let x = rect["x"].number, let y = rect["y"].number,
        let w = rect["width"].number, let h = rect["height"].number else {
        throw AgentLoopError.protocolError("Lab field has no mapped image rectangle")
      }
      guard let imageWidth = before["width"].number, let imageHeight = before["height"].number,
        imageWidth > 1, imageHeight > 1 else { throw AgentLoopError.protocolError("Fixture frame dimensions missing") }
      _ = try await call("tap", ["x": .number((x + w / 2) / (imageWidth - 1)),
        "y": .number((y + h / 2) / (imageHeight - 1)), "frame_id": before["frame_id"]])
      _ = try await call("press_key", ["key": .string("cmd+a")])
      _ = try await call("press_key", ["key": .string("Backspace")])
      _ = try await call("type_text", ["text": .string("tree731")])
      let after = try await call("read_tree")
      let value = try field(after)["value"].string
      guard value == "tree731" else { throw AgentLoopError.protocolError("Tree did not verify typed fixture value") }
      report["status"] = "passed"
      report["verified_value"] = value
      report["node_count"] = after["accessibility"]["node_count"].number
      report["image_width"] = before["width"].number
      report["image_height"] = before["height"].number
      report["phone_calls"] = index
      _ = try await call("open_app", ["app_id": .string(RuntimeIdentifiers.app)])
    } catch {
      report["status"] = "failed"
      report["error"] = error.localizedDescription
    }
    await driver.close(reason: "tree_tool_check_complete")
    TaskDiagnostics.shared.finish(report["status"] as? String ?? "failed")
    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("tree-tool-check.json")
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: url, options: .atomic)
    }
  }
}
#endif
