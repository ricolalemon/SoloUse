import Foundation

private enum TestFailure: Error {
  case failed(String)
  case systemError
}
@MainActor private final class Center {
  var permission: NotificationPermission
  var decision: NotificationPermission
  var requests = 0
  var reads = 0
  var fails = false
  init(_ permission: NotificationPermission, decision: NotificationPermission? = nil) {
    self.permission = permission
    self.decision = decision ?? permission
  }
  func read() async -> NotificationPermission {
    reads += 1
    return permission
  }
  func request() async throws {
    requests += 1
    if fails { throw TestFailure.systemError }
    permission = decision
  }
  func prepare() async -> NotificationPermissionUpdate {
    await NotificationPermissionRequest.prepare(
      read: { await self.read() }, request: { try await self.request() })
  }
}
@main struct NotificationPermissionTests {
  @MainActor static func main() async throws {
    func check(_ value: Bool, _ message: String) throws {
      if !value { throw TestFailure.failed(message) }
    }
    let granted = NotificationPermission(
      status: .authorized, banners: true, lockScreen: true, notificationCenter: true, sound: false)
    let first = Center(.init(status: .notDetermined), decision: granted)
    let result = await first.prepare()
    try check(
      first.requests == 1 && first.reads == 2 && result.permission == granted
        && result.error == nil,
      "The first request must reread actual settings after the system decision")
    _ = await first.prepare()
    try check(
      first.requests == 1,
      "Already allowed permission must not trigger another authorization request")
    print("PASS first grant rereads actual options; repeated enable does not request again")

    let denied = Center(.init(status: .notDetermined), decision: .init(status: .denied))
    let denial = await denied.prepare()
    try check(
      !denial.permission.canNotify && !denial.permission.canRequest,
      "Denied state incorrectly offers another system prompt")
    _ = await denied.prepare()
    try check(
      denied.requests == 1, "Repeated tap after denial must use Settings instead of re-requesting")
    denied.permission = granted  // User changes the permission in the Settings app.
    let afterSettings = await denied.prepare()
    try check(
      afterSettings.permission == granted && denied.requests == 1,
      "Settings changes must replace the old denial without another prompt")
    print("PASS denied request persists; later Settings change is observed without re-prompting")

    let broken = Center(.init(status: .notDetermined))
    broken.fails = true
    let error = await broken.prepare()
    try check(
      error.error != nil && !error.permission.canNotify && broken.reads == 2,
      "System errors must remain visible and must not claim enabled")
    print("PASS authorization errors surface and do not become false success")

    for status in [NotificationPermission.Status.provisional, .ephemeral] {
      let quiet = Center(.init(status: status, notificationCenter: true))
      let result = await quiet.prepare()
      try check(
        quiet.requests == 0 && result.permission.canNotify && !result.permission.banners
          && !result.permission.sound,
        "Limited delivery permission must preserve its actual presentation options")
    }
    let unknown = Center(.init())
    let unavailable = await unknown.prepare()
    try check(
      unknown.requests == 0 && !unavailable.permission.canNotify,
      "Unknown status must not be treated as enabled")
    print("PASS quiet/temporary permission and unknown state retain accurate capabilities")
  }
}
