import Combine
import Foundation

@MainActor final class PhoneHealthCheck: ObservableObject {
  static let shared = PhoneHealthCheck()
  @Published private(set) var busy = false
  @Published private(set) var status = ""
  private var task: Task<Void, Never>?
  private let driver = NativePhoneDriver.shared
  func start() {
    guard !busy, !ProbeModel.shared.busy, !PhoneAgentModel.shared.busy,
      !SubscriptionModel.shared.busy, !PhonePreparationModel.shared.busy
    else { return }
    TaskDiagnostics.shared.begin(id: UUID(), kind: "health_check")
    busy = true
    status = "连接并读取应用列表…"
    task = Task {
      let started = ContinuousClock.now
      do {
        ProbeModel.shared.presentAgentStatus(.connecting, detail: "通用工具自检", turns: 0, calls: 0)
        try await driver.start(readOnly: false)
        let before = ContinuousClock.now
        let apps = try await driver.perform(
          action: .object(["op": .string("list_apps")]), id: "health_apps")
        guard apps.status == "executed", let count = apps.value["apps"].array?.count, count > 0
        else { throw AgentLoopError.protocolError("应用列表自检失败") }
        let inventoryElapsed = before.duration(to: .now)
        ProbeModel.shared.log([
          "kind": "health_inventory_passed", "count": count,
          "elapsed_ms": Int(
            inventoryElapsed.components.seconds * 1000 + inventoryElapsed.components.attoseconds
              / 1_000_000_000_000_000),
        ])
        status = "应用列表读取成功；即将回主屏幕观察 70 秒"
        ProbeModel.shared.presentAgentStatus(.acting, detail: "后台自检 70 秒", turns: 0, calls: 1)
        let home = try await driver.perform(
          action: .object(["op": .string("home")]), id: "health_home")
        guard home.status == "executed" else {
          throw AgentLoopError.needsAttention("Home 自检结果不确定，已停止")
        }
        for index in 0..<14 {
          let wait = try await driver.perform(
            action: .object(["op": .string("wait"), "milliseconds": .number(5000)]),
            id: "health_wait_\(index)")
          guard wait.status == "executed" else { throw AgentLoopError.protocolError("后台会话提前结束") }
          ProbeModel.shared.presentAgentStatus(
            .acting, detail: "后台自检 \((index+1)*5)/70 秒", turns: 0, calls: index + 3)
        }
        let frame = try await driver.perform(
          action: .object(["op": .string("observe")]), id: "health_observe")
        guard frame.status == "executed" else { throw AgentLoopError.protocolError("后台截图失败") }
        let elapsed = started.duration(to: .now)
        status = "自检通过：应用列表和 70 秒后台截图正常"
        ProbeModel.shared.presentAgentStatus(.completed, detail: "自检通过", turns: 0, calls: 17)
        ProbeModel.shared.log([
          "kind": "health_check_passed", "app_count": count,
          "elapsed_seconds": elapsed.components.seconds, "model_calls": 0,
        ])
      } catch {
        status = Task.isCancelled ? "自检已停止" : error.localizedDescription
        ProbeModel.shared.log(["kind": "health_check_failed", "message": status])
      }
      let handoff = TaskHandoffLease()
      defer { handoff.end() }
      await driver.close(reason: "health_check_complete")
      TaskDiagnostics.shared.finish(status)
      busy = false
      task = nil
    }
  }
  func stop() {
    task?.cancel()
    driver.cancel(reason: "health_stop_button")
  }
}
