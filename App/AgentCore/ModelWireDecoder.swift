import Foundation

struct ModelResponseCollector {
  var serverModel: String?
  private let configuration: ModelRunConfiguration
  private var responseID: String?
  private var usage: ModelUsage?
  private var serviceTier: String?
  private var items: [Int: JSONValue] = [:]
  private var itemIDs: [String: Int] = [:]
  init(serverModel: String?, configuration: ModelRunConfiguration = .initial) {
    self.serverModel = serverModel
    self.configuration = configuration
  }
  mutating func consume(_ raw: [String: Any]) throws -> AgentModelTurn? {
    let event = try JSONValue(raw)
    let type = event["type"].string ?? ""
    let response = event["response"]
    if let id = response["id"].string ?? event["response_id"].string { responseID = id }
    if response["usage"].object != nil { usage = ModelUsage(response["usage"]) }
    if let model = response["model"].string { serverModel = model }
    // Only the completion receipt establishes the tier actually used. Created
    // events may echo the request and must not be mistaken for confirmation.
    if type == "response.completed" { serviceTier = response["service_tier"].string }
    let headers = response["headers"].object ?? event["headers"].object ?? [:]
    for (name, value) in headers
    where ["openai-model", "x-openai-model"].contains(name.lowercased()) {
      if let model = value.string ?? value.array?.first?.string { serverModel = model }
    }
    if type == "response.output_item.done", case .object = event["item"] {
      let item = event["item"]
      if let n = event["output_index"].number, !n.isFinite || n < 0 || n > 10000 || n.rounded() != n
      {
        throw SubscriptionFailure.invalid("模型输出索引无效")
      }
      let index =
        event["output_index"].number.map(Int.init) ?? item["id"].string.flatMap { itemIDs[$0] }
        ?? items.count
      items[index] = item
      if let id = item["id"].string { itemIDs[id] = index }
    }
    if ["error", "response.failed", "response.incomplete"].contains(type) {
      throw SubscriptionFailure.invalid("模型未完成本轮响应：\(type)")
    }
    if type == "response.completed" {
      return try complete(response, completionEvent: true)
    }
    return nil
  }
  func complete(_ response: JSONValue, completionEvent: Bool = false) throws -> AgentModelTurn {
    guard let status = response["status"].string ?? (completionEvent ? "completed" : nil),
      status == "completed"
    else { throw SubscriptionFailure.invalid("模型响应未完成") }
    guard let model = response["model"].string ?? serverModel,
      configuration.accepts(model: model)
    else { throw SubscriptionFailure.invalid("服务端实际模型与所选模型不符（所选：\(configuration.choice.id)）") }
    let effort = response["reasoning"]["effort"].string
    if let effort, let requested = configuration.choice.effort, effort != requested {
      throw SubscriptionFailure.invalid("服务端实际推理强度与所选强度不符（所选：\(requested)）")
    }
    let output = response["output"].array ?? []
    let resolved = output.isEmpty ? items.keys.sorted().compactMap { items[$0] } : output
    guard !resolved.isEmpty else { throw SubscriptionFailure.invalid("模型完成回执没有输出") }
    for item in resolved where item["type"].string == "function_call" {
      guard let id = item["call_id"].string, !id.isEmpty, item["name"].string != nil,
        item["arguments"].string != nil
      else { throw SubscriptionFailure.invalid("模型工具调用不完整") }
    }
    return AgentModelTurn(
      output: resolved, model: model, effort: effort,
      responseID: response["id"].string ?? responseID,
      usage: response["usage"].object != nil ? ModelUsage(response["usage"]) : usage,
      serviceTier: response["service_tier"].string ?? serviceTier)
  }
}

struct ModelWireDecoder {
  private var parser = SubscriptionSSEBytes()
  private var collector: ModelResponseCollector
  private var data = Data()
  private var format: String?
  private var textStream = AgentTextStream()
  private(set) var eventCount = 0
  private(set) var hasOutput = false
  mutating func drainUpdates() -> [AgentMessageUpdate] { textStream.drain() }
  private mutating func consume(_ event: [String: Any]) throws -> AgentModelTurn? {
    eventCount += 1
    let type = event["type"] as? String ?? ""
    if type == "response.output_item.done" || type == "response.output_text.delta"
      || type == "response.function_call_arguments.delta"
    {
      hasOutput = true
    }
    textStream.consume(try JSONValue(event))
    let turn = try collector.consume(event)
    if let turn { textStream.finish(turn) }
    return turn
  }
  init(serverModel: String?, configuration: ModelRunConfiguration = .initial) {
    collector = ModelResponseCollector(serverModel: serverModel, configuration: configuration)
  }
  mutating func feed(_ byte: UInt8) throws -> AgentModelTurn? {
    data.append(byte)
    guard data.count < 8_000_000 else { throw SubscriptionFailure.invalid("模型响应过大") }
    if format == nil {
      if [9, 10, 13, 32].contains(byte) { return nil }
      if byte == 60 { throw SubscriptionFailure.invalid("模型接口返回了网页") }
      format = byte == 123 ? "json" : "sse"
    }
    if format == "sse", let event = try parser.feed(byte) { return try consume(event) }
    return nil
  }
  mutating func finish() throws -> AgentModelTurn {
    if format == "json" {
      let response = try JSONDecoder().decode(JSONValue.self, from: data)
      if response["type"].string == "response.completed",
        let object = try response.foundation() as? [String: Any],
        let turn = try consume(object)
      {
        return turn
      }
      let turn = try collector.complete(response)
      textStream.finish(turn)
      return turn
    }
    for _ in 0..<2 {
      if let event = try parser.feed(10), let turn = try consume(event) { return turn }
    }
    throw SubscriptionFailure.invalid("模型事件流提前结束，没有完成回执")
  }
}
