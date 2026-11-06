import Foundation
private func check(_ condition: Bool, _ message: String) throws {
  if !condition { throw AgentLoopError.protocolError(message) }
}
@main struct LocalizationTests {
  static func main() throws {
    let file = CommandLine.arguments[1]
    let catalog = try LocalizationCatalog(data: Data(contentsOf: URL(fileURLWithPath: file)))
    try check(catalog.entries.count > 500, "Catalog coverage unexpectedly small")
    let slots = try NSRegularExpression(pattern: #"\{[0-9]+\}"#)
    func placeholders(_ text: String) -> Set<String> {
      Set(slots.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { (text as NSString).substring(with: $0.range) })
    }
    for (key, value) in catalog.entries {
      try check(!value.zh.isEmpty && !value.en.isEmpty, "Empty translation: \(key)")
      try check(placeholders(value.zh) == placeholders(value.en) && placeholders(key) == placeholders(value.en), "Placeholder mismatch: \(key)")
      try check(!value.en.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }, "Chinese leaked into English entry: \(key)")
      // Keys, including template keys, must resolve in either language.
      try check(catalog.text(key, language: .english) == value.en, "English lookup mismatch: \(key)")
      try check(catalog.text(key, language: .chinese) == value.zh, "Chinese lookup mismatch: \(key)")
    }
    print("PASS all \(catalog.entries.count) catalog entries, both languages and matching placeholders")
    try check(catalog.text("24 轮 · 23 次工具调用", language: .english) == "24 turns · 23 tool calls", "Turn counts not localized")
    try check(catalog.text("聊天未能保存：聊天已删除", language: .english) == "Could not save chat: Chat deleted", "Nested app error not localized")
    try check(catalog.text("不限轮数 · 不限时长", language: .english) == "Unlimited turns · Unlimited runtime", "Combined labels not localized")
    try check(catalog.text("选择模型，当前 GPT-6.1-Sol🙂", language: .english) == "Choose model. Current: GPT-6.1-Sol🙂", "Unicode interpolation changed")
    try check(catalog.text("选择模型，当前 {1}", language: .english) == "Choose model. Current: {1}", "Placeholder-like argument was rewritten")
    try check(catalog.text("本次模型：GPT-6.1-Sol · low", language: .english) == "Model for this run: GPT-6.1-Sol · low", "Historical model-prefix label not localized")
    try check(catalog.text("观察屏幕 · 已执行", language: .english) == "Observe screen · Executed", "Action receipt suffix not localized")
    print("PASS dynamic counts, nested statuses, composed labels, Unicode and literal placeholders")
    try check(AppLanguage.system.resolved(preferred: ["zh-Hant-TW","en-US"]) == .chinese, "Chinese system language not resolved")
    try check(AppLanguage.system.resolved(preferred: ["en-US","zh-Hans"]) == .english, "English system language not resolved")
    try check(AppLanguage.system.resolved(preferred: ["de-DE"]) == .english, "Unsupported language fallback failed")
    try check(AppLanguage.chinese.resolved(preferred: ["en-US"]) == .chinese, "Manual override ignored")
    let defaults = UserDefaults(suiteName: "solouse-language-test-\(UUID())")!
    defaults.set(AppLanguage.english.rawValue, forKey: AppLanguage.defaultsKey)
    try check(AppLanguage(rawValue: defaults.string(forKey: AppLanguage.defaultsKey)!) == .english, "Preference did not persist")
    defaults.removeObject(forKey: AppLanguage.defaultsKey)
    print("PASS system matching, manual override, fallback and preference storage")
    let raw = "Observe SoloUse and handle its clipboard permission dialog before leaving the app. The model can use tap; no automatic permission response is sent."
    try check(catalog.text(raw, language: .chinese) == "等待粘贴授权。处理 SoloUse 的系统弹窗后，再切换应用。", "Clipboard hint not localized")
    try check(catalog.text(raw, language: .english).hasPrefix("Waiting for paste permission."), "Clipboard English not simplified")
    try check(catalog.text("unknown service detail 73", language: .chinese) == "unknown service detail 73", "Unknown diagnostic was invented")
    print("PASS historical clipboard hint and preservation of unknown raw details")
  }
}
