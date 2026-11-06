import Foundation

// The interpreter runs off the UI actor; its only native export yields a JSON
// phone request. Swift applies the same validation, receipts and pause gate as
// ordinary tools before resolving that promise.
private final class ScriptWorker: @unchecked Sendable {
  private let queue = DispatchQueue(label: "dev.solouse.javascript")
  private let lock = NSLock()
  private var runtime: OpaquePointer?
  func interrupt() {
    lock.lock()
    if let runtime { solo_js_interrupt(runtime) }
    lock.unlock()
  }
  func reset() async {
    await withCheckedContinuation { continuation in
      queue.async {
        self.lock.lock()
        let old = self.runtime
        self.runtime = nil
        if let old { solo_js_destroy(old) }
        self.lock.unlock()
        continuation.resume()
      }
    }
  }
  func discardRun() async {
    await withCheckedContinuation { continuation in
      queue.async {
        self.lock.lock()
        if let runtime = self.runtime { solo_js_discard_run(runtime) }
        self.lock.unlock()
        continuation.resume()
      }
    }
  }
  func execute(code: String? = nil, response: String? = nil) async throws -> JSONValue {
    try Task.checkCancellation()
    let data: Data = try await withCheckedThrowingContinuation { continuation in
      queue.async {
        self.lock.lock()
        if self.runtime == nil { self.runtime = solo_js_create() }
        let runtime = self.runtime
        self.lock.unlock()
        guard let runtime else {
          continuation.resume(throwing: AgentLoopError.protocolError("无法创建 JavaScript 运行环境"))
          return
        }
        let output =
          code.map { text in text.withCString { solo_js_begin(runtime, $0) } }
          ?? response.map { text in text.withCString { solo_js_step(runtime, $0) } }
          ?? solo_js_step(runtime, nil)
        guard let output else {
          continuation.resume(throwing: AgentLoopError.protocolError("JavaScript 未返回结果"))
          return
        }
        let data = Data(String(cString: output).utf8)
        solo_js_free_string(output)
        continuation.resume(returning: data)
      }
    }
    try Task.checkCancellation()
    return try JSONDecoder().decode(JSONValue.self, from: data)
  }
  deinit { if let runtime { solo_js_destroy(runtime) } }
}

