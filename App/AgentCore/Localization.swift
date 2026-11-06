import Foundation

enum AppLanguage: String, CaseIterable {
  case system, chinese = "zh-Hans", english = "en"
  static let defaultsKey = "app.language"
  func resolved(preferred: [String] = Locale.preferredLanguages) -> AppLanguage {
    guard self == .system else { return self }
    for tag in preferred {
      if tag.lowercased().hasPrefix("zh") { return .chinese }
      if tag.lowercased().hasPrefix("en") { return .english }
    }
    return .english
  }
  var locale: Locale { Locale(identifier: resolved().rawValue) }
}

// Presentation-only catalog. Internal tool messages and stored conversations
// stay unchanged. Call only for app-owned labels/status, never user/model prose.
struct LocalizationCatalog {
  struct Entry: Codable { let zh: String; let en: String }
  let entries: [String: Entry]
  private struct Template {
    let regex: NSRegularExpression
    let indices: [String]
    let entry: Entry
  }
  private let exact: [String: Entry]
  private let templates: [Template]
  init(data: Data) throws {
    entries = try JSONDecoder().decode([String: Entry].self, from: data)
    var exact: [String: Entry] = [:]
    var templates: [Template] = []
    let slot = try NSRegularExpression(pattern: #"\{([0-9]+)\}"#)
    for key in entries.keys.sorted(by: { $0.count > $1.count }) {
      let entry = entries[key]!
      // English aliases also let saved app-owned messages follow later changes.
      for source in Set([key, entry.zh, entry.en]) {
        let ns = source as NSString
        let matches = slot.matches(in: source, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { exact[source] = entry; continue }
        var pattern = "\\A", cursor = 0, indices: [String] = []
        for match in matches {
          pattern += NSRegularExpression.escapedPattern(for: ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
          pattern += "(.*?)"; indices.append(ns.substring(with: match.range(at: 1)))
          cursor = NSMaxRange(match.range)
        }
        pattern += NSRegularExpression.escapedPattern(for: ns.substring(from: cursor)) + "\\z"
        templates.append(Template(regex: try NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators), indices: indices, entry: entry))
      }
    }
    // Canonical keys take precedence over aliases with the same translation.
    for (key, entry) in entries where !key.contains("{0}") { exact[key] = entry }
    self.exact = exact; self.templates = templates
  }
  func text(_ source: String, language: AppLanguage, depth: Int = 0) -> String {
    let selected = language.resolved()
    if let value = exact[source] { return selected == .chinese ? value.zh : value.en }
    guard depth < 4 else { return source }
    let ns = source as NSString, range = NSRange(location: 0, length: ns.length)
    for template in templates {
      guard let match = template.regex.firstMatch(in: source, range: range) else { continue }
      var value = selected == .chinese ? template.entry.zh : template.entry.en
      // Substitute in one pass: an argument containing “{1}” stays literal.
      var arguments: [String: String] = [:]
      for (offset, index) in template.indices.enumerated() {
        let raw = ns.substring(with: match.range(at: offset + 1))
        arguments[index] = text(raw, language: selected, depth: depth + 1)
      }
      let slot = try! NSRegularExpression(pattern: #"\{([0-9]+)\}"#)
      let original = value as NSString
      for item in slot.matches(in: value, range: NSRange(location: 0, length: original.length)).reversed() {
        let index = original.substring(with: item.range(at: 1))
        if let replacement = arguments[index], let range = Range(item.range, in: value) {
          value.replaceSubrange(range, with: replacement)
        }
      }
      return value
    }
    // Run-limit/status components are composed with this separator internally.
    if source.contains(" · ") {
      return source.components(separatedBy: " · ").map { text($0, language: selected, depth: depth + 1) }.joined(separator: " · ")
    }
    return source
  }
}

enum L10n {
  static var language: AppLanguage {
    (AppLanguage(rawValue: UserDefaults.standard.string(forKey: AppLanguage.defaultsKey) ?? "system") ?? .system).resolved()
  }
  static var locale: Locale { language.locale }
  private static let catalog: LocalizationCatalog = {
    let data = Bundle.main.url(forResource: "Localizations", withExtension: "json")
      .flatMap { try? Data(contentsOf: $0) } ?? Data("{}".utf8)
    return (try? LocalizationCatalog(data: data)) ?? (try! LocalizationCatalog(data: Data("{}".utf8)))
  }()
  static func text(_ source: String) -> String { catalog.text(source, language: language) }
  static func time(_ date: Date) -> String {
    date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
  }
  static func toolDetail(_ source: String) -> String {
    text(PhoneConnectionFailure.recognizedMessage(source) ?? source)
  }
}
