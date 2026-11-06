import CryptoKit
import Foundation
import UIKit

@MainActor final class NativePhoneDriver: PhoneDriver {
  static let shared = NativePhoneDriver()
  private(set) var sessionID: String?
  private var startWaiter: CheckedContinuation<Void, Error>?
  private var pending: [String: CheckedContinuation<PhoneDriverReply, Error>] = [:]
  private var pendingImages: [String: Bool] = [:]
  private var preparing: [String: Task<Void, Never>] = [:]
  private var pendingMutation: [String: Bool] = [:]
  private var closeWaiters: [CheckedContinuation<Void, Never>] = []
  private var pendingInfo: [String: (name: String, started: Double)] = [:]
  private var stopping = false
  private var clipboardPreparationTask: Task<Void, Never>?
  private(set) var clipboardPreparationState: JSONValue?
  var onUnexpectedEnd: ((String) -> Void)?

  func start(readOnly: Bool) async throws {
    try Task.checkCancellation()
    guard sessionID == nil, !ProbeModel.shared.busy, solo_is_running() == 0 else {
      throw AgentLoopError.protocolError("已有手机会话在运行")
    }
    let id = UUID().uuidString
    sessionID = id
    stopping = false
    clipboardPreparationState = nil
    TaskDiagnostics.shared.bindSession(id)
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        startWaiter = continuation
        ProbeModel.shared.start("session", sessionID: id, readOnly: readOnly)
      }
    } onCancel: {
      Task { @MainActor in self.cancel() }
    }
    try Task.checkCancellation()
  }
  func perform(action: JSONValue, id: String) async throws -> PhoneDriverReply {
    try await perform(action: action, id: id, includeImage: true)
  }
  func observe(id: String, includeImage: Bool) async throws -> PhoneDriverReply {
    try await perform(action: .object(["op": .string("observe")]), id: id, includeImage: includeImage)
  }
  func prepareClipboardIfNeeded() async throws {
    guard let preparationSession = sessionID, !stopping, clipboardPreparationTask == nil,
      UIApplication.shared.applicationState == .active else { return }
    let status = try await perform(action: .object(["op": .string("clipboard_status")]), id: UUID().uuidString)
    try Task.checkCancellation()
    guard sessionID == preparationSession, !stopping, clipboardPreparationTask == nil else { return }
    TaskDiagnostics.shared.record("clipboard_status", ["status": .string(status.status), "value": status.value])
    if status.status == "executed", status.value["payload_readable"].bool == true {
      clipboardPreparationState = .object(["state": .string("ready")])
      return
    }
    guard status.status == "executed", status.value["requires_local_copy"].bool == true else { return }
    clipboardPreparationState = .object(["state": .string("pending"),
      "message": .string("SoloUse is preparing an authorized local clipboard backup. Observe and handle its paste-permission dialog before leaving SoloUse. Phone observation and tap remain available.")])
    // Do not block the model loop on the very permission dialog it can handle.
    clipboardPreparationTask = Task { [weak self] in
      do {
        let result = try await ClipboardPreparation.prepare()
        try Task.checkCancellation()
        guard let self, self.sessionID == preparationSession, !self.stopping else { return }
        TaskDiagnostics.shared.record("clipboard_local_copy", result.object ?? [:])
        // The system service can still be draining an earlier provider read.
        // Keep this asynchronous: observation/tap must remain usable meanwhile.
        var readable = false
        for attempt in 0..<3 {
          if attempt > 0 { try await Task.sleep(for: .milliseconds(250)) }
          let verified = try await self.perform(action: .object(["op": .string("clipboard_status")]), id: UUID().uuidString)
          try Task.checkCancellation()
          guard self.sessionID == preparationSession, !self.stopping else { return }
          if verified.status == "executed", verified.value["payload_readable"].bool == true {
            readable = true
            break
          }
        }
        guard readable else {
          throw ClipboardPreparationError.verificationFailed
        }
        self.clipboardPreparationState = .object(["state": .string("ready")])
        TaskDiagnostics.shared.record("clipboard_preparation", result.object ?? [:])
        self.clipboardPreparationTask = nil
      } catch {
        guard let self, self.sessionID == preparationSession, !self.stopping else { return }
        self.clipboardPreparationState = .object(["state": .string("unavailable"),
          "message": .string(error.localizedDescription)])
        TaskDiagnostics.shared.failure(error, stage: "clipboard_preparation")
        self.clipboardPreparationTask = nil
      }
    }
  }
  private func perform(action: JSONValue, id: String, includeImage: Bool) async throws -> PhoneDriverReply {
    try Task.checkCancellation()
    guard let sessionID, !stopping else { throw CancellationError() }
    if clipboardPreparationTask != nil, ["open_app", "home"].contains(action["op"].string ?? "") {
      return .init(status: "not_executed", value: .object(["clipboard_preparation": clipboardPreparationState ?? .null]),
        error: .object(["code": .string("clipboard_preparation_pending"),
          "message": .string("Observe SoloUse and handle its clipboard permission dialog before leaving the app. The model can use tap; no automatic permission response is sent.")]))
    }
    // Backend-provided call IDs never become filesystem paths directly.
    let commandID = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    let request = JSONValue.object([
      "session_id": .string(sessionID), "id": .string(commandID), "action": action,
    ])
    let json = try request.text()
    guard pending[commandID] == nil else { throw AgentLoopError.protocolError("同一工具动作已在执行") }
    TaskDiagnostics.shared.bindCommand(id: commandID, actionID: id, action: action)
    pendingInfo[commandID] = (
      action["op"].string ?? "unknown", ProcessInfo.processInfo.systemUptime
    )
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        pending[commandID] = continuation
        pendingImages[commandID] = includeImage
        pendingMutation[commandID] = !["observe", "read_tree", "list_apps", "wait", "clipboard_probe", "clipboard_status"].contains(
          action["op"].string ?? "")
        let accepted = json.withCString { solo_submit_command($0) }
        if accepted != 0 {
          TaskDiagnostics.shared.record(
            "native_command_rejected", ["code": .number(Double(accepted))])
          pendingInfo.removeValue(forKey: commandID)
          TaskDiagnostics.shared.releaseCommand(commandID)
          pending.removeValue(forKey: commandID)
          pendingImages.removeValue(forKey: commandID)
          pendingMutation.removeValue(forKey: commandID)
          continuation.resume(
            returning: PhoneDriverReply(
              status: accepted == -4 ? "may_have_executed" : "not_executed", value: .null,
              error: .object([
                "code": .string("command_rejected"),
                "message": .string("Phone session rejected the command (\(accepted))"),
              ])))
        }
      }
    } onCancel: {
      Task { @MainActor in self.cancel() }
    }
  }
  func receive(_ event: [String: Any]) {
    guard let captureSession = event["session_id"] as? String, captureSession == sessionID else { return }
    if event["kind"] as? String == "session_ready" {
      startWaiter?.resume(); startWaiter = nil
      return
    }
    guard event["kind"] as? String == "command_result", let commandID = event["id"] as? String,
      pending[commandID] != nil, preparing[commandID] == nil else { return }
    if let info = pendingInfo.removeValue(forKey: commandID) {
      TaskDiagnostics.shared.record("native_command_received", [
        "operation": .string(info.name),
        "elapsed_ms": .number((ProcessInfo.processInfo.systemUptime - info.started) * 1000),
        "status": .string(event["status"] as? String ?? "unknown"),
      ])
    }
    do {
      let payload = try JSONValue(event)
      guard payload["status"].string == "executed", let frameID = payload["value"]["frame_buffer"].string else {
        finish(commandID, reply: .init(status: payload["status"].string ?? "may_have_executed",
          value: payload["value"], error: payload["error"]))
        return
      }
      var length = 0
      guard let pointer = frameID.withCString({ solo_take_frame($0, &length) }) else {
        throw AgentLoopError.protocolError("截图缓冲区已失效，请重新观察")
      }
      // Copy immutable bytes before returning ownership to Rust. A subsequent
      // capture or session shutdown cannot overwrite the worker's input.
      let png = Data(bytes: pointer, count: length)
      solo_frame_free(pointer, length)
      var metadata = payload["value"].object ?? [:]
      metadata["captured_at"] = .string(ISO8601DateFormatter().string(from: Date()))
      let sourceMetadata = JSONValue.object(metadata)
      let includeImage = pendingImages[commandID] ?? true
      let sink = TaskDiagnostics.shared.frameSink()
      let started = ProcessInfo.processInfo.systemUptime
      preparing[commandID] = Task { [self] in
        defer { if sessionID == captureSession { preparing.removeValue(forKey: commandID) } }
        do {
          let saveImage = await sink.needsImage()
          let image = try await PhoneImagePreparation.prepare(png: png, metadata: sourceMetadata,
            includeImage: includeImage, saveImage: saveImage)
          guard sessionID == captureSession, pending[commandID] != nil else { return }
          guard !stopping, !Task.isCancelled else {
            finish(commandID, reply: .init(status: "not_executed", value: .null,
              error: .object(["code": .string("observation_cancelled"), "message": .string("Capture was interrupted. Obtain a fresh observation after resume.")])))
            return
          }
          var debugMetadata = image.metadata.object ?? [:]
          if let jpeg = image.jpeg {
            debugMetadata["jpeg_sha256"] = .string(SHA256.hash(data: jpeg).map { String(format: "%02x", $0) }.joined())
          }
          sink.save(id: frameID, data: image.jpeg, metadata: .object(debugMetadata))
          TaskDiagnostics.shared.record("observation_prepared", [
            "elapsed_ms": .number((ProcessInfo.processInfo.systemUptime - started) * 1000),
            "processing_ms": .number(image.elapsedMS),
            "base64_characters": .number(Double(image.dataURL?.utf8.count ?? 0)),
            "model_width": image.metadata["width"], "model_height": image.metadata["height"],
            "image_emitted": .bool(includeImage), "jpeg_encoded": .bool(image.jpeg != nil),
            "thermal_state": .number(Double(ProcessInfo.processInfo.thermalState.rawValue)),
          ])
          let images: [JSONValue] = image.dataURL.map { url in
            [.object(["type": .string("input_image"), "image_url": .string(url), "detail": .string("original")])]
          } ?? []
          finish(commandID, reply: .init(status: "executed", value: image.metadata, images: images))
        } catch {
          guard sessionID == captureSession, pending[commandID] != nil else { return }
          observationFailed(commandID, error: error)
        }
      }
    } catch { observationFailed(commandID, error: error) }
  }
  private func finish(_ commandID: String, reply: PhoneDriverReply) {
    guard let continuation = pending.removeValue(forKey: commandID) else { return }
    pendingMutation.removeValue(forKey: commandID)
    pendingImages.removeValue(forKey: commandID)
    pendingInfo.removeValue(forKey: commandID)
    TaskDiagnostics.shared.releaseCommand(commandID)
    if let clipboardPreparationState {
      var fields = reply.value.object ?? [:]
      fields["clipboard_preparation"] = clipboardPreparationState
      continuation.resume(returning: .init(status: reply.status, value: .object(fields), error: reply.error, images: reply.images))
    } else { continuation.resume(returning: reply) }
  }
  private func observationFailed(_ commandID: String, error: Error) {
    TaskDiagnostics.shared.failure(error, stage: "decode_observation")
    finish(commandID, reply: .init(
      status: pendingMutation[commandID] == true ? "may_have_executed" : "not_executed", value: .null,
      error: .object(["code": .string("observation_decode_failed"),
        "message": .string("Could not prepare the phone observation; capture a new one")])) )
  }
  func cancel(reason: String = "swift_task_cancelled") {
    TaskDiagnostics.shared.record(
      "driver_cancel",
      ["source": .string(reason), "pending_commands": .number(Double(pending.count))])
    stopping = true
    clipboardPreparationTask?.cancel()
    ProbeModel.shared.stop(reason: reason)
  }
  func close(reason: String = "close_session") async {
    guard sessionID != nil else { return }
    stopping = true
    clipboardPreparationTask?.cancel()
    await withCheckedContinuation { continuation in
      closeWaiters.append(continuation)
      TaskDiagnostics.shared.record(
        "driver_close",
        ["source": .string(reason), "pending_commands": .number(Double(pending.count))])
      ProbeModel.shared.stop(reason: reason)
    }
  }
  func ended(_ message: String) {
    guard sessionID != nil else { return }
    let expected = stopping
    let failedDuringStart = startWaiter != nil
    let displayMessage = PhoneConnectionFailure.displayMessage(message)
    TaskDiagnostics.shared.record(
      "session_ended",
      [
        "expected": .bool(expected), "during_start": .bool(failedDuringStart),
        "message": .string(displayMessage), "pending_commands": .number(Double(pending.count)),
      ])
    sessionID = nil
    clipboardPreparationTask?.cancel()
    clipboardPreparationTask = nil
    clipboardPreparationState = nil
    stopping = false
    startWaiter?.resume(throwing: AgentLoopError.protocolError(displayMessage))
    startWaiter = nil
    for (id, waiter) in pending {
      waiter.resume(
        returning: PhoneDriverReply(
          status: pendingMutation[id] == true ? "may_have_executed" : "not_executed", value: .null,
          error: .object([
            "code": .string("session_ended"),
            "message": .string("The phone session ended before a receipt arrived"),
          ])))
    }
    preparing.values.forEach { $0.cancel() }
    preparing.removeAll()
    pendingImages.removeAll()
    pending.removeAll()
    pendingInfo.removeAll()
    pendingMutation.removeAll()
    let waiters = closeWaiters
    closeWaiters = []
    waiters.forEach { $0.resume() }
    // A failed start already has a throwing continuation. Do not also cancel the
    // task and obscure the original connection failure as an unexpected disconnect.
    if !expected && !failedDuringStart { onUnexpectedEnd?(displayMessage) }
  }
}
