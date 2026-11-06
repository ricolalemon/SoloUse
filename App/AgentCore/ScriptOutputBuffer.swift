import Foundation

// Output pressure never interrupts phone execution. Keep the newest images,
// bound verbose text, and retain every action's status even when values are large.
struct ScriptOutputBuffer {
  struct Limits {
    var imageBytes = 4 * 1024 * 1024
    var textBytes = 256 * 1024
  }
  private struct Part {
    var item: JSONValue
    var imageBytes: Int = 0
    var frameID: String?
  }
  private let limits: Limits
  private var parts: [Part] = []
  private var retainedImageBytes = 0
  private var retainedTextBytes = 0
  private(set) var omittedImages = 0
  private(set) var suppressedImages = 0
  private(set) var trimmedText = 0
  private(set) var omittedLogs = 0
  init(limits: Limits = .init()) { self.limits = limits }

  mutating func append(_ items: [JSONValue], emitImages: Bool = true) {
    var frameID: String?
    for item in items {
      if item["type"].string == "input_image" {
        guard emitImages else { suppressedImages += 1; continue }
        let bytes = item["image_url"].string?.utf8.count ?? 0
        parts.append(.init(item: item, imageBytes: bytes, frameID: frameID))
        retainedImageBytes += bytes
        while retainedImageBytes > limits.imageBytes,
          let index = parts.firstIndex(where: { $0.imageBytes > 0 }) {
          retainedImageBytes -= parts[index].imageBytes
          let frame = parts[index].frameID.map { " (frame_id=\($0))" } ?? ""
          parts[index] = .init(item: .textContent("Screenshot\(frame) omitted from output; its action receipt remains valid."))
          omittedImages += 1
        }
      } else if let text = item["text"].string {
        let receipt = text.data(using: .utf8).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        frameID = receipt?["value"]["frame_id"].string ?? frameID
        if retainedTextBytes + text.utf8.count <= limits.textBytes {
          parts.append(.init(item: item)); retainedTextBytes += text.utf8.count
        } else if let receipt, receipt["status"].string != nil {
          // Receipt summaries are a small reserved allowance beyond verbose text.
          // At most 64 script operations plus one final observation can reach here.
          parts.append(.init(item: .textContent((try? Self.compact(receipt).text()) ?? "Action receipt could not be encoded.")))
          trimmedText += 1
        } else {
          trimmedText += 1
        }
      }
    }
  }
  mutating func recordOmittedLogs(_ count: Int) { omittedLogs += max(0, count) }
  mutating func recordSuppressedImage() { suppressedImages += 1 }
  var content: [JSONValue] { parts.map(\.item) }
  var summary: JSONValue {
    .object([
      "images_retained": .number(Double(parts.filter { $0.imageBytes > 0 }.count)),
      "images_omitted": .number(Double(omittedImages)),
      "images_suppressed": .number(Double(suppressedImages)),
      "text_items_trimmed": .number(Double(trimmedText)),
      "logs_omitted": .number(Double(omittedLogs)),
    ])
  }
  private static func compact(_ receipt: JSONValue) -> JSONValue {
    var value: [String: JSONValue] = ["output_details_omitted": .bool(true)]
    for key in ["frame_id", "width", "height", "source_width", "source_height", "coordinate_unit", "clipboard_restored", "clipboard_pending", "paste_id", "pending_paste_id", "newer_clipboard_preserved"] {
      let field = receipt["value"][key]
      if let text = field.string { value[key] = .string(String(text.prefix(200))) }
      else if field.number != nil || field.bool != nil { value[key] = field }
    }
    let error: JSONValue = receipt["error"] == .null ? .null : .object([
      "code": .string(String((receipt["error"]["code"].string ?? "unknown").prefix(100))),
      "message": .string(String((receipt["error"]["message"].string ?? "").prefix(300))),
    ])
    if let state = receipt["value"]["clipboard_preparation"]["state"].string {
      value["clipboard_preparation"] = .object(["state": .string(String(state.prefix(40)))])
    }
    return .object([
      "status": receipt["status"], "error": error, "value": .object(value),
      "output_note": .string("Large receipt details omitted from model output; the script received the full receipt. Completed actions must not be repeated."),
    ])
  }
}

enum ScriptToolPresentation {
  static func detail(_ result: AgentToolResult) -> String? {
    let values = result.content.compactMap { item -> JSONValue? in
      guard let text = item["text"].string, let data = text.data(using: .utf8) else { return nil }
      return try? JSONDecoder().decode(JSONValue.self, from: data)
    }
    if let error = values.last(where: { $0["error"]["code"].string?.hasPrefix("script_") == true }) {
      switch error["error"]["code"].string {
      case "script_timeout": return "这段脚本执行超时，变量已清空；已完成的手机操作保留。"
      case "script_cpu_limit": return "这段脚本计算时间过长，已停止并清空变量；已完成的手机操作保留。"
      default: return "这段脚本已停止，变量已清空；已完成的手机操作保留，模型可根据记录继续。"
      }
    }
    guard !values.contains(where: { $0["status"].string != nil && $0["status"].string != "executed" }) else { return nil }
    guard let marker = values.last(where: { $0["script_status"].string != nil }) else { return nil }
    if marker["script_status"].string == "segment_complete" {
      return "本段操作已完成，变量已保留，等待模型继续。"
    }
    let output = marker["output"]
    if (output["images_omitted"].number ?? 0) + (output["text_items_trimmed"].number ?? 0)
      + (output["logs_omitted"].number ?? 0) > 0 {
      return "脚本已完成；较早的截图或过长的输出已省略，变量已保留。"
    }
    return nil
  }
}
