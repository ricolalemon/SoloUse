import Foundation

struct NotificationPermission: Codable, Equatable, Sendable {
  enum Status: String, Codable, Sendable {
    case unknown, notDetermined, denied, authorized, provisional, ephemeral
  }
  var status: Status = .unknown
  var banners = false
  var lockScreen = false
  var notificationCenter = false
  var sound = false
  var canNotify: Bool { [.authorized, .provisional, .ephemeral].contains(status) }
  var canRequest: Bool { status == .notDetermined }
  var title: String {
    switch status {
    case .unknown: return "正在读取通知状态"
    case .notDetermined: return "未设置"
    case .denied: return "未开启"
    case .authorized: return "已开启"
    case .provisional: return "静默通知"
    case .ephemeral: return "临时允许"
    }
  }
  var detail: String {
    switch status {
    case .unknown: return ""
    case .notDetermined: return "接收任务结果和回复提醒。"
    case .denied: return "前往系统设置，打开「允许通知」。"
    case .authorized: return "任务结束或需要回复时通知你。"
    case .provisional: return "通知以静默方式送达。"
    case .ephemeral: return "通知权限暂时有效。"
    }
  }
}

struct NotificationPermissionUpdate: Sendable {
  let permission: NotificationPermission
  var error: String? = nil
}

@MainActor enum NotificationPermissionRequest {
  // Subsequent taps must read the stored decision, not pretend another prompt was shown.
  static func prepare(
    read: () async -> NotificationPermission,
    request: () async throws -> Void
  ) async -> NotificationPermissionUpdate {
    let current = await read()
    guard current.canRequest else { return .init(permission: current) }
    do {
      try await request()
      return .init(permission: await read())
    } catch {
      return .init(permission: await read(), error: "无法请求通知权限，请稍后重试或前往系统设置。")
    }
  }
}
