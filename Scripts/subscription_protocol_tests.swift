import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  if !condition() { throw SubscriptionFailure.invalid(message) }
}
private func rejects(_ body: () throws -> Void) throws {
  var rejected = false
  do { try body() } catch { rejected = true }
  try require(rejected, "Expected rejection")
}
private func jwt(_ claims: [String: Any]) throws -> String {
  let raw = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
    .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
  return "fixture.\(raw).signature"
}
private func call(_ id: String, _ name: String, _ args: [String: Any] = [:]) throws -> AgentToolCall
{
  AgentToolCall(id: id, name: name, arguments: try JSONValue(args).text())
}
private func turn(_ calls: [AgentToolCall], reasoning: Bool = false) -> AgentModelTurn {
  var output: [JSONValue] =
    reasoning
    ? [
      .object([
        "type": .string("reasoning"), "id": .string("reasoning1"),
        "encrypted_content": .string("opaque-fixture"), "summary": .array([]),
      ])
    ] : []
  output += calls.map {
    .object([
      "type": .string("function_call"), "id": .string("item_" + $0.id), "call_id": .string($0.id),
      "name": .string($0.name), "arguments": .string($0.arguments), "status": .string("completed"),
    ])
  }
  return AgentModelTurn(output: output, model: "gpt-6-astra", effort: "low")
}
private let done = AgentModelTurn(
  output: [
    .object([
      "type": .string("message"), "role": .string("assistant"),
      "content": .array([.object(["type": .string("output_text"), "text": .string("done")])]),
    ])
  ], model: "gpt-6-astra", effort: "low")
@MainActor private final class Model: AgentModelTransport {
  var script: [AgentModelTurn]
  var requests: [[JSONValue]] = []
  init(_ script: [AgentModelTurn]) { self.script = script }
  func respond(
    input: [JSONValue], tools: [JSONValue],
    onMessage: @escaping @MainActor (AgentMessageUpdate) -> Void
  ) async throws -> AgentModelTurn {
    let names = Set(tools.compactMap { $0["name"].string })
    try require(names.count == tools.count && Set(["phone_observe", "phone_tap", "phone_exec_js", "phone_ask_user", "phone_history_image"]).isSubset(of: names), "Generic tools missing or duplicated")
    requests.append(input)
    guard !script.isEmpty else { throw AgentLoopError.protocolError("test script exhausted") }
    return script.removeFirst()
  }
}
@MainActor private final class Executor: AgentToolExecutor {
  var calls: [AgentToolCall] = []
  var results: [AgentToolResult]
  init(_ results: [AgentToolResult]) { self.results = results }
  func execute(_ call: AgentToolCall) async throws -> AgentToolResult {
    calls.append(call)
    return results.removeFirst()
  }
}
@MainActor private final class Driver: PhoneDriver {
  var calls: [JSONValue] = []
  var results: [PhoneDriverReply] = []
  var afterCall: (() -> Void)?
  func perform(action: JSONValue, id: String) async throws -> PhoneDriverReply {
    calls.append(action)
    afterCall?()
    return results.removeFirst()
  }
}
private func observed(_ id: String = "frame") -> PhoneDriverReply {
  PhoneDriverReply(
    status: "executed",
    value: .object(["frame_id": .string(id), "width": .number(101), "height": .number(201)]),
    images: [
      .object([
        "type": .string("input_image"), "image_url": .string("data:image/png;base64,fixture"),
        "detail": .string("original"),
      ])
    ])
}

