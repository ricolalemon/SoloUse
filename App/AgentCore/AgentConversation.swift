// SPDX-License-Identifier: Apache-2.0
// Contains protocol/flow adaptations from OpenAI Codex, copyright 2025 OpenAI.
// Reimplemented/modified for SoloUse; see NOTICE and THIRD_PARTY_NOTICES.md.
import Foundation

struct AgentToolCall: Codable, Equatable, Sendable {
  let id: String
  let name: String
  let arguments: String
}

struct AgentModelTurn: Sendable {
  let output: [JSONValue]
  let model: String
  let effort: String?
  var responseID: String? = nil
  var usage: ModelUsage? = nil
  var serviceTier: String? = nil
  var calls: [AgentToolCall] {
    output.compactMap { item in
      guard item["type"].string == "function_call", let id = item["call_id"].string,
        let name = item["name"].string, let args = item["arguments"].string
      else { return nil }
      return AgentToolCall(id: id, name: name, arguments: args)
    }
  }
  var finalText: String {
    output.filter { $0["type"].string == "message" && $0["phase"].string != "commentary" }
      .flatMap { $0["content"].array ?? [] }.compactMap { part in
        if part["type"].string == "output_text" { return part["text"].string }
        if part["type"].string == "refusal" { return part["refusal"].string }
        return nil
      }.joined(separator: "\n")
  }
}

struct AgentToolResult: Codable, Sendable {
  let content: [JSONValue]
  var needsAttention = false
  var userReply: String? = nil
  static func error(_ code: String, _ message: String, attention: Bool = false) -> Self {
    let body = JSONValue.object([
      "status": .string(attention ? "may_have_executed" : "not_executed"),
      "error": .object(["code": .string(code), "message": .string(message)]),
    ])
    return Self(
      content: [.textContent((try? body.text()) ?? "Tool failed")], needsAttention: attention)
  }
}

enum AgentLoopError: Error, LocalizedError {
  case protocolError(String)
  case turnLimit(Int)
  case contextLimit(Int)
  case needsAttention(String)
  var errorDescription: String? {
    switch self {
    case .protocolError(let s): return s
    case .turnLimit(let count): return "已达到设置的 \(count) 轮模型调用上限"
    case .contextLimit(let bytes): return "当前请求过大（\(bytes / 1_000_000) MB），请整理上下文后继续；历史记录仍保留。"
    case .needsAttention(let s): return s
    }
  }
}

