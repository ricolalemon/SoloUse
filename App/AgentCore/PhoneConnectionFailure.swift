import Foundation

enum PhoneConnectionFailure {
  private static let callInProgress = "手机正在通话，暂时无法连接屏幕。请结束电话或语音通话后，再手动开始任务。"
  private static let displayInUse = "屏幕连接已被其他会话占用。请关闭其他屏幕共享或镜像连接后重试。"
  static func recognizedMessage(_ raw: String) -> String? {
    // Match the device's explicit reason, not merely a stage or a numeric code.
    if raw.contains("A phone or VoIP call is currently in progress") || raw == callInProgress {
      return callInProgress
    }
    if raw.contains("An existing display session is active") || raw == displayInUse {
      return displayInUse
    }
    return nil
  }

  static func displayMessage(_ raw: String) -> String {
    if let message = recognizedMessage(raw) { return message }
    // Keep native protocol objects and serialized byte arrays in diagnostics only.
    if raw.contains("Dictionary(") || raw.contains("Data([") || raw.count > 240 {
      return "手机连接失败。请在「调试记录」中查看详细错误。"
    }
    return raw
  }
}
