import SwiftUI
import UIKit

struct DeviceView: View {
  @ObservedObject var model: ProbeModel
  @ObservedObject var preparation = PhonePreparationModel.shared
  @ObservedObject private var selection = ModelSelection.shared
  var onOpenAccount: () -> Void = {}
  @State private var showModels = false
  @State private var showNotifications = false
  @ObservedObject private var agent = PhoneAgentModel.shared
  @ObservedObject private var account = SubscriptionModel.shared
  @State private var showSteps = false
  @State private var showLanguage = false
  private var locked: Bool { model.busy || agent.busy || account.busy || preparation.busy || selection.busy }
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("连接这台 iPhone")).font(.title.bold())
            Text(L10n.text("首次使用需要配对。"))
              .font(.callout).foregroundStyle(.secondary)
          }.padding(.top, 8)
          PreparationCard(
            preparation: preparation, account: account, probe: model, selection: selection,
            onAccount: onOpenAccount, onDevice: { showSteps = true },
            onModel: { showModels = true }, onNotifications: { showNotifications = true })
          if !model.paired || !model.pin.isEmpty {
          SoloCard {
            VStack(alignment: .leading, spacing: 18) {
              HStack(spacing: 13) {
                SoloMark(size: 46)
                VStack(alignment: .leading, spacing: 4) {
                  Text(L10n.text("本机配对")).font(.headline)
                  Text(model.paired ? L10n.text("配对记录已保存在这台手机") : L10n.text("首次使用需要在系统设置中确认"))
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                StateBadge(
                  text: model.paired ? L10n.text("已配对") : L10n.text("待配对"),
                  color: model.paired ? SoloStyle.accent : .secondary)
              }
              if !model.pin.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                  Text(model.pin).font(.system(.largeTitle, design: .monospaced, weight: .bold))
                    .textSelection(.enabled)
                  Text(L10n.text("在「设置 → 隐私与安全性 → 开发者模式」中选择「与 SoloUse 配对」，输入这组 PIN。"))
                    .font(.callout).foregroundStyle(.secondary)
                }
              }
              if model.busy {
                HStack(alignment: .top, spacing: 10) {
                  ProgressView().controlSize(.small)
                  Text(agent.busy ? L10n.text("当前任务正在使用设备") : L10n.text("设备连接进行中…")).font(.subheadline)
                  Spacer()
                  Button(L10n.text("停止")) {
                    if preparation.busy { preparation.stop() } else { model.stop() }
                  }.font(.subheadline)
                    .disabled(agent.busy)
                }
              } else {
                Button {
                  model.host = "10.7.0.1"
                  if model.paired { preparation.start() } else { model.start("pair") }
                } label: {
                  Label(
                    model.paired ? L10n.text("检查连接") : L10n.text("开始本机配对"),
                    systemImage: model.paired ? "arrow.triangle.2.circlepath" : "link"
                  )
                  .frame(maxWidth: .infinity).padding(.vertical, 5)
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(locked)
              }
              if let image = model.frame {
                HStack(alignment: .top, spacing: 12) {
                  Image(uiImage: image).resizable().scaledToFit().frame(width: 40, height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 6)).accessibilityHidden(true)
                  VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("最近一次截图")).font(.subheadline.weight(.medium))
                    Text(L10n.text("最近一次检查的画面。"))
                      .font(.caption).foregroundStyle(.secondary)
                  }
                }
              }
              if !model.lines.isEmpty && !model.busy {
                Text(L10n.text(PhoneConnectionFailure.recognizedMessage(model.phase) ?? model.phase))
                  .font(.caption).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled)
              }
              if agent.busy {
                Text(L10n.text("任务运行中。请先在任务页停止任务，再检查设备连接。"))
                  .font(.caption).foregroundStyle(.secondary)
              }
            }
          }
          }
          SoloCard {
            VStack(alignment: .leading, spacing: 13) {
              Label(L10n.text("运行时保持 LocalDevVPN 连接"), systemImage: "network")
                .font(.subheadline.weight(.semibold))
              Text(L10n.text("开始任务时会检查连接。"))
                .font(.caption).foregroundStyle(.secondary)
              DisclosureGroup(L10n.text("首次使用步骤"), isExpanded: $showSteps) {
                VStack(alignment: .leading, spacing: 13) {
                  step("1", L10n.text("准备开发者模式"), L10n.text("完成安装和开发服务准备，并在系统设置中开启开发者模式。"))
                  step("2", L10n.text("连接本地 VPN"), L10n.text("打开 LocalDevVPN 并连接，再回到 SoloUse。"))
                  step("3", L10n.text("完成本机配对"), L10n.text("点击上方配对按钮，在系统设置中输入 PIN。"))
                  step("4", L10n.text("检查后开始任务"), L10n.text("取得截图后，回到任务页描述你要完成的事。"))
                }.padding(.top, 12)
              }.font(.subheadline).tint(SoloStyle.accent)
            }
          }
          NavigationLink {
            ProbeView(model: model).navigationTitle(L10n.text("高级诊断")).navigationBarTitleDisplayMode(.inline)
          } label: {
            HStack(spacing: 12) {
              Image(systemName: "wrench.and.screwdriver").foregroundStyle(.secondary)
              VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("高级诊断")).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                Text(L10n.text("点击、后台运行与连接路径测试")).font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }.padding(17).background(SoloStyle.surface, in: RoundedRectangle(cornerRadius: 18))
          }.disabled(locked)
          DisclosureGroup(L10n.text("粘贴权限")) {
            VStack(alignment: .leading, spacing: 12) {
              Text(L10n.text("若 SoloUse 反复请求允许粘贴，可在系统设置中将「从其他 App 粘贴」设为「允许」。这会允许 SoloUse 读取剪贴板；原内容仅在本机备份和恢复。"))
                .font(.caption).foregroundStyle(.secondary)
              Button(L10n.text("打开 SoloUse 设置")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                  UIApplication.shared.open(url)
                }
              }.disabled(locked)
            }.padding(.top, 10)
          }.font(.subheadline).tint(SoloStyle.accent)
          Button("Language / 语言", systemImage: "globe") { showLanguage = true }
          Text(L10n.text("运行时请保持手机解锁。"))
            .font(.caption).foregroundStyle(.secondary)
        }.padding(20)
      }.background(SoloStyle.canvas)
        .navigationTitle(L10n.text("设备")).navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showLanguage) { LanguageSettingsView() }
        .sheet(isPresented: $showModels) { ModelPickerView(selection: selection) }
        .sheet(isPresented: $showNotifications) { TaskNotificationSettingsView() }
    }
  }
  private func step(_ number: String, _ title: String, _ detail: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Text(number).font(.caption.weight(.semibold)).foregroundStyle(SoloStyle.accent)
        .frame(width: 24, height: 24).background(SoloStyle.accent.opacity(0.10), in: Circle())
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.subheadline.weight(.medium))
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}
