import Foundation

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  if !condition() { throw AgentLoopError.protocolError(message) }
}
private func call(_ id: String, _ name: String, _ args: [String: Any] = [:]) throws -> AgentToolCall
{
  .init(id: id, name: name, arguments: try JSONValue(args).text())
}
private func turn(_ calls: [AgentToolCall]) -> AgentModelTurn {
  .init(
    output: calls.map {
      .object([
        "type": .string("function_call"), "call_id": .string($0.id), "name": .string($0.name),
        "arguments": .string($0.arguments),
      ])
    }, model: "gpt-6-astra", effort: "low")
}
private let done = AgentModelTurn(
  output: [
    .object([
      "type": .string("message"), "role": .string("assistant"), "phase": .string("final_answer"),
      "id": .string("final"),
      "content": .array([.object(["type": .string("output_text"), "text": .string("已完成")])]),
    ])
  ], model: "gpt-6-astra", effort: "low")
@MainActor private final class Model: AgentModelTransport {
  var script: [AgentModelTurn]
  var requests: [[JSONValue]] = []
  var beforeResponse: (() -> Void)?
  init(_ turns: [AgentModelTurn]) { script = turns }
  func respond(
    input: [JSONValue], tools: [JSONValue],
    onMessage: @escaping @MainActor (AgentMessageUpdate) -> Void
  ) async throws -> AgentModelTurn {
    requests.append(input)
    beforeResponse?()
    beforeResponse = nil
    return script.removeFirst()
  }
}
@MainActor private final class Executor: AgentToolExecutor {
  var executed: [String] = []
  func execute(_ call: AgentToolCall) async throws -> AgentToolResult {
    executed.append(call.id)
    return .init(content: [.textContent("{\"status\":\"executed\"}")])
  }
}
@MainActor private final class Driver: PhoneDriver {
  var executed: [String] = []
  var onAction: (() -> Void)?
  func perform(action: JSONValue, id: String) async throws -> PhoneDriverReply {
    executed.append(id)
    onAction?()
    return .init(status: "executed", value: .null)
  }
}

