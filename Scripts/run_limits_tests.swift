import Foundation

private func check(_ ok: @autoclosure () -> Bool, _ message: String) throws {
  if !ok() { throw AgentLoopError.protocolError(message) }
}
private let done = AgentModelTurn(
  output: [
    .object([
      "type": .string("message"), "role": .string("assistant"),
      "content": .array([.object(["type": .string("output_text"), "text": .string("done")])]),
    ])
  ], model: "gpt-6-astra", effort: "low")
@MainActor private final class Model: AgentModelTransport {
  var requests: [[JSONValue]] = []
  let steps: Int
  init(_ steps: Int) { self.steps = steps }
  func respond(
    input: [JSONValue], tools: [JSONValue],
    onMessage: @escaping @MainActor (AgentMessageUpdate) -> Void
  ) async throws -> AgentModelTurn {
    requests.append(input)
    if requests.count > steps { return done }
    return AgentModelTurn(
      output: [
        .object([
          "type": .string("function_call"), "call_id": .string("step-\(requests.count)"),
          "name": .string("phone_wait"), "arguments": .string("{\"milliseconds\":1}"),
        ])
      ], model: "gpt-6-astra", effort: "low")
  }
}
@MainActor private final class Executor: AgentToolExecutor {
  var ids: [String] = []
  func execute(_ call: AgentToolCall) async throws -> AgentToolResult {
    ids.append(call.id)
    return .init(content: [.textContent("executed")])
  }
}
@main struct RunLimitsTests {
  @MainActor static func main() async throws {
    let model = Model(32)
    let executor = Executor()
    let loop = PhoneAgentLoop(task: "continue until done", model: model, executor: executor)
    let result = try await loop.run()
    try check(
      result == "done" && loop.turns == 33 && executor.ids.count == 32,
      "Default stopped at a hidden round limit")
    try check(Set(executor.ids).count == 32, "Actions were replayed")
    print("PASS default task completes after 33 rounds without a configured limit")

    let gate = AgentPauseGate()
    let limitedModel = Model(2)
    let limitedExecutor = Executor()
    var limitReached = false
    var finished = false
    let limitedLoop = PhoneAgentLoop(
      task: "original task", model: limitedModel, executor: limitedExecutor)
    let task = Task { @MainActor in
      let result = try await limitedLoop.run(
        maxTurns: 2,
        onTurnLimit: { count in
          try check(count == 2, "Wrong configured limit")
          limitReached = true
          gate.pause()
          return try await gate.checkpoint()
        })
      finished = true
      return result
    }
    for _ in 0..<100 where !limitReached { await Task.yield() }
    try check(
      limitReached && !finished && limitedModel.requests.count == 2,
      "Configured limit did not pause before another request")
    gate.resume()
    let continued = try await task.value
    try check(
      continued == "done" && limitedExecutor.ids == ["step-1", "step-2"],
      "Resume restarted or replayed the task")
    let last = try JSONValue.array(limitedModel.requests.last!).text()
    try check(
      last.contains("original task") && last.contains("function_call_output")
        && last.contains("User control event"),
      "Resume lost task history or fresh-observation notice")
    print(
      "PASS configured limit waits for explicit continuation and preserves the same conversation")

    let cancelGate = AgentPauseGate()
    let cancelModel = Model(3)
    var waiting = false
    let cancelled = Task { @MainActor in
      try await PhoneAgentLoop(task: "task", model: cancelModel, executor: Executor()).run(
        maxTurns: 1,
        onTurnLimit: { _ in
          waiting = true
          cancelGate.pause()
          return try await cancelGate.checkpoint()
        })
    }
    for _ in 0..<100 where !waiting { await Task.yield() }
    cancelled.cancel()
    do {
      _ = try await cancelled.value
      throw AgentLoopError.protocolError("Cancellation did not interrupt limit pause")
    } catch is CancellationError {}
    try check(cancelModel.requests.count == 1, "Stopped limit pause made another request")
    print("PASS stop remains effective while waiting at a user-selected limit")

    let unlimited = AgentRunLimits()
    try check(
      unlimited.turns == nil && unlimited.seconds == nil
        && !unlimited.timeReached(start: 0, now: 1_000_000),
      "Defaults still impose a time or turn cap")
    let timed = AgentRunLimits(turns: 100, minutes: 5)
    try check(
      !timed.timeReached(start: 10, now: 309) && timed.timeReached(start: 10, now: 310),
      "Time boundary incorrect")
    try check(!timed.timeReached(start: 310, now: 311), "A new runtime segment immediately expired")
    var progress = PhoneSessionProgress()
    progress.observe(seconds: 600, packets: 9000)
    let reported = Progress(totalUnitCount: progress.total)
    reported.completedUnitCount = progress.completed
    try check(
      progress.completed == 600 && !reported.isIndeterminate && !reported.isFinished,
      "Progress introduced a hidden five-minute deadline")
    print("PASS opt-in time limit and finite ongoing progress beyond five minutes")

    do {
      try AgentConversation(task: String(repeating: "x", count: 32_000_000)).checkSize()
      throw AgentLoopError.protocolError("Context resource guard disappeared")
    } catch AgentLoopError.contextLimit(let bytes) {
      try check(bytes >= 32_000_000, "Context size not included in error")
    }
    do {
      var c = AgentConversation(task: "task")
      let calls = (0..<9).map {
        JSONValue.object([
          "type": .string("function_call"), "call_id": .string("c\($0)"),
          "name": .string("phone_home"), "arguments": .string("{}"),
        ])
      }
      try c.append(.init(output: calls, model: "gpt-6-astra", effort: "low"))
      throw AgentLoopError.needsAttention("Too many calls accepted")
    } catch AgentLoopError.protocolError(let message) {
      try check(message.contains("工具协议"), "Protocol error mislabeled as usage budget")
    }
    print("PASS memory and protocol failures use distinct, accurate messages")
  }
}
