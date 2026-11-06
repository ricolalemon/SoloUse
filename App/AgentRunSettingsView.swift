import SwiftUI

struct AgentRunSettingsView: View {
  @ObservedObject var model: PhoneAgentModel
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      Form {
        Section {
          Picker(L10n.text("模型轮数"), selection: $model.turnLimit) {
            Text(L10n.text("不限（默认）")).tag(0)
            Text(L10n.text("50 轮")).tag(50)
            Text(L10n.text("100 轮")).tag(100)
            Text(L10n.text("200 轮")).tag(200)
            Text(L10n.text("500 轮")).tag(500)
          }
          Picker(L10n.text("连续运行时长"), selection: $model.runtimeMinutes) {
            Text(L10n.text("不限（默认）")).tag(0)
            Text(L10n.text("5 分钟")).tag(5)
            Text(L10n.text("15 分钟")).tag(15)
            Text(L10n.text("30 分钟")).tag(30)
            Text(L10n.text("60 分钟")).tag(60)
          }
        } header: {
          Text(L10n.text("下一次任务"))
        } footer: {
          Text(L10n.text("默认不会按轮数或时长截断。若你设置上限，达到后会在下一步操作前暂停，保留当前上下文；点继续即可再运行一段。截图和工具选择也会占用模型轮次。"))
        }
        Section {
          Text(L10n.text("这不是订阅额度设置。运行仍会使用你的模型用量；网络错误、iOS 后台限制和内存容量问题会单独说明。"))
            .font(.footnote).foregroundStyle(.secondary)
        }
      }
      .scrollContentBackground(.hidden)
      .background(SoloStyle.canvas)
      .tint(SoloStyle.accent)
      .disabled(model.busy)
      .navigationTitle(L10n.text("运行设置")).navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("完成")) { dismiss() } } }
    }
  }
}