@main struct StatusTests {
  @MainActor static func main() async throws {
    var stream = AgentTextStream()
    stream.consume(
      try JSONValue([
        "type": "response.output_item.added",
        "item": ["type": "message", "role": "assistant", "id": "m", "phase": "commentary"],
      ]))
    for text in ["正在", "查看屏幕"] {
      stream.consume(
        try JSONValue([
          "type": "response.output_text.delta", "item_id": "m", "content_index": 0, "delta": text,
        ]))
    }
    let partial = stream.drain()
    try check(
      partial.count == 1 && partial[0].text == "正在查看屏幕" && !partial[0].complete,
      "Deltas did not coalesce")
    stream.consume(
      try JSONValue([
        "type": "response.reasoning_text.delta", "item_id": "r", "delta": "private reasoning",
      ]))
    try check(stream.drain().isEmpty, "Reasoning leaked")
    let item = try JSONValue([
      "type": "message", "role": "assistant", "id": "m", "phase": "commentary",
      "content": [["type": "output_text", "text": "已读取当前屏幕。"]],
    ])
    stream.consume(.object(["type": .string("response.output_item.done"), "item": item]))
    let authoritative = stream.drain()
    try check(
      authoritative.count == 1 && authoritative[0].text == "已读取当前屏幕。" && authoritative[0].complete,
      "Final item was not authoritative")
    stream.finish(.init(output: [item], model: "gpt-6-astra", effort: "low"))
    try check(stream.drain().isEmpty, "Completion duplicated streamed text")
    print(
      "PASS visible-message streaming, coalescing, authoritative completion, reasoning exclusion")

    let refusal = AgentModelTurn(
      output: [
        try JSONValue([
          "id": "refusal", "type": "message", "role": "assistant",
          "content": [["type": "refusal", "refusal": "无法执行该任务。"]],
        ])
      ], model: "gpt-6-astra", effort: "low")
    stream.finish(refusal)
    try check(
      stream.drain().first?.text == refusal.finalText && refusal.finalText == "无法执行该任务。",
      "Visible refusal disappeared")

    var decoder = ModelWireDecoder(serverModel: "gpt-6-astra")
    let events: [[String: Any]] = [
      [
        "type": "response.output_item.added",
        "item": ["id": "m", "type": "message", "role": "assistant", "phase": "commentary"],
      ],
      ["type": "response.output_text.delta", "item_id": "m", "content_index": 0, "delta": "你好"],
      ["type": "response.output_item.done", "output_index": 0, "item": try item.foundation()],
      ["type": "response.completed", "response": ["status": "completed", "model": "gpt-6-astra"]],
    ]
    var updates: [AgentMessageUpdate] = []
    var receipt: AgentModelTurn?
    for event in events {
      let bytes = Data(("data: " + (try JSONValue(event).text()) + "\n\n").utf8)
      for byte in bytes { if let r = try decoder.feed(byte) { receipt = r } }
      updates += decoder.drainUpdates()
    }
    try check(
      updates.map(\.text) == ["你好", "已读取当前屏幕。"] && receipt?.output == [item],
      "Wire decoder lost early messages or conversation output")
    print("PASS production SSE decoder publishes text before response completion")

    var timeline = AgentTimeline()
    timeline.note("查询电池", kind: .user)
    timeline.accept(.message(partial[0]), turn: 1)
    timeline.accept(.message(authoritative[0]), turn: 1)
    let tool = try call("t", "phone_batch")
    timeline.accept(.toolStarted(tool), turn: 1)
    timeline.accept(.actionStarted(id: "t_0", parent: "t", name: "tap"), turn: 1)
    timeline.accept(
      .actionFinished(id: "t_0", name: "tap", status: "executed", detail: ""), turn: 1)
    timeline.accept(.toolFinished(tool, .error("unsupported_input", "此输入尚未支持")), turn: 1)
    try check(
      timeline.entries.filter { $0.kind == .assistant }.count == 1,
      "UI duplicated assistant message")
    try check(
      timeline.entries.first { $0.id == "action-t_0" }?.parent == "tool-t", "Action nesting lost")
    try check(
      timeline.entries.first { $0.id == "tool-t" }?.state == .failed,
      "Tool error displayed as success")
    print("PASS timeline item identity, grouped actions, real tool failure states")

    let gate = AgentPauseGate()
    gate.pause()
    var released = false
    let waiting = Task { @MainActor in
      let note = try await gate.checkpoint()
      released = true
      return note
    }
    await Task.yield()
    try check(!released && !gate.allowsActions, "Paused gate allowed progress")
    gate.resume()
    let note = try await waiting.value
    try check(
      released && note?.contains("fresh observation") == true,
      "Resume did not demand a fresh observation")
    gate.pause()
    let stopped = Task { @MainActor in try await gate.checkpoint() }
    await Task.yield()
    gate.stop()
    do {
      _ = try await stopped.value
      throw AgentLoopError.protocolError("Stopped gate resumed")
    } catch is CancellationError {}
    gate.resume()
    try check(!gate.allowsActions, "Stopped gate could be resumed")
    print("PASS pause blocks work, resume retains context, stop releases paused waiters")

    let staleGate = AgentPauseGate()
    let home = try call("stale", "phone_home")
    let model = Model([turn([home]), done])
    let executor = Executor()
    model.beforeResponse = {
      staleGate.pause()
      staleGate.resume()
    }
    _ = try await PhoneAgentLoop(task: "任务", model: model, executor: executor).run(
      beforeModel: { try await staleGate.checkpoint() }, allowsActions: { staleGate.allowsActions },
      controlVersion: { staleGate.revision })
    try check(executor.executed.isEmpty, "An action planned before user takeover ran after resume")
    let nextRequest = try JSONValue.array(model.requests[1]).text()
    try check(
      model.requests.count == 2 && nextRequest.contains("user_paused"),
      "Skipped action did not reach the next model turn")
    let finalGate = AgentPauseGate()
    let staleFinalModel = Model([done, done])
    staleFinalModel.beforeResponse = {
      finalGate.pause()
      finalGate.resume()
    }
    _ = try await PhoneAgentLoop(task: "task", model: staleFinalModel, executor: Executor()).run(
      beforeModel: { try await finalGate.checkpoint() }, allowsActions: { finalGate.allowsActions },
      controlVersion: { finalGate.revision })
    try check(
      staleFinalModel.requests.count == 2,
      "A final answer completed the task after its view was invalidated")
    print("PASS pause/resume during model inference invalidates queued actions")

    let receiptGate = AgentPauseGate()
    let repeatedModel = Model([turn([home]), turn([home]), done])
    let repeatedExecutor = Executor()
    _ = try await PhoneAgentLoop(task: "task", model: repeatedModel, executor: repeatedExecutor)
      .run(
        beforeModel: { try await receiptGate.checkpoint() },
        allowsActions: { receiptGate.allowsActions }, controlVersion: { receiptGate.revision },
        onEvent: { event in
          if case .modelStarted(2) = event {
            receiptGate.pause()
            receiptGate.resume()
          }
        })
    let repeatedResults = repeatedModel.requests[2].filter {
      $0["type"].string == "function_call_output"
    }
    try check(
      repeatedExecutor.executed.count == 1 && repeatedResults.count == 2,
      "Repeated completed action executed again")
    let resultsText = try JSONValue.array(repeatedResults).text()
    try check(
      !resultsText.contains("not_executed"),
      "Pause replaced an existing executed receipt with not-executed")
    let commentary = AgentModelTurn(output: [item], model: "gpt-6-astra", effort: "low")
    let commentaryModel = Model([commentary, done])
    _ = try await PhoneAgentLoop(task: "task", model: commentaryModel, executor: Executor()).run()
    try check(
      commentaryModel.requests[1].contains(item),
      "Commentary-only turn stopped the task or lost context")
    print("PASS pause preserves completed receipts; commentary-only turns continue")

    let batchGate = AgentPauseGate()
    let driver = Driver()
    driver.onAction = {
      batchGate.pause()
      batchGate.resume()
    }
    let dispatcher = PhoneToolDispatcher(
      driver: driver, automaticallyObserve: false, allowsActions: { batchGate.allowsActions },
      controlVersion: { batchGate.revision }
    ) { _ in "" }
    let batch = try call(
      "batch", "phone_batch", ["actions": [["op": "home"], ["op": "wait", "milliseconds": 1]]])
    let partialResult = try await dispatcher.execute(batch)
    try check(
      driver.executed.count == 1 && partialResult.content.count == 2,
      "Remaining batch replayed after takeover")
    print("PASS partial batch receipts survive pause; later actions do not execute")

    let runID = UUID()
    for phase in [TaskPhase.waiting, .completed, .failed] {
      let a = TaskNotice.make(runID: runID, phase: phase, sequence: 2, foreground: false)
      try check(
        a?.runID == runID
          && a?.id
            == TaskNotice.make(runID: runID, phase: phase, sequence: 2, foreground: false)?.id,
        "Notification lost task binding/deduplication identity")
      try check(
        TaskNotice.make(runID: runID, phase: phase, sequence: 2, foreground: true) == nil,
        "Foreground duplicated the notification")
    }
    try check(
      TaskNotice.make(runID: runID, phase: .stopped, sequence: 0, foreground: false) == nil,
      "Stopping caused an unwanted alert")
    print("PASS task-bound completion/help/failure notifications and foreground suppression")

    var progress = PhoneSessionProgress()
    progress.observe(seconds: 10, packets: 100)
    try check(progress.completed == 10, "Live control work did not advance")
    progress.observe(seconds: 30, packets: 100)
    try check(progress.completed == 10, "Stalled video falsely advanced progress")
    progress.observe(seconds: 5, packets: 110)
    try check(progress.completed == 10, "Out-of-order statistics regressed progress")
    progress.observe(seconds: 1000, packets: 120)
    let foundationProgress = Progress(totalUnitCount: progress.total)
    foundationProgress.completedUnitCount = progress.completed
    try check(
      !foundationProgress.isIndeterminate && !foundationProgress.isFinished,
      "Ongoing background task reported indeterminate or finished progress")
    print(
      "PASS finite monotonic session progress, stalled-stream handling, and completion boundary")

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "solouse-status-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = TaskRecordStore(directory: folder)
    timeline.accept(.toolStarted(try call("inflight", "phone_tap")), turn: 2)
    try store.save(
      .init(
        id: runID, prompt: "private task", phase: .acting, timeline: timeline, result: "",
        startedAt: Date(), updatedAt: Date()))
    var restored = store.load()!
    restored.restoreForViewing()
    try check(
      restored.id == runID && restored.phase == .interrupted,
      "Relaunch pretended execution was live")
    try check(
      !restored.timeline.entries.contains { $0.state == .running }, "Relaunch left spinners active")
    print("PASS persisted conversation restores as interrupted, never auto-runs")
  }
}
