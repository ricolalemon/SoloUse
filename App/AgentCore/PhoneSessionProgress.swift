import Foundation

// Finite progress for an ongoing media session. This is not a task deadline or
// an estimate of goal completion. A positive look-ahead window avoids reporting
// stalled/indeterminate progress to iOS while the live stream is doing work.
struct PhoneSessionProgress {
  private(set) var total: Int64 = 300
  private(set) var completed: Int64 = 1
  private var lastPackets = 0
  mutating func observe(seconds: Int, packets: Int) {
    guard packets > lastPackets else { return }
    lastPackets = packets
    completed = max(completed, Int64(min(Int.max / 2, max(1, seconds))))
    total = max(total, completed + 60)
  }
}
