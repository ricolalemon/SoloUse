// SPDX-License-Identifier: Apache-2.0
// Contains protocol/flow adaptations from OpenAI Codex, copyright 2025 OpenAI.
// Reimplemented/modified for SoloUse; see NOTICE and THIRD_PARTY_NOTICES.md.
// Device-code grant sequence and backend request fields adapted from OpenAI Codex,
// revision d3e584093222018fc27919403aea149ccfd3bb38 (Apache-2.0).
// This is a new Swift implementation; see Licenses/codex-Apache-2.0.txt.
import Foundation
import Security

enum SubscriptionKeychain {
  private static var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "dev.solouse.subscription", kSecAttrAccount as String: "chatgpt",
    ]
  }
  static func load() throws -> SubscriptionTokens? {
    var q = query
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw SubscriptionFailure.invalid("无法读取本机钥匙串（\(status)）")
    }
    return try JSONDecoder().decode(SubscriptionTokens.self, from: data)
  }
  static func save(_ tokens: SubscriptionTokens) throws {
    let data = try JSONEncoder().encode(tokens)
    let fields: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let status = SecItemUpdate(query as CFDictionary, fields as CFDictionary)
    if status == errSecItemNotFound {
      var q = query
      fields.forEach { q[$0.key] = $0.value }
      q[kSecAttrSynchronizable as String] = false
      let added = SecItemAdd(q as CFDictionary, nil)
      guard added == errSecSuccess else { throw SubscriptionFailure.invalid("无法保存本机钥匙串（\(added)）") }
    } else if status != errSecSuccess {
      throw SubscriptionFailure.invalid("无法更新本机钥匙串（\(status)）")
    }
  }
  static func delete() throws {
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw SubscriptionFailure.invalid("无法清除本机钥匙串（\(status)）")
    }
  }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(nil) }
}

// UI serializes operations: one login, refresh, or inference at a time.
enum ModelTransportPreference { case automatic, httpOnly, webSocketOnly }

@MainActor final class SubscriptionClient {
  private let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
  private let issuer = "https://auth.openai.com"
  private let backend = "https://chatgpt.com/backend-api/codex"
  static let verificationURL = URL(string: "https://auth.openai.com/codex/device")!
  private let session: URLSession
  let modelConfiguration: ModelRunConfiguration
  private let transportPreference: ModelTransportPreference
  private let socketTransport = SubscriptionSocket()
  private var routing: ModelSessionRouting
  private var cacheKey: String { routing.cacheKey }
  private var httpFallback = false
  private var account: String?
  private(set) var metrics: [ModelRequestMetrics] = []
  private(set) var catalogMetadata: JSONValue = .null
  var onServiceTierStatus: (@MainActor (String) -> Void)?
  private var lastServiceTierStatus: String?
  #if DEBUG
    var omitSessionRoutingForBenchmark = false
    var benchmarkInstructions: String?
  #endif
  init(
    modelConfiguration: ModelRunConfiguration = .initial,
    transport: ModelTransportPreference = .httpOnly,
    sessionID: UUID = UUID()
  ) {
    self.routing = ModelSessionRouting(id: sessionID)
    self.transportPreference = transport
    self.modelConfiguration = modelConfiguration
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 45
    configuration.timeoutIntervalForResource = 180
    session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
  }

  private func request(_ url: String) -> URLRequest {
    var request = URLRequest(url: URL(string: url)!)
    request.httpMethod = "POST"
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    request.setValue(
      "SoloUse/\(version) (iOS; experimental native client)", forHTTPHeaderField: "User-Agent")
    request.setValue("solouse_ios", forHTTPHeaderField: "originator")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if request.url?.host == "chatgpt.com", request.url?.path == "/backend-api/codex/responses" {
      request.setValue(modelConfiguration.routingHint, forHTTPHeaderField: "x-codex-routing-hint")
      #if DEBUG
        if !omitSessionRoutingForBenchmark { routing.apply(to: &request) }
      #else
        routing.apply(to: &request)
      #endif
    }
    return request
  }

