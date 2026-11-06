import Foundation
import UIKit
import UserNotifications

@MainActor
final class TaskNotifications: NSObject, UNUserNotificationCenterDelegate, ObservableObject {
  static let shared = TaskNotifications()
  @Published private(set) var authorization = L10n.text("通知尚未开启")
  @Published private(set) var permission = NotificationPermission()
  @Published private(set) var requestingPermission = false
  @Published private(set) var permissionError = ""
  private var permissionRequest: Task<NotificationPermissionUpdate, Never>?
  private var delivered: Set<String> = []
  #if DEBUG
    @Published private(set) var replyTestStage = "idle"
    @Published private(set) var replyTestMessage = ""
    @Published private(set) var replyTestSending = false
    @Published private(set) var replyTestFireAt: Date?
    @Published private(set) var replyTestOpenRequest = UUID()
    private var replyTestRunID: UUID?
    private static let replyTestCategory = "solouse.notification-reply-test"
  #endif
  func configure() {
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    configureQuestion(PhoneAgentModel.shared.pendingHandoff?.question)
  }
  private func configureQuestion(_ question: AgentQuestion?) {
    var categories: Set<UNNotificationCategory> = [makeQuestionCategory(
      choices: question?.choices ?? [], id: QuestionNotificationAction.category)]
    #if DEBUG
      categories.insert(makeQuestionCategory(choices: [L10n.text("收到"), L10n.text("稍后")], id: Self.replyTestCategory))
    #endif
    UNUserNotificationCenter.current().setNotificationCategories(categories)
  }
  private func makeQuestionCategory(choices: [String], id: String) -> UNNotificationCategory {
    var actions: [UNNotificationAction] = choices.enumerated().map {
      index, title in
      UNNotificationAction(
        identifier: QuestionNotificationAction.choicePrefix + String(index),
        title: title, options: [.authenticationRequired])
    }
    actions.append(
      UNTextInputNotificationAction(
        identifier: QuestionNotificationAction.replyID, title: id == QuestionNotificationAction.category ? L10n.text("回复并继续") : L10n.text("回复"),
        options: [.authenticationRequired],
        textInputButtonTitle: L10n.text("发送"), textInputPlaceholder: L10n.text("输入你的回答")))
    actions.append(
      UNNotificationAction(
        identifier: QuestionNotificationAction.stopID,
        title: id == QuestionNotificationAction.category ? L10n.text("停止任务") : L10n.text("停止测试"), options: [.authenticationRequired, .destructive]))
    return UNNotificationCategory(
      identifier: id,
      actions: actions, intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: L10n.text("有问题等待你回复"),
      options: [])
  }
  func prepare() async {
    if let permissionRequest {
      _ = await permissionRequest.value
      return
    }
    permissionError = ""
    requestingPermission = true
    let request = Task { @MainActor in
      await NotificationPermissionRequest.prepare(
        read: { Self.snapshot(await UNUserNotificationCenter.current().notificationSettings()) },
        request: {
          _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [
            .alert, .sound,
          ])
        })
    }
    permissionRequest = request
    let result = await request.value
    permission = result.permission
    authorization = permission.title
    permissionError = result.error ?? ""
    requestingPermission = false
    permissionRequest = nil
  }
  func refresh() async {
    updateAuthorization(await UNUserNotificationCenter.current().notificationSettings())
  }
  func openSystemSettings() async {
    permissionError = ""
    if let url = URL(string: UIApplication.openNotificationSettingsURLString),
      await UIApplication.shared.open(url)
    {
      return
    }
    if let url = URL(string: UIApplication.openSettingsURLString),
      await UIApplication.shared.open(url)
    {
      return
    }
    permissionError = L10n.text("无法打开系统设置。请手动前往「设置 → 通知 → SoloUse」。")
  }
  private func updateAuthorization(_ settings: UNNotificationSettings) {
    permission = Self.snapshot(settings)
    authorization = permission.title
  }
  private static func snapshot(_ settings: UNNotificationSettings) -> NotificationPermission {
    let status: NotificationPermission.Status
    switch settings.authorizationStatus {
    case .notDetermined: status = .notDetermined
    case .denied: status = .denied
    case .authorized: status = .authorized
    case .provisional: status = .provisional
    case .ephemeral: status = .ephemeral
    @unknown default: status = .unknown
    }
    return .init(
      status: status, banners: settings.alertSetting == .enabled,
      lockScreen: settings.lockScreenSetting == .enabled,
      notificationCenter: settings.notificationCenterSetting == .enabled,
      sound: settings.soundSetting == .enabled)
  }
  private func canDeliver() async -> Bool {
    let settings = await UNUserNotificationCenter.current().notificationSettings()
    updateAuthorization(settings)
    return [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
  }
  private func add(_ content: UNMutableNotificationContent, id: String) async {
    do {
      try await UNUserNotificationCenter.current().add(
        UNNotificationRequest(identifier: id, content: content, trigger: nil))
      delivered.insert(id)
    } catch { authorization = L10n.text("通知未能送达，请在任务页回复") }
  }
  func send(runID: UUID, phase: TaskPhase, sequence: Int) async {
    guard
      let notice = TaskNotice.make(
        runID: runID, phase: phase, sequence: sequence,
        foreground: UIApplication.shared.applicationState == .active),
      !delivered.contains(notice.id), await canDeliver()
    else { return }
    let content = UNMutableNotificationContent()
    content.title = L10n.text(notice.title)
    content.body = L10n.text(notice.body)
    content.sound = .default
    content.threadIdentifier = runID.uuidString
    content.userInfo = ["solouse_task": runID.uuidString]
    await add(content, id: notice.id)
  }
  static func questionNoticeID(runID: UUID, questionID: UUID) -> String {
    "solouse.\(runID.uuidString).question.\(questionID.uuidString)"
  }
  func sendQuestion(runID: UUID, question: AgentQuestion) async {
    guard await canDeliver(),
      PhoneAgentModel.shared.matchesQuestion(runID: runID, questionID: question.id)
    else { return }
    let content = questionContent(runID: runID, question: question)
    let id = Self.questionNoticeID(runID: runID, questionID: question.id)
    await add(content, id: id)
    if !PhoneAgentModel.shared.matchesQuestion(runID: runID, questionID: question.id) {
      clearQuestion(runID: runID, questionID: question.id)
    }
  }
  private func questionContent(runID: UUID, question: AgentQuestion) -> UNMutableNotificationContent
  {
    configureQuestion(question)
    let content = UNMutableNotificationContent()
    content.title = L10n.text("SoloUse 等待你的回复")
    // This is the question the user must answer, respecting the system's preview settings.
    content.body = question.text
    content.categoryIdentifier = QuestionNotificationAction.category
    content.sound = .default
    content.threadIdentifier = runID.uuidString
    content.userInfo = [
      "solouse_task": runID.uuidString, "solouse_question": question.id.uuidString,
    ]
    return content
  }
  #if DEBUG
    func sendReplyTest(force: Bool = false) async {
      guard !replyTestSending else { return }
      if !force, ["scheduled", "waiting", "passed"].contains(replyTestStage) { return }
      if let replyTestFireAt, replyTestFireAt > Date() { return }
      guard !PhoneAgentModel.shared.busy, PhoneAgentModel.shared.pendingHandoff == nil else {
        replyTestStage = "failed"
        replyTestMessage = L10n.text("请在当前任务结束后测试通知。")
        return
      }
      replyTestSending = true
      replyTestStage = "preparing"
      replyTestMessage = L10n.text("正在检查通知权限…")
      defer { replyTestSending = false }
      await prepare()
      guard await canDeliver() else {
        replyTestStage = "failed"
        replyTestMessage = permissionError.isEmpty ? L10n.text("通知尚未开启，请前往系统设置允许通知。") : permissionError
        return
      }
      guard !PhoneAgentModel.shared.busy, PhoneAgentModel.shared.pendingHandoff == nil else {
        replyTestStage = "failed"; replyTestMessage = L10n.text("请在当前任务结束后测试通知。")
        return
      }
      do {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: ["solouse.notification-test"])
        let state = try NotificationReplySelfTest.prepare()
        replyTestRunID = state.runID
        configureQuestion(PhoneAgentModel.shared.pendingHandoff?.question)
        let content = UNMutableNotificationContent()
        content.title = L10n.text("SoloUse 通知回复测试")
        content.body = L10n.text("长按这条通知，选择「收到」或输入一句回复。")
        content.categoryIdentifier = Self.replyTestCategory
        content.sound = .default
        content.threadIdentifier = state.runID.uuidString
        content.userInfo = ["solouse_task": state.runID.uuidString, "solouse_question": state.question.id.uuidString]
        content.userInfo["solouse_notification_test"] = true
        try await center.add(
          UNNotificationRequest(
            identifier: "solouse.notification-test", content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 7, repeats: false)))
        replyTestFireAt = Date().addingTimeInterval(7)
        replyTestStage = "scheduled"
        replyTestMessage = L10n.text("长按测试通知，选择「收到」或输入回复。可以停留在此页。")
        ProbeModel.shared.log(["kind": "notification_test_scheduled", "delay_seconds": 7])
      } catch {
        replyTestStage = "failed"
        replyTestMessage = L10n.text("通知测试未能启动，请重试。")
        ProbeModel.shared.log(["kind": "notification_test_schedule_failed", "message": error.localizedDescription])
      }
    }
    func refreshReplyTest() async {
      await refresh()
      guard !replyTestSending, ["idle", "scheduled", "waiting"].contains(replyTestStage) else { return }
      guard let result = NotificationReplySelfTest.latestResult(),
        let status = result["status"] as? String,
        let run = result["run_id"] as? String,
        replyTestRunID == nil || replyTestRunID?.uuidString == run else { return }
      if ["passed", "stopped", "failed"].contains(status) {
        replyTestRunID = UUID(uuidString: run)
        updateReplyTest(status)
      }
    }
    private func updateReplyTest(_ status: String) {
      replyTestFireAt = nil
      replyTestStage = status
      switch status {
      case "passed": replyTestMessage = L10n.text("已收到你的回复，测试通过。")
      case "stopped": replyTestMessage = L10n.text("测试已停止。")
      case "failed": replyTestMessage = L10n.text("回复未能保存，请重新测试。")
      default: replyTestMessage = L10n.text("长按测试通知，选择一个选项或输入回复。")
      }
    }
  #endif
  func sendRecovery(runID: UUID, questionID: UUID) async {
    guard UIApplication.shared.applicationState != .active, await canDeliver(),
      let pending = PhoneAgentModel.shared.pendingHandoff,
      pending.runID == runID, pending.question.id == questionID
    else { return }
    let content = UNMutableNotificationContent()
    content.title = L10n.text("SoloUse 需要恢复连接")
    content.body =
      pending.answer == nil ? L10n.text("后台连接已结束。你仍可回复问题，之后打开 SoloUse 继续。") : L10n.text("你的回答已保存。打开 SoloUse，点继续原任务。")
    content.sound = .default
    content.threadIdentifier = runID.uuidString
    content.userInfo = ["solouse_task": runID.uuidString]
    await add(content, id: "solouse.\(runID).recovery.\(questionID)")
  }
  func clearQuestion(runID: UUID, questionID: UUID) {
    let id = Self.questionNoticeID(runID: runID, questionID: questionID)
    let center = UNUserNotificationCenter.current()
    center.removePendingNotificationRequests(withIdentifiers: [id])
    center.removeDeliveredNotifications(withIdentifiers: [id])
  }
  func clear(runID: UUID) {
    let center = UNUserNotificationCenter.current()
    Task {
      let notices = await center.deliveredNotifications()
      center.removeDeliveredNotifications(
        withIdentifiers: notices.filter {
          $0.request.content.userInfo["solouse_task"] as? String == runID.uuidString
        }.map { $0.request.identifier })
    }
  }
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let info = response.notification.request.content.userInfo
    let taskID = (info["solouse_task"] as? String).flatMap(UUID.init(uuidString:))
    let questionID = (info["solouse_question"] as? String).flatMap(UUID.init(uuidString:))
    let action = QuestionNotificationAction.parse(
      identifier: response.actionIdentifier,
      text: (response as? UNTextInputNotificationResponse)?.userText,
      isDefault: response.actionIdentifier == UNNotificationDefaultActionIdentifier)
    Task { @MainActor in
      let lease = TaskHandoffLease()
      defer {
        lease.end()
        completionHandler()
      }
      guard let taskID else { return }
      #if DEBUG
        if info["solouse_notification_test"] as? Bool == true {
          let status = NotificationReplySelfTest.handle(action, runID: taskID, questionID: questionID)
          if let status { self.updateReplyTest(status) }
          if action == .open { self.replyTestOpenRequest = UUID() }
          return
        }
      #endif
      if action == .open {
        PhoneAgentModel.shared.openDetails(for: taskID)
        return
      }
      guard let questionID else { return }
      let accepted = PhoneAgentModel.shared.notificationAction(
        action, runID: taskID, questionID: questionID)
      ProbeModel.shared.log([
        "kind": "notification_action", "accepted": accepted,
        "text_reply": response is UNTextInputNotificationResponse,
      ])
      if accepted, PhoneAgentModel.shared.needsHandoffRecovery {
        await sendRecovery(runID: taskID, questionID: questionID)
      }
    }
  }
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    #if DEBUG
      if notification.request.content.userInfo["solouse_notification_test"] as? Bool == true {
        let run = notification.request.content.userInfo["solouse_task"] as? String
        Task { @MainActor in
          if run == self.replyTestRunID?.uuidString, self.replyTestStage == "scheduled" {
            self.updateReplyTest("waiting")
          }
          ProbeModel.shared.log(["kind": "notification_test_foreground_presentation_requested"])
        }
        completionHandler([.banner, .list, .sound])
        return
      }
    #endif
    // The foreground conversation presents questions inline.
    completionHandler([])
  }
}
