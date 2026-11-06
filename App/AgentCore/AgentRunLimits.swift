import Foundation

struct AgentRunLimits: Equatable, Sendable {
  let turns: Int?
  let seconds: TimeInterval?
  init(turns: Int = 0, minutes: Int = 0) {
    self.turns = turns > 0 ? turns : nil
    self.seconds = minutes > 0 ? TimeInterval(minutes) * 60 : nil
  }
  func timeReached(start: TimeInterval, now: TimeInterval) -> Bool {
    guard let seconds else { return false }
    return now - start >= seconds
  }
  var label: String {
    let rounds = turns.map { "\($0) 轮后暂停" } ?? "不限轮数"
    let duration = seconds.map { "\(Int($0 / 60)) 分钟后暂停" } ?? "不限时长"
    return rounds + " · " + duration
  }
}
