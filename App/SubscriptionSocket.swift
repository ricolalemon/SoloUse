import Foundation

struct SubscriptionSocketFailure: Error, LocalizedError {
  let canFallback: Bool
  let reason: String
  var errorDescription: String? { "模型长连接不可用（\(reason)）" }
}
private final class SocketNoRedirects: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(nil) }
}

@MainActor final class SubscriptionSocket {
  private let session: URLSession
  private var socket: URLSessionWebSocketTask?
  private var continuation = ModelContinuation()
  private var credential: String?
  init() {
    let config = URLSessionConfiguration.ephemeral
    config.httpShouldSetCookies = false
    config.httpCookieStorage = nil
    config.urlCache = nil
    config.timeoutIntervalForRequest = 45
    config.timeoutIntervalForResource = 0
    session = URLSession(configuration: config, delegate: SocketNoRedirects(), delegateQueue: nil)
  }
  func close() {
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
    continuation.reset()
    credential = nil
  }
  deinit {
    socket?.cancel(with: .goingAway, reason: nil)
    session.invalidateAndCancel()
  }

  private func bounded<T>(
    socket: URLSessionWebSocketTask, seconds: Double,
    operation: () async throws -> T
  ) async throws -> T {
    let deadline = Task {
      do {
        try await Task.sleep(for: .seconds(seconds))
        socket.cancel(with: .goingAway, reason: nil)
      } catch {}
    }
    defer { deadline.cancel() }
    return try await operation()
  }

  func respond(
    request: URLRequest, input: [JSONValue], tools: [JSONValue],
    configuration: ModelRunConfiguration, cacheKey: String,
    onMessage: @escaping @MainActor (AgentMessageUpdate) -> Void,
    onMetrics: @escaping @MainActor (ModelRequestMetrics) -> Void
  ) async throws -> AgentModelTurn {
    let started = ProcessInfo.processInfo.systemUptime
    var metrics = ModelRequestMetrics(requestID: UUID().uuidString, transport: "websocket")
    metrics.requestedServiceTier = configuration.requestedServiceTier
    metrics.fullInputItems = input.count
    var hasOutput = false
    defer {
      metrics.elapsedMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
      onMetrics(metrics)
    }
    try Task.checkCancellation()
    if credential != request.value(forHTTPHeaderField: "Authorization") { close() }
    if let socket, socket.state != .running || socket.closeCode != .invalid { close() }
    metrics.reusedConnection = socket != nil
    if socket == nil {
      guard let url = request.url, url.scheme == "wss", url.host == "chatgpt.com",
        url.path == "/backend-api/codex/responses"
      else {
        throw SubscriptionSocketFailure(canFallback: false, reason: "unexpected_endpoint")
      }
      let task = session.webSocketTask(with: request)
      task.maximumMessageSize = 8_000_000
      credential = request.value(forHTTPHeaderField: "Authorization")
      socket = task
      task.resume()
    }
    guard let socket else {
      throw SubscriptionSocketFailure(canFallback: true, reason: "not_connected")
    }
    return try await withTaskCancellationHandler {
      let overallDeadline = Task {
        do {
          try await Task.sleep(for: .seconds(180))
          socket.cancel(with: .goingAway, reason: nil)
        } catch {}
      }
      defer { overallDeadline.cancel() }
      do {
        let encodingStart = ProcessInfo.processInfo.systemUptime
        let delta = continuation.delta(input: input, tools: tools)
        let sentInput = delta?.items ?? input
        metrics.mode = delta == nil ? "full" : "incremental"
        metrics.sentInputItems = sentInput.count
        var body = configuration.requestBody(input: sentInput, tools: tools).object!
        body.removeValue(forKey: "stream")
        body["type"] = .string("response.create")
        body["prompt_cache_key"] = .string(cacheKey)
        if let delta { body["previous_response_id"] = .string(delta.id) }
        let encoded = try JSONValue.object(body).data()
        metrics.encodingMS = (ProcessInfo.processInfo.systemUptime - encodingStart) * 1000
        metrics.requestBytes = encoded.count
        try await bounded(socket: socket, seconds: 15) {
          try await socket.send(.string(String(decoding: encoded, as: UTF8.self)))
        }
        metrics.sendFinishedMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
        let http = socket.response as? HTTPURLResponse
        var collector = ModelResponseCollector(
          serverModel: http?.value(forHTTPHeaderField: "openai-model")
            ?? http?.value(forHTTPHeaderField: "x-openai-model"), configuration: configuration)
        var messages = AgentTextStream()
        var lastDelivery = ContinuousClock.now
        while true {
          try Task.checkCancellation()
          let message = try await bounded(socket: socket, seconds: 45) {
            try await socket.receive()
          }
          let data: Data
          switch message {
          case .string(let text): data = Data(text.utf8)
          case .data(let bytes): data = bytes
          @unknown default:
            throw SubscriptionSocketFailure(canFallback: !hasOutput, reason: "unknown_frame")
          }
          metrics.responseBytes += data.count
          guard metrics.responseBytes < 8_000_000 else {
            throw SubscriptionSocketFailure(canFallback: false, reason: "response_too_large")
          }
          guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SubscriptionSocketFailure(canFallback: !hasOutput, reason: "invalid_event")
          }
          if metrics.firstEventMS == nil {
            metrics.firstEventMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
          }
          let event = try JSONValue(raw)
          let type = event["type"].string ?? ""
          if [
            "response.output_item.done", "response.output_text.delta",
            "response.function_call_arguments.delta", "response.refusal.delta",
          ].contains(type) {
            hasOutput = true
            if metrics.firstOutputMS == nil {
              metrics.firstOutputMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
            }
          }
          if ["error", "response.failed", "response.incomplete"].contains(type) {
            let supplied =
              event["error"]["code"].string ?? event["response"]["error"]["code"].string ?? type
            let reason =
              supplied.count < 100
                && supplied.allSatisfy({
                  $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0))
                }) ? supplied : "provider_error"
            if event["status"].number == 401 { throw SubscriptionFailure.http("模型长连接", 401) }
            throw SubscriptionSocketFailure(canFallback: !hasOutput, reason: reason)
          }
          messages.consume(event)
          let turn = try collector.consume(raw)
          if turn != nil || lastDelivery.duration(to: .now) >= .milliseconds(80) {
            messages.drain().forEach(onMessage)
            lastDelivery = .now
          }
          if let turn {
            messages.finish(turn)
            messages.drain().forEach(onMessage)
            continuation.commit(input: input, tools: tools, turn: turn)
            metrics.completed = true
            metrics.usage = turn.usage
            metrics.actualServiceTier = turn.serviceTier
            return turn
          }
        }
      } catch {
        let status = (socket.response as? HTTPURLResponse)?.statusCode
        close()
        if Task.isCancelled { throw CancellationError() }
        if status == 401 { throw SubscriptionFailure.http("模型长连接", 401) }
        if let failure = error as? SubscriptionSocketFailure { throw failure }
        if hasOutput { throw error }
        throw SubscriptionSocketFailure(
          canFallback: true, reason: status.map { "http_\($0)" } ?? "connection_failed")
      }
    } onCancel: {
      socket.cancel(with: .goingAway, reason: nil)
    }
  }
}
