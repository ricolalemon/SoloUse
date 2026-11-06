import Foundation

struct AgentMessageUpdate: Equatable, Sendable {
  let id: String
  let text: String
  let phase: String?
  let complete: Bool
}

enum AgentEvent: Sendable {
  case modelStarted(Int)
  case message(AgentMessageUpdate)
  case toolStarted(AgentToolCall)
  case toolFinished(AgentToolCall, AgentToolResult)
  case actionStarted(id: String, parent: String, name: String)
  case actionFinished(id: String, name: String, status: String, detail: String)

  func namespaced(_ prefix: String) -> Self {
    func call(_ value: AgentToolCall) -> AgentToolCall {
      .init(id: prefix + ":" + value.id, name: value.name, arguments: value.arguments)
    }
    switch self {
    case .modelStarted: return self
    case .message(let value):
      return .message(.init(id: prefix + ":" + value.id, text: value.text, phase: value.phase, complete: value.complete))
    case .toolStarted(let value): return .toolStarted(call(value))
    case .toolFinished(let value, let result): return .toolFinished(call(value), result)
    case .actionStarted(let id, let parent, let name):
      return .actionStarted(id: prefix + ":" + id, parent: prefix + ":" + parent, name: name)
    case .actionFinished(let id, let name, let status, let detail):
      return .actionFinished(id: prefix + ":" + id, name: name, status: status, detail: detail)
    }
  }
}

// Only visible assistant message text is presented. Reasoning and encrypted
// content remain in the model conversation and never enter the UI event stream.
struct AgentTextStream {
  private var parts: [String: [Int: String]] = [:]
  private var phases: [String: String] = [:]
  private var emitted: [String: AgentMessageUpdate] = [:]
  private var queue: [AgentMessageUpdate] = []
  mutating func consume(_ event: JSONValue) {
    let type = event["type"].string ?? ""
    if type == "response.output_item.added" || type == "response.output_item.done" {
      let item = event["item"]
      guard item["type"].string == "message", item["role"].string == "assistant" else { return }
      let id = item["id"].string ?? "output-\(event["output_index"].number ?? 0)"
      if let phase = item["phase"].string { phases[id] = phase }
      if type == "response.output_item.done" { publish(item, id: id, complete: true) }
    } else if ["response.output_text.delta", "response.refusal.delta"].contains(type),
      let id = event["item_id"].string,
      let delta = event["delta"].string
    {
      let number = event["content_index"].number ?? 0
      guard number >= 0, number <= 1000, number.rounded() == number else { return }
      parts[id, default: [:]][Int(number), default: ""] += delta
      emit(id, complete: false)
    }
  }
  mutating func finish(_ turn: AgentModelTurn) {
    for (index, item) in turn.output.enumerated()
    where item["type"].string == "message" && item["role"].string == "assistant" {
      publish(item, id: item["id"].string ?? "output-\(index)", complete: true)
    }
  }
  private mutating func publish(_ item: JSONValue, id: String, complete: Bool) {
    if let phase = item["phase"].string { phases[id] = phase }
    var content: [Int: String] = [:]
    for (index, part) in (item["content"].array ?? []).enumerated() {
      if part["type"].string == "output_text", let text = part["text"].string {
        content[index] = text
      }
      if part["type"].string == "refusal", let text = part["refusal"].string {
        content[index] = text
      }
    }
    parts[id] = content
    emit(id, complete: complete)
  }
  private mutating func emit(_ id: String, complete: Bool) {
    let text = (parts[id] ?? [:]).sorted { $0.key < $1.key }.map(\.value).joined(separator: "\n")
    guard !text.isEmpty else { return }
    let update = AgentMessageUpdate(id: id, text: text, phase: phases[id], complete: complete)
    guard emitted[id] != update else { return }
    emitted[id] = update
    // Coalesce updates between UI deliveries, while preserving item ordering.
    if let index = queue.firstIndex(where: { $0.id == id }) {
      queue[index] = update
    } else {
      queue.append(update)
    }
  }
  mutating func drain() -> [AgentMessageUpdate] {
    defer { queue.removeAll() }
    return queue
  }
}

