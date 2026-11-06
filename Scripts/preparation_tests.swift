import Foundation

private func require(_ ok: @autoclosure () -> Bool, _ message: String) throws {
  if !ok() { throw SubscriptionFailure.invalid(message) }
}

@main struct PreparationTests {
  static func main() throws {
    let now = Date(timeIntervalSince1970: 1000)
    let model = CatalogModel(
      id: "fixture", name: "Fixture", description: "", efforts: ["low"], defaultEffort: "low",
      supportsOriginalImages: true, priority: 1, serviceTiers: [],
      additionalSpeedTiers: [], defaultServiceTier: nil)
    func rows(_ device: DevicePreparation, signedIn: Bool = true, paired: Bool = true,
      choice: ModelChoice = .init(id: "fixture", effort: "low"), error: String = "",
      catalogBusy: Bool = false, time: Date? = nil
    ) -> [PreparationRow] {
      PreparationChecklist.rows(
        signedIn: signedIn, paired: paired, models: [model], choice: choice,
        catalogBusy: catalogBusy, catalogError: error, catalogUpdatedAt: now,
        device: device, now: time ?? now)
    }
    var device = DevicePreparation()
    try require(!PreparationChecklist.allPassed(rows(device)), "Saved pairing mistaken for a live route")
    device.begin()
    device.connected()
    try require(!PreparationChecklist.allPassed(rows(device)), "Connection alone counted as screenshot/control")
    device.succeed(at: now)
    try require(PreparationChecklist.allPassed(rows(device)), "Verified full checklist did not pass")
    try require(!PreparationChecklist.allPassed(rows(device, paired: false)), "Missing pairing passed")
    try require(!PreparationChecklist.allPassed(rows(device, signedIn: false)), "Signed-out account passed")
    try require(!PreparationChecklist.allPassed([]), "Empty checklist passed")
    print("PASS all five prerequisites required; pairing or tunnel alone never implies readiness")

    try require(!PreparationChecklist.allPassed(rows(device, choice: .initial)), "Unavailable model passed")
    try require(!PreparationChecklist.allPassed(rows(device, choice: .init(id: "fixture", effort: "high"))), "Unsupported effort passed")
    try require(!PreparationChecklist.allPassed(rows(device, choice: .init(id: "fixture", effort: "low", fastMode: true))), "Unsupported Fast passed")
    try require(!PreparationChecklist.allPassed(rows(device, error: "offline")), "Failed auth/catalog request passed")
    try require(!PreparationChecklist.allPassed(rows(device, catalogBusy: true)), "In-flight catalog passed")
    print("PASS model identity, reasoning, Fast eligibility and failed/in-flight catalog remain distinct")

    try require(PreparationChecklist.allPassed(rows(device, time: now.addingTimeInterval(59))), "Fresh checks expire early")
    try require(!PreparationChecklist.allPassed(rows(device, time: now.addingTimeInterval(60))), "Expired check stayed green")
    try require(!PreparationChecklist.allPassed(rows(device, time: now.addingTimeInterval(-1))), "Clock rollback stayed green")
    device = .init()
    try require(!PreparationChecklist.allPassed(rows(device)), "Background invalidation stayed green")
    print("PASS expiry, clock rollback and clearing evidence require another connection check")

    device.begin(); device.fail("VPN unavailable", at: now)
    try require(device.route == .failed && device.control == .pending, "Route failure blamed screen")
    device.begin(); device.connected(); device.fail("Phone call in progress", at: now)
    let partial = rows(device)
    try require(partial.last?.mark == .failed && partial[3].mark == .passed, "Media failure lost route evidence")
    try require(!PreparationChecklist.allPassed(partial), "Partial success counted as ready")
    device.begin()
    try require(device.detail.isEmpty && device.checkedAt == nil && device.control == .pending, "Retry kept old evidence")
    print("PASS route versus media failure, partial success and retry clear stale evidence")
  }
}
