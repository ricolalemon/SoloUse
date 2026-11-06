import SwiftUI

struct TaskNotificationSettingsView: View {
  @ObservedObject private var notifications = TaskNotifications.shared
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          SoloCard {
            VStack(alignment: .leading, spacing: 16) {
              HStack(alignment: .top, spacing: 12) {
                Image(
                  systemName: notifications.permission.canNotify ? "bell.badge.fill" : "bell.slash"
                )
                .font(.title2).foregroundStyle(
                  notifications.permission.canNotify ? SoloStyle.accent : .secondary
                )
                .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 6) {
                  Text(L10n.text(notifications.permission.title)).font(.headline)
                  if !notifications.permission.detail.isEmpty {
                    Text(L10n.text(notifications.permission.detail)).font(.callout).foregroundStyle(.secondary)
                  }
                }
              }
              if notifications.permission.status == .unknown {
                ProgressView(L10n.text("读取系统设置…")).font(.caption)
              } else if notifications.permission.canRequest {
                Button {
                  Task { await notifications.prepare() }
                } label: {
                  HStack {
                    if notifications.requestingPermission {
                      ProgressView().tint(Color(uiColor: .systemBackground))
                    }
                    Text(notifications.requestingPermission ? L10n.text("等待系统授权…") : L10n.text("开启任务通知"))
                  }.foregroundStyle(Color(uiColor: .systemBackground))
                    .frame(maxWidth: .infinity).padding(.vertical, 5)
                }.buttonStyle(.borderedProminent).controlSize(.large)
                  .disabled(notifications.requestingPermission)
              } else {
                Button {
                  Task { await notifications.openSystemSettings() }
                } label: {
                  Label(L10n.text("前往系统设置"), systemImage: "arrow.up.right.square")
                    .foregroundStyle(Color(uiColor: .systemBackground))
                    .frame(maxWidth: .infinity).padding(.vertical, 5)
                }.buttonStyle(.borderedProminent).controlSize(.large)
              }
              if !notifications.permissionError.isEmpty {
                Text(L10n.text(notifications.permissionError)).font(.caption).foregroundStyle(.orange)
              }
            }
          }
          if notifications.permission.canNotify {
            SoloCard {
              VStack(alignment: .leading, spacing: 14) {
                Text(L10n.text("提醒方式")).font(.subheadline.weight(.semibold))
                setting(L10n.text("横幅或提醒"), enabled: notifications.permission.banners)
                setting(L10n.text("锁定屏幕"), enabled: notifications.permission.lockScreen)
                setting(L10n.text("通知中心"), enabled: notifications.permission.notificationCenter)
                setting(L10n.text("声音"), enabled: notifications.permission.sound)
              }
            }
          }
          VStack(alignment: .leading, spacing: 13) {
            Label(L10n.text("长按通知回复"), systemImage: "bubble.left.and.bubble.right")
            Label(L10n.text("在 App 内直接查看任务进度"), systemImage: "iphone")
          }.font(.callout).foregroundStyle(.secondary)
          Text(L10n.text("提醒可能受专注模式或通知摘要影响。"))
            .font(.caption).foregroundStyle(.secondary)
          Button(L10n.text("刷新状态"), systemImage: "arrow.clockwise") {
            Task { await notifications.refresh() }
          }.font(.subheadline).disabled(notifications.requestingPermission)
        }.padding(20)
      }.background(SoloStyle.canvas).tint(SoloStyle.accent)
        .navigationTitle(L10n.text("任务通知")).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("完成")) { dismiss() } } }
        .task {
          await notifications.refresh()
          #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--solouse-show-notification-settings") {
              try? await Task.sleep(for: .milliseconds(1500))
              NotificationSettingsCheck.capture()
            }
          #endif
        }
        .onChange(of: scenePhase) { _, phase in
          if phase == .active { Task { await notifications.refresh() } }
        }
    }
  }
  private func setting(_ title: String, enabled: Bool) -> some View {
    HStack {
      Text(title).font(.subheadline)
      Spacer()
      Text(enabled ? L10n.text("已开启") : L10n.text("未开启")).font(.subheadline)
        .foregroundStyle(enabled ? SoloStyle.accent : .secondary)
    }
  }
}

#if DEBUG
  import UIKit
  // Read-only inspection: no permission prompt, test notification, phone command or model call.
  @MainActor enum NotificationSettingsCheck {
    static func capture(imageName: String = "notification-settings") {
      let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      if let data = try? JSONEncoder().encode(TaskNotifications.shared.permission) {
        try? data.write(
          to: directory.appendingPathComponent("notification-permission-check.json"),
          options: .atomic)
      }
      guard
        let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
          .flatMap({ $0.windows }).first(where: { $0.isKeyWindow })
      else { return }
      let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      }
      try? image.pngData()?.write(
        to: directory.appendingPathComponent(imageName + ".png"), options: .atomic)
    }
  }
#endif
