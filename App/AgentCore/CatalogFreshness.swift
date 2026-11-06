import Foundation

struct CatalogFreshness {
  private(set) var updatedAt: Date?
  private(set) var attemptedAt: Date?

  func needsRefresh(at now: Date = Date()) -> Bool {
    // Retry failures after one minute; refresh successful catalogs after five.
    // Treat clock rollback as stale rather than suppressing refresh indefinitely.
    if let attemptedAt, (0..<60).contains(now.timeIntervalSince(attemptedAt)) { return false }
    guard let updatedAt else { return true }
    return !(0..<300).contains(now.timeIntervalSince(updatedAt))
  }

  mutating func attempted(at now: Date = Date()) { attemptedAt = now }
  mutating func received(at now: Date = Date()) { updatedAt = now }
  mutating func reset() { self = .init() }
}
