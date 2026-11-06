import Foundation

// Application identity follows local signing configuration, not the author's team.
enum RuntimeIdentifiers {
  static var app: String { Bundle.main.bundleIdentifier ?? "dev.solouse.probe" }
  static var prefix: String {
    Bundle.main.object(forInfoDictionaryKey: "SoloUseBundlePrefix") as? String ?? "dev.solouse"
  }
  static var lab: String { prefix + ".lab" }
  static var backgroundTask: String { app + ".session" }
}
