#if DEBUG
import UIKit

// Explicit developer-only, local file console. No listener or network service.
// Commands require the current random nonce and execute through production tools.
@MainActor enum InputProbeConsole {
  static func run() async {
    for _ in 0..<30 {
      if UIApplication.shared.applicationState == .active { break }
      try? await Task.sleep(for: .milliseconds(100))
    }
    guard UIApplication.shared.applicationState == .active else { return }
    guard !PhoneAgentModel.shared.busy, PhoneAgentModel.shared.pendingHandoff == nil,
      !ProbeModel.shared.busy, !SubscriptionModel.shared.busy else { return }
    SubscriptionModel.shared.busy = true
    defer { SubscriptionModel.shared.busy = false }
    let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let nonce = UUID().uuidString
    let driver = NativePhoneDriver.shared
    var failure: String?
    TaskDiagnostics.shared.begin(id: UUID(), kind: "input_probe_console")
    func save(_ object: [String: Any], name: String) {
      if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: folder.appendingPathComponent(name), options: .atomic)
      }
    }
    do {
      try await driver.start(readOnly: false)
      let phone = PhoneToolDispatcher(driver: driver, onEvent: { TaskDiagnostics.shared.event($0) }) { _ in
        throw AgentLoopError.protocolError("Questions unavailable in a developer probe")
      }
      let script = ScriptExecutor(phone: phone, allowsActions: { driver.sessionID != nil }, controlVersion: { 0 })
      save(["status": "ready", "session": nonce], name: "input-probe-status.json")
      var seen = Set<String>()
      var deadline = Date().addingTimeInterval(180)
      while driver.sessionID != nil, Date() < deadline {
        try await Task.sleep(for: .milliseconds(150))
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("input-probe-command.json")), data.count < 100_000,
          let command = try? JSONDecoder().decode(JSONValue.self, from: data),
          command["session"].string == nonce, let id = command["id"].string,
          UUID(uuidString: id) != nil, seen.insert(id).inserted else { continue }
        if command["finish"].bool == true { break }
        if command["native_action"]["op"].string == "clipboard_representation_test" {
          let board = UIPasteboard.withUniqueName()
          defer { UIPasteboard.remove(withName: board.name) }
          let expected = "Synthetic 中文🙂"
          board.items = [["public.utf8-plain-text": expected, "public.text": expected,
            "public.html": "<b>Synthetic 中文🙂</b>"]]
          let before = board.hasStrings
          let utf8 = board.data(forPasteboardType: "public.utf8-plain-text")
          var encoded: [String: Any] = [:]
          for type in board.types { encoded[type] = board.data(forPasteboardType: type) }
          board.items = [encoded]
          let value = JSONValue.object(["has_strings_before": .bool(before),
            "has_strings_after": .bool(board.hasStrings), "text_preserved": .bool(board.string == expected),
            "utf8_data_matches": .bool(utf8 == Data(expected.utf8))])
          let receipt = JSONValue.object(["status": .string("executed"), "value": value, "error": .null])
          save(["status": "completed", "session": nonce, "id": id, "images": 0,
            "needs_attention": false, "content": try JSONValue.array([.textContent(try receipt.text())]).foundation()],
            name: "input-probe-result.json")
          continue
        }
        if command["native_action"]["op"].string == "clipboard_localize" {
          deadline = Date().addingTimeInterval(180)
          try await driver.prepareClipboardIfNeeded()
          let value = JSONValue.object(["clipboard_preparation": driver.clipboardPreparationState ?? .null])
          let receipt = JSONValue.object(["status": .string("executed"), "value": value, "error": .null])
          save(["status": "completed", "session": nonce, "id": id, "images": 0,
            "needs_attention": false, "content": try JSONValue.array([.textContent(try receipt.text())]).foundation()],
            name: "input-probe-result.json")
          continue
        }
        if command["native_action"]["op"].string == "clipboard_api_probe" {
          deadline = Date().addingTimeInterval(180)
          let appState = UIApplication.shared.applicationState.rawValue
          save(["status": "reading", "session": nonce, "id": id, "app_state": appState], name: "input-probe-result.json")
          let summary: JSONValue = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
              let board = UIPasteboard.general
              let count = board.numberOfItems
              let before = board.changeCount
              let items = board.items
              do {
                continuation.resume(returning: try JSONValue(["policy": "uikit_read", "items": items.count,
                  "announced_items": count, "before_change_count": before,
                  "change_count": board.changeCount, "app_state": appState,
                  "formats": items.map { Array($0.keys).sorted() },
                  "value_types": items.map { $0.mapValues { String(describing: type(of: $0)) } }]))
              } catch { continuation.resume(throwing: error) }
            }
          }
          let receipt = JSONValue.object(["status": .string("executed"), "value": summary, "error": .null])
          save(["status": "completed", "session": nonce, "id": id, "images": 0,
            "needs_attention": false, "content": try JSONValue.array([.textContent(try receipt.text())]).foundation()],
            name: "input-probe-result.json")
          continue
        }
        if ["clipboard_probe", "clipboard_status"].contains(command["native_action"]["op"].string ?? "") {
          deadline = Date().addingTimeInterval(180)
          let reply = try await driver.perform(action: command["native_action"], id: id)
          save(["status": "completed", "session": nonce, "id": id, "images": 0,
            "needs_attention": false, "content": try JSONValue.array(reply.content).foundation()],
            name: "input-probe-result.json")
          continue
        }
        if let task = command["agent_task"].string {
          deadline = Date().addingTimeInterval(240)
          let report = await WeChatTreeBenchmark.run(task: task, tree: command["tree"].bool ?? true,
            id: id, driver: driver, progress: { progress in
              save(progress, name: "wechat-benchmark-progress.json")
            })
          save(report, name: "wechat-benchmark-\(id).json")
          save(["status": "completed", "id": id, "session": nonce, "report": "wechat-benchmark-\(id).json"], name: "input-probe-result.json")
          deadline = Date().addingTimeInterval(180)
          continue
        }
        guard let code = command["code"].string else { continue }
        deadline = Date().addingTimeInterval(180)
        let result = try await script.execute(.init(id: id, name: "phone_exec_js",
          arguments: try JSONValue.object(["code": .string(code)]).text()))
        var items: [JSONValue] = []
        var imageCount = 0
        for item in result.content {
          if item["type"].string == "input_image", let url = item["image_url"].string,
            let encoded = url.split(separator: ",", maxSplits: 1).last,
            let jpeg = Data(base64Encoded: String(encoded)) {
            imageCount += 1
            try jpeg.write(to: folder.appendingPathComponent("input-probe-latest.jpg"), options: .atomic)
          } else { items.append(item) }
        }
        save(["status": "completed", "session": nonce, "id": id, "images": imageCount,
          "needs_attention": result.needsAttention, "content": try JSONValue.array(items).foundation()],
          name: "input-probe-result.json")
        if result.needsAttention { break }
      }
    } catch {
      failure = error.localizedDescription
      save(["status": "failed", "error": error.localizedDescription, "session": nonce], name: "input-probe-status.json")
    }
    await driver.close(reason: "input_probe_finished")
    TaskDiagnostics.shared.finish("input_probe_finished")
    var closed: [String: Any] = ["status": "closed", "session": nonce]
    closed["error"] = failure
    save(closed, name: "input-probe-status.json")
  }
}
#endif
