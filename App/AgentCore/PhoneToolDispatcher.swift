import Foundation

struct PhoneDriverReply: Sendable {
  let status: String
  let value: JSONValue
  var error: JSONValue = .null
  var images: [JSONValue] = []
  var content: [JSONValue] {
    let summary = JSONValue.object(["status": .string(status), "value": value, "error": error])
    return [.textContent((try? summary.text()) ?? "Phone tool error")] + images
  }
}

@MainActor protocol PhoneDriver {
  func perform(action: JSONValue, id: String) async throws -> PhoneDriverReply
  func observe(id: String, includeImage: Bool) async throws -> PhoneDriverReply
}
extension PhoneDriver {
  func observe(id: String, includeImage: Bool) async throws -> PhoneDriverReply {
    var reply = try await perform(action: .object(["op": .string("observe")]), id: id)
    if !includeImage { reply.images = [] }
    return reply
  }
}

@MainActor protocol PhoneSequenceExecutor: AgentToolExecutor {
  func executeInSequence(_ call: AgentToolCall) async throws -> AgentToolResult
  func executeInSequence(_ call: AgentToolCall, emittingObservation: Bool) async throws -> AgentToolResult
  func finishSequence(id: String) async throws -> AgentToolResult?
}
extension PhoneSequenceExecutor {
  func executeInSequence(_ call: AgentToolCall, emittingObservation: Bool) async throws -> AgentToolResult {
    try await executeInSequence(call)
  }
}

