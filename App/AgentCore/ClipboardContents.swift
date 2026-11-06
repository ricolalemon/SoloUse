import Foundation

struct ClipboardContents: Equatable, Sendable {
  static let remoteOriginType = "com.apple.is-remote-clipboard"
  let items: [[String: Data]]
  var isRemoteCopy: Bool { items.contains { $0[Self.remoteOriginType] != nil } }
  var bytes: Int { items.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.count } } }
  var formats: Int { items.reduce(0) { $0 + $1.count } }
  var localCopy: Self {
    // Re-copying authorized content locally retires only the remote-origin
    // transport annotation. Confidential/transient and all payload types stay.
    Self(items: items.compactMap { item in
      let local = item.filter { $0.key != Self.remoteOriginType }
      return local.isEmpty ? nil : local
    })
  }
}
