import SwiftUI

struct PreparationCard: View {
  @ObservedObject var preparation: PhonePreparationModel
  @ObservedObject var account: SubscriptionModel
  @ObservedObject var probe: ProbeModel
  @ObservedObject var selection: ModelSelection
  @ObservedObject private var agent = PhoneAgentModel.shared
  @ObservedObject private var notifications = TaskNotifications.shared
  var onAccount: () -> Void
  var onDevice: () -> Void
  var onModel: () -> Void
  var onNotifications: () -> Void
  private var locked: Bool {
    preparation.busy || agent.busy || account.busy || probe.busy || selection.busy
  }
  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let rows = PreparationChecklist.rows(
        signedIn: account.signedIn, paired: probe.paired, models: selection.models,
        choice: selection.choice, catalogBusy: selection.busy, catalogError: selection.error,
        catalogUpdatedAt: selection.updatedAt, device: preparation.device, now: context.date)
      let ready = PreparationChecklist.allPassed(rows) && !preparation.busy
      SoloCard {
        VStack(alignment: .leading, spacing: 16) {
          HStack {
            Text(L10n.text("使用准备")).font(.headline)
            Spacer()
            StateBadge(
              text: preparation.busy ? L10n.text("检查中") : ready ? L10n.text("可以开始") : "\(rows.filter { $0.mark == .passed }.count) / 5",
              color: ready ? SoloStyle.accent : .secondary)
          }
          VStack(spacing: 13) {
            ForEach(rows) { row in
              Button { open(row.id) } label: {
                HStack(alignment: .top, spacing: 11) {
                  mark(row.mark).frame(width: 22, height: 22)
                  VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text(row.title)).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                    Text(L10n.text(row.detail)).font(.caption)
                      .foregroundStyle(row.mark == .failed ? .orange : .secondary)
                      .fixedSize(horizontal: false, vertical: true)
                  }
                  Spacer(minLength: 0)
                  if row.mark != .passed {
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                      .padding(.top, 5)
                  }
                }.contentShape(Rectangle())
              }.buttonStyle(.plain).disabled(locked)
                .accessibilityLabel("\(L10n.text(row.title)), \(stateLabel(row.mark)), \(L10n.text(row.detail))")
            }
          }
          if preparation.busy {
            Button(L10n.text("停止检查"), systemImage: "stop.circle") { preparation.stop() }
              .buttonStyle(.bordered).frame(maxWidth: .infinity)
          } else {
            Button { preparation.start() } label: {
              Label(ready ? L10n.text("重新检查") : L10n.text("检查准备状态"), systemImage: "arrow.triangle.2.circlepath")
                .frame(maxWidth: .infinity).padding(.vertical, 3)
            }.buttonStyle(.borderedProminent).controlSize(.large).disabled(locked)
          }
          if let date = preparation.device.checkedAt {
            Text(L10n.text("检查于 \(L10n.time(date)) · 开始任务时会重新连接"))
              .font(.caption2).foregroundStyle(.secondary)
          }
          Divider()
          Button(action: onNotifications) {
            HStack(spacing: 9) {
              Image(systemName: notifications.permission.canNotify ? "bell.badge" : "bell")
              Text(L10n.text("任务通知")).font(.caption)
              Text(L10n.text("可选")).font(.caption2).foregroundStyle(.secondary)
              Spacer()
              Text(notifications.permission.canNotify ? L10n.text("已开启") : L10n.text("设置")).font(.caption)
              Image(systemName: "chevron.right").font(.caption2)
            }.foregroundStyle(.secondary)
          }.buttonStyle(.plain).disabled(locked)
        }
      }
    }
  }
  private func open(_ id: String) {
    switch id {
    case "account": onAccount()
    case "model": onModel()
    case "pairing", "route": onDevice()
    default: preparation.start()
    }
  }
  @ViewBuilder private func mark(_ state: PreparationMark) -> some View {
    if state == .checking { ProgressView().controlSize(.small) }
    else {
      Image(systemName: state == .passed ? "checkmark.circle.fill" : state == .failed ? "exclamationmark.circle" : "circle")
        .foregroundStyle(state == .passed ? SoloStyle.accent : state == .failed ? .orange : .secondary)
    }
  }
  private func stateLabel(_ state: PreparationMark) -> String {
    switch state {
    case .pending: L10n.text("待检查")
    case .checking: L10n.text("检查中")
    case .passed: L10n.text("已通过")
    case .failed: L10n.text("未通过")
    }
  }
}

struct PreparationSheet: View {
  @ObservedObject var preparation: PhonePreparationModel
  @ObservedObject var account: SubscriptionModel
  @ObservedObject var probe: ProbeModel
  @ObservedObject var selection: ModelSelection
  var onAccount: () -> Void
  var onDevice: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var showModels = false
  @State private var showNotifications = false
  var body: some View {
    NavigationStack {
      ScrollView {
        PreparationCard(
          preparation: preparation, account: account, probe: probe, selection: selection,
          onAccount: { dismiss(); onAccount() }, onDevice: { dismiss(); onDevice() },
          onModel: { showModels = true }, onNotifications: { showNotifications = true }
        ).padding(20)
      }.background(SoloStyle.canvas)
        .navigationTitle(L10n.text("准备状态")).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("完成")) { dismiss() } } }
        .sheet(isPresented: $showModels) { ModelPickerView(selection: selection) }
        .sheet(isPresented: $showNotifications) { TaskNotificationSettingsView() }
    }
  }
}
