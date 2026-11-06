import Foundation

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  if !condition() { throw AgentLoopError.protocolError(message) }
}
private func call(_ id: String, _ name: String, _ args: [String: JSONValue] = [:]) throws
  -> AgentToolCall
{
  .init(id: id, name: name, arguments: try JSONValue.object(args).text())
}
@MainActor private final class Driver: PhoneDriver {
  var operations: [String] = []
  var failObservation = false
  var emittedObservations: [Bool] = []
  func observe(id: String, includeImage: Bool) async throws -> PhoneDriverReply {
    emittedObservations.append(includeImage)
    var result = try await perform(action: .object(["op": .string("observe")]), id: id)
    if !includeImage { result.images = [] }
    return result
  }
  var uncertain = false
  var onAction: (() -> Void)?
  private var frames = 0
  func perform(action: JSONValue, id: String) async throws -> PhoneDriverReply {
    let operation = action["op"].string!
    operations.append(operation)
    if operation == "observe" {
      if failObservation { return .init(status: "not_executed", value: .null) }
      frames += 1
      return .init(
        status: "executed",
        value: .object([
          "frame_id": .string("f\(frames)"), "width": .number(101), "height": .number(201),
        ]),
        images: [
          .object([
            "type": .string("input_image"), "image_url": .string("data:image/png;base64,fixture"),
          ])
        ])
    }
    onAction?()
    return .init(
      status: uncertain ? "may_have_executed" : "executed", value: .object(["ok": .bool(true)]))
  }
}
@main struct SpeedCoreTests {
  @MainActor static func main() async throws {
    let driver = Driver()
    let gate = AgentPauseGate()
    let dispatcher = PhoneToolDispatcher(
      driver: driver, minimumObservationDelay: 0,
      allowsActions: { gate.allowsActions }, controlVersion: { gate.revision }
    ) { _ in "reply" }
    let opened = try await dispatcher.execute(
      call("open", "phone_open_app", ["app_id": .string("dev.fixture")]))
    try check(driver.operations == ["open_app", "observe"], "Action did not include observation")
    try check(
      opened.content.contains { $0["type"].string == "input_image" }, "Automatic image missing")
    _ = try await dispatcher.execute(
      call("tap", "phone_tap", ["x": .number(50), "y": .number(100), "frame_id": .string("f1")]))
    let before = driver.operations.count
    _ = try await dispatcher.execute(
      call("stale", "phone_tap", ["x": .number(50), "y": .number(100), "frame_id": .string("f1")]))
    try check(driver.operations.count == before, "Old frame survived automatic observation")
    print("PASS direct actions return fresh images and update frame validation")

    let batchDriver = Driver()
    let batches = PhoneToolDispatcher(driver: batchDriver, minimumObservationDelay: 0) { _ in "" }
    _ = try await batches.execute(
      call(
        "batch", "phone_batch",
        [
          "actions": .array([
            .object(["op": .string("home")]),
            .object(["op": .string("wait"), "milliseconds": .number(1)]),
          ])
        ]))
    try check(
      batchDriver.operations == ["home", "wait", "observe"],
      "Batch observed between deterministic actions")
    batchDriver.failObservation = true
    let failed = try await batches.execute(call("failure", "phone_home"))
    let failureText = failed.content.compactMap { $0["text"].string }.joined()
    try check(
      failureText.contains("executed") && failureText.contains("automatic_observation_failed")
        && !failed.needsAttention, "Follow-up capture erased action receipt")
    batchDriver.uncertain = true
    let oldCount = batchDriver.operations.count
    let unsure = try await batches.execute(call("uncertain", "phone_home"))
    try check(
      unsure.needsAttention && batchDriver.operations.count == oldCount + 1,
      "Uncertain effect was followed by another operation")
    print("PASS one capture per batch, partial receipts and no observation after uncertain effects")

    driver.onAction = { gate.pause() }
    let old = driver.operations.count
    _ = try await dispatcher.execute(call("pause", "phone_home"))
    try check(driver.operations.count == old + 1, "Pause failed to stop automatic capture")
    driver.onAction = nil
    gate.resume()
    let scriptDriver = Driver()
    let scriptPhone = PhoneToolDispatcher(driver: scriptDriver, minimumObservationDelay: 0) { _ in
      ""
    }
    let script = ScriptExecutor(phone: scriptPhone, allowsActions: { true }, controlVersion: { 0 })
    _ = try await script.execute(
      call("script1", "phone_exec_js", ["code": .string("await phone.home(); await phone.home();")])
    )
    try check(
      scriptDriver.operations == ["home", "home", "observe"],
      "Script captured after every operation")
    _ = try await script.execute(
      call(
        "script2", "phone_exec_js", ["code": .string("await phone.home(); await phone.observe();")])
    )
    try check(
      Array(scriptDriver.operations.suffix(2)) == ["home", "observe"],
      "Explicit final observation duplicated")
    print("PASS pause gate and script-end capture without duplicate observations")

    let selective = try await script.execute(call("selective", "phone_exec_js", [
      "code": .string("state.frame=await phone.observe({emit:false}); await phone.tap({x:20,y:30,frame_id:state.frame.frame_id}); await phone.observe();")]))
    try check(Array(scriptDriver.emittedObservations.suffix(2)) == [false, true], "Image intent did not reach the driver")
    try check(selective.content.filter { $0["type"].string == "input_image" }.count == 1, "Selective image output changed")
    try check(Array(scriptDriver.operations.suffix(3)) == ["observe", "tap", "observe"], "Metadata capture lost coordinate validation")
    print("PASS metadata-only intent reaches capture with unchanged geometry and final image")

    var collector = ModelResponseCollector(serverModel: "gpt-6-astra")
    _ = try collector.consume(["type": "response.created", "response": ["id": "resp_fixture"]])
    _ = try collector.consume([
      "type": "response.output_item.done", "output_index": 0,
      "item": [
        "type": "function_call", "call_id": "call1", "name": "phone_home", "arguments": "{}",
      ],
    ])
    let turn = try collector.consume([
      "type": "response.completed",
      "response": [
        "status": "completed",
        "usage": [
          "input_tokens": 200, "output_tokens": 12, "input_tokens_details": ["cached_tokens": 100],
          "output_tokens_details": ["reasoning_tokens": 5],
        ],
      ],
    ])!
    try check(
      turn.responseID == "resp_fixture" && turn.usage?.cachedInputTokens == 100,
      "Response identity/usage lost")
    var continuation = ModelContinuation()
    let initial = [
      JSONValue.object(["role": .string("user"), "content": .array([.textContent("fixture")])])
    ]
    let tools = PhoneTools.definitions
    continuation.commit(input: initial, tools: tools, turn: turn)
    let fresh = JSONValue.object([
      "type": .string("function_call_output"), "call_id": .string("call1"),
      "output": .string("done"),
    ])
    let next = initial + turn.output + [fresh]
    try check(
      continuation.delta(input: next, tools: tools)?.items == [fresh],
      "Incremental request repeated history")
    try check(
      continuation.delta(input: [.textContent("changed")] + turn.output + [fresh], tools: tools)
        == nil, "Changed prefix reused")
    try check(continuation.delta(input: next, tools: []) == nil, "Changed tools reused")
    continuation.reset()
    try check(
      continuation.delta(input: next, tools: tools) == nil,
      "Disconnected connection retained continuation")
    print("PASS response IDs, usage, incremental suffix, changed-prefix/tool rejection and reset")
  }
}