  private func json(_ request: URLRequest, stage: String, pending: Bool = false) async throws
    -> [String: Any]?
  {
    try Task.checkCancellation()
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw SubscriptionFailure.invalid("\(stage)：缺少 HTTP 响应")
    }
    if pending && [403, 404].contains(http.statusCode) { return nil }
    guard (200...299).contains(http.statusCode) else {
      throw SubscriptionFailure.http(stage, http.statusCode)
    }
    guard data.count < 1_000_000,
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw SubscriptionFailure.invalid("\(stage)：响应格式无效")
    }
    return object
  }

  func authorize(showCode: (String) -> Void) async throws -> SubscriptionTokens {
    var initial = request(issuer + "/api/accounts/deviceauth/usercode")
    initial.httpBody = try JSONSerialization.data(withJSONObject: ["client_id": clientID])
    let authorization = try DeviceAuthorization(try await json(initial, stage: "申请设备码") ?? [:])
    showCode(authorization.code)
    let deadline = ContinuousClock.now.advanced(by: .seconds(900))
    var granted: [String: Any]?
    while ContinuousClock.now < deadline {
      try Task.checkCancellation()
      var poll = request(issuer + "/api/accounts/deviceauth/token")
      poll.httpBody = try JSONSerialization.data(withJSONObject: [
        "device_auth_id": authorization.id, "user_code": authorization.code,
      ])
      if let result = try await json(poll, stage: "等待网页授权", pending: true) {
        granted = result
        break
      }
      try await Task.sleep(for: .seconds(authorization.interval))
    }
    guard let granted, let code = granted["authorization_code"] as? String,
      let verifier = granted["code_verifier"] as? String
    else { throw SubscriptionFailure.invalid("设备码已过期，请重新登录") }
    try Task.checkCancellation()
    var exchange = request(issuer + "/oauth/token")
    exchange.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    let fields = [
      "grant_type": "authorization_code", "client_id": clientID, "code": code,
      "redirect_uri": issuer + "/deviceauth/callback", "code_verifier": verifier,
    ]
    let allowed = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    exchange.httpBody = Data(
      fields.sorted(by: { $0.key < $1.key }).map {
        "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters:allowed)!)"
      }.joined(separator: "&").utf8)
    // Do not retry an uncertain one-time authorization-code exchange.
    let tokens = try SubscriptionTokens.decode(try await json(exchange, stage: "交换登录凭据") ?? [:])
    try SubscriptionKeychain.save(tokens)
    return tokens
  }

  private func refresh(_ tokens: SubscriptionTokens) async throws -> SubscriptionTokens {
    var refresh = request(issuer + "/oauth/token")
    refresh.httpBody = try JSONSerialization.data(withJSONObject: [
      "grant_type": "refresh_token", "client_id": clientID, "refresh_token": tokens.refresh,
    ])
    let fresh = try SubscriptionTokens.decode(
      try await json(refresh, stage: "续期登录凭据") ?? [:], previous: tokens)
    // Persist the rotated refresh token before another operation can start.
    try SubscriptionKeychain.save(fresh)
    return fresh
  }

  func models(clientVersion: String = ModelCatalog.clientVersion) async throws -> [CatalogModel] {
    guard var tokens = try SubscriptionKeychain.load() else {
      throw SubscriptionFailure.invalid("请先登录 ChatGPT")
    }
    if tokens.expires.timeIntervalSinceNow < 120 { tokens = try await refresh(tokens) }
    do { return try await catalog(tokens, clientVersion: clientVersion) } catch SubscriptionFailure.http(_, 401) {
      tokens = try await refresh(tokens)
      return try await catalog(tokens, clientVersion: clientVersion)
    }
  }

  private func catalog(_ tokens: SubscriptionTokens, clientVersion: String) async throws -> [CatalogModel] {
    var components = URLComponents(string: backend + "/models")!
    components.queryItems = [URLQueryItem(name: "client_version", value: clientVersion)]
    var call = request(components.url!.absoluteString)
    call.httpMethod = "GET"
    call.timeoutInterval = 15
    call.cachePolicy = .reloadIgnoringLocalCacheData
    call.setValue("Bearer " + tokens.access, forHTTPHeaderField: "Authorization")
    call.setValue(tokens.account, forHTTPHeaderField: "ChatGPT-Account-Id")
    call.setValue("application/json", forHTTPHeaderField: "Accept")
    let value = try JSONValue(try await json(call, stage: "读取模型列表") ?? [:])
    let models = try ModelCatalog.parse(value)
    // Only catalog identity/capabilities, never tokens, account IDs or model instructions.
    catalogMetadata = .object([
      "client_version": .string(clientVersion),
      "entries": .array((value["models"].array ?? []).map {
        .object(["id": $0["slug"], "visibility": $0["visibility"],
                 "input_modalities": $0["input_modalities"]])
      }),
    ])
    ProbeModel.shared.log([
      "kind": "model_catalog_received", "models": models.map(\.id),
      "count": models.count, "client_version": clientVersion,
    ])
    return models
  }

  func respond(
    input: [JSONValue], tools: [JSONValue],
    onMessage: @escaping @MainActor (AgentMessageUpdate) -> Void
  ) async throws -> AgentModelTurn {
    guard var tokens = try SubscriptionKeychain.load() else {
      throw SubscriptionFailure.invalid("请先登录 ChatGPT")
    }
    if let account, account != tokens.account {
      socketTransport.close()
      routing.resetTurnState()
      throw SubscriptionFailure.invalid("账号已变化，请重新开始任务")
    }
    account = tokens.account
    if tokens.expires.timeIntervalSinceNow < 120 { tokens = try await refresh(tokens) }
    do {
      return try await route(input: input, tools: tools, tokens: tokens, onMessage: onMessage)
    } catch SubscriptionFailure.http(_, 401) {
      socketTransport.close()
      routing.resetTurnState()
      tokens = try await refresh(tokens)
      return try await route(input: input, tools: tools, tokens: tokens, onMessage: onMessage)
    }
  }

  private func route(
    input: [JSONValue], tools: [JSONValue], tokens: SubscriptionTokens,
    onMessage: @escaping @MainActor (AgentMessageUpdate) -> Void
  ) async throws -> AgentModelTurn {
    if transportPreference != .httpOnly && !httpFallback {
      var call = request("wss://chatgpt.com/backend-api/codex/responses")
      call.httpMethod = "GET"
      call.setValue("Bearer " + tokens.access, forHTTPHeaderField: "Authorization")
      call.setValue(tokens.account, forHTTPHeaderField: "ChatGPT-Account-Id")
      call.setValue("responses_websockets=2026-02-06", forHTTPHeaderField: "OpenAI-Beta")
      call.setValue(cacheKey, forHTTPHeaderField: "x-client-request-id")
      do {
        let turn = try await socketTransport.respond(
          request: call, input: input, tools: tools,
          configuration: modelConfiguration, cacheKey: cacheKey, onMessage: onMessage,
          onMetrics: { [self] in recordMetrics($0) })
        recordReceipt(turn, requestID: metrics.last?.requestID ?? "")
        return turn
      } catch let error as SubscriptionSocketFailure {
        guard transportPreference == .automatic, error.canFallback else { throw error }
        httpFallback = true
        TaskDiagnostics.shared.record("model_transport_fallback", ["reason": .string(error.reason)])
      }
    }
    return try await infer(input: input, tools: tools, tokens: tokens, onMessage: onMessage)
  }

  private func recordMetrics(_ value: ModelRequestMetrics) {
    metrics.append(value)
    if metrics.count > 64 { metrics.removeFirst(metrics.count - 64) }
    if let data = try? JSONEncoder().encode(value),
      let json = try? JSONDecoder().decode(JSONValue.self, from: data), let fields = json.object
    {
      TaskDiagnostics.shared.record("model_request_metrics", fields)
    }
  }

  private func infer(
    input: [JSONValue], tools: [JSONValue], tokens: SubscriptionTokens,
    onMessage: @escaping @MainActor (AgentMessageUpdate) -> Void
  )
    async throws -> AgentModelTurn
  {
    let requestID = UUID().uuidString
    let started = ProcessInfo.processInfo.systemUptime
    var measurement = ModelRequestMetrics(requestID: requestID, transport: "http_sse")
    measurement.requestedServiceTier = modelConfiguration.requestedServiceTier
    measurement.fullInputItems = input.count
    measurement.sentInputItems = input.count
    var stage = "prepare"
    var completed = false
    TaskDiagnostics.shared.record(
      "model_request_started",
      [
        "request_id": .string(requestID), "requested_model": .string(modelConfiguration.choice.id),
        "requested_effort": modelConfiguration.choice.effort.map(JSONValue.string) ?? .null,
        "requested_service_tier": modelConfiguration.requestedServiceTier.map(JSONValue.string)
          ?? .null,
        "input_items": .number(Double(input.count)),
      ])
    defer {
      measurement.elapsedMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
      measurement.completed = completed
      recordMetrics(measurement)
      TaskDiagnostics.shared.record(
        "model_request_finished",
        [
          "request_id": .string(requestID), "stage": .string(stage), "completed": .bool(completed),
          "elapsed_ms": .number((ProcessInfo.processInfo.systemUptime - started) * 1000),
        ])
    }
    var call = request(backend + "/responses")
    call.setValue("Bearer " + tokens.access, forHTTPHeaderField: "Authorization")
    call.setValue(tokens.account, forHTTPHeaderField: "ChatGPT-Account-Id")
    call.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    let encodingStarted = ProcessInfo.processInfo.systemUptime
    var body = modelConfiguration.requestBody(input: input, tools: tools).object!
    #if DEBUG
      if let benchmarkInstructions { body["instructions"] = .string(benchmarkInstructions) }
    #endif
    body["prompt_cache_key"] = .string(cacheKey)
    call.httpBody = try JSONValue.object(body).data()
    measurement.encodingMS = (ProcessInfo.processInfo.systemUptime - encodingStarted) * 1000
    measurement.requestBytes = call.httpBody?.count ?? 0
    stage = "http"
    let (bytes, response) = try await session.bytes(for: call)
    measurement.headersMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
    guard let http = response as? HTTPURLResponse else {
      throw SubscriptionFailure.invalid("模型请求没有 HTTP 响应")
    }
    TaskDiagnostics.shared.record(
      "model_http_response",
      [
        "request_id": .string(requestID), "status": .number(Double(http.statusCode)),
        "provider_request_id": .string(http.value(forHTTPHeaderField: "x-request-id") ?? ""),
        "content_type": .string(http.value(forHTTPHeaderField: "Content-Type") ?? ""),
      ])
    guard (200...299).contains(http.statusCode) else {
      throw SubscriptionFailure.http("模型请求", http.statusCode)
    }
    routing.receive(http)
    stage = "response_stream"
    var decoder = ModelWireDecoder(
      serverModel: http.value(forHTTPHeaderField: "openai-model")
        ?? http.value(forHTTPHeaderField: "x-openai-model"), configuration: modelConfiguration)
    var lastDelivery = ContinuousClock.now
    for try await byte in bytes {
      try Task.checkCancellation()
      measurement.responseBytes += 1
      let turn = try decoder.feed(byte)
      if measurement.firstEventMS == nil && decoder.eventCount > 0 {
        measurement.firstEventMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
      }
      if measurement.firstOutputMS == nil && decoder.hasOutput {
        measurement.firstOutputMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
      }
      if turn != nil || lastDelivery.duration(to: .now) >= .milliseconds(80) {
        decoder.drainUpdates().forEach(onMessage)
        lastDelivery = .now
      }
      if let turn {
        completed = true
        stage = "completed"
        measurement.usage = turn.usage
        measurement.actualServiceTier = turn.serviceTier
        recordReceipt(turn, requestID: requestID)
        return turn
      }
    }
    let turn = try decoder.finish()
    decoder.drainUpdates().forEach(onMessage)
    completed = true
    stage = "completed"
    measurement.usage = turn.usage
    measurement.actualServiceTier = turn.serviceTier
    recordReceipt(turn, requestID: requestID)
    return turn
  }

  private func recordReceipt(_ turn: AgentModelTurn, requestID: String) {
    if let status = modelConfiguration.serviceTierStatus(actual: turn.serviceTier),
      status != lastServiceTierStatus
    {
      lastServiceTierStatus = status
      onServiceTierStatus?(status)
    }
    TaskDiagnostics.shared.record(
      "model_receipt",
      [
        "request_id": .string(requestID), "actual_model": .string(turn.model),
        "actual_effort": turn.effort.map(JSONValue.string) ?? .null,
        "actual_service_tier": turn.serviceTier.map(JSONValue.string) ?? .null,
        "requested_service_tier": modelConfiguration.requestedServiceTier.map(JSONValue.string)
          ?? .null,
        "requested_model": .string(modelConfiguration.choice.id),
        "requested_effort": modelConfiguration.choice.effort.map(JSONValue.string) ?? .null,
      ])
  }
}

extension SubscriptionClient: AgentModelTransport {}
