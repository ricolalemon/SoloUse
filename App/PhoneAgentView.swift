import SwiftUI

struct PhoneAgentView: View {
  @ObservedObject var model: PhoneAgentModel
  @ObservedObject var account: SubscriptionModel
  @ObservedObject var probe: ProbeModel
  var onOpenAccount: () -> Void = {}
  var onOpenDevice: () -> Void = {}
  @ObservedObject private var notifications = TaskNotifications.shared
  @ObservedObject var modelSelection = ModelSelection.shared
  @ObservedObject var preparation = PhonePreparationModel.shared
  @State private var showPreparation = false
  @State private var showModelPicker = false
  @State private var followLatest = true
  @State private var showDebugRecords = false
  @State private var showRunSettings = false
  @State private var showNotificationSettings = false
  @State private var showHistory = false
  @State private var showLanguage = false
  #if DEBUG
    @State private var showReplyTest = false
  #endif
  @FocusState private var composing: Bool
  private var canStart: Bool {
    !model.busy && !account.busy && !probe.busy && !modelSelection.busy && !preparation.busy && account.signedIn
      && probe.paired && !model.taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  private var blockedReason: String? {
    if preparation.busy { return L10n.text("正在检查准备状态") }
    if !account.signedIn { return L10n.text("先登录账号，再开始任务") }
    if !probe.paired { return L10n.text("先完成设备配对，再开始任务") }
    if account.busy { return L10n.text("账号正在连接，请稍候") }
    if probe.busy { return L10n.text("设备检查进行中，请稍候") }
    if modelSelection.busy { return L10n.text("正在更新模型列表") }
    return nil
  }
  var body: some View {
    NavigationStack {
      ScrollViewReader { scroll in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 18) {
            if model.timeline.entries.isEmpty {
              AgentWelcomeView(
                preparation: preparationCard,
                onExample: {
                  model.taskText = $0
                  composing = true
                })
            }
            ForEach(model.timeline.entries.filter { $0.parent == nil }) { entry in
              TimelineRow(
                entry: entry, children: model.timeline.entries.filter { $0.parent == entry.id }
              )
              .id(entry.id)
            }
            if !model.result.isEmpty
              && !model.timeline.entries.contains(where: {
                $0.kind == .assistant && $0.text == model.result
              })
            {
              VStack(alignment: .leading, spacing: 8) {
                Label("SoloUse", systemImage: "sparkles").font(.caption.weight(.semibold))
                  .foregroundStyle(SoloStyle.accent)
                MarkdownMessageView(source: model.result).equatable()
              }
            }
            if !model.storageStatus.isEmpty {
              Label(L10n.text(model.storageStatus), systemImage: "exclamationmark.circle")
                .font(.caption).foregroundStyle(.orange)
            }
            Color.clear.frame(height: 1).id("latest")
          }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 16)
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: model.timeline.entries) { _, _ in
          if followLatest { scroll.scrollTo("latest", anchor: .bottom) }
        }
        .onChange(of: model.status) { _, _ in
          if followLatest { scroll.scrollTo("latest", anchor: .bottom) }
        }
        .overlay(alignment: .bottomTrailing) {
          if !followLatest && !model.timeline.entries.isEmpty {
            Button {
              followLatest = true
              scroll.scrollTo("latest", anchor: .bottom)
            } label: {
              Label(L10n.text("最新进度"), systemImage: "arrow.down").font(.caption.weight(.medium))
                .padding(.horizontal, 13).padding(.vertical, 10).background(
                  .regularMaterial, in: Capsule())
            }.padding(14).accessibilityLabel(L10n.text("回到最新进度"))
          }
        }
        .simultaneousGesture(
          DragGesture(minimumDistance: 20).onChanged { _ in followLatest = false })
      }
      .safeAreaInset(edge: .bottom, spacing: 0) { composer }
      .background(SoloStyle.canvas)
      .navigationTitle("SoloUse").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItemGroup(placement: .topBarLeading) {
          Button {
            composing = false
            model.refreshHistory()
            showHistory = true
          } label: { Image(systemName: "clock.arrow.circlepath") }
            .accessibilityLabel(L10n.text("历史聊天"))
          Button {
            if model.newChat() { followLatest = true }
          } label: {
            Image(systemName: "square.and.pencil")
          }
          .disabled(!model.canSwitchChat).accessibilityLabel(L10n.text("新聊天"))
        }
        ToolbarItem(placement: .topBarTrailing) {
          Menu {
            Button("Language / 语言", systemImage: "globe") { showLanguage = true }
            Button(L10n.text("准备状态"), systemImage: "checklist") { showPreparation = true }
              .disabled(model.busy)
            Toggle(L10n.text("只观察，不操作"), isOn: $model.readOnly).disabled(model.busy)
            Button(L10n.text("运行设置"), systemImage: "slider.horizontal.3") { showRunSettings = true }.disabled(
              model.busy)
            Button(L10n.text("任务通知"), systemImage: "bell") {
              composing = false
              model.pause(reason: "notification_settings")
              showNotificationSettings = true
            }
            #if DEBUG
              Button(L10n.text("测试通知回复"), systemImage: "bubble.left.and.bubble.right") {
                composing = false
                showReplyTest = true
                Task { await notifications.sendReplyTest() }
              }.disabled(model.busy || model.pendingHandoff != nil)
            #endif
            Button(L10n.text("调试记录"), systemImage: "ladybug") {
              model.pause(reason: "debug_panel")
              showDebugRecords = true
            }.disabled(preparation.busy)
          } label: {
            Image(systemName: "ellipsis")
          }
          .accessibilityLabel(L10n.text("任务选项"))
        }
      }
      .sheet(isPresented: $showPreparation) {
        PreparationSheet(
          preparation: preparation, account: account, probe: probe, selection: modelSelection,
          onAccount: onOpenAccount, onDevice: onOpenDevice)
      }
      .sheet(isPresented: $showModelPicker) { ModelPickerView(selection: modelSelection) }
      .sheet(isPresented: $showLanguage) { LanguageSettingsView() }
      .sheet(isPresented: $showHistory) {
        ChatHistoryView(model: model) { followLatest = true }
      }
      .sheet(isPresented: $showDebugRecords) { DebugRecordsView() }
      .sheet(isPresented: $showNotificationSettings) { TaskNotificationSettingsView() }
      #if DEBUG
        .sheet(isPresented: $showReplyTest) { NotificationReplyTestView() }
        .onChange(of: notifications.replyTestOpenRequest) { _, _ in showReplyTest = true }
      #endif
      .sheet(isPresented: $showRunSettings) { AgentRunSettingsView(model: model) }
      .task {
        #if DEBUG
          if ProcessInfo.processInfo.arguments.contains("--solouse-ui-snapshots") { return }
        #endif
        await notifications.refresh()
        #if DEBUG
          if ProcessInfo.processInfo.arguments.contains("--solouse-show-history") {
            model.refreshHistory()
            showHistory = true
          }
          if ProcessInfo.processInfo.arguments.contains("--solouse-notification-test") {
            showReplyTest = true
          }
        #endif
        #if DEBUG
          if ProcessInfo.processInfo.arguments.contains("--solouse-show-preparation") {
            showPreparation = true
            if ProcessInfo.processInfo.arguments.contains("--run-preparation-check") {
              await PreparationSelfTest.run()
            }
          }
        #endif
        #if DEBUG
          if ProcessInfo.processInfo.arguments.contains("--solouse-show-notification-settings") {
            showNotificationSettings = true
          }
        #endif
        #if DEBUG
          if ProcessInfo.processInfo.arguments.contains("--solouse-show-model-picker") {
            showModelPicker = true
          }
        #endif
      }
      .onChange(of: model.openRequest) { _, _ in
        composing = false
        followLatest = true
      }
    }
  }
  private var preparationCard: some View {
    PreparationCard(
      preparation: preparation, account: account, probe: probe, selection: modelSelection,
      onAccount: onOpenAccount, onDevice: onOpenDevice,
      onModel: { composing = false; showModelPicker = true },
      onNotifications: { composing = false; showNotificationSettings = true })
  }
  private var composer: some View {
    VStack(alignment: .leading, spacing: 10) {
      if (model.busy || !model.timeline.entries.isEmpty) && model.question == nil
        && (!composing || model.busy)
      {
        TaskStatusCard(
          phase: model.phase, detail: model.status,
          modelLabel: model.runModel?.label, turns: model.turns, calls: model.calls)
      }
      if let question = model.question {
        ScrollView {
          QuestionPromptView(
            question: question, choices: model.questionChoices, canReply: model.canReply
          ) {
            composing = false
            model.submitChoice($0)
          }
        }.frame(maxHeight: composing ? 140 : 230).fixedSize(horizontal: false, vertical: true)
        inputField(
          placeholder: L10n.text("回复，或补充你的要求…"), text: $model.answer,
          enabled: model.canReply
            && !model.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          label: L10n.text("发送回复")
        ) { model.submitAnswer() }
      } else if model.needsHandoffRecovery {
        Text(L10n.text("回答已保存，继续时会重新查看当前屏幕。")).font(.caption).foregroundStyle(.secondary)
        Button(L10n.text("继续原任务"), systemImage: "play.fill") { model.resume() }
          .buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
          .disabled(account.busy || probe.busy || preparation.busy || !account.signedIn || !probe.paired)
      } else if !model.busy {
        VStack(alignment: .leading, spacing: 12) {
          if model.canRecoverTask && model.taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Button(L10n.text("从恢复点继续"), systemImage: "play.fill") { model.recoverTask() }
              .disabled(account.busy || probe.busy || preparation.busy || !account.signedIn || !probe.paired)
          }
          HStack(alignment: .bottom, spacing: 12) {
            TextField(model.hasChatHistory ? L10n.text("继续聊，或补充要求…") : L10n.text("告诉手机要做什么…"), text: $model.taskText, axis: .vertical)
              .lineLimit(2...6).font(.body).textInputAutocapitalization(.never)
              .autocorrectionDisabled().focused($composing)
            sendButton(enabled: canStart, label: L10n.text("发送")) {
              followLatest = true
              model.start()
            }
          }
          HStack(spacing: 10) {
            Button {
              composing = false
              showModelPicker = true
            } label: {
              HStack(spacing: 5) {
                if modelSelection.choice.fastMode { Image(systemName: "bolt.fill") }
                Text(modelSelection.label.replacingOccurrences(of: " · Fast ⚡", with: ""))
                  .lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
              }.font(.caption.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 8)
                .background(SoloStyle.canvas, in: Capsule())
            }.buttonStyle(.plain).disabled(account.busy || probe.busy || modelSelection.busy || preparation.busy)
              .accessibilityLabel(L10n.text("选择模型，当前 \(modelSelection.label)"))
            Spacer(minLength: 0)
            Button {
              showRunSettings = true
            } label: {
              Image(systemName: "slider.horizontal.3").font(.subheadline).frame(
                width: 44, height: 44)
            }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel(L10n.text("运行设置"))
          }
        }.padding(15).background(SoloStyle.surface, in: RoundedRectangle(cornerRadius: 24))
          .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(SoloStyle.line))
        if !model.timeline.entries.isEmpty {
          TimelineView(.periodic(from: .now, by: 1)) { context in
            let rows = PreparationChecklist.rows(
              signedIn: account.signedIn, paired: probe.paired, models: modelSelection.models,
              choice: modelSelection.choice, catalogBusy: modelSelection.busy,
              catalogError: modelSelection.error, catalogUpdatedAt: modelSelection.updatedAt,
              device: preparation.device, now: context.date)
            let ready = PreparationChecklist.allPassed(rows) && !preparation.busy
            Button { composing = false; showPreparation = true } label: {
              Label(
                preparation.busy ? L10n.text("正在检查准备状态") : ready ? L10n.text("准备就绪 · 可以开始") : L10n.text("准备状态 · \(rows.filter { $0.mark == .passed }.count)/5"),
                systemImage: ready ? "checkmark.circle.fill" : "checklist")
                .font(.caption).frame(maxWidth: .infinity)
            }.buttonStyle(.plain).foregroundStyle(ready ? SoloStyle.accent : .secondary)
          }
        }
        if let blockedReason {
          Text(blockedReason).font(.caption2).foregroundStyle(.secondary)
        } else {
          Text(model.readOnly ? L10n.text("只观察屏幕 · 不执行操作") : L10n.text("保持 LocalDevVPN 连接"))
            .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
      }
      if model.busy {
        HStack(spacing: 12) {
          if model.phase == .paused {
            Button(model.pendingHandoff == nil ? L10n.text("继续任务") : L10n.text("继续原任务"), systemImage: "play.fill") {
              model.resume()
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
          } else if model.phase != .waiting {
            Button(L10n.text("暂停"), systemImage: "pause.fill") { model.pause() }
              .buttonStyle(.bordered).controlSize(.large)
              .disabled(model.phase == .pausing || model.phase == .connecting)
          }
          Spacer(minLength: 0)
          Button(L10n.text("停止任务"), systemImage: "stop.fill") { model.stop() }
            .buttonStyle(.bordered).controlSize(.large).tint(.secondary)
        }
      }
    }.padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 10)
      .background(.regularMaterial)
  }
  private func inputField(
    placeholder: String, text: Binding<String>, enabled: Bool, label: String,
    action: @escaping () -> Void
  ) -> some View {
    HStack(alignment: .bottom, spacing: 12) {
      TextField(placeholder, text: text, axis: .vertical).lineLimit(1...5).focused($composing)
      sendButton(enabled: enabled, label: label, action: action)
    }.padding(14).background(SoloStyle.surface, in: RoundedRectangle(cornerRadius: 20))
      .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(SoloStyle.line))
  }
  private func sendButton(enabled: Bool, label: String, action: @escaping () -> Void) -> some View {
    Button {
      composing = false
      action()
    } label: {
      Image(systemName: "arrow.up").font(.system(size: 17, weight: .semibold))
        .foregroundStyle(Color(uiColor: .systemBackground)).frame(width: 44, height: 44)
        .background(enabled ? SoloStyle.accent : Color.secondary.opacity(0.25), in: Circle())
    }.buttonStyle(.plain).disabled(!enabled).accessibilityLabel(label)
  }
}

