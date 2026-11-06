import Foundation

struct ModelUsage: Codable, Equatable, Sendable {
  let inputTokens: Int?
  let outputTokens: Int?
  let cachedInputTokens: Int?
  let reasoningTokens: Int?
  init(_ value: JSONValue) {
    func count(_ value: JSONValue) -> Int? {
      guard let n = value.number, n.isFinite, n >= 0, n < Double(Int.max) else { return nil }
      return Int(n)
    }
    inputTokens = count(value["input_tokens"])
    outputTokens = count(value["output_tokens"])
    cachedInputTokens = count(value["input_tokens_details"]["cached_tokens"])
    reasoningTokens = count(value["output_tokens_details"]["reasoning_tokens"])
  }
}

struct ModelContinuation {
  private var prefix: [JSONValue] = []
  private var tools: [JSONValue] = []
  private var responseID: String?
  func delta(input: [JSONValue], tools: [JSONValue]) -> (id: String, items: [JSONValue])? {
    guard let responseID, self.tools == tools, input.count >= prefix.count,
      input.prefix(prefix.count).elementsEqual(prefix)
    else { return nil }
    return (responseID, Array(input.dropFirst(prefix.count)))
  }
  mutating func commit(input: [JSONValue], tools: [JSONValue], turn: AgentModelTurn) {
    guard let id = turn.responseID, !id.isEmpty, id.utf8.count <= 1024 else {
      reset()
      return
    }
    prefix = input + turn.output
    self.tools = tools
    responseID = id
  }
  mutating func reset() {
    prefix = []
    tools = []
    responseID = nil
  }
}

struct ModelRequestMetrics: Codable, Sendable {
  let requestID: String
  let transport: String
  var mode = "full"
  var reusedConnection: Bool? = nil
  var fullInputItems = 0
  var sentInputItems = 0
  var requestBytes = 0
  var responseBytes = 0
  var encodingMS: Double = 0
  var headersMS: Double?
  var sendFinishedMS: Double?
  var firstEventMS: Double?
  var firstOutputMS: Double?
  var elapsedMS: Double = 0
  var completed = false
  var usage: ModelUsage?
  var requestedServiceTier: String?
  var actualServiceTier: String?
}
