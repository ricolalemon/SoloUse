import Foundation

struct AgentQuestion: Codable, Equatable, Sendable {
  let id: UUID
  let text: String
  let choices: [String]
  init(id: UUID = UUID(), text: String, choices: [String] = []) {
    self.id = id
    self.text = text
    self.choices = choices
  }
}

struct PendingHandoff: Codable, Sendable {
  let runID: UUID
  let question: AgentQuestion
  let call: AgentToolCall
  var conversation: AgentConversation
  let model: ModelRunConfiguration
  let accountTag: String
  let readOnly: Bool
  let turnLimit: Int
  let runtimeMinutes: Int
  let turns: Int
  let calls: Int
  var answer: String?

  mutating func accept(runID: UUID, questionID: UUID, text: String) -> Bool {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard runID == self.runID, questionID == question.id, answer == nil,
      !text.isEmpty, text.utf8.count <= 16_384
    else { return false }
    answer = text
    return true
  }
  func answeredConversation() throws -> AgentConversation {
    guard let answer else { throw AgentLoopError.protocolError("尚未收到问题的回答") }
    var value = conversation
    try value.resolveHandoff(call: call, answer: answer)
    return value
  }
}

enum QuestionNotificationAction: Equatable {
  case open
  case reply(String)
  case choice(Int)
  case stop, ignored
  static let category = "solouse.question"
  static let replyID = "solouse.reply"
  static let stopID = "solouse.stop"
  static let choicePrefix = "solouse.choice."
  static func parse(identifier: String, text: String?, isDefault: Bool) -> Self {
    if isDefault { return .open }
    if identifier == replyID, let text { return .reply(text) }
    if identifier == stopID { return .stop }
    if identifier.hasPrefix(choicePrefix),
      let index = Int(identifier.dropFirst(choicePrefix.count)), (0..<2).contains(index)
    {
      return .choice(index)
    }
    return .ignored
  }
}
