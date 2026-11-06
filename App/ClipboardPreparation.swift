import Foundation
import UIKit

enum ClipboardPreparationError: Error, LocalizedError {
  case unavailable, changed, tooLarge, verificationFailed
  var errorDescription: String? {
    switch self {
    case .unavailable: return "无法读取剪贴板，请在 SoloUse 中允许粘贴后重试。"
    case .changed: return "剪贴板已变化，未继续更改，请重新开始或继续任务。"
    case .tooLarge: return "剪贴板内容超过本机备份容量，原内容未更改。"
    case .verificationFailed: return "本机剪贴板副本未通过校验，请检查后重试。"
    }
  }
}
private final class ClipboardPreparationCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  func cancel() { lock.lock(); cancelled = true; lock.unlock() }
  func check() throws {
    lock.lock(); let value = cancelled; lock.unlock()
    if value { throw CancellationError() }
  }
}

enum ClipboardPreparation {
  private static let queue = DispatchQueue(label: "dev.solouse.clipboard-preparation", qos: .userInitiated)
  @MainActor static func prepare() async throws -> JSONValue {
    guard UIApplication.shared.applicationState == .active else {
      throw ClipboardPreparationError.unavailable
    }
    let cancellation = ClipboardPreparationCancellation()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        queue.async {
          do {
            let result = try prepareSynchronously(cancellation)
            continuation.resume(returning: result)
          } catch { continuation.resume(throwing: error) }
        }
      }
    } onCancel: { cancellation.cancel() }
  }
  private static func read(_ board: UIPasteboard, rawItems: [[String: Any]]? = nil) throws -> ClipboardContents {
    let count = board.numberOfItems
    guard count <= 64 else { throw ClipboardPreparationError.tooLarge }
    let raw = rawItems ?? board.items
    guard raw.count == count else { throw ClipboardPreparationError.changed }
    var items: [[String: Data]] = []
    var total = 0
    for (index, source) in raw.enumerated() {
      guard !source.isEmpty else { throw ClipboardPreparationError.unavailable }
      var item: [String: Data] = [:]
      for (type, value) in source {
        let data: Data
        if let bytes = value as? Data {
          // Materialize mutable/dispatch-backed Foundation data before leaving
          // the authorized foreground read. No lazy external providers remain.
          data = bytes.withUnsafeBytes { Data($0) }
        } else if let representations = board.data(forPasteboardType: type, inItemSet: IndexSet(integer: index)),
          representations.count == 1, let bytes = representations.first {
          data = bytes.withUnsafeBytes { Data($0) }
        } else { throw ClipboardPreparationError.unavailable }
        total += data.count
        guard total <= 2_000_000 else { throw ClipboardPreparationError.tooLarge }
        item[type] = data
      }
      items.append(item)
    }
    return ClipboardContents(items: items)
  }
  private static func write(_ contents: ClipboardContents, to board: UIPasteboard) {
    board.setItems(contents.items.map { $0.mapValues { $0 as Any } }, options: [.localOnly: true])
  }
  private static func prepareSynchronously(_ cancellation: ClipboardPreparationCancellation) throws -> JSONValue {
    try cancellation.check()
    let board = UIPasteboard.general
    let started = ProcessInfo.processInfo.systemUptime
    let before = board.changeCount
    // Public type lists can omit transport annotations. Obtain the authorized
    // item dictionaries first, but never mistake a redacted item for empty data.
    let declaredCount = board.numberOfItems
    let rawItems = board.items
    guard rawItems.count == declaredCount, !rawItems.contains(where: { $0.isEmpty }) else {
      throw ClipboardPreparationError.unavailable
    }
    let original = try read(board, rawItems: rawItems)
    try cancellation.check()
    guard board.changeCount == before else { throw ClipboardPreparationError.changed }
    // Local delayed providers can also fail through CoreDevice. Materialize
    // those too; a remote-origin marker is not required for this recovery.
    let local = original.localCopy
    guard !local.items.isEmpty else { throw ClipboardPreparationError.unavailable }
    write(local, to: board)
    let owned = board.changeCount
    do {
      let verified = try read(board)
      guard board.changeCount == owned, verified == local else {
        throw ClipboardPreparationError.verificationFailed
      }
    } catch {
      // A newer user copy takes precedence. Never restore over their change.
      if board.changeCount == owned { write(original, to: board) }
      throw error
    }
    return .object(["localized_remote_copy": .bool(original.isRemoteCopy), "local_copy_prepared": .bool(true), "payload_verified": .bool(true),
      "formats_preserved": .number(Double(local.formats)), "bytes_preserved": .number(Double(local.bytes)),
      "elapsed_ms": .number((ProcessInfo.processInfo.systemUptime - started) * 1000)])
  }
}