struct AgentConversation: Codable, Sendable {
  private(set) var items: [JSONValue]
  private var pending: Set<String> = []
  private var known: [String: AgentToolCall] = [:]
  private var results: [String: AgentToolResult] = [:]
  // Full history stays in items; compaction changes only the active model window.
  private var compactedInput: [JSONValue]?
  private var compactedThrough: Int?
  var imageDirectory: URL? = nil
  private enum CodingKeys: String, CodingKey {
    case items, pending, known, results, compactedInput, compactedThrough
  }
  init(task: String) {
    items = [.object(["role": .string("user"), "content": .array([.textContent(task)])])]
  }
  mutating func append(_ turn: AgentModelTurn) throws {
    guard pending.isEmpty else { throw AgentLoopError.protocolError("工具结果尚未齐全") }
    guard turn.calls.count <= 8 else {
      throw AgentLoopError.protocolError("模型单轮返回了超过 8 个工具调用，响应不符合当前工具协议")
    }
    var inTurn: Set<String> = []
    for call in turn.calls {
      guard !call.id.isEmpty, call.id.utf8.count <= 200, inTurn.insert(call.id).inserted else {
        throw AgentLoopError.protocolError("模型返回重复或无效的工具编号")
      }
      if let previous = known[call.id], previous != call {
        throw AgentLoopError.needsAttention("工具编号被不同请求重复使用，已停止")
      }
    }
    // Preserve full model output, including opaque encrypted reasoning and
    // function calls. Never reduce it to a textual action summary.
    items += turn.output
    for call in turn.calls {
      known[call.id] = call
      pending.insert(call.id)
    }
  }
  func cached(_ call: AgentToolCall) -> AgentToolResult? {
    known[call.id] == call ? results[call.id] : nil
  }
  mutating func append(_ result: AgentToolResult, for call: AgentToolCall) throws {
    guard pending.remove(call.id) != nil else { throw AgentLoopError.protocolError("工具结果与当前请求不匹配") }
    items.append(
      .object([
        "type": .string("function_call_output"), "call_id": .string(call.id),
        "output": .array(result.content),
      ]))
    if results[call.id] == nil, let answer = result.userReply {
      items.append(.object(["role": .string("user"), "content": .array([.textContent(answer)])]))
    }
    results[call.id] = result
  }
  mutating func controlNote(_ text: String) {
    items.append(.object(["role": .string("user"), "content": .array([.textContent(text)])]))
  }
  mutating func appendFollowup(_ text: String) throws {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard pending.isEmpty, !text.isEmpty else {
      throw AgentLoopError.protocolError("续聊消息无效，或之前的工具结果尚未结算")
    }
    controlNote("A new user message continues this conversation. Previous actions and receipts are history; do not replay them. The phone control session and JavaScript runtime are new: state/globalThis and pending clipboard leases are empty, and old frame IDs are invalid. Obtain a fresh observation before deciding new phone actions.")
    items.append(.object(["role": .string("user"), "content": .array([.textContent(text)])]))
  }
  func checkpoint(unfinishedCall: String? = nil) throws -> Self {
    var copy = self
    for id in copy.pending.sorted() {
      guard let call = copy.known[id] else { throw AgentLoopError.protocolError("工具记录不完整") }
      let uncertain = id == unfinishedCall
      try copy.append(.error("previous_execution_ended",
        uncertain ? "The prior execution ended while this call was in flight. Its effect is uncertain; observe before deciding any further action. Never replay automatically."
          : "This queued call was not executed before the prior execution ended. It will not resume automatically.",
        attention: uncertain), for: call)
    }
    return copy
  }
  static func recoveringVisibleHistory(_ snapshot: TaskSnapshot) throws -> Self {
    var value = AgentConversation(task: snapshot.prompt)
    value.items = []
    for entry in snapshot.timeline.entries where entry.parent == nil {
      switch entry.kind {
      case .user where !entry.text.isEmpty:
        value.controlNote(entry.text)
      case .assistant where !entry.text.isEmpty:
        value.items.append(.object(["role": .string("assistant"), "content": .string(entry.text)]))
      case .tool:
        value.items.append(.object(["role": .string("assistant"),
          "content": .string("Saved activity record: \(entry.title), status=\(entry.state.rawValue). \(entry.text)")]))
      default: break
      }
    }
    if value.items.isEmpty { value.controlNote(snapshot.prompt) }
    if !snapshot.result.isEmpty,
      !snapshot.timeline.entries.contains(where: { $0.kind == .assistant && $0.text == snapshot.result }) {
      value.items.append(.object(["role": .string("assistant"), "content": .string(snapshot.result)]))
    }
    value.controlNote("This older saved record contains the visible conversation and activity summaries only; exact tool arguments/results and screenshots were not saved. Activity status is not proof of a UI outcome. Treat it as history, do not replay prior actions, and check the current phone before acting.")
    return value
  }
  // A checkpoint is saved only while ask_user is executing. On recovery, settle
  // that call and discard the rest of that model turn; never replay queued actions.
  mutating func resolveHandoff(call: AgentToolCall, answer: String) throws {
    guard call.name == "phone_ask_user", pending.contains(call.id), known[call.id] == call else {
      throw AgentLoopError.protocolError("保存的问题与待完成工具不匹配")
    }
    try append(
      .init(
        content: [.textContent("User replied. Obtain a fresh observation before continuing.")],
        userReply: answer), for: call)
    for id in pending.sorted() {
      guard let queued = known[id] else { throw AgentLoopError.protocolError("工具记录不完整") }
      try append(
        .error("user_handoff", "Queued call was not executed. Re-observe and re-plan."), for: queued
      )
    }
    controlNote(
      "The user answered via a saved handoff. Resume the same task from a fresh observation; completed actions must not be repeated. The JavaScript runtime was recreated, so state/globalThis variables are empty."
    )
  }
  func checkSize() throws {
    // A request guard, never a limit on saving or continuing a conversation.
    let bytes = try JSONEncoder().encode(modelInput()).count
    guard bytes < 16_000_000 else { throw AgentLoopError.contextLimit(bytes) }
  }
  func archivingImages(to directory: URL) throws -> Self {
    var copy = self
    let destination = ConversationImages(directory: directory)
    func archive(_ image: JSONValue) throws -> JSONValue {
      guard let url = image["image_url"].string else { return image }
      let id: String
      if url.hasPrefix(ConversationImages.prefix) {
        id = String(url.dropFirst(ConversationImages.prefix.count))
        _ = try destination.file(id)
        if imageDirectory != directory {
          guard let imageDirectory else { throw AgentLoopError.protocolError("History image location missing") }
          let value = try ConversationImages(directory: imageDirectory).read(id)
          _ = try destination.put(value)
        }
      } else if url.hasPrefix("data:image/") { id = try destination.put(url) }
      else { return image }
      var object = image.object!
      object["image_url"] = .string(ConversationImages.prefix + id)
      return .object(object)
    }
    copy.items = try items.map { try $0.mapImages(archive) }
    for (id, result) in results {
      var value = result; value = .init(content: try result.content.map { try $0.mapImages(archive) },
        needsAttention: result.needsAttention, userReply: result.userReply)
      copy.results[id] = value
    }
    copy.compactedInput = try compactedInput?.map { try $0.mapImages(archive) }
    copy.imageDirectory = directory
    return copy
  }
  private var activeItems: [JSONValue] {
    guard let compactedInput, let through = compactedThrough, through >= 0, through <= items.count else { return items }
    return compactedInput + items.dropFirst(through)
  }
  func modelInput() throws -> [JSONValue] {
    // Retain the newest eight visual observations within an 8 MB image window.
    // Old pixels remain addressable; tool arguments/results and all user text stay.
    var count = 0, bytes = 0
    var projected: [JSONValue] = []
    for item in activeItems.reversed() {
      // Reverse content order too, so a multi-image tool keeps its newest frames.
      func project(_ value: JSONValue) throws -> JSONValue {
        if value["type"].string == "input_image", let url = value["image_url"].string {
          let id = url.hasPrefix(ConversationImages.prefix) ? String(url.dropFirst(ConversationImages.prefix.count)) : nil
          if count >= 8 {
            return .textContent(id.map { "Archived screenshot image_id=\($0). Use phone_history_image to review; historical pixels are not a current screen." } ?? "Older screenshot omitted from this request; take a fresh observation if needed.")
          }
          var object = value.object!
          let resolved: String
          if let id {
            guard let imageDirectory else { throw AgentLoopError.protocolError("History image location missing") }
            do { resolved = try ConversationImages(directory: imageDirectory).read(id) }
            catch {
              return .textContent("Screenshot image_id=\(id) is unavailable or damaged. Its receipt remains historical evidence, not proof of the current UI. Obtain a fresh observation if needed.")
            }
          } else { resolved = url }
          if bytes + resolved.utf8.count > 8_000_000 && count > 0 {
            count = 8
            return .textContent(id.map { "Archived screenshot image_id=\($0). Use phone_history_image to review." } ?? "Older screenshot omitted from this request.")
          }
          count += 1; bytes += resolved.utf8.count
          object["image_url"] = .string(resolved)
          return .object(object)
        }
        switch value {
        case .array(let values): return .array(try values.reversed().map(project).reversed())
        case .object(let values):
          var result = values
          for key in values.keys.sorted() { result[key] = try project(values[key]!) }
          return .object(result)
        default: return value
        }
      }
      projected.append(try project(item))
    }
    return projected.reversed()
  }
  func modelInputAsync() async throws -> [JSONValue] {
    let value = self
    return try await Task.detached(priority: .utility) {
      let input = try value.modelInput()
      let bytes = try JSONEncoder().encode(input).count
      guard bytes < 16_000_000 else { throw AgentLoopError.contextLimit(bytes) }
      return input
    }.value
  }
  var canCompactAgain: Bool { compactedThrough.map { items.count - $0 >= 16 } ?? true }
  var needsCompaction: Bool {
    guard canCompactAgain else { return false }
    let withoutImages = activeItems.map { $0.mapImages { _ in .null } }
    return ((try? JSONEncoder().encode(withoutImages).count) ?? Int.max) > 240_000
  }
  mutating func installCompaction(_ output: [JSONValue]) throws {
    guard pending.isEmpty, output.contains(where: { $0["type"].string == "compaction" && $0["encrypted_content"].string?.isEmpty == false }),
      !output.contains(where: { $0["type"].string == "function_call" }) else {
      throw AgentLoopError.protocolError("上下文整理未完成，历史记录仍保留，可稍后继续。")
    }
    // Codex's compaction-trigger protocol retains real user instructions. Do not
    // interpret or rewrite encrypted compaction/reasoning items.
    compactedInput = items.filter { $0["role"].string == "user" } + output
    compactedThrough = items.count
  }
  func historyImages(_ call: AgentToolCall) -> AgentToolResult {
    do {
      guard call.arguments.utf8.count < 1000,
        let args = try JSONDecoder().decode(JSONValue.self, from: Data(call.arguments.utf8)).object,
        Set(args.keys) == ["offset", "limit"], let offset = args["offset"]?.number,
        let limit = args["limit"]?.number, offset.isFinite, limit.isFinite,
        offset >= 0, offset <= 1_000_000, offset.rounded() == offset,
        (1...50).contains(limit), limit.rounded() == limit else {
        throw AgentLoopError.protocolError("Invalid history image request")
      }
      var catalog: [JSONValue] = []
      for (itemIndex, item) in items.enumerated() {
        _ = item.mapImages { image in
          if let url = image["image_url"].string, url.hasPrefix(ConversationImages.prefix) {
            let callID = item["call_id"].string
            catalog.append(.object([
              "index": .number(Double(catalog.count)), "history_item": .number(Double(itemIndex)),
              "image_id": .string(String(url.dropFirst(ConversationImages.prefix.count))),
              "call_id": callID.map(JSONValue.string) ?? .null,
              "tool": callID.flatMap { known[$0]?.name }.map(JSONValue.string) ?? .null
            ]))
          }
          return image
        }
      }
      let start = min(Int(offset), catalog.count), end = min(start + Int(limit), catalog.count)
      let result = JSONValue.object(["status": .string("executed"), "total": .number(Double(catalog.count)),
        "offset": .number(Double(start)), "next_offset": end < catalog.count ? .number(Double(end)) : .null,
        "images": .array(Array(catalog[start..<end]))])
      return .init(content: [.textContent(try result.text())])
    } catch { return .error("history_image_unavailable", "Historical image unavailable: \(error.localizedDescription). Observe the current screen if needed.") }
  }
  func historyImage(_ call: AgentToolCall) -> AgentToolResult {
    do {
      guard call.arguments.utf8.count < 1000,
        let args = try JSONDecoder().decode(JSONValue.self, from: Data(call.arguments.utf8)).object,
        Set(args.keys) == ["image_id"], let id = args["image_id"]?.string, ConversationImages.validID(id),
        let imageDirectory else { throw AgentLoopError.protocolError("Invalid history image request") }
      var found: JSONValue?
      for item in items {
        _ = item.mapImages { image in
          if image["image_url"].string == ConversationImages.prefix + id { found = image }
          return image
        }
      }
      guard var image = found?.object else { throw AgentLoopError.protocolError("Image does not belong to this conversation") }
      image["image_url"] = .string(try ConversationImages(directory: imageDirectory).read(id))
      return .init(content: [.textContent("Historical screenshot \(id); not a fresh observation. Do not use its frame_id for actions."), .object(image)])
    } catch { return .error("history_image_unavailable", "Historical image unavailable: \(error.localizedDescription). Observe the current screen if needed.") }
  }

}

