#if DEBUG
  import UIKit

  @MainActor enum PreparationSelfTest {
    static func run() async {
      for _ in 0..<30 {
        if UIApplication.shared.applicationState == .active { break }
        try? await Task.sleep(for: .milliseconds(100))
      }
      let preparation = PhonePreparationModel.shared
      preparation.start()
      for _ in 0..<450 {
        if !preparation.busy { break }
        try? await Task.sleep(for: .milliseconds(200))
      }
      let selection = ModelSelection.shared
      let rows = PreparationChecklist.rows(
        signedIn: SubscriptionModel.shared.signedIn, paired: ProbeModel.shared.paired,
        models: selection.models, choice: selection.choice, catalogBusy: selection.busy,
        catalogError: selection.error, catalogUpdatedAt: selection.updatedAt,
        device: preparation.device, now: Date())
      let report: [String: Any] = [
        "generated_at": ISO8601DateFormatter().string(from: Date()),
        "ready": PreparationChecklist.allPassed(rows) && !preparation.busy,
        "busy": preparation.busy, "driver_closed": NativePhoneDriver.shared.sessionID == nil,
        "developer_port": Int(ProbeModel.shared.developerPort),
        "port_discovered_on_iphone": ProbeModel.shared.developerPortDiscovered,
        "rows": rows.map { ["id": $0.id, "state": $0.mark.rawValue, "detail": $0.detail] },
        "model_calls": 0, "phone_mutations": 0,
      ]
      let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: directory.appendingPathComponent("preparation-check.json"), options: .atomic)
      }
      try? await Task.sleep(for: .seconds(1))
      if let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
        .flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
          window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try? image.pngData()?.write(to: directory.appendingPathComponent("preparation-check.png"), options: .atomic)
      }
    }
  }
#endif