enum TaskPhase: String, Codable, Sendable {
  case idle, connecting, thinking, acting, pausing, paused, waiting, completed, stopped, failed,
    interrupted
  var terminal: Bool { [.completed, .stopped, .failed, .interrupted].contains(self) }
  var label: String {
    switch self {
    case .idle: return "准备就绪"
    case .connecting: return "正在连接手机"
    case .thinking: return "模型处理中"
    case .acting: return "正在操作手机"
    case .pausing: return "正在暂停"
    case .paused: return "已暂停"
    case .waiting: return "等待你的回复"
    case .completed: return "任务结束"
    case .stopped: return "已停止"
    case .failed: return "需要检查"
    case .interrupted: return "任务已中断"
    }
  }
}

struct TimelineEntry: Identifiable, Codable, Equatable, Sendable {
  enum Kind: String, Codable { case user, assistant, tool, action, system }
  enum State: String, Codable { case running, completed, failed, interrupted }
  let id: String
  let kind: Kind
  var title: String
  var text: String
  var state: State
  var phase: String?
  var parent: String?
  let time: Date
}

struct AgentTimeline: Codable, Sendable {
  private(set) var entries: [TimelineEntry] = []
  mutating func note(_ text: String, kind: TimelineEntry.Kind = .system) {
    entries.append(
      .init(
        id: UUID().uuidString, kind: kind, title: "", text: text, state: .completed, time: Date()))
  }
  mutating func accept(_ event: AgentEvent, turn: Int) {
    switch event {
    case .modelStarted: break
    case .message(let message):
      upsert(
        .init(
          id: "message-\(turn)-\(message.id)", kind: .assistant, title: "SoloUse",
          text: message.text,
          state: message.complete ? .completed : .running, phase: message.phase, time: Date()))
    case .toolStarted(let call):
      upsert(
        .init(
          id: "tool-\(call.id)", kind: .tool, title: Self.label(call.name), text: "",
          state: .running, time: Date()))
    case .toolFinished(let call, let result):
      let receipts = result.content.compactMap { item -> JSONValue? in
        guard item["type"].string == "input_text", let text = item["text"].string,
          let data = text.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
      }
      let error = receipts.first { $0["status"].string != nil && $0["status"].string != "executed" }
      let treeUnavailable = call.name == "phone_read_tree" && receipts.contains {
        $0["status"].string == "executed" && $0["value"]["accessibility"]["status"].string == "unavailable"
      }
      update(
        "tool-\(call.id)", state: result.needsAttention || error != nil || treeUnavailable ? .failed : .completed,
        detail: (call.name == "phone_exec_js" ? ScriptToolPresentation.detail(result) : nil)
          ?? error?["error"]["message"].string ?? (treeUnavailable ? "控件树暂不可用，已返回截图" : nil) ?? (result.needsAttention ? "执行结果不确定，已停止" : ""))
    case .actionStarted(let id, let parent, let name):
      upsert(
        .init(
          id: "action-\(id)", kind: .action, title: Self.label(name), text: "", state: .running,
          parent: "tool-\(parent)", time: Date()))
    case .actionFinished(let id, _, let status, let detail):
      update("action-\(id)", state: status == "executed" ? .completed : .failed, detail: detail)
    }
  }
  mutating func interruptOpenEntries() {
    for index in entries.indices where entries[index].state == .running {
      entries[index].state = .interrupted
    }
  }
  private mutating func upsert(_ item: TimelineEntry) {
    if let index = entries.firstIndex(where: { $0.id == item.id }) {
      entries[index].title = item.title
      entries[index].text = item.text
      entries[index].state = item.state
      entries[index].phase = item.phase
    } else {
      entries.append(item)
    }
  }
  private mutating func update(_ id: String, state: TimelineEntry.State, detail: String) {
    guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
    entries[index].state = state
    entries[index].text = detail
  }
  static func label(_ tool: String) -> String {
    let name = tool.hasPrefix("phone_") ? String(tool.dropFirst(6)) : tool
    return [
      "observe": "观察屏幕", "history_image": "查看历史截图", "history_images": "查看截图目录", "read_tree": "读取控件树", "list_apps": "查找应用", "open_app": "打开应用", "tap": "点击屏幕",
      "double_tap": "双击屏幕", "long_press": "长按屏幕", "swipe": "滑动屏幕", "type_text": "输入文字",
      "press_key": "按下组合键", "home": "回到主屏幕", "wait": "等待界面变化", "batch": "执行一组操作",
      "ask_user": "向你提问", "exec_js": "执行手机脚本", "paste_text": "粘贴文字", "paste_at": "粘贴文字",
      "finish_paste": "完成粘贴",
    ][name] ?? "执行工具"
  }
}