@MainActor final class ScriptExecutor: AgentToolExecutor {
  private let worker = ScriptWorker()
  private let phone: any AgentToolExecutor
  private let allowsActions: () -> Bool
  private let controlVersion: () -> Int
  private let onEvent: (AgentEvent) -> Void
  private let outputLimits: ScriptOutputBuffer.Limits
  private let uptime: () -> TimeInterval
  init(
    phone: any AgentToolExecutor, allowsActions: @escaping () -> Bool,
    controlVersion: @escaping () -> Int, onEvent: @escaping (AgentEvent) -> Void = { _ in },
    outputLimits: ScriptOutputBuffer.Limits = .init(),
    uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  ) {
    self.phone = phone
    self.allowsActions = allowsActions
    self.controlVersion = controlVersion
    self.onEvent = onEvent
    self.outputLimits = outputLimits
    self.uptime = uptime
  }
  func execute(_ call: AgentToolCall) async throws -> AgentToolResult {
    guard call.name == "phone_exec_js" else { return try await phone.execute(call) }
    let code: String
    do {
      guard let data = call.arguments.data(using: .utf8), data.count <= 100_000 else {
        return .error("invalid_script", "Script arguments exceed the supported size")
      }
      let args = try JSONDecoder().decode(JSONValue.self, from: data)
      guard let object = args.object, Set(object.keys) == ["code"], let value = args["code"].string,
        !value.isEmpty, !value.utf8.contains(0), value.utf8.count <= 64_000
      else {
        return .error("invalid_script", "Provide a code string up to 64 KB")
      }
      code = value
    } catch { return .error("invalid_script", "Invalid JavaScript tool arguments") }
    let version = controlVersion()
    let started = uptime()
    var output = ScriptOutputBuffer(limits: outputLimits)
    var operations = 0
    func failure(_ reason: String, code: String = "script_stopped") -> AgentToolResult {
      let error = AgentToolResult.error(
          code,
          reason
            + " Runtime reset; state/globalThis variables were lost. Earlier action receipts remain valid; do not repeat completed actions."
        )
      return .init(content: output.content + error.content)
    }
    func success(_ status: String, pending: String? = nil) -> AgentToolResult {
      let marker: JSONValue = .object([
        "status": .string("executed"), "script_status": .string(status),
        "value": .object(["operations": .number(Double(operations)), "state_preserved": .bool(true)]),
        "pending_operation_not_executed": pending.map(JSONValue.string) ?? .null,
        "output": output.summary,
        "message": .string(status == "segment_complete"
          ? "This segment completed. Pending code was discarded, not executed. Continue with a new script using state/globalThis and completed receipts; no queued actions resume automatically. Use the latest returned frame for visual decisions."
          : "Script completed. Persistent variables remain available in state/globalThis. Output omissions do not undo actions; use the retained latest frame for visual decisions."),
      ])
      return .init(content: output.content + [.textContent((try? marker.text()) ?? "Script completed.")])
    }
    return try await withTaskCancellationHandler {
      do {
        var packet = try await worker.execute(code: code)
        while true {
          try Task.checkCancellation()
          for log in packet["logs"].array ?? [] {
            if let text = log.string {
              output.append([.textContent("Script log: " + text)])
            }
          }
          output.recordOmittedLogs(Int(packet["logs_omitted"].number ?? 0))
          guard allowsActions(), version == controlVersion() else {
            await worker.reset()
            return failure("Phone control was paused; queued script operations were discarded.")
          }
          guard uptime() - started < 120 else {
            await worker.reset()
            return failure(
              "This script exceeded its 120-second execution deadline. Continue with a new short script after observing the screen.", code: "script_timeout"
            )
          }
          if packet["state"].string == "done" {
            if let sequence = phone as? any PhoneSequenceExecutor,
              let observation = try await sequence.finishSequence(id: call.id)
            {
              output.append(observation.content)
            }
            return success("completed")
          }
          if packet["state"].string == "error" {
            await worker.reset()
            if let sequence = phone as? any PhoneSequenceExecutor,
              let observation = try await sequence.finishSequence(id: call.id)
            {
              output.append(observation.content)
            }
            let message = packet["error"].string ?? "JavaScript failed"
            return failure(message, code: message.contains("CPU slice") ? "script_cpu_limit" : "script_runtime_error")
          }
          guard packet["state"].string == "request", let name = packet["request"]["name"].string,
            PhoneTools.specs.contains(where: { $0.0 == name }),
            var arguments = packet["request"]["arguments"].object
          else {
            await worker.reset()
            return failure("Unknown phone operation; ask_user must be a separate tool call.")
          }
          if operations >= 64 {
            await worker.discardRun()
            if let sequence = phone as? any PhoneSequenceExecutor,
              let observation = try await sequence.finishSequence(id: call.id) {
              output.append(observation.content)
            }
            return success("segment_complete", pending: name)
          }
          var emitImages = true
          if name == "observe", let emit = arguments.removeValue(forKey: "emit") {
            guard let enabled = emit.bool else {
              await worker.reset()
              return failure("phone.observe emit must be true or false.", code: "script_runtime_error")
            }
            emitImages = enabled
          }
          let child = AgentToolCall(
            id: call.id + "_js_" + String(operations), name: "phone_" + name,
            arguments: try JSONValue.object(arguments).text())
          operations += 1
          onEvent(.toolStarted(child))
          let result: AgentToolResult
          if let sequence = phone as? any PhoneSequenceExecutor {
            result = try await sequence.executeInSequence(child, emittingObservation: emitImages)
          } else {
            result = try await phone.execute(child)
          }
          onEvent(.toolFinished(child, result))
          output.append(result.content, emitImages: emitImages)
          if !emitImages, !result.content.contains(where: { $0["type"].string == "input_image" }) {
            output.recordSuppressedImage()
          }
          if result.needsAttention {
            await worker.reset()
            return .init(content: output.content, needsAttention: true)
          }
          // A single phone tool returns its structured receipt before any image.
          guard let text = result.content.first?["text"].string,
            let data = text.data(using: .utf8),
            let receipt = try? JSONDecoder().decode(JSONValue.self, from: data),
            receipt["status"].string != nil
          else {
            await worker.reset()
            return failure("Phone operation returned no structured receipt.")
          }
          guard allowsActions(), version == controlVersion() else {
            await worker.reset()
            return failure("Control changed after the last operation. Its receipt is preserved.")
          }
          packet = try await worker.execute(response: text)
        }
      } catch {
        await worker.reset()
        if Task.isCancelled { throw CancellationError() }
        return failure(error.localizedDescription)
      }
    } onCancel: { [worker] in
      worker.interrupt()
    }
  }
}