struct TimelineRow: View {
  let entry: TimelineEntry
  let children: [TimelineEntry]
  @State private var expanded = false
  init(entry: TimelineEntry, children: [TimelineEntry]) {
    self.entry = entry; self.children = children
    #if DEBUG
      _expanded = State(initialValue: ProcessInfo.processInfo.arguments.contains("--solouse-ui-snapshots") && entry.state == .failed)
    #endif
  }
  var body: some View {
    switch entry.kind {
    case .user:
      HStack {
        Spacer(minLength: 28)
        Text(entry.text).textSelection(.enabled).padding(.horizontal, 16).padding(.vertical, 13)
          .background(SoloStyle.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 20))
      }
    case .assistant:
      VStack(alignment: .leading, spacing: 9) {
        HStack(spacing: 6) {
          Image(systemName: "sparkles").foregroundStyle(SoloStyle.accent)
          Text("SoloUse").fontWeight(.semibold)
          if entry.state == .running { Text(L10n.text("正在回复")).foregroundStyle(.secondary) }
          if entry.state == .interrupted { Text(L10n.text("未完成")).foregroundStyle(.secondary) }
        }.font(.caption)
        MarkdownMessageView(source: entry.text).equatable()
      }.padding(.vertical, 4)
    case .tool:
      DisclosureGroup(isExpanded: $expanded) {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(children) { child in
            HStack(alignment: .top, spacing: 9) {
              stateIcon(child.state)
              VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text(child.title)).font(.caption.weight(.medium))
                if !child.text.isEmpty {
                  Text(L10n.toolDetail(child.text))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
              }
              Spacer(minLength: 0)
            }
          }
          if !entry.text.isEmpty {
            Text(L10n.toolDetail(entry.text))
              .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
          }
        }.padding(.top, 12)
      } label: {
        HStack(spacing: 9) {
          stateIcon(entry.state)
          Text(L10n.text(entry.title)).font(.subheadline)
          Spacer(minLength: 0)
          if children.count > 1 {
            Text(L10n.text("\(children.count) 步")).font(.caption).foregroundStyle(.secondary)
          }
          if entry.state == .failed { Text(L10n.text("需检查")).font(.caption).foregroundStyle(.orange) }
        }.foregroundStyle(.primary)
      }.tint(.secondary).padding(14).background(
        SoloStyle.surface, in: RoundedRectangle(cornerRadius: 16)
      )
      .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(SoloStyle.line))
    case .system:
      let text = L10n.text(PhoneConnectionFailure.recognizedMessage(entry.text) ?? entry.text)
      if text.count > 180 {
        DisclosureGroup(L10n.text("查看任务详情")) { Text(text).textSelection(.enabled) }
          .font(.caption).foregroundStyle(.secondary)
      } else {
        Text(text).font(.caption).foregroundStyle(.secondary).lineSpacing(3).textSelection(.enabled)
      }
    case .action: EmptyView()
    }
  }
  @ViewBuilder private func stateIcon(_ state: TimelineEntry.State) -> some View {
    if state == .running {
      ProgressView().controlSize(.mini).tint(SoloStyle.accent)
    } else {
      Image(
        systemName: state == .completed
          ? "checkmark.circle.fill" : (state == .failed ? "exclamationmark.circle" : "pause.circle")
      )
      .font(.caption).foregroundStyle(
        state == .completed ? SoloStyle.accent : (state == .failed ? .orange : .secondary))
    }
  }
}
