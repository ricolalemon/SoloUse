import UIKit

// Keep enough execution time to persist the result and enqueue its local
// notification after the continued-processing phone session has been closed.
@MainActor final class TaskHandoffLease {
  private var identifier: UIBackgroundTaskIdentifier = .invalid
  init() {
    identifier = UIApplication.shared.beginBackgroundTask(withName: "SoloUse task handoff") {
      [weak self] in
      Task { @MainActor in self?.end() }
    }
  }
  func end() {
    guard identifier != .invalid else { return }
    let old = identifier
    identifier = .invalid
    UIApplication.shared.endBackgroundTask(old)
  }
}
