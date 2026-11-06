#if DEBUG
  import SwiftUI

  struct NotificationReplyTestView: View {
    @ObservedObject private var notifications = TaskNotifications.shared
    @ObservedObject private var agent = PhoneAgentModel.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    var body: some View {
      NavigationStack {
        ScrollView {
          SoloCard {
            VStack(alignment: .leading, spacing: 20) {
              TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, Int(ceil(notifications.replyTestFireAt?.timeIntervalSince(context.date) ?? 0)))
                VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 13) {
                  Image(systemName: notifications.replyTestStage == "passed" ? "checkmark.circle.fill" : "bell.badge")
                    .font(.title).foregroundStyle(SoloStyle.accent)
                  VStack(alignment: .leading, spacing: 8) {
                    Text(title(remaining)).font(.headline)
                    Text(notifications.replyTestMessage.isEmpty ? L10n.text("发送一条通知，检查能否直接回复。") : L10n.text(notifications.replyTestMessage))
                      .font(.callout).foregroundStyle(.secondary)
                  }
                }
                if notifications.replyTestSending {
                  ProgressView().padding(.top, 12)
                } else {
                  Button {
                    Task { await notifications.sendReplyTest(force: true) }
                  } label: {
                    Label(notifications.replyTestStage == "idle" ? L10n.text("发送测试通知") : L10n.text("重新发送"), systemImage: "paperplane")
                      .frame(maxWidth: .infinity).padding(.vertical, 5)
                  }.buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 12)
                    .disabled(remaining > 0 || agent.busy || agent.pendingHandoff != nil)
                }
                }
              }
              if notifications.replyTestStage != "passed" {
                Text(L10n.text("没有看到横幅时，可以在通知中心找到测试通知。"))
                  .font(.caption).foregroundStyle(.secondary)
              }
              Button(L10n.text("通知设置"), systemImage: "bell") { showSettings = true }.font(.subheadline)
              Text(L10n.text("测试不会运行手机任务。")).font(.caption).foregroundStyle(.secondary)
            }
          }.padding(20)
        }.background(SoloStyle.canvas).tint(SoloStyle.accent)
          .navigationTitle(L10n.text("通知回复测试")).navigationBarTitleDisplayMode(.inline)
          .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("完成")) { dismiss() } } }
          .sheet(isPresented: $showSettings) { TaskNotificationSettingsView() }
          .task {
            await notifications.refreshReplyTest()
            if ProcessInfo.processInfo.arguments.contains("--solouse-notification-test") {
              try? await Task.sleep(for: .seconds(9))
              NotificationSettingsCheck.capture(imageName: "notification-reply-test")
            }
          }
          .onChange(of: notifications.replyTestStage) { _, stage in
            if stage == "passed", ProcessInfo.processInfo.arguments.contains("--solouse-notification-test") {
              Task {
                try? await Task.sleep(for: .milliseconds(500))
                NotificationSettingsCheck.capture(imageName: "notification-reply-test-passed")
              }
            }
          }
          .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await notifications.refreshReplyTest() } }
          }
      }
    }
    private func title(_ remaining: Int) -> String {
      switch notifications.replyTestStage {
      case "idle": L10n.text("发送测试通知")
      case "preparing": L10n.text("准备发送")
      case "scheduled": remaining > 0 ? L10n.text("约 \(remaining) 秒后发出") : L10n.text("等待通知回复")
      case "passed": L10n.text("测试通过")
      case "failed": L10n.text("测试未完成")
      case "stopped": L10n.text("测试已停止")
      default: L10n.text("等待通知回复")
      }
    }
  }
#endif