@main struct ProtocolTests {
  @MainActor static func main() async throws {
    let auth = ["chatgpt_account_id": "fixture-account", "chatgpt_plan_type": "pro"]
    let token = try jwt(["https://api.openai.com/auth": auth, "exp": 4_000_000_000])
    let previous = try SubscriptionTokens.decode([
      "access_token": token, "refresh_token": "old-fixture", "id_token": token,
    ])
    let refreshed = try SubscriptionTokens.decode(
      ["access_token": token, "refresh_token": "rotated-fixture"], previous: previous)
    try require(
      refreshed.refresh == "rotated-fixture" && refreshed.id == previous.id,
      "Refresh rotation failed")
    let other = try jwt(["https://api.openai.com/auth": ["chatgpt_account_id": "other"]])
    try rejects {
      _ = try SubscriptionTokens.decode(
        ["access_token": other, "id_token": other, "refresh_token": "fixture"], previous: previous)
    }
    let authorization = try DeviceAuthorization([
      "device_auth_id": "fixture", "usercode": "code", "interval": "12",
    ])
    try require(authorization.interval == 12, "Polling interval ignored")
    print("PASS auth rotation, account binding, polling interval")

    var parser = SubscriptionSSE()
    _ = try parser.feed(": comment")
    _ = try parser.feed("data: {")
    _ = try parser.feed("data: \"type\":\"fixture\"}")
    let event = try parser.feed("")
    try require(event?["type"] as? String == "fixture", "Multiline SSE failed")
    for separator in ["\n", "\r\n", "\r"] {
      var parser = SubscriptionSSEBytes()
      var parsed: [String: Any]?
      for byte in ("data: {\"text\":\"你好\"}" + separator + separator).utf8 {
        if let value = try parser.feed(byte) { parsed = value }
      }
      try require(parsed?["text"] as? String == "你好", "UTF-8 SSE framing failed")
    }
    let observe = try call("observe1", "phone_observe")
    let first = turn([observe], reasoning: true)
    let response = JSONValue.object([
      "status": .string("completed"), "model": .string("gpt-6-astra"),
      "reasoning": .object(["effort": .string("low")]), "output": .array(first.output),
    ])
    var decoder = ModelWireDecoder(serverModel: nil)
    for byte in try response.data() { _ = try decoder.feed(byte) }
    let decoded = try decoder.finish()
    try require(decoded.output == first.output, "Full JSON output lost")
    var collector = ModelResponseCollector(serverModel: "gpt-6-astra")
    for (index, item) in first.output.enumerated() {
      _ = try collector.consume([
        "type": "response.output_item.done", "output_index": index, "item": try item.foundation(),
      ])
    }
    let collected = try collector.consume([
      "type": "response.completed", "response": ["id": "fixture"],
    ])
    try require(collected?.output == first.output, "Separate completion output lost")
    try rejects {
      _ = try collector.consume([
        "type": "response.output_item.done", "output_index": 1e90, "item": ["type": "message"],
      ])
    }
    var stream = ModelWireDecoder(serverModel: nil)
    var streamed: AgentModelTurn?
    let completion = try JSONValue([
      "type": "response.completed", "response": response.foundation(),
    ]).text()
    for byte in ("data: " + completion + "\n\n").utf8 {
      if let value = try stream.feed(byte) { streamed = value }
    }
    try require(streamed?.output == first.output, "SSE without MIME rejected")
    for invalid in [
      "<html>error</html>", "{\"error\":\"bad\"}", "data: {\"type\":\"response.created\"}\n\n",
    ] {
      try rejects {
        var d = ModelWireDecoder(serverModel: nil)
        for b in invalid.utf8 { _ = try d.feed(b) }
        _ = try d.finish()
      }
    }
    try rejects { _ = try collector.consume(["type": "response.failed"]) }
    try rejects {
      _ = try collector.complete(
        try JSONValue([
          "status": "completed", "model": "other",
          "output": first.output.map { try $0.foundation() },
        ]))
    }
    print(
      "PASS complete JSON, separate items, SSE framing, truncated/error streams, model identity, index bounds"
    )

    let action = try call("input1", "phone_type_text", ["text": "Any app, 任意任务🙂"])
    _ = try PhoneTools.parse(action)  // Hardware driver, not business policy, determines supported characters.
    try rejects {
      _ = try PhoneTools.parse(call("bad", "phone_tap", ["x": true, "y": 20, "frame_id": "f"]))
    }
    try rejects { _ = try PhoneTools.parse(call("bad", "phone_wait", ["milliseconds": 1.5])) }
    try rejects {
      _ = try PhoneTools.parse(
        call("bad", "phone_batch", ["actions": [["op": "ask_user", "question": "bypass"]]]))
    }
    let definitions = PhoneTools.definitions
    let encoded = try JSONValue.array(definitions).text()
    try require(
      !encoded.contains("recipient") && !encoded.contains("WeChat") && !encoded.contains("Lab"),
      "App-specific schema leaked")
    print("PASS generic tool schema and argument validation")

    let imageResult = AgentToolResult(content: observed().content)
    let model = Model([first, turn([action]), done])
    let executor = Executor([
      imageResult, .error("unsupported_input", "Use available keyboard keys"),
    ])
    let loop = PhoneAgentLoop(task: "任意任务", model: model, executor: executor)
    let result = try await loop.run()
    try require(result == "done" && model.requests.count == 3, "Loop did not recover")
    try require(model.requests[1].contains(first.output[0]), "Reasoning was dropped")
    try require(model.requests[1].contains(first.output[1]), "Function call was dropped")
    let output = model.requests[1].first { $0["type"].string == "function_call_output" }
    try require(
      output?["call_id"].string == "observe1" && output?["output"].array == imageResult.content,
      "Image/result call identity was lost")
    try require(
      model.requests[2].prefix(model.requests[1].count).elementsEqual(model.requests[1]),
      "History was replaced on the next turn")
    print("PASS multi-turn history, encrypted reasoning, image results, ordinary-error recovery")

    let duplicateModel = Model([turn([action]), turn([action]), done])
    let duplicateExecutor = Executor([.init(content: [.textContent("executed")])])
    _ = try await PhoneAgentLoop(task: "task", model: duplicateModel, executor: duplicateExecutor)
      .run()
    try require(duplicateExecutor.calls.count == 1, "Repeated call executed twice")
    var conversation = AgentConversation(task: "task")
    try conversation.append(turn([action]))
    try conversation.append(.init(content: [.textContent("ok")]), for: action)
    let changed = try call("input1", "phone_home")
    try rejects { try conversation.append(turn([changed])) }
    try rejects {
      try AgentConversation(task: "task").checkSize()
      var c = AgentConversation(task: "task")
      try c.append(turn([action, action]))
    }
    let uncertainModel = Model([turn([action]), done])
    let uncertainExecutor = Executor([.error("lost_receipt", "unknown", attention: true)])
    do {
      _ = try await PhoneAgentLoop(task: "task", model: uncertainModel, executor: uncertainExecutor)
        .run()
      throw SubscriptionFailure.invalid("Uncertain effect continued")
    } catch AgentLoopError.needsAttention {}
    try require(uncertainModel.requests.count == 1, "Uncertain effect reached another model turn")
    print("PASS duplicate suppression, conflicting IDs, uncertain-effect stop")

    let driver = Driver()
    driver.results = [
      observed(), .init(status: "executed", value: .null),
      .init(
        status: "not_executed", value: .null, error: .object(["code": .string("unsupported_input")])
      ),
    ]
    let dispatcher = PhoneToolDispatcher(driver: driver, automaticallyObserve: false) { _ in "user answer" }
    _ = try await dispatcher.execute(observe)
    let batch = try call(
      "batch", "phone_batch",
      [
        "actions": [
          ["op": "tap", "x": 50, "y": 100, "frame_id": "frame"], ["op": "type_text", "text": "中文"],
          ["op": "home"],
        ]
      ])
    let batchResult = try await dispatcher.execute(batch)
    try require(
      driver.calls.count == 3 && batchResult.content.count == 2,
      "Batch continued after failure or lost partial receipts")
    try require(
      driver.calls[1]["x"].number == 0.5 && driver.calls[1]["y"].number == 0.5,
      "Image coordinates were not normalized")
    let before = driver.calls.count
    _ = try await dispatcher.execute(
      call("stale", "phone_tap", ["x": 50, "y": 100, "frame_id": "old"]))
    _ = try await dispatcher.execute(
      call("outside", "phone_tap", ["x": 101, "y": 100, "frame_id": "frame"]))
    try require(driver.calls.count == before, "Invalid frame/coordinates reached driver")
    let ask = try call("ask", "phone_ask_user", ["question": "Which folder?"])
    var userConversation = AgentConversation(task: "task")
    try userConversation.append(turn([ask]))
    try userConversation.append(try await dispatcher.execute(ask), for: ask)
    try require(
      userConversation.items.last?["role"].string == "user", "User answer lost its origin")
    _ = try await dispatcher.execute(
      call("after_handoff", "phone_tap", ["x": 50, "y": 100, "frame_id": "frame"]))
    try require(driver.calls.count == before, "Handoff kept stale geometry")
    print(
      "PASS ordered batch, partial failure, coordinate mapping, stale-frame rejection, user handoff"
    )

    let pendingAfterAsk = try call("pending", "phone_home")
    let handoffModel = Model([turn([ask, pendingAfterAsk]), done])
    let handoffExecutor = Executor([
      .init(content: [.textContent("reply")], userReply: "Change the task")
    ])
    _ = try await PhoneAgentLoop(task: "task", model: handoffModel, executor: handoffExecutor).run()
    try require(handoffExecutor.calls.count == 1, "Queued action survived user handoff")
    try require(
      PhoneTools.definitions(readOnly: true).allSatisfy {
        ["phone_observe", "phone_list_apps", "phone_wait", "phone_ask_user", "phone_exec_js", "phone_history_image", "phone_history_images"].contains(
          $0["name"].string ?? "")
      }, "Read-only mode advertises mutation tools")
    print("PASS user handoff discards queued actions and read-only tool exposure")

    let cancelledDriver = Driver()
    cancelledDriver.results = [.init(status: "executed", value: .null)]
    let cancelledDispatcher = PhoneToolDispatcher(driver: cancelledDriver, automaticallyObserve: false) { _ in "" }
    cancelledDriver.afterCall = { withUnsafeCurrentTask { $0?.cancel() } }
    let cancellation = Task { @MainActor in
      try await cancelledDispatcher.execute(
        call(
          "cancel", "phone_batch",
          ["actions": [["op": "home"], ["op": "wait", "milliseconds": 1]]]))
    }
    do {
      _ = try await cancellation.value
      throw SubscriptionFailure.invalid("Cancellation was ignored")
    } catch is CancellationError {}
    try require(cancelledDriver.calls.count == 1, "Next action ran after cancellation")
    let bounded = Model([turn([observe])])
    let boundedExecutor = Executor([imageResult])
    do {
      _ = try await PhoneAgentLoop(task: "task", model: bounded, executor: boundedExecutor).run(
        maxTurns: 1)
      throw SubscriptionFailure.invalid("Budget ignored")
    } catch AgentLoopError.turnLimit {}
    print("PASS cancellation between actions and model-turn budget")
  }
}
