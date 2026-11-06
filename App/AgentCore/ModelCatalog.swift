import Foundation

struct ModelChoice: Codable, Equatable, Sendable {
  let id: String
  let effort: String?
  let fastMode: Bool
  init(id: String, effort: String?, fastMode: Bool = false) {
    self.id = id
    self.effort = effort
    self.fastMode = fastMode
  }
  private enum CodingKeys: String, CodingKey { case id, effort, fastMode }
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(String.self, forKey: .id)
    effort = try values.decodeIfPresent(String.self, forKey: .effort)
    fastMode = try values.decodeIfPresent(Bool.self, forKey: .fastMode) ?? false
  }
  static let initial = ModelChoice(id: "gpt-6-astra", effort: "low")
}

struct CatalogServiceTier: Equatable, Sendable {
  let id: String
  let name: String
  let description: String
}

struct CatalogModel: Identifiable, Equatable, Sendable {
  let id: String
  let name: String
  let description: String
  let efforts: [String]
  let defaultEffort: String?
  let supportsOriginalImages: Bool
  let priority: Double
  let serviceTiers: [CatalogServiceTier]
  let additionalSpeedTiers: [String]
  let defaultServiceTier: String?
  var supportsFastMode: Bool {
    serviceTiers.contains { ["priority", "fast"].contains($0.id) }
      || additionalSpeedTiers.contains("fast")
  }

  func configuration(for choice: ModelChoice) throws -> ModelRunConfiguration {
    guard choice.id == id,
      choice.effort.map({ efforts.contains($0) }) ?? efforts.isEmpty
    else { throw SubscriptionFailure.invalid("所选模型或推理强度已不可用，请重新选择") }
    guard !choice.fastMode || supportsFastMode else {
      throw SubscriptionFailure.invalid("当前账号目录未提供此模型的 Fast，请在模型菜单关闭 Fast 或选择支持的模型")
    }
    return .init(choice: choice, name: name, supportsOriginalImages: supportsOriginalImages)
  }
}

enum ModelCatalog {
  // Wire compatibility with the inspected Codex runtime; SoloUse identifies itself separately.
  static let clientVersion = "0.162.0"
  static func parse(_ value: JSONValue) throws -> [CatalogModel] {
    guard let entries = value["models"].array else {
      throw SubscriptionFailure.invalid("模型目录格式无效")
    }
    var seen = Set<String>()
    return entries.compactMap { item -> CatalogModel? in
      guard let id = item["slug"].string, !id.isEmpty, id.count <= 200,
        item["visibility"].string == "list",
        (item["input_modalities"].array ?? [.string("text"), .string("image")])
          .contains(.string("image")), seen.insert(id).inserted
      else { return nil }
      var seenEfforts = Set<String>()
      let efforts = (item["supported_reasoning_levels"].array ?? []).compactMap {
        row -> String? in
        guard let effort = row["effort"].string, !effort.isEmpty,
          seenEfforts.insert(effort).inserted
        else { return nil }
        return effort
      }
      let preferred = item["default_reasoning_level"].string
      return CatalogModel(
        id: id, name: item["display_name"].string ?? id,
        description: item["description"].string ?? "", efforts: efforts,
        defaultEffort: preferred.flatMap { efforts.contains($0) ? $0 : nil } ?? efforts.first,
        supportsOriginalImages: item["supports_image_detail_original"].bool ?? false,
        priority: item["priority"].number ?? 999,
        serviceTiers: (item["service_tiers"].array ?? []).compactMap { tier in
          guard let id = tier["id"].string, !id.isEmpty else { return nil }
          return CatalogServiceTier(
            id: id, name: tier["name"].string ?? id,
            description: tier["description"].string ?? "")
        },
        additionalSpeedTiers: (item["additional_speed_tiers"].array ?? []).compactMap(\.string),
        defaultServiceTier: item["default_service_tier"].string)
    }.sorted { $0.priority == $1.priority ? $0.id < $1.id : $0.priority < $1.priority }
  }

  static func resolve(_ choice: ModelChoice, in models: [CatalogModel]) throws
    -> ModelRunConfiguration
  {
    guard let model = models.first(where: { $0.id == choice.id }) else {
      throw SubscriptionFailure.invalid("当前订阅未列出所选模型，请打开模型菜单重新选择")
    }
    return try model.configuration(for: choice)
  }
}

struct ModelRunConfiguration: Codable, Equatable, Sendable {
  let choice: ModelChoice
  let name: String
  let supportsOriginalImages: Bool
  static let initial = ModelRunConfiguration(
    choice: .initial, name: "GPT-6 Astra", supportsOriginalImages: true)
  var label: String {
    name + (choice.effort.map { " · " + $0 } ?? "") + (choice.fastMode ? " · Fast ⚡" : "")
  }
  // Codex ServiceTier::Fast maps to priority on the wire. An explicit standard
  // selection omits the field; catalog defaults never silently enable Fast.
  var requestedServiceTier: String? { choice.fastMode ? "priority" : nil }
  var routingHint: String? {
    guard !choice.id.isEmpty, choice.id.utf8.count <= 200,
      choice.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) })
    else { return nil }
    return "model=" + choice.id + (requestedServiceTier.map { ";tier=" + $0 } ?? "")
  }
  func serviceTierStatus(actual: String?) -> String? {
    guard choice.fastMode else { return nil }
    switch actual {
    case "priority", "fast": return "Fast：服务端已确认"
    case "default": return "已请求 Fast；服务端回执未确认加速档位"
    case nil: return "已请求 Fast；服务端未返回实际速度档位"
    default: return "已请求 Fast；本轮服务端返回其他速度档位，详见诊断记录"
    }
  }

  func accepts(model: String) -> Bool {
    if model == choice.id { return true }
    let pattern =
      "^" + NSRegularExpression.escapedPattern(for: choice.id)
      + "-[0-9]{4}-[0-9]{2}-[0-9]{2}$"
    return model.range(of: pattern, options: .regularExpression) != nil
  }

  // Image bytes and coordinate metadata remain identical across supported detail modes.
  func prepare(_ value: JSONValue) -> JSONValue {
    switch value {
    case .array(let values): return .array(values.map(prepare))
    case .object(let fields):
      var result = fields.mapValues(prepare)
      if result["type"]?.string == "input_image" {
        result["detail"] = .string(supportsOriginalImages ? "original" : "high")
      }
      return .object(result)
    default: return value
    }
  }

  func requestBody(input: [JSONValue], tools: [JSONValue]) -> JSONValue {
    var body: [String: JSONValue] = [
      "model": .string(choice.id), "store": .bool(false), "stream": .bool(true),
      "instructions": .string(PhoneTools.instructions),
      "input": prepare(.array(input)), "tools": .array(tools), "tool_choice": .string("auto"),
      "parallel_tool_calls": .bool(false),
    ]
    if let effort = choice.effort {
      body["reasoning"] = .object(["effort": .string(effort)])
      body["include"] = .array([.string("reasoning.encrypted_content")])
    }
    if let tier = requestedServiceTier { body["service_tier"] = .string(tier) }
    return .object(body)
  }
}