@MainActor final class PhoneToolDispatcher: PhoneSequenceExecutor {
  private let driver: any PhoneDriver
  private let automaticallyObserve: Bool
  private let minimumObservationDelay: TimeInterval
  private var needsObservation = false
  private var observationNotBefore: TimeInterval = 0
  private let askUser: (AgentToolCall, AgentQuestion) async throws -> String
  private let allowsActions: () -> Bool
  private let controlVersion: () -> Int
  private let onEvent: (AgentEvent) -> Void
  private var geometry: (id: String, width: Double, height: Double)?
  init(
    driver: any PhoneDriver, automaticallyObserve: Bool = true,
    minimumObservationDelay: TimeInterval = 0.3, allowsActions: @escaping () -> Bool = { true },
    controlVersion: @escaping () -> Int = { 0 }, onEvent: @escaping (AgentEvent) -> Void = { _ in },
    askUser: @escaping (AgentToolCall, AgentQuestion) async throws -> String
  ) {
    self.driver = driver
    self.automaticallyObserve = automaticallyObserve
    self.minimumObservationDelay = minimumObservationDelay
    self.askUser = askUser
    self.allowsActions = allowsActions
    self.controlVersion = controlVersion
    self.onEvent = onEvent
  }
  convenience init(
    driver: any PhoneDriver, automaticallyObserve: Bool = true,
    minimumObservationDelay: TimeInterval = 0.3, allowsActions: @escaping () -> Bool = { true },
    controlVersion: @escaping () -> Int = { 0 }, onEvent: @escaping (AgentEvent) -> Void = { _ in },
    askUser: @escaping (String) async throws -> String
  ) {
    self.init(
      driver: driver, automaticallyObserve: automaticallyObserve,
      minimumObservationDelay: minimumObservationDelay, allowsActions: allowsActions,
      controlVersion: controlVersion,
      onEvent: onEvent, askUser: { _, question in try await askUser(question.text) })
  }
  func invalidateObservation() {
    geometry = nil
    needsObservation = false
  }
  func execute(_ call: AgentToolCall) async throws -> AgentToolResult {
    let result = try await executeInSequence(call)
    guard !result.needsAttention, let observation = try await finishSequence(id: call.id) else {
      return result
    }
    return .init(
      content: result.content + observation.content, needsAttention: observation.needsAttention,
      userReply: result.userReply)
  }
  func executeInSequence(_ call: AgentToolCall) async throws -> AgentToolResult {
    try await executeInSequence(call, emittingObservation: true)
  }
  func executeInSequence(_ call: AgentToolCall, emittingObservation: Bool) async throws -> AgentToolResult {
    let version = controlVersion()
    guard allowsActions() else { return .error("user_paused", "Phone control is paused") }
    let actions: [(String, JSONValue)]
    do { actions = try PhoneTools.parse(call) } catch {
      return .error(
        "invalid_arguments", "Tool arguments are invalid: \(error.localizedDescription)")
    }
    if actions.count == 1, actions[0].0 == "ask_user" {
      let answer = try await askUser(
        call,
        AgentQuestion(
          text: actions[0].1["question"].string ?? "",
          choices: actions[0].1["choices"].array?.compactMap(\.string) ?? []))
      geometry = nil
      needsObservation = true
      observationNotBefore = 0
      return AgentToolResult(
        content: [.textContent("The user replied; a fresh observation is required after handoff.")],
        userReply: answer)
    }
    var content: [JSONValue] = []
    for (index, pair) in actions.enumerated() {
      try Task.checkCancellation()
      guard allowsActions(), controlVersion() == version else {
        geometry = nil
        content +=
          AgentToolResult.error(
            "user_paused", "Remaining batch actions were not executed. Re-observe after resume."
          ).content
        return AgentToolResult(content: content)
      }
      let action: JSONValue
      do { action = try nativeAction(pair.0, pair.1) } catch {
        content += AgentToolResult.error("invalid_observation", error.localizedDescription).content
        return AgentToolResult(content: content)
      }
      let actionID = call.id + "_" + String(index)
      onEvent(.actionStarted(id: actionID, parent: call.id, name: pair.0))
      let actionStartedAt = ProcessInfo.processInfo.systemUptime
      let reply: PhoneDriverReply
      if pair.0 == "observe" {
        reply = try await driver.observe(id: actionID, includeImage: emittingObservation)
      } else {
        reply = try await driver.perform(action: action, id: actionID)
      }
      onEvent(
        .actionFinished(
          id: actionID, name: pair.0, status: reply.status,
          detail: reply.error["message"].string ?? (pair.0 == "type_text" ? "已发送按键，结果由后续观察核对" : ""))
      )
      content += reply.content
      if reply.status == "may_have_executed" {
        return AgentToolResult(content: content, needsAttention: true)
      }
      if reply.status != "executed" { return AgentToolResult(content: content) }
      if pair.0 == "observe", let id = reply.value["frame_id"].string,
        let width = reply.value["width"].number, let height = reply.value["height"].number,
        width > 1, height > 1
      {
        geometry = (id, width, height)
        needsObservation = false
      } else if ["open_app", "home"].contains(pair.0) {
        geometry = nil
      }
      if !["observe", "list_apps"].contains(pair.0) {
        needsObservation = true
        // Count time spent in the action itself toward the settling interval.
        observationNotBefore = actionStartedAt + minimumObservationDelay
      }
    }
    return AgentToolResult(content: content)
  }
  func finishSequence(id: String) async throws -> AgentToolResult? {
    guard automaticallyObserve, needsObservation, allowsActions() else { return nil }
    let version = controlVersion()
    let delay = observationNotBefore - ProcessInfo.processInfo.systemUptime
    if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
    guard allowsActions(), version == controlVersion() else {
      invalidateObservation()
      return nil
    }
    let actionID = id + "_post_observe"
    onEvent(.actionStarted(id: actionID, parent: id, name: "observe"))
    do {
      let reply = try await driver.perform(
        action: .object(["op": .string("observe")]), id: actionID)
      onEvent(
        .actionFinished(id: actionID, name: "observe", status: reply.status, detail: "动作后的新画面"))
      guard allowsActions(), version == controlVersion() else {
        invalidateObservation()
        return nil
      }
      if reply.status == "executed", let frameID = reply.value["frame_id"].string,
        let width = reply.value["width"].number, let height = reply.value["height"].number,
        width > 1, height > 1
      {
        geometry = (frameID, width, height)
        needsObservation = false
        return .init(
          content: [
            .textContent(
              "Fresh observation after the completed actions. Use this frame_id for subsequent coordinates; do not repeat the actions above."
            )
          ] + reply.content)
      }
    } catch {
      onEvent(
        .actionFinished(id: actionID, name: "observe", status: "not_executed", detail: "自动观察未完成"))
      if Task.isCancelled { throw CancellationError() }
    }
    geometry = nil
    return .error(
      "automatic_observation_failed",
      "Earlier action receipts remain valid. Only the follow-up observation failed. Call phone_observe again; do not replay completed actions."
    )
  }
  private func nativeAction(_ name: String, _ args: JSONValue) throws -> JSONValue {
    var object = args.object ?? [:]
    object["op"] = .string(name)
    if ["tap", "double_tap", "long_press", "swipe", "paste_at"].contains(name) {
      guard let frame = geometry, args["frame_id"].string == frame.id else {
        throw AgentLoopError.protocolError("Observe again to obtain the current image and frame_id")
      }
      for (key, size) in [
        ("x", frame.width), ("y", frame.height), ("end_x", frame.width), ("end_y", frame.height),
      ] where object[key] != nil {
        guard let n = object[key]?.number, n.isFinite, n >= 0, n < size else {
          throw AgentLoopError.protocolError("Coordinate is outside the observed image")
        }
        object[key] = .number(n / (size - 1))
      }
    }
    return .object(object)
  }
}
