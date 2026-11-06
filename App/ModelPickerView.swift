import SwiftUI

@MainActor final class ModelSelection: ObservableObject {
  static let shared = ModelSelection()
  @Published private(set) var choice: ModelChoice
  @Published private(set) var models: [CatalogModel] = []
  @Published private(set) var busy = false
  @Published private(set) var error = ""
  @Published private(set) var updatedAt: Date?
  private let client = SubscriptionClient()
  private var freshness = CatalogFreshness()
  #if DEBUG
    init(interfacePreview: Bool) {
      self.choice = .initial
      self.updatedAt = Date()
      self.models = [
        ("gpt-6-astra", "GPT-6 Astra"), ("gpt-6-sol", "GPT-6 Sol"), ("gpt-6-luna", "GPT-6 Luna"),
      ].enumerated().map { index, pair in
        CatalogModel(
          id: pair.0, name: pair.1,
          description: [L10n.text("适合需要细致理解画面的复杂任务"), L10n.text("适合日常操作与多步骤任务"), L10n.text("适合简单、直接的任务")][index],
          efforts: ["low", "medium", "high", "xhigh"], defaultEffort: "low",
          supportsOriginalImages: true, priority: Double(index),
          serviceTiers: [.init(id: "priority", name: "Fast", description: "")],
          additionalSpeedTiers: ["fast"], defaultServiceTier: nil)
      }
    }
  #endif
  init() {
    choice =
      UserDefaults.standard.data(forKey: "agent.modelChoice")
      .flatMap { try? JSONDecoder().decode(ModelChoice.self, from: $0) } ?? .initial
  }
  var selected: CatalogModel? { models.first { $0.id == choice.id } }
  var label: String {
    (selected?.name ?? (choice.id == ModelChoice.initial.id ? "GPT-6 Astra" : choice.id))
      + (choice.effort.map { " · " + $0 } ?? "")
      + (choice.fastMode ? " · Fast ⚡" : "")
  }
  func choose(_ model: CatalogModel) {
    guard !busy, !PhoneAgentModel.shared.busy, !SubscriptionModel.shared.busy,
      !PhonePreparationModel.shared.busy else { return }
    let effort =
      choice.effort.flatMap { model.efforts.contains($0) ? $0 : nil }
      ?? model.defaultEffort
    save(.init(id: model.id, effort: effort, fastMode: choice.fastMode))
  }
  func chooseEffort(_ effort: String) {
    guard !busy, !PhoneAgentModel.shared.busy, !SubscriptionModel.shared.busy,
      !PhonePreparationModel.shared.busy, selected?.efforts.contains(effort) == true
    else { return }
    save(.init(id: choice.id, effort: effort, fastMode: choice.fastMode))
  }
  func chooseFastMode(_ enabled: Bool) {
    guard !busy, !PhoneAgentModel.shared.busy, !SubscriptionModel.shared.busy,
      !PhonePreparationModel.shared.busy, !enabled || selected?.supportsFastMode == true
    else { return }
    save(.init(id: choice.id, effort: choice.effort, fastMode: enabled))
  }
  private func save(_ choice: ModelChoice) {
    self.choice = choice
    UserDefaults.standard.set(try? JSONEncoder().encode(choice), forKey: "agent.modelChoice")
  }
  func accept(_ models: [CatalogModel]) {
    self.models = models
    freshness.received()
    updatedAt = freshness.updatedAt
    error = ""
  }
  func clearCatalog() {
    freshness.reset()
    models = []
    updatedAt = nil
    error = ""
  }
  func refreshIfNeeded() async {
    guard SubscriptionModel.shared.signedIn, freshness.needsRefresh() else { return }
    await refresh()
  }
  func refresh() async {
    guard !busy, !PhoneAgentModel.shared.busy, !SubscriptionModel.shared.busy,
      !ProbeModel.shared.busy else { return }
    guard SubscriptionModel.shared.signedIn else {
      error = L10n.text("请先在账号页登录")
      return
    }
    busy = true
    freshness.attempted()
    error = ""
    defer { busy = false }
    do { accept(try await client.models()) } catch is CancellationError {} catch let error as URLError where error.code == .cancelled {} catch {
      self.error = error.localizedDescription
    }
  }
}

