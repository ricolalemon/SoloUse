#if DEBUG
import UIKit

/// An explicit local launch argument submits a new ordinary task for rehearsals.
/// No altered model instructions, tool set, run budgets or game knowledge.
@MainActor enum DemoTaskLauncher {
  private static var consumed = false
  static func run(goal: String, continuing chatID: UUID? = nil) async {
    guard !consumed else { return }
    consumed = true
    let agent = PhoneAgentModel.shared
    let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let token = UUID().uuidString
    var report: [String: Any] = ["token": token, "status": "preparing"]
    func save() {
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: folder.appendingPathComponent("demo-launch-status.json"), options: .atomic)
      }
    }
    for _ in 0..<30 {
      if UIApplication.shared.applicationState == .active { break }
      try? await Task.sleep(for: .milliseconds(100))
    }
    guard UIApplication.shared.applicationState == .active, !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      goal.utf8.count <= 16_384, !agent.busy, agent.pendingHandoff == nil,
      !ProbeModel.shared.busy, !SubscriptionModel.shared.busy, !ModelSelection.shared.busy,
      !PhonePreparationModel.shared.busy, SubscriptionModel.shared.signedIn, ProbeModel.shared.paired else {
      report["status"] = "not_started"; report["error"] = "A task is active or the app is not ready."
      save(); return
    }
    report["original_chat_id"] = agent.runID?.uuidString
    if let chatID {
      guard agent.runID == chatID, agent.hasChatHistory else {
        report["status"] = "not_started"; report["error"] = "The expected conversation is not selected."
        save(); return
      }
    } else {
      guard agent.newChat() else {
        report["status"] = "not_started"; report["error"] = agent.storageStatus
        save(); return
      }
    }
    agent.taskText = goal
    agent.start()
    guard agent.busy, let runID = agent.runID else {
      report["status"] = "not_started"; report["error"] = agent.status
      save(); return
    }
    report["run_id"] = runID.uuidString
    // The local file is writable only through normal developer-container access.
    // Only this launch token/current run may stop the rehearsal; old files cannot.
    let control = folder.appendingPathComponent("demo-control.json")
    while agent.runID == runID, !Task.isCancelled {
      report["status"] = agent.busy ? "running" : "finished"
      report["phase"] = agent.phase.rawValue
      report["turns"] = agent.turns
      report["calls"] = agent.calls
      save()
      if !agent.busy { break }
      if let data = try? Data(contentsOf: control), data.count < 4096,
        let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        command["token"] as? String == token, command["stop"] as? Bool == true {
        try? FileManager.default.removeItem(at: control)
        agent.stop(reason: "explicit_demo_control")
      }
      try? await Task.sleep(for: .seconds(1))
    }
  }
}
#endif
