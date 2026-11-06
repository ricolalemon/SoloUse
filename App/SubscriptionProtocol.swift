// SPDX-License-Identifier: Apache-2.0
// Contains protocol/flow adaptations from OpenAI Codex, copyright 2025 OpenAI.
// Reimplemented/modified for SoloUse; see NOTICE and THIRD_PARTY_NOTICES.md.
import Foundation

enum SubscriptionFailure: Error, LocalizedError {
  case invalid(String)
  case http(String, Int)
  var errorDescription: String? {
    switch self {
    case .invalid(let message): return message
    case .http(let stage, let status): return "\(stage)：HTTP \(status)"
    }
  }
}

struct SubscriptionTokens: Codable {
  let access: String
  let refresh: String
  let id: String
  let account: String
  let plan: String
  let expires: Date

  // Claims are decoded only from tokens received over TLS from the fixed issuer.
  // Decoding is not signature verification or an independent authorization decision.
  static func claims(_ jwt: String) -> [String: Any] {
    let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return [:] }
    var part = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(
      of: "_", with: "/")
    part += String(repeating: "=", count: (4 - part.count % 4) % 4)
    guard let data = Data(base64Encoded: part),
      let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return claims
  }

  static func decode(_ response: [String: Any], previous: SubscriptionTokens? = nil) throws -> Self
  {
    guard let access = response["access_token"] as? String, !access.isEmpty,
      let refresh = response["refresh_token"] as? String ?? previous?.refresh, !refresh.isEmpty,
      let id = response["id_token"] as? String ?? previous?.id, !id.isEmpty
    else {
      throw SubscriptionFailure.invalid("登录响应缺少凭据，请重新登录")
    }
    let accessClaims = claims(access)
    let idClaims = claims(id)
    let auth = idClaims["https://api.openai.com/auth"] as? [String: Any] ?? [:]
    let accessAuth = accessClaims["https://api.openai.com/auth"] as? [String: Any] ?? [:]
    guard
      let account = auth["chatgpt_account_id"] as? String ?? accessAuth["chatgpt_account_id"]
        as? String,
      !account.isEmpty, !account.contains("\n"), !account.contains("\r")
    else {
      throw SubscriptionFailure.invalid("登录响应缺少订阅账户信息")
    }
    if let other = accessAuth["chatgpt_account_id"] as? String, other != account {
      throw SubscriptionFailure.invalid("登录响应中的账户不一致")
    }
    if let previous, previous.account != account {
      throw SubscriptionFailure.invalid("续期后的账户发生变化，请重新登录")
    }
    if auth["chatgpt_account_is_fedramp"] as? Bool == true
      || accessAuth["chatgpt_account_is_fedramp"] as? Bool == true
    {
      throw SubscriptionFailure.invalid("此实验尚未适配该工作区的专用服务入口")
    }
    let expiry = (accessClaims["exp"] as? NSNumber)?.doubleValue
    let expires =
      expiry.map(Date.init(timeIntervalSince1970:))
      ?? Date().addingTimeInterval((response["expires_in"] as? NSNumber)?.doubleValue ?? 3600)
    return Self(
      access: access, refresh: refresh, id: id, account: account,
      plan: auth["chatgpt_plan_type"] as? String ?? "unknown", expires: expires)
  }
}

struct DeviceAuthorization {
  let id: String
  let code: String
  let interval: Double
  init(_ response: [String: Any]) throws {
    guard let id = response["device_auth_id"] as? String,
      let code = response["user_code"] as? String ?? response["usercode"] as? String,
      !id.isEmpty, !code.isEmpty
    else { throw SubscriptionFailure.invalid("设备码响应不完整") }
    self.id = id
    self.code = code
    let supplied =
      (response["interval"] as? NSNumber)?.doubleValue ?? Double(
        response["interval"] as? String ?? "") ?? 5
    guard supplied.isFinite, supplied <= 900 else { throw SubscriptionFailure.invalid("设备码轮询间隔无效") }
    interval = max(5, supplied)
  }
}

struct SubscriptionSSE {
  private var dataLines: [String] = []
  private var size = 0
  mutating func feed(_ line: String) throws -> [String: Any]? {
    if line.isEmpty {
      defer {
        dataLines.removeAll(keepingCapacity: true)
        size = 0
      }
      guard !dataLines.isEmpty else { return nil }
      let body = dataLines.joined(separator: "\n")
      if body == "[DONE]" { return nil }
      guard let object = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
      else {
        throw SubscriptionFailure.invalid("模型事件格式无效")
      }
      return object
    }
    if line.hasPrefix("data:") {
      var value = String(line.dropFirst(5))
      if value.hasPrefix(" ") { value.removeFirst() }
      size += value.utf8.count
      guard size < 2_000_000 else { throw SubscriptionFailure.invalid("模型事件超过实验大小限制") }
      dataLines.append(value)
    }
    return nil
  }
}

// URLSession.AsyncBytes.lines omits empty lines on Apple platforms. SSE needs
// those delimiters, so frame bytes ourselves and preserve CR, LF, and CRLF.
struct SubscriptionSSEBytes {
  private var parser = SubscriptionSSE()
  private var line = Data()
  private var skipLF = false
  mutating func feed(_ byte: UInt8) throws -> [String: Any]? {
    if byte == 10, skipLF {
      skipLF = false
      return nil
    }
    skipLF = byte == 13
    if byte == 10 || byte == 13 {
      guard let text = String(data: line, encoding: .utf8) else {
        throw SubscriptionFailure.invalid("模型事件不是有效 UTF-8")
      }
      line.removeAll(keepingCapacity: true)
      return try parser.feed(text)
    }
    line.append(byte)
    guard line.count < 2_000_000 else { throw SubscriptionFailure.invalid("模型事件行超过实验大小限制") }
    return nil
  }
}
