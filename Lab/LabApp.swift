import UIKit

// Independent GUI fixture. It never accepts text or success state from SoloUse.
// Only ordinary UIKit text input changes the field and its diagnostic report.
@main
final class LabApp: UIResponder, UIApplicationDelegate {
  func application(
    _ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    let config = UISceneConfiguration(name: "Lab", sessionRole: connectingSceneSession.role)
    config.delegateClass = LabScene.self
    return config
  }
}

final class LabScene: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let scene = scene as? UIWindowScene else { return }
    let window = UIWindow(windowScene: scene)
    window.rootViewController = LabController()
    window.makeKeyAndVisible()
    self.window = window
  }
}

final class LabTextField: UITextField {
  var onKeys: ((String, Set<UIPress>) -> Void)?
  var onPasteCheck: ((String, Bool) -> Void)?
  override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
    let allowed = super.canPerformAction(action, withSender: sender)
    if action == #selector(paste(_:)) { onPasteCheck?("can_paste", allowed) }
    return allowed
  }
  override func paste(_ sender: Any?) {
    onPasteCheck?("paste_invoked", true)
    super.paste(sender)
  }
  override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    onKeys?("down", presses)
    super.pressesBegan(presses, with: event)
  }
  override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    onKeys?("up", presses)
    super.pressesEnded(presses, with: event)
  }
}

final class LabController: UIViewController {
  private let titleLabel = UILabel()
  private let subtitle = UILabel()
  private let field = LabTextField()
  private let result = UILabel()
  private let runID = UUID().uuidString
  private var changes: [String] = []
  private var changeTimes: [Int64] = []
  private var keyEvents: [[String: Any]] = []
  private var pasteEvents: [[String: Any]] = []
  private let agentMode = ProcessInfo.processInfo.arguments.contains("--agent-lab")
  private lazy var fieldY: Double = {
    guard agentMode else { return 0.35 }
    let next = (UserDefaults.standard.integer(forKey: "lastAgentPosition") + 1) % 3
    UserDefaults.standard.set(next, forKey: "lastAgentPosition")
    return [0.32, 0.41, 0.50][next]
  }()
  private var focusEvents: [Bool] = []

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = UIColor(red: 0.035, green: 0.055, blue: 0.10, alpha: 1)
    titleLabel.text = "SoloUse Lab"
    titleLabel.textColor = .white
    titleLabel.font = .systemFont(ofSize: 32, weight: .bold)
    subtitle.text =
      agentMode
      ? "GUI INPUT PROBE\nLive model input test" : "GUI INPUT PROBE\n等待 SoloUse 自动输入 hello。"
    subtitle.textColor = .lightGray
    subtitle.font = .systemFont(ofSize: 16)
    subtitle.numberOfLines = 0
    field.borderStyle = .roundedRect
    field.backgroundColor = .white
    field.textColor = .black
    field.font = .systemFont(ofSize: 26, weight: .medium)
    field.placeholder = agentMode ? "Tap to type" : "等待自动输入…"
    field.autocorrectionType = .no
    field.autocapitalizationType = .none
    field.spellCheckingType = .no
    field.keyboardType = ProcessInfo.processInfo.arguments.contains("--system-keyboard") ? .default : .asciiCapable
    field.smartQuotesType = .no
    field.smartDashesType = .no
    field.accessibilityIdentifier = "solouse.lab.input"
    field.onKeys = { [weak self] stage, presses in
      guard let self else { return }
      for press in presses {
        if let key = press.key {
          self.keyEvents.append([
            "stage": stage, "code": key.keyCode.rawValue, "modifiers": key.modifierFlags.rawValue,
            "timestamp_ms": Int64(Date().timeIntervalSince1970 * 1000),
          ])
        }
      }
      self.writeReport()
    }
    field.onPasteCheck = { [weak self] stage, allowed in
      guard let self else { return }
      // Read only availability metadata; never inspect clipboard payloads.
      let board = UIPasteboard.general
      self.pasteEvents.append(["stage": stage, "allowed": allowed,
        "has_strings": board.hasStrings, "items": board.numberOfItems,
        "change_count": board.changeCount,
        "timestamp_ms": Int64(Date().timeIntervalSince1970 * 1000)])
      self.pasteEvents = Array(self.pasteEvents.suffix(120))
      self.writeReport()
    }
    field.addTarget(self, action: #selector(changed), for: .editingChanged)
    field.addTarget(self, action: #selector(focusChanged), for: [.editingDidBegin, .editingDidEnd])
    result.text = "尚未收到输入"
    result.textColor = .lightGray
    result.font = .systemFont(ofSize: 24, weight: .bold)
    result.numberOfLines = 0
    [titleLabel, subtitle, field, result].forEach(view.addSubview)
    writeReport()
  }
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let w = view.bounds.width
    let h = view.bounds.height
    titleLabel.frame = CGRect(x: 24, y: 100, width: w - 48, height: 45)
    subtitle.frame = CGRect(x: 24, y: 155, width: w - 48, height: 72)
    field.frame = CGRect(x: 24, y: h * fieldY - 30, width: w - 48, height: 60)
    result.frame = CGRect(x: 24, y: h * (fieldY + 0.09), width: w - 48, height: 80)
  }
  @objc private func changed() {
    let value = field.text ?? ""
    changes.append(value)
    changeTimes.append(Int64(Date().timeIntervalSince1970 * 1000))
    result.text =
      agentMode ? "Received: \(value)" : (value == "hello" ? "✓ 收到 hello" : "输入中：\(value)")
    result.textColor = agentMode ? .white : (value == "hello" ? .systemGreen : .white)
    writeReport()
  }
  @objc private func focusChanged() {
    focusEvents.append(field.isFirstResponder)
    writeReport()
  }
  private func writeReport() {
    var report: [String: Any] = [
      "run_id": runID, "timestamp_ms": Int64(Date().timeIntervalSince1970 * 1000),
      "text": field.text ?? "", "text_changes": changes, "key_events": keyEvents,
      "text_change_times_ms": changeTimes,
      "paste_events": pasteEvents,
      "agent_mode": agentMode, "field_center_y": fieldY, "focus_events": focusEvents,
      "input_language": field.textInputMode?.primaryLanguage ?? "unknown",
      "has_marked_text": field.markedTextRange != nil,
      "is_first_responder": field.isFirstResponder,
    ]
    if !agentMode { report["success"] = field.text == "hello" }
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    else { return }
    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("lab-result.json")
    try? data.write(to: url, options: .atomic)
  }
}
