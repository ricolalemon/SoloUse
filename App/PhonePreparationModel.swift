import Combine
import Foundation
import UIKit

@MainActor final class PhonePreparationModel: ObservableObject {
  static let shared = PhonePreparationModel()
  @Published private(set) var busy = false
  @Published private(set) var device = DevicePreparation()
  private var operation: Task<Void, Never>?
  private var timeout: Task<Void, Never>?
  private var ownsSession = false
  private var timedOut = false
  private let driver = NativePhoneDriver.shared

  #if DEBUG
    init(preview: DevicePreparation) { device = preview }
  #endif
  init() {}

  func start() {
    guard UIApplication.shared.applicationState == .active, !busy,
      !PhoneAgentModel.shared.busy, !ProbeModel.shared.busy,
      !SubscriptionModel.shared.busy, !ModelSelection.shared.busy,
      driver.sessionID == nil, solo_is_running() == 0 else { return }
    busy = true
    timedOut = false
    device = .init()
    TaskDiagnostics.shared.begin(id: UUID(), kind: "preparation_check")
    operation = Task {
      if SubscriptionModel.shared.signedIn { await ModelSelection.shared.refresh() }
      ProbeModel.shared.refreshPaired()
      if ProbeModel.shared.paired && !Task.isCancelled {
        device.begin()
        ownsSession = true
        do {
          ProbeModel.shared.presentAgentStatus(.connecting, detail: "检查准备状态", turns: 0, calls: 0)
          try await driver.start(readOnly: true)
          device.connected()
          let frame = try await driver.perform(
            action: .object(["op": .string("observe")]), id: "preparation_observe")
          guard frame.status == "executed", !frame.images.isEmpty else {
            throw AgentLoopError.protocolError("无法读取屏幕，请保持手机解锁后重试")
          }
          try Task.checkCancellation()
          // Publish success only after releasing the temporary connection.
          ProbeModel.shared.presentAgentStatus(.completed, detail: "检查完成", turns: 0, calls: 1)
          await driver.close(reason: "preparation_complete")
          try Task.checkCancellation()
          device.succeed()
        } catch {
          let message = failureMessage(error.localizedDescription)
          await driver.close(reason: "preparation_failed")
          if timedOut { device.fail("连接检查超时，请检查 LocalDevVPN 后重试") }
          else if Task.isCancelled { device = .init() }
          else { device.fail(message) }
        }
        ownsSession = false
      }
      timeout?.cancel()
      timeout = nil
      ProbeModel.shared.log([
        "kind": "preparation_check_finished", "route": device.route.rawValue,
        "control": device.control.rawValue, "model_calls": 0, "phone_mutations": 0,
      ])
      TaskDiagnostics.shared.finish(device.control == .passed ? "检查通过" : "检查结束")
      busy = false
      operation = nil
    }
    timeout = Task {
      do { try await Task.sleep(for: .seconds(60)) } catch { return }
      guard busy else { return }
      timedOut = true
      stop()
    }
  }

  // RSD proves the authenticated local route independently of media/HID setup.
  func receivedRSD() {
    guard busy, ownsSession, operation?.isCancelled != true else { return }
    device.connected()
  }
  func stop() {
    operation?.cancel()
    if ownsSession {
      ProbeModel.shared.presentAgentStatus(.stopped, detail: "检查已停止", turns: 0, calls: 0)
      driver.cancel(reason: "preparation_cancelled")
    }
  }
  func invalidate() {
    stop()
    device = .init()
  }
  private func failureMessage(_ raw: String) -> String {
    if let known = PhoneConnectionFailure.recognizedMessage(raw) { return known }
    if raw.contains("Connection refused") {
      return ProbeModel.shared.developerPortDiscovered
        ? "已发现本机开发服务，但端口拒绝连接。请保持手机解锁后重新检查"
        : "未发现本机开发服务，默认端口拒绝连接。请保持 Wi‑Fi 和开发者模式开启后重试"
    }
    if raw.contains("pair_verify") {
      return "本机配对验证未通过，请在设备页检查配对状态"
    }
    if raw.contains("Background task denied") || raw.contains("后台会话") {
      return "系统未能启动后台会话，请稍后重试"
    }
    if device.route != .passed { return "无法连接本机。请连接 LocalDevVPN 后重试" }
    return "屏幕或控制服务不可用。请保持手机解锁，检查开发者模式后重试"
  }
}
