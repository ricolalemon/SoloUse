import Foundation

enum PreparationMark: String, Codable { case pending, checking, passed, failed }

struct PreparationRow: Identifiable {
  let id: String
  let title: String
  let mark: PreparationMark
  let detail: String
}

struct DevicePreparation {
  var route: PreparationMark = .pending
  var control: PreparationMark = .pending
  var detail = ""
  var checkedAt: Date?

  var isChecking: Bool { route == .checking || control == .checking }
  func fresh(at now: Date) -> Bool {
    guard let checkedAt else { return false }
    return (0..<60).contains(now.timeIntervalSince(checkedAt))
  }
  mutating func begin() {
    self = .init(route: .checking)
  }
  mutating func connected() { route = .passed; control = .checking }
  mutating func succeed(at now: Date = Date()) {
    route = .passed; control = .passed; checkedAt = now; detail = ""
  }
  mutating func fail(_ message: String, at now: Date = Date()) {
    if route == .passed { control = .failed } else { route = .failed; control = .pending }
    detail = message
    checkedAt = now
  }
  func rows(at now: Date) -> [PreparationRow] {
    let expired = !isChecking && checkedAt != nil && !fresh(at: now)
    let routeMark = expired && route == .passed ? PreparationMark.pending : route
    let controlMark = expired && control == .passed ? PreparationMark.pending : control
    return [
      .init(id: "route", title: "本地 VPN 通路", mark: routeMark,
        detail: routeMark == .failed ? detail : routeMark == .passed ? "本机连接已验证"
          : routeMark == .checking ? "正在连接这台 iPhone…" : "连接 LocalDevVPN 后检查"),
      .init(id: "control", title: "屏幕与控制", mark: controlMark,
        detail: controlMark == .failed ? detail : controlMark == .passed ? "截图与控制服务正常"
          : controlMark == .checking ? "正在检查屏幕与控制服务…" : "等待连接检查"),
    ]
  }
}

enum PreparationChecklist {
  static func rows(
    signedIn: Bool, paired: Bool, models: [CatalogModel], choice: ModelChoice,
    catalogBusy: Bool, catalogError: String, catalogUpdatedAt: Date?,
    device: DevicePreparation, now: Date
  ) -> [PreparationRow] {
    let modelMark: PreparationMark
    let modelDetail: String
    if !signedIn {
      modelMark = .pending; modelDetail = "登录后检查"
    } else if catalogBusy {
      modelMark = .checking; modelDetail = "正在读取模型目录…"
    } else if !catalogError.isEmpty {
      modelMark = .failed; modelDetail = "目录读取失败，请检查网络后重试"
    } else if let date = catalogUpdatedAt, (0..<300).contains(now.timeIntervalSince(date)) {
      do {
        let config = try ModelCatalog.resolve(choice, in: models)
        modelMark = .passed; modelDetail = config.label
      } catch {
        modelMark = .failed; modelDetail = error.localizedDescription
      }
    } else {
      modelMark = .pending; modelDetail = "等待刷新模型目录"
    }
    return [
      .init(id: "account", title: "ChatGPT 账号", mark: signedIn ? .passed : .pending,
        detail: signedIn ? "已登录" : "登录你的 ChatGPT / Codex 订阅"),
      .init(id: "model", title: "所选模型", mark: modelMark, detail: modelDetail),
      .init(id: "pairing", title: "本机配对", mark: paired ? .passed : .pending,
        detail: paired ? "配对记录已保存" : "前往设备页完成配对"),
    ] + device.rows(at: now)
  }
  static func allPassed(_ rows: [PreparationRow]) -> Bool {
    rows.count == 5 && rows.allSatisfy { $0.mark == .passed }
  }
}