struct ModelPickerView: View {
  @ObservedObject var selection: ModelSelection
  @ObservedObject private var agent = PhoneAgentModel.shared
  @ObservedObject private var account = SubscriptionModel.shared
  @ObservedObject private var preparation = PhonePreparationModel.shared
  @Environment(\.dismiss) private var dismiss
  private var locked: Bool { selection.busy || agent.busy || account.busy || preparation.busy }
  var body: some View {
    NavigationStack {
      List {
        Section {
          HStack(spacing: 12) {
            Image(systemName: "sparkles").font(.title2).foregroundStyle(SoloStyle.accent)
            VStack(alignment: .leading, spacing: 4) {
              Text(selection.selected?.name ?? selection.choice.id).font(.headline)
              Text(L10n.text("用于下一次任务")).font(.caption).foregroundStyle(.secondary)
            }
          }.padding(.vertical, 6)
          if let selected = selection.selected, !selected.efforts.isEmpty {
            Picker(
              L10n.text("推理强度"),
              selection: Binding(
                get: { selection.choice.effort ?? "" },
                set: { selection.chooseEffort($0) }
              )
            ) {
              if let effort = selection.choice.effort, !selected.efforts.contains(effort) {
                Text(effort + L10n.text("（已不可用）")).tag(effort)
              }
              ForEach(selected.efforts, id: \.self) { effort in
                Text(effort == "low" ? L10n.text("low · 轻量") : effort).tag(effort)
              }
            }.disabled(locked)
          }
        } header: {
          Text(L10n.text("当前选择"))
        } footer: {
          Text(L10n.text("选择会自动保存。执行中的任务保持原模型和推理强度。"))
        }
        Section {
          Toggle(
            isOn: Binding(get: { selection.choice.fastMode }, set: { selection.chooseFastMode($0) })
          ) {
            Label(L10n.text("Fast 优先处理"), systemImage: "bolt.fill")
          }.disabled(
            locked || (selection.selected?.supportsFastMode != true && !selection.choice.fastMode))
          if selection.selected?.supportsFastMode != true {
            Text(
              selection.choice.fastMode
                ? L10n.text("此模型暂未提供 Fast。请关闭 Fast 或选择支持的模型后开始任务。")
                : L10n.text("当前账号目录暂未提供此模型的 Fast。")
            )
            .font(.caption).foregroundStyle(.secondary)
          }
          Link(
            L10n.text("查看官方用量说明"),
            destination: URL(
              string: "https://learn.chatgpt.com/docs/agent-configuration/speed#fast-mode")!
          )
          .font(.caption)
        } header: {
          Text(L10n.text("响应速度"))
        } footer: {
          Text(
            L10n.text("Fast 会消耗更多订阅用量，费率见官方说明。它保持所选模型与推理强度，实际处理档位会显示在任务记录中。")
          )
        }
        Section {
          if selection.busy {
            HStack {
              ProgressView()
              Text(L10n.text("读取订阅模型…"))
            }
          }
          ForEach(selection.models) { model in
            Button {
              selection.choose(model)
            } label: {
              HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                  HStack(spacing: 7) {
                    Text(model.name).font(.body.weight(.medium))
                    if model.supportsFastMode {
                      Image(systemName: "bolt.fill").font(.caption2).foregroundStyle(
                        SoloStyle.accent
                      )
                      .accessibilityLabel(L10n.text("支持 Fast"))
                    }
                  }
                  if !model.description.isEmpty {
                    Text(L10n.text(model.description)).font(.caption).foregroundStyle(.secondary)
                  }
                }
                Spacer(minLength: 4)
                if model.id == selection.choice.id {
                  Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                }
              }.padding(.vertical, 4).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(locked)
          }
          if selection.models.isEmpty && !selection.busy && selection.error.isEmpty {
            Text(L10n.text("当前订阅没有返回可用于识图的模型")).foregroundStyle(.secondary)
          }
        } header: {
          Text(L10n.text("可用模型"))
        } footer: {
          Text(L10n.text("显示当前账号目录中支持图片输入的模型。可用性以服务端为准。"))
        }
        Section {
          if !selection.error.isEmpty {
            Text(L10n.text(selection.error)).foregroundStyle(.orange).textSelection(.enabled)
          }
          if !selection.models.isEmpty && selection.selected == nil {
            Text(L10n.text("之前选择的模型已不在目录中，请重新选择。")).foregroundStyle(.orange)
          }
          Button(L10n.text("刷新模型列表"), systemImage: "arrow.clockwise") {
            Task { await selection.refresh() }
          }.disabled(locked)
          if let updatedAt = selection.updatedAt {
            Text(L10n.text("更新于 \(L10n.time(updatedAt))"))
              .font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      .scrollContentBackground(.hidden)
      .background(SoloStyle.canvas)
      .tint(SoloStyle.accent)
      .navigationTitle(L10n.text("模型与速度")).navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("完成")) { dismiss() } } }
      .task {
        #if DEBUG
          if ProcessInfo.processInfo.arguments.contains("--solouse-ui-snapshots") { return }
        #endif
        await selection.refresh()
        #if DEBUG
          if ProcessInfo.processInfo.arguments.contains("--solouse-show-model-picker") {
            try? await Task.sleep(for: .milliseconds(750))
            ModelSelectionSelfTest.capturePicker()
          }
        #endif
      }
    }
  }
}