struct TaskSnapshot: Codable, Sendable {
  let id: UUID
  let prompt: String
  var phase: TaskPhase
  var timeline: AgentTimeline
  var result: String
  let startedAt: Date
  var updatedAt: Date
  var model: ModelRunConfiguration? = nil
  var conversationRevision: UUID? = nil
  mutating func restoreForViewing() {
    // A history item can be an unsent draft with no execution to interrupt.
    if phase == .idle && timeline.entries.isEmpty { return }
    if !phase.terminal {
      phase = .interrupted
      timeline.interruptOpenEntries()
      timeline.note("上次任务已中断。这里只恢复记录，不会自动操作手机。")
    }
  }
}

struct TaskNotice: Equatable, Sendable {
  let id: String
  let runID: UUID
  let title: String
  let body: String
  static func make(runID: UUID, phase: TaskPhase, sequence: Int, foreground: Bool) -> Self? {
    guard !foreground, [.waiting, .completed, .failed, .paused].contains(phase) else { return nil }
    if phase == .paused {
      return .init(
        id: "solouse.\(runID.uuidString).paused.\(sequence)", runID: runID,
        title: "SoloUse 已按设置暂停", body: "已达到你设置的运行限制，点开后可继续同一任务。")
    }
    let title =
      phase == .waiting ? "SoloUse 需要你的回复" : (phase == .failed ? "SoloUse 需要检查" : "SoloUse 任务结束")
    return .init(
      id: "solouse.\(runID.uuidString).\(phase.rawValue).\(sequence)", runID: runID,
      title: title, body: phase == .waiting ? "手机操作已暂停，点开查看问题。" : "点开 SoloUse 查看任务记录和回答。")
  }
}

// Pausing blocks new actions immediately. The owner closes the native driver
// before releasing the gate; resume never replays a partly completed tool call.
@MainActor final class AgentPauseGate {
  private(set) var paused = false
  private(set) var revision = 0
  private var stopped = false
  private var resumed = false
  private var waiters: [CheckedContinuation<Void, Error>] = []
  func pause() {
    if !paused { revision += 1 }
    paused = true
  }
  func resume() {
    guard !stopped else { return }
    paused = false
    resumed = true
    release()
  }
  func stop() {
    stopped = true
    release()
  }
  var allowsActions: Bool { !paused && !stopped }
  func checkpoint() async throws -> String? {
    try Task.checkCancellation()
    if stopped { throw CancellationError() }
    if paused {
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { waiters.append($0) }
      } onCancel: {
        Task { @MainActor in self.stop() }
      }
    }
    try Task.checkCancellation()
    if stopped { throw CancellationError() }
    guard resumed else { return nil }
    resumed = false
    return
      "[User control event] The user paused phone control to inspect the task and has now explicitly resumed. The screen may have changed. Obtain a fresh observation and re-plan; do not replay queued actions."
  }
  private func release() {
    let pending = waiters
    waiters = []
    for waiter in pending {
      if stopped { waiter.resume(throwing: CancellationError()) } else { waiter.resume() }
    }
  }
}
