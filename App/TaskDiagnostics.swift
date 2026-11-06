import Combine
import Foundation
import UIKit

struct DiagnosticFrameSink: Sendable {
  let store: DebugTraceStore?
  let context: [String: JSONValue]
  func needsImage() async -> Bool { await store?.needsFrameData() ?? false }
  func save(id: String, data: Data?, metadata: JSONValue) {
    var fields = metadata.object ?? [:]
    context.forEach { fields[$0.key] = $0.value }
    store?.frame(id: id, data: data, metadata: .object(fields))
  }
}

@MainActor final class TaskDiagnostics: ObservableObject {
  static let shared = TaskDiagnostics()
  @Published var saveScreenshots: Bool {
    didSet { UserDefaults.standard.set(saveScreenshots, forKey: "debug.screenshots") }
  }
  @Published var saveVisibleText: Bool {
    didSet { UserDefaults.standard.set(saveVisibleText, forKey: "debug.visibleText") }
  }
  @Published private(set) var storageError = ""
  private var active: DebugTraceStore?
  private var writers: [UUID: DebugTraceStore] = [:]
  private var runID: UUID?
  private var sessionID: String?
  private var toolID: String?
  private var actionID: String?
  private var commandID: String?
  private var turn = 0
  private var phase = ""
  private var lastPhaseDetail = ""
  private var lastStreamSecond = -100
  private var currentOptions = DebugOptions()
  private var root: URL {
    ProbeModel.shared.directory.appendingPathComponent("debug-traces", isDirectory: true)
  }
  init() {
    saveScreenshots = UserDefaults.standard.object(forKey: "debug.screenshots") as? Bool ?? true
    saveVisibleText = UserDefaults.standard.bool(forKey: "debug.visibleText")
  }
  func begin(id: UUID, kind: String, prompt: String? = nil, options: DebugOptions? = nil) {
    active?.finish("superseded")
    runID = id
    sessionID = nil
    toolID = nil
    actionID = nil
    commandID = nil
    turn = 0
    phase = ""
    lastPhaseDetail = ""
    lastStreamSecond = -100
    currentOptions =
      options ?? DebugOptions(screenshots: saveScreenshots, visibleText: saveVisibleText)
    do {
      let store = try DebugTraceStore(
        root: root, runID: id, kind: kind,
        version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
          ?? "dev",
        build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev",
        options: currentOptions)
      active = store
      writers[id] = store
      storageError = ""
      let kept = Set(DebugTraceStore.summaries(root: root).map(\.id))
      writers = writers.filter { kept.contains($0.key) }
      record(
        "task_started",
        [
          "task_kind": .string(kind), "prompt": .string(prompt ?? ""),
          "os_version": .string(UIDevice.current.systemVersion),
        ])
    } catch {
      active = nil
      storageError = "调试记录无法保存：\(error.localizedDescription)"
    }
  }
  func record(_ kind: String, _ fields: [String: JSONValue] = [:]) {
    guard let active else { return }
    var value = fields
    value["turn"] = .number(Double(turn))
    value["phase"] = .string(phase)
    value["app_state"] = .number(Double(UIApplication.shared.applicationState.rawValue))
    if let sessionID, value["session_id"] == nil { value["session_id"] = .string(sessionID) }
    if let toolID { value["tool_call_id"] = .string(toolID) }
    if let actionID { value["action_id"] = .string(actionID) }
    if let commandID { value["native_command_id"] = .string(commandID) }
    active.append(kind, .object(value))
  }
  func event(_ event: AgentEvent) {
    switch event {
    case .modelStarted(let number):
      turn = number
      toolID = nil
      actionID = nil
      commandID = nil
      record("model_turn_started")
    case .message(let message):
      if message.complete {
        record(
          "model_message",
          [
            "message_id": .string(message.id),
            "message_phase": .string(message.phase ?? "unspecified"), "text": .string(message.text),
          ])
      }
    case .toolStarted(let call):
      toolID = call.id
      actionID = nil
      commandID = nil
      record(
        "tool_started",
        [
          "tool": .string(call.name),
          "arguments": DebugPrivacy.arguments(call, visibleText: currentOptions.visibleText),
        ])
    case .toolFinished(let call, let result):
      let summaries = result.content.compactMap { item -> JSONValue? in
        guard item["type"].string == "input_text", let text = item["text"].string,
          let data = text.data(using: .utf8),
          let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return nil }
        var error = value["error"]
        if call.name == "phone_exec_js", !currentOptions.visibleText, error != .null {
          error = .object([
            "code": error["code"],
            "message": .string("Script error detail hidden by visible-text setting"),
          ])
        }
        return .object(["status": value["status"], "error": error])
      }
      record(
        "tool_finished",
        [
          "tool": .string(call.name), "needs_attention": .bool(result.needsAttention),
          "receipts": .array(summaries),
        ])
      toolID = nil
      actionID = nil
      commandID = nil
    case .actionStarted(let id, _, let name):
      actionID = id
      record("action_started", ["operation": .string(name)])
    case .actionFinished(_, let name, let status, let detail):
      record(
        "action_finished",
        ["operation": .string(name), "status": .string(status), "detail": .string(detail)])
    }
  }
  func setPhase(_ value: TaskPhase, detail: String) {
    guard phase != value.rawValue || lastPhaseDetail != detail else { return }
    phase = value.rawValue
    lastPhaseDetail = detail
    record("task_phase", ["detail": .string(detail)])
  }
  func bindSession(_ id: String) {
    sessionID = id
    lastStreamSecond = -100
    record("session_requested")
  }
  func bindCommand(id: String, actionID: String, action: JSONValue) {
    commandID = id
    self.actionID = actionID
    record(
      "native_command_submitted",
      ["action": action, "coordinate_unit": .string("normalized_0_to_1")])
  }
  func releaseCommand(_ id: String) { if commandID == id { commandID = nil } }
  func frame(id: String, data: Data, metadata: JSONValue) {
    var value = metadata.object ?? [:]
    value["action_id"] = actionID.map(JSONValue.string) ?? .null
    value["native_command_id"] = commandID.map(JSONValue.string) ?? .null
    value["tool_call_id"] = toolID.map(JSONValue.string) ?? .null
    value["turn"] = .number(Double(turn))
    active?.frame(id: id, data: data, metadata: .object(value))
  }
  func frameSink() -> DiagnosticFrameSink {
    DiagnosticFrameSink(store: active, context: [
      "action_id": actionID.map(JSONValue.string) ?? .null,
      "native_command_id": commandID.map(JSONValue.string) ?? .null,
      "tool_call_id": toolID.map(JSONValue.string) ?? .null,
      "turn": .number(Double(turn)),
    ])
  }
  func native(_ event: [String: Any]) {
    guard let kind = event["kind"] as? String, active != nil else { return }
    if kind == "stream" {
      let seconds = event["seconds"] as? Int ?? 0
      guard seconds >= lastStreamSecond + 5 else { return }
      lastStreamSecond = seconds
    }
    let allowed: [String]
    switch kind {
    case "session_ready": allowed = ["session_id", "read_only", "capabilities", "unsupported"]
    case "phase": allowed = ["stage"]
    case "stream": allowed = ["seconds", "rtp_packets", "last_packet_age_ms"]
    case "app_inventory_result": allowed = ["transport", "elapsed_ms", "ok", "count"]
    case "media_recovered": allowed = ["stream_count"]
    case "media_cleanup_deferred": allowed = ["reason"]
    case "capture_metrics": allowed = ["reused_connection", "reconnected", "connect_ms", "capture_ms", "elapsed_ms", "png_bytes"]
    case "keyboard_stage": allowed = ["stage", "setup_ms", "reports"]
    case "clipboard_stage": allowed = ["stage", "paste_id", "clipboard_restored", "newer_clipboard_preserved"]
    case "clipboard_reply_shape": allowed = ["root_keys", "body_keys", "command", "items_count", "error_keys", "error_code", "error_domain", "error_description", "error_reason"]
    case "command_started": allowed = ["id", "session_id", "operation"]
    case "command_failed":
      allowed = [
        "id", "session_id", "code", "mutating", "operation", "stage", "cancel_requested",
        "input_started", "input_reports_sent", "raw_error", "cleanup_error", "elapsed_ms",
      ]
    case "command_result": allowed = ["id", "session_id", "status", "error"]
    case "finished": allowed = ["ok"]
    case "error":
      let raw = event["message"] as? String ?? ""
      if raw.hasPrefix("start_audio:") || raw.hasPrefix("start_video:") {
        // Media startup happens after authentication. Preserve CoreDevice's
        // original error for export, including its code/domain and description.
        record(
          "native_worker_error",
          [
            "raw_error": .string(raw),
            "message": .string(PhoneConnectionFailure.displayMessage(raw)),
          ])
      } else {
        // Earlier connection phases may contain authentication protocol material.
        record(
          "native_worker_error",
          [
            "message": .string("Native worker ended; see command_failed or connection stage")
          ])
      }
      return
    default: return
    }
    var fields: [String: JSONValue] = [:]
    for key in allowed {
      if let value = event[key], let encoded = try? JSONValue(value) { fields[key] = encoded }
    }
    if let time = event["native_timestamp_ms"] as? NSNumber {
      fields["native_timestamp_ms"] = .number(time.doubleValue)
    }
    if kind == "command_result", let value = event["value"] as? [String: Any] {
      if let apps = value["apps"] as? [Any] { fields["app_count"] = .number(Double(apps.count)) }
      for key in [
        "frame_id", "width", "height", "orientation", "characters", "verification_required",
        "input_method", "clipboard_pending", "paste_id", "pending_paste_id", "clipboard_restored", "newer_clipboard_preserved",
      ] {
        if let item = value[key], let encoded = try? JSONValue(item) { fields[key] = encoded }
      }
    }
    record("native_" + kind, fields)
  }
  func failure(_ error: Error, stage: String) {
    let value = error as NSError
    record(
      "error",
      [
        "stage": .string(stage), "domain": .string(value.domain),
        "code": .number(Double(value.code)), "message": .string(value.localizedDescription),
      ])
  }
  func finish(_ outcome: String) {
    active?.finish(outcome)
    active = nil
    runID = nil
  }
  func summaries() async -> [DebugTraceSummary] {
    let pending = Array(writers.values)
    let folder = root
    return await Task.detached {
      for store in pending { try? store.flush() }
      return DebugTraceStore.summaries(root: folder)
    }.value
  }
  func export(_ id: UUID) async throws -> URL {
    let pending = writers[id]
    let folder = root
    let exports = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("DebugExports", isDirectory: true)
    return try await Task.detached {
      try pending?.flush()
      guard let trace = DebugTraceStore.summaries(root: folder).first(where: { $0.id == id }) else {
        throw CocoaError(.fileReadNoSuchFile)
      }
      try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
      let target = exports.appendingPathComponent(
        "SoloUse-debug-\(id.uuidString)-\(UUID().uuidString.prefix(6)).zip")
      if let pending {
        try pending.export(to: target)
      } else {
        try DebugArchive.export(directory: trace.directory, to: target)
      }
      let existing =
        (try? FileManager.default.contentsOfDirectory(
          at: exports, includingPropertiesForKeys: [.creationDateKey])) ?? []
      for file in existing.sorted(by: {
        ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
          > ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
      }).dropFirst(3) {
        try? FileManager.default.removeItem(at: file)
      }
      return target
    }.value
  }
  func delete(_ id: UUID) async throws {
    guard id != runID else { throw AgentLoopError.protocolError("请先结束当前任务再删除记录") }
    let writer = writers.removeValue(forKey: id)
    let folder = root
    try await Task.detached {
      try writer?.flush()
      guard let trace = DebugTraceStore.summaries(root: folder).first(where: { $0.id == id }) else {
        return
      }
      try FileManager.default.removeItem(at: trace.directory)
    }.value
  }
}