@MainActor protocol AgentModelTransport {
  func respond(
    input: [JSONValue], tools: [JSONValue],
    onMessage: @escaping @MainActor (AgentMessageUpdate) -> Void
  ) async throws -> AgentModelTurn
}
@MainActor protocol AgentToolExecutor {
  func execute(_ call: AgentToolCall) async throws -> AgentToolResult
}

@MainActor final class PhoneAgentLoop {
  private(set) var conversation: AgentConversation
  private(set) var turns = 0
  private(set) var toolCalls = 0
  private(set) var unfinishedCall: String?
  private let model: any AgentModelTransport
  private let executor: any AgentToolExecutor
  private let tools: [JSONValue]
  init(
    task: String, model: any AgentModelTransport, executor: any AgentToolExecutor,
    tools: [JSONValue] = PhoneTools.definitions
  ) {
    conversation = AgentConversation(task: task)
    self.model = model
    self.executor = executor
    self.tools = tools
  }
  func restore(_ handoff: PendingHandoff) throws {
    conversation = try handoff.answeredConversation()
    turns = handoff.turns
    toolCalls = handoff.calls + 1
  }
  func continueConversation(_ value: AgentConversation) throws {
    conversation = try value.checkpoint()
    // Per-execution counters and runtime stay new; history and cached receipts
    // continue across user messages, without dispatching any old calls.
    turns = 0
    toolCalls = 0
  }
  func run(
    persist: @escaping @MainActor (AgentConversation, String?, Int, Int) async throws -> AgentConversation = { value, _, _, _ in value },
    onContext: @escaping @MainActor (String) -> Void = { _ in },
    maxTurns: Int? = nil,
    onTurnLimit: (@MainActor (Int) async throws -> String?)? = nil,
    beforeModel: () async throws -> String? = { nil },
    allowsActions: () -> Bool = { true }, controlVersion: () -> Int = { 0 },
    onEvent: @escaping @MainActor (AgentEvent) -> Void = { _ in },
    onTurn: (Int, Int) -> Void = { _, _ in }
  ) async throws -> String {
    if let maxTurns, maxTurns <= 0 { throw AgentLoopError.protocolError("轮数上限必须为正数，或不设置上限") }
    var nextLimit = maxTurns.map { turns + $0 }
    var lastInputTokens = 0
    conversation = try await persist(conversation, nil, turns, toolCalls)
    while true {
      try Task.checkCancellation()
      if let maxTurns, let limit = nextLimit, turns >= limit {
        guard let onTurnLimit else { throw AgentLoopError.turnLimit(maxTurns) }
        if let note = try await onTurnLimit(maxTurns) { conversation.controlNote(note) }
        try Task.checkCancellation()
        nextLimit = turns + maxTurns
      }
      if let note = try await beforeModel() {
        conversation.controlNote(note)
        if let maxTurns { nextLimit = turns + maxTurns }
      }
      try Task.checkCancellation()
      if conversation.needsCompaction || (lastInputTokens >= 90_000 && conversation.canCompactAgain) {
        onContext("正在整理上下文，历史截图已保存")
        let window = try await conversation.modelInputAsync()
        let compacted = try await model.respond(input: window + [.object(["type": .string("compaction_trigger")])],
          tools: tools, onMessage: { _ in })
        try Task.checkCancellation()
        try conversation.installCompaction(compacted.output)
        turns += 1
        onTurn(turns, toolCalls)
        conversation = try await persist(conversation, nil, turns, toolCalls)
        lastInputTokens = 0
        // Re-check cancellation, takeover and any user-configured turn limit.
        continue
      }
      let input = try await conversation.modelInputAsync()
      let version = controlVersion()
      onEvent(.modelStarted(turns + 1))
      let response = try await model.respond(
        input: input, tools: tools, onMessage: { onEvent(.message($0)) })
      try Task.checkCancellation()
      lastInputTokens = response.usage?.inputTokens ?? 0
      turns += 1
      try conversation.append(response)
      conversation = try await persist(conversation, nil, turns, toolCalls)
      onTurn(turns, toolCalls)
      if response.calls.isEmpty {
        if !allowsActions() || controlVersion() != version {
          // Text may finish streaming after the user takes over. Preserve it as
          // history, but do not report the task complete on an obsolete view.
          continue
        }
        guard !response.finalText.isEmpty else {
          if response.output.contains(where: {
            $0["type"].string == "message" && $0["phase"].string == "commentary"
          }) {
            continue
          }
          throw AgentLoopError.protocolError("模型既未调用工具，也未返回结果")
        }
        return response.finalText
      }
      var userHandoff = false
      for call in response.calls {
        try Task.checkCancellation()
        let result: AgentToolResult
        onEvent(.toolStarted(call))
        if let cached = conversation.cached(call) {
          result = cached
        } else if !allowsActions() || controlVersion() != version {
          result = .error(
            "user_paused",
            "The user paused or returned to SoloUse. This queued call was not executed. Re-observe and re-plan after resume."
          )
        } else if userHandoff {
          result = .error(
            "user_handoff", "The user replied. Re-plan before executing further actions.")
        } else {
          conversation = try await persist(conversation, call.id, turns, toolCalls)
          try Task.checkCancellation()
          // Persistence yields: check takeover again before any phone action.
          if !allowsActions() || controlVersion() != version {
            result = .error("user_paused", "Not executed; user took over while saving the recovery point.")
          } else if call.name == "phone_history_image" { result = conversation.historyImage(call) }
          else if call.name == "phone_history_images" { result = conversation.historyImages(call) }
          else {
            unfinishedCall = call.id
            result = try await executor.execute(call)
          }
          toolCalls += 1
        }
        try conversation.append(result, for: call)
        unfinishedCall = nil
        onEvent(.toolFinished(call, result))
        conversation = try await persist(conversation, nil, turns, toolCalls)
        userHandoff = userHandoff || result.userReply != nil
        onTurn(turns, toolCalls)
        if result.needsAttention {
          throw AgentLoopError.needsAttention("某个操作可能已执行，已停止自动操作。请检查手机后再决定下一步。")
        }
      }
    }
  }
}
