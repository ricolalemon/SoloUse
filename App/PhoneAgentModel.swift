import Combine
import CryptoKit
import Foundation
import UIKit

@MainActor final class PhoneAgentModel: ObservableObject {
  static let shared = PhoneAgentModel()
  // Unsent composer draft, separate from the immutable prompt of the recorded run.
  @Published var taskText = "" {
    didSet { if !loadingChat && !busy { scheduleDraftSave() } }
  }
  @Published private(set) var historyEntries: [ChatHistorySummary] = []
  private var loadingChat = false
  private var savedDraft = ""
  private var chatUpdatedAt = Date()
  private var draftSaveOperation: Task<Void, Never>?
  var canSwitchChat: Bool { !busy && !ProbeModel.shared.busy && !SubscriptionModel.shared.busy && !PhonePreparationModel.shared.busy }
  private var activePrompt = ""
  private var savedConversation: ConversationCheckpoint?
  private var conversationRevision: UUID?
  private var timelineEpoch = UUID().uuidString
  var hasChatHistory: Bool { runID != nil && !timeline.entries.isEmpty }
  var canRecoverTask: Bool { !busy && pendingHandoff == nil && savedConversation != nil && [.failed, .interrupted].contains(phase) }
  func recoverTask() {
    guard canRecoverTask, taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    taskText = L10n.text("继续上次任务。先查看当前屏幕，核对已完成的操作和不确定的结果，再继续。")
    start()
  }
  var hasFullConversationContext: Bool { savedConversation != nil }
  @Published var readOnly = false
  @Published var turnLimit = UserDefaults.standard.integer(forKey: "agent.turnLimit") {
    didSet { UserDefaults.standard.set(max(0, turnLimit), forKey: "agent.turnLimit") }
  }
  @Published var runtimeMinutes = UserDefaults.standard.integer(forKey: "agent.runtimeMinutes") {
    didSet { UserDefaults.standard.set(max(0, runtimeMinutes), forKey: "agent.runtimeMinutes") }
  }
  private var runLimits = AgentRunLimits()
  private var segmentStartedAt = ProcessInfo.processInfo.systemUptime
  var runLimitLabel: String { AgentRunLimits(turns: turnLimit, minutes: runtimeMinutes).label }

  @Published private(set) var busy = false
  @Published private(set) var phase: TaskPhase = .idle
  @Published private(set) var status = "输入要做的事，由你启动"
  @Published private(set) var result = ""
  @Published private(set) var question: String?
  @Published var answer = ""
  @Published private(set) var canReply = false
  @Published private(set) var turns = 0
  @Published private(set) var calls = 0
  @Published private(set) var timeline = AgentTimeline()
  @Published private(set) var openRequest = UUID()
  @Published private(set) var storageStatus = ""
  private(set) var runID: UUID?
  private var startedAt = Date()
  private var operation: Task<Void, Never>?
  private var pauseOperation: Task<Void, Never>?
  private var saveOperation: Task<Void, Never>?
  private var reply: CheckedContinuation<String, Error>?
  private var currentLoop: PhoneAgentLoop?
  private var replySource = "app"
  private var questionNeedsManualResume = false
  @Published private(set) var pendingHandoff: PendingHandoff?
  var questionChoices: [String] {
    #if DEBUG
      if let interfacePreviewChoices { return interfacePreviewChoices }
    #endif
    return pendingHandoff?.question.choices ?? []
  }
  var needsHandoffRecovery: Bool { !busy && pendingHandoff != nil }
  private var handoffs: HandoffStore { HandoffStore(directory: records.directory) }
  private func accountTag() throws -> String {
    guard let account = try SubscriptionKeychain.load()?.account else {
      throw SubscriptionFailure.invalid("请先登录原来的 ChatGPT 账号")
    }
    return SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  private var interruption: String?
  private var runReadOnly = false
  private var gate = AgentPauseGate()
  private var executor: PhoneToolDispatcher?
  private var wasBackgrounded = false
  private var takeoverVersion = 0
  private var transitionID = UUID()
  private let driver = NativePhoneDriver.shared
  @Published private(set) var runModel: ModelRunConfiguration?
  private var records: TaskRecordStore {
    TaskRecordStore(directory: ProbeModel.shared.directory.appendingPathComponent("task-records"))
  }
  private var conversations: ConversationStore { ConversationStore(directory: records.directory) }
  private var history: ChatHistoryStore { ChatHistoryStore(directory: records.directory) }

  #if DEBUG
    private var interfacePreviewChoices: [String]?
    private var isInterfacePreview = false
    init(interfacePreview phase: TaskPhase) {
      isInterfacePreview = true
      self.phase = phase
      self.busy = [.thinking, .acting, .paused, .waiting].contains(phase)
      self.status = phase.label
      var previewTimeline = AgentTimeline()
      previewTimeline.note(L10n.text("查看我明天的日历安排，按时间顺序整理给我。"), kind: .user)
      historyEntries = [ChatHistorySummary(snapshot: .init(id: UUID(), prompt: "", phase: .completed,
        timeline: previewTimeline, result: L10n.text("任务结束"), startedAt: Date(), updatedAt: Date()), draft: "")]
      guard phase != .idle else { return }
      self.activePrompt = L10n.text("查看我明天的日历安排，按时间顺序整理给我。")
      self.runModel = .initial
      self.turns = 3
      self.calls = 4
      timeline.note(activePrompt, kind: .user)
      timeline.accept(
        .message(
          .init(
            id: "preview-message", text: L10n.text("我会先查看日历，再整理明天的安排。"), phase: "commentary", complete: true)),
        turn: 1)
      for (index, name) in ["phone_open_app", "phone_observe"].enumerated() {
        let call = AgentToolCall(id: "preview-\(index)", name: name, arguments: "{}")
        timeline.accept(.toolStarted(call), turn: 1)
        timeline.accept(.toolFinished(call, .init(content: [])), turn: 1)
      }
      if phase == .waiting {
        question = L10n.text("我找到了两个名为「项目讨论」的日程。你希望我整理哪一个？也可以补充你要关注的内容。")
        canReply = true
        interfacePreviewChoices = [L10n.text("上午 10:00 · 设计评审"), L10n.text("下午 15:00 · 项目进度同步")]
        status = L10n.text("操作已暂停，等待你选择。")
      } else if phase == .paused {
        status = L10n.text("你已接管手机。继续时会重新查看当前屏幕。")
      } else if phase == .failed {
        status = L10n.text("设备连接已中断。请保持手机解锁，并检查 LocalDevVPN 是否仍在连接。")
        timeline.note(status)
        let call = AgentToolCall(id: "preview-clipboard", name: "phone_open_app", arguments: "{}")
        timeline.accept(.toolStarted(call), turn: 2)
        let receipt = JSONValue.object(["status": .string("not_executed"), "error": .object([
          "code": .string("clipboard_preparation_pending"), "message": .string("Observe SoloUse and handle its clipboard permission dialog before leaving the app. The model can use tap; no automatic permission response is sent.")])])
        timeline.accept(.toolFinished(call, .init(content: [.textContent((try? receipt.text()) ?? "")])), turn: 2)
      } else if phase == .completed {
        result = L10n.text("明天有两项安排：\n\n**10:00 — 设计评审**\n讨论新版本的界面方案。\n\n**15:00 — 项目进度同步**\n确认本周的交付安排。")
      } else {
        status = L10n.text("正在查看明天的日程安排")
        let call = AgentToolCall(id: "preview-running", name: "phone_exec_js", arguments: "{}")
        timeline.accept(.toolStarted(call), turn: 3)
        timeline.accept(
          .actionStarted(id: "preview-action", parent: call.id, name: "observe"), turn: 3)
      }
    }
  #endif

  init() {
    do {
      if let chat = try history.bootstrap() { applyChat(chat) }
      updateHistoryList()
    } catch { storageStatus = "历史聊天读取失败：\(error.localizedDescription)" }
  }

  private func applyChat(_ chat: LoadedChat) {
    resetCurrentChat()
    loadingChat = true
    defer { loadingChat = false }
    var snapshot = chat.record.snapshot
    snapshot.restoreForViewing()
    runID = snapshot.id
    activePrompt = snapshot.prompt
    phase = snapshot.phase
    timeline = snapshot.timeline
    result = snapshot.result
    startedAt = snapshot.startedAt
    chatUpdatedAt = snapshot.updatedAt
    status = phase.label
    runModel = snapshot.model
    savedConversation = chat.context
    conversationRevision = chat.context?.revision
    taskText = chat.record.draft
    savedDraft = taskText
    if chat.contextUnavailable { storageStatus = "完整上下文未找到，仍保留已有聊天记录。" }
    if let pending = chat.handoff, ![.completed, .stopped].contains(snapshot.phase) {
      pendingHandoff = pending
      question = pending.answer == nil ? pending.question.text : nil
      canReply = pending.answer == nil
      status = pending.answer == nil ? "已恢复待回答的问题，回复后可继续原任务" : "回答已保存，点继续原任务"
    }
  }

  func start(restoring handoff: PendingHandoff? = nil) {
    let submittedDraft = taskText
    let goal = (handoff == nil ? submittedDraft : activePrompt)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard UIApplication.shared.applicationState == .active, !busy, !ProbeModel.shared.busy,
      !SubscriptionModel.shared.busy,
      !PhonePreparationModel.shared.busy,
      !ModelSelection.shared.busy,
      SubscriptionModel.shared.signedIn, ProbeModel.shared.paired, !goal.isEmpty
    else { return }
    PhonePreparationModel.shared.invalidate()
    #if targetEnvironment(simulator)
      status = "模拟器仅用于界面预览，请在 iPhone 上运行任务"
      return
    #endif
    let continuesChat = handoff == nil && hasChatHistory
    let ownerTag: String
    let inputConversation: AgentConversation
    var recoveredVisibleHistory = false
    do {
      ownerTag = try accountTag()
      if continuesChat, let savedConversation {
        inputConversation = try savedConversation.adding(goal, accountTag: ownerTag)
      } else if continuesChat, let existingID = runID {
        let snapshot = TaskSnapshot(id: existingID, prompt: activePrompt, phase: phase,
          timeline: timeline, result: result, startedAt: startedAt, updatedAt: Date(), model: runModel)
        var recovered = try AgentConversation.recoveringVisibleHistory(snapshot)
        try recovered.appendFollowup(goal)
        inputConversation = recovered
        recoveredVisibleHistory = true
      } else { inputConversation = AgentConversation(task: goal) }
    } catch {
      status = error.localizedDescription
      storageStatus = status
      return
    }
    if let handoff {
      guard handoff.answer != nil else { return }
      do {
        guard try accountTag() == handoff.accountTag else {
          status = "请登录原来的 ChatGPT 账号后恢复任务"
          return
        }
      } catch {
        status = error.localizedDescription
        return
      }
    } else {
      do { try handoffs.consume() } catch {
        storageStatus = "旧的询问记录无法清除，请稍后重试"
        return
      }
      pendingHandoff = nil
    }
    let choice = handoff?.model.choice ?? ModelSelection.shared.choice
    runModel = nil
    saveOperation?.cancel()
    saveOperation = nil
    storageStatus = ""
    if let runID { TaskNotifications.shared.clear(runID: runID) }
    let id = handoff?.runID ?? runID ?? UUID()
    runID = id
    conversationRevision = nil
    timelineEpoch = UUID().uuidString
    TaskDiagnostics.shared.begin(
      id: handoff == nil && !continuesChat ? id : UUID(),
      kind: handoff != nil ? "agent_recovered" : (continuesChat ? "agent_followup" : "agent"),
      prompt: goal)
    if handoff == nil && !continuesChat { startedAt = Date() }
    if continuesChat {
      TaskDiagnostics.shared.record("conversation_followup", ["task_id": .string(id.uuidString),
        "history_items": .number(Double(inputConversation.items.count)),
        "visible_history_only": .bool(recoveredVisibleHistory)])
    }
    if handoff != nil {
      TaskDiagnostics.shared.record("handoff_recovered", ["task_id": .string(id.uuidString)])
    }
    activePrompt = goal
    if handoff == nil { taskText = "" }
    busy = true
    draftSaveOperation?.cancel()
    draftSaveOperation = nil
    result = ""
    question = nil
    answer = ""
    turns = 0
    calls = 0
    interruption = nil
    runReadOnly = handoff?.readOnly ?? readOnly
    runLimits = AgentRunLimits(
      turns: handoff?.turnLimit ?? turnLimit, minutes: handoff?.runtimeMinutes ?? runtimeMinutes)
    TaskDiagnostics.shared.record(
      "run_settings",
      [
        "turn_limit": runLimits.turns.map { .number(Double($0)) } ?? .null,
        "runtime_seconds": runLimits.seconds.map(JSONValue.number) ?? .null,
      ])

    gate = AgentPauseGate()
    wasBackgrounded = false
    if handoff == nil {
      if !continuesChat { timeline = AgentTimeline() }
      if recoveredVisibleHistory { timeline.note("已带入旧版保存的聊天记录；旧版未保存完整操作上下文。") }
      timeline.note(goal, kind: .user)
    } else if let text = handoff?.answer {
      if timeline.entries.last?.kind != .user || timeline.entries.last?.text != text {
        timeline.note(text, kind: .user)
      }
      timeline.note("从已保存的问题处继续，之前的操作不会重放。")
    }
    setPhase(.connecting, "正在准备任务")
    do { try persistCurrentChat() } catch {
      busy = false
      storageStatus = "聊天未能保存：\(error.localizedDescription)"
      taskText = submittedDraft
      return
    }
    driver.onUnexpectedEnd = { [weak self] message in
      guard let self, self.busy else { return }
      if let handoff = self.pendingHandoff, self.gate.paused {
        self.setPhase(
          handoff.answer == nil ? .waiting : .paused,
          handoff.answer == nil ? "手机连接已结束；你可以先回复，再打开 SoloUse 继续" : "回答已保存；打开 SoloUse 后点继续")
        self.saveNow()
        Task {
          await TaskNotifications.shared.sendRecovery(
            runID: handoff.runID, questionID: handoff.question.id)
        }
        return
      }
      self.interruption = "手机连接已结束：\(message)"
      self.stop(reason: "unexpected_session_end")
    }
    operation = Task {
      var beganAgentLoop = false
      do {
        setPhase(.connecting, "正在确认所选模型")
        let models = try await SubscriptionClient().models()
        try Task.checkCancellation()
        ModelSelection.shared.accept(models)
        let configuration = try ModelCatalog.resolve(choice, in: models)
        runModel = configuration
        timeline.note("本次模型：" + configuration.label)
        TaskDiagnostics.shared.record(
          "model_selected",
          [
            "requested_model": .string(configuration.choice.id),
            "requested_effort": configuration.choice.effort.map(JSONValue.string) ?? .null,
            "requested_service_tier": configuration.requestedServiceTier.map(JSONValue.string)
              ?? .null,
            "image_detail": .string(configuration.supportsOriginalImages ? "original" : "high"),
          ])
        let client = SubscriptionClient(modelConfiguration: configuration, sessionID: id)
        client.onServiceTierStatus = { [weak agent = self] status in
          agent?.timeline.note(status)
          agent?.saveNow()
        }
        await TaskNotifications.shared.prepare()
        try Task.checkCancellation()
        try await connectAllowingPause(waitIfPaused: true)
        try await prepareClipboardIfNeeded()
        let executor = PhoneToolDispatcher(
          driver: driver,
          allowsActions: { [self] in permitsNextAction() },
          controlVersion: { [self] in gate.revision },
          onEvent: { [self] in receive($0) },
          askUser: { [self] call, question in try await ask(call, question) })
        self.executor = executor
        let scriptExecutor = ScriptExecutor(
          phone: executor,
          allowsActions: { [self] in permitsNextAction() },
          controlVersion: { [self] in gate.revision },
          onEvent: { [self] in receive($0) })
        let loop = PhoneAgentLoop(
          task: goal, model: client, executor: scriptExecutor,
          tools: PhoneTools.definitions(readOnly: runReadOnly))
        currentLoop = loop
        if let handoff {
          try loop.restore(handoff)
          try handoffs.consume()
          pendingHandoff = nil
        } else if continuesChat {
          try loop.continueConversation(inputConversation)
        }
        beganAgentLoop = true
        result = try await loop.run(
          persist: { [self] conversation, unfinished, turn, callCount in
            guard var snapshot = currentSnapshot() else { throw AgentLoopError.protocolError("Missing task record") }
            snapshot.updatedAt = Date()
            let checkpointStarted = ProcessInfo.processInfo.systemUptime
            let saved = try await RunRecoveryStore(directory: records.directory).save(
              conversation: conversation, unfinishedCall: unfinished, snapshot: snapshot, accountTag: ownerTag)
            savedConversation = saved.1
            conversationRevision = saved.1.revision
            TaskDiagnostics.shared.record("recovery_checkpoint_saved", [
              "history_items": .number(Double(conversation.items.count)), "turn": .number(Double(turn)),
              "calls": .number(Double(callCount)), "in_flight": .bool(unfinished != nil),
              "elapsed_ms": .number((ProcessInfo.processInfo.systemUptime - checkpointStarted) * 1000)])
            return saved.0
          },
          onContext: { [self] message in setPhase(.thinking, message) },
          maxTurns: runLimits.turns,
          onTurnLimit: { [self] limit in
            TaskDiagnostics.shared.record(
              "configured_limit_reached",
              ["limit_kind": .string("turns"), "limit": .number(Double(limit))])
            pause(reason: "configured_turn_limit", message: "已达到你设置的 \(limit) 轮上限；点继续可接着当前任务")
            return try await gate.checkpoint()
          },
          beforeModel: { [self] in
            _ = permitsNextAction()
            return try await gate.checkpoint()
          },
          allowsActions: { [self] in permitsNextAction() },
          controlVersion: { [self] in gate.revision },
          onEvent: { [self] in receive($0) },
          onTurn: { [self] turns, calls in
            self.turns = turns
            self.calls = calls
          })
        turns = loop.turns
        calls = loop.toolCalls
        setPhase(.completed)
      } catch {
        // Startup failure keeps the original draft available to retry. Never
        // overwrite a newer draft or reinsert a task after execution has begun.
        if !beganAgentLoop, handoff == nil, !Task.isCancelled, taskText.isEmpty {
          taskText = submittedDraft
        }
        TaskDiagnostics.shared.failure(error, stage: "agent_loop")
        if Task.isCancelled {
          setPhase(interruption == nil ? .stopped : .failed, interruption ?? "已停止；已完成的操作不会撤销")
        } else {
          setPhase(.failed, error.localizedDescription)
        }
        timeline.note(status)
      }
      gate.stop()
      let handoff = TaskHandoffLease()
      defer { handoff.end() }
      await driver.close(reason: "task_finished")
      driver.onUnexpectedEnd = nil
      reply?.resume(throwing: CancellationError())
      reply = nil
      canReply = false
      question = pendingHandoff?.answer == nil ? pendingHandoff?.question.text : nil
      canReply = question != nil
      answer = ""
      if pendingHandoff == nil {
        do {
          let context = try (currentLoop?.conversation ?? inputConversation).checkpoint(
            unfinishedCall: currentLoop?.unfinishedCall)
          let checkpoint = ConversationCheckpoint(runID: id, revision: UUID(),
            accountTag: ownerTag, conversation: context)
          // Keep in-memory continuity even if the disk write fails. Persist once
          // per execution, off the UI actor; don't rewrite image history on each UI update.
          savedConversation = checkpoint
          try await conversations.saveAsync(checkpoint)
          conversationRevision = checkpoint.revision
          TaskDiagnostics.shared.record("conversation_saved", [
            "task_id": .string(id.uuidString), "history_items": .number(Double(context.items.count))])
        } catch { storageStatus = "上下文未能保存：\(error.localizedDescription)" }
      }
      currentLoop = nil
      timeline.interruptOpenEntries()
      busy = false
      operation = nil
      self.executor = nil
      TaskDiagnostics.shared.finish(phase.rawValue)
      saveNow()
      do { try persistCurrentChat() } catch { storageStatus = "历史聊天未能保存：\(error.localizedDescription)" }
      updateHistoryList()
      await TaskNotifications.shared.send(runID: id, phase: phase, sequence: turns)
      ProbeModel.shared.log([
        "kind": "phone_agent_finished", "turns": turns, "tool_calls": calls,
        "status": phase.rawValue,
      ])
    }
  }

  private func receive(_ event: AgentEvent) {
    TaskDiagnostics.shared.event(event)
    if case .modelStarted(let turn) = event { turns = turn }
    timeline.accept(event.namespaced(timelineEpoch), turn: turns)
    if gate.allowsActions && !phase.terminal {
      switch event {
      case .modelStarted: setPhase(.thinking)
      case .message: setPhase(.thinking, "模型正在回复")
      case .toolStarted(let call): setPhase(.acting, AgentTimeline.label(call.name))
      case .actionStarted(_, _, let name): setPhase(.acting, AgentTimeline.label(name))
      case .actionFinished(_, let name, let result, _):
        setPhase(.acting, result == "executed" ? AgentTimeline.label(name) + " · 已执行" : "正在处理操作结果")
      case .toolFinished: break
      }
    }
    scheduleSave()
  }
  private func setPhase(_ value: TaskPhase, _ text: String? = nil) {
    phase = value
    status = text ?? value.label
    TaskDiagnostics.shared.setPhase(value, detail: status)
    ProbeModel.shared.presentAgentStatus(value, detail: status, turns: turns, calls: calls)
    scheduleSave()
  }
  func stop(reason: String = "stop_button") {
    guard busy, !phase.terminal else { return }
    TaskDiagnostics.shared.record(
      "control_requested", ["control": .string("stop"), "source": .string(reason)])
    pendingHandoff = nil
    handoffs.remove()
    if let runID { TaskNotifications.shared.clear(runID: runID) }
    gate.stop()
    operation?.cancel()
    pauseOperation?.cancel()
    driver.cancel(reason: reason)
    reply?.resume(throwing: CancellationError())
    reply = nil
    canReply = false
    question = nil
    setPhase(.stopped, "正在停止…")
    saveNow()
  }
  private func permitsNextAction() -> Bool {
    if gate.allowsActions,
      runLimits.timeReached(start: segmentStartedAt, now: ProcessInfo.processInfo.systemUptime)
    {
      let minutes = Int((runLimits.seconds ?? 0) / 60)
      TaskDiagnostics.shared.record(
        "configured_limit_reached",
        ["limit_kind": .string("duration"), "minutes": .number(Double(minutes))])
      pause(reason: "configured_duration_limit", message: "已达到你设置的 \(minutes) 分钟上限；点继续可接着当前任务")
    }
    return gate.allowsActions
  }
  func pause(reason: String = "pause_button", message: String? = nil) {
    guard busy, !phase.terminal, ![.waiting, .paused, .pausing].contains(phase) else { return }
    TaskDiagnostics.shared.record(
      "control_requested", ["control": .string("pause"), "source": .string(reason)])
    takeoverVersion += 1
    gate.pause()
    executor?.invalidateObservation()
    setPhase(.pausing)
    // Called at willEnterForeground, before the task page becomes interactive.
    driver.cancel(reason: "pause." + reason)
    let id = runID
    let transition = UUID()
    transitionID = transition
    pauseOperation = Task {
      let handoff = TaskHandoffLease()
      defer { handoff.end() }
      await driver.close(reason: "pause." + reason)
      guard runID == id, transitionID == transition, busy, !phase.terminal, !Task.isCancelled else {
        return
      }
      setPhase(.paused, message)
      timeline.note(message ?? "你接管了手机，自动操作已暂停。继续时会重新观察屏幕。")
      saveNow()
      if reason.hasPrefix("configured_"), let id = runID {
        await TaskNotifications.shared.send(runID: id, phase: .paused, sequence: turns)
      }
      if transitionID == transition { pauseOperation = nil }
    }
  }
  func resume() {
    if needsHandoffRecovery {
      start(restoring: pendingHandoff)
      return
    }
    guard busy, phase == .paused, gate.paused,
      UIApplication.shared.applicationState == .active
    else { return }
    TaskDiagnostics.shared.record(
      "control_requested", ["control": .string("resume"), "source": .string("resume_button")])
    setPhase(.connecting)
    let version = takeoverVersion
    let transition = UUID()
    transitionID = transition
    pauseOperation = Task {
      do {
        if driver.sessionID == nil { try await driver.start(readOnly: runReadOnly) }
        try await prepareClipboardIfNeeded()
        try Task.checkCancellation()
        guard takeoverVersion == version, transitionID == transition else { return }
        executor?.invalidateObservation()
        timeline.note("你继续了任务。")
        segmentStartedAt = ProcessInfo.processInfo.systemUptime
        gate.resume()
        setPhase(.thinking)
        saveNow()
      } catch {
        guard takeoverVersion == version, transitionID == transition else { return }
        interruption = "恢复连接失败：\(error.localizedDescription)"
        stop(reason: "resume_connection_failed")
      }
      if transitionID == transition { pauseOperation = nil }
    }
  }
  private func connectAllowingPause(waitIfPaused: Bool) async throws {
    if waitIfPaused, gate.paused {
      _ = try await gate.checkpoint()
      if driver.sessionID != nil { return }
    }
    let version = takeoverVersion
    do {
      try await driver.start(readOnly: runReadOnly)
      segmentStartedAt = ProcessInfo.processInfo.systemUptime
    } catch {
      guard version != takeoverVersion, !Task.isCancelled else { throw error }
      _ = try await gate.checkpoint()
      guard driver.sessionID != nil else { throw AgentLoopError.protocolError("恢复后没有可用的手机会话") }
      return
    }
    if version != takeoverVersion {
      await driver.close()
      _ = try await gate.checkpoint()
      guard driver.sessionID != nil else { throw AgentLoopError.protocolError("恢复后没有可用的手机会话") }
    }
  }
  private func prepareClipboardIfNeeded() async throws {
    guard !runReadOnly, UIApplication.shared.applicationState == .active else { return }
    do {
      try await driver.prepareClipboardIfNeeded()
    } catch {
      try Task.checkCancellation()
      // Clipboard is optional: denied/unavailable access must not prevent
      // unrelated phone actions. A later paste still fails before any mutation.
      TaskDiagnostics.shared.failure(error, stage: "clipboard_preparation")
    }
    try Task.checkCancellation()
  }
  func didEnterBackground() {
    if busy { wasBackgrounded = true }
    else {
      draftSaveOperation?.cancel(); draftSaveOperation = nil
      do { try persistCurrentChat() }
      catch { storageStatus = "草稿未能保存：\(error.localizedDescription)" }
    }
    if let pending = pendingHandoff, pending.answer == nil {
      Task {
        await TaskNotifications.shared.sendQuestion(
          runID: pending.runID, question: pending.question)
      }
    }
  }
  func willEnterForeground(source: String = "foreground") {
    TaskDiagnostics.shared.record(
      "foreground_notice",
      ["source": .string(source), "was_backgrounded": .bool(wasBackgrounded), "busy": .bool(busy)])
    guard wasBackgrounded else { return }
    wasBackgrounded = false
    if pendingHandoff != nil { questionNeedsManualResume = true }
    if busy { pause(reason: source) }
    openRequest = UUID()
    if let runID { TaskNotifications.shared.clear(runID: runID) }
  }
  func openDetails(for id: UUID) {
    TaskDiagnostics.shared.record("notification_opened", ["target_task_id": .string(id.uuidString)])
    if id != runID {
      guard openHistory(id) else { return }
    }
    if pendingHandoff != nil { questionNeedsManualResume = true }
    pause(reason: "task_notification")
    openRequest = UUID()
    TaskNotifications.shared.clear(runID: id)
  }
  private func ask(_ call: AgentToolCall, _ question: AgentQuestion) async throws -> String {
    guard let runID, let currentLoop, let runModel else {
      throw AgentLoopError.protocolError("无法保存询问上下文")
    }
    TaskDiagnostics.shared.record(
      "control_requested", ["control": .string("handoff"), "source": .string("model_ask_user")])
    gate.pause()
    executor?.invalidateObservation()
    questionNeedsManualResume = false
    let pending = PendingHandoff(
      runID: runID, question: question, call: call, conversation: currentLoop.conversation,
      model: runModel, accountTag: try accountTag(), readOnly: runReadOnly,
      turnLimit: runLimits.turns ?? 0, runtimeMinutes: Int((runLimits.seconds ?? 0) / 60),
      turns: currentLoop.turns, calls: currentLoop.toolCalls)
    try handoffs.save(pending)
    pendingHandoff = pending
    self.question = question.text
    answer = ""
    canReply = true
    setPhase(.waiting, "等待你的回复，可长按通知直接回答")
    timeline.note(question.text, kind: .assistant)
    saveNow()
    // Keep the existing media session and OS background grant. No phone command
    // can pass the paused gate while the user's notification UI is on screen.
    await TaskNotifications.shared.sendQuestion(runID: runID, question: question)
    let response: String = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<String, Error>) in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else if let answer = pendingHandoff?.answer {
          continuation.resume(returning: answer)
        } else {
          reply = continuation
        }
      }
    } onCancel: {
      Task { @MainActor in
        self.reply?.resume(throwing: CancellationError())
        self.reply = nil
        self.canReply = false
      }
    }
    try Task.checkCancellation()
    self.question = nil
    answer = ""
    timeline.note(response, kind: .user)
    saveNow()
    // Allow the notification keyboard/banner to dismiss before observing again.
    if replySource == "notification" { try await Task.sleep(for: .milliseconds(1200)) }
    try Task.checkCancellation()
    if (replySource == "notification" && questionNeedsManualResume)
      || (driver.sessionID == nil && UIApplication.shared.applicationState != .active)
    {
      setPhase(.paused, "回答已保存；打开 SoloUse 后点继续")
      saveNow()
      await TaskNotifications.shared.sendRecovery(runID: runID, questionID: question.id)
      _ = try await gate.checkpoint()
    } else if driver.sessionID == nil {
      setPhase(.connecting, "正在恢复手机连接")
      try await connectAllowingPause(waitIfPaused: false)
    }
    try Task.checkCancellation()
    executor?.invalidateObservation()
    try handoffs.consume()
    pendingHandoff = nil
    segmentStartedAt = ProcessInfo.processInfo.systemUptime
    gate.resume()
    setPhase(.thinking)
    return response
  }
  @discardableResult
  func acceptAnswer(_ text: String, runID: UUID, questionID: UUID, source: String) -> Bool {
    if runID != self.runID {
      do {
        let accepted = try history.answer(runID: runID, questionID: questionID, text: text)
        if accepted { TaskNotifications.shared.clearQuestion(runID: runID, questionID: questionID); updateHistoryList() }
        return accepted
      } catch { return false }
    }
    guard var pending = pendingHandoff,
      pending.accept(runID: runID, questionID: questionID, text: text)
    else { return false }
    do { try handoffs.save(pending) } catch {
      storageStatus = "回答未能保存，请回到任务页重试"
      return false
    }
    pendingHandoff = pending
    answer = ""
    replySource = source
    if source == "app" { questionNeedsManualResume = false }
    canReply = false
    question = nil
    TaskNotifications.shared.clearQuestion(runID: runID, questionID: questionID)
    TaskDiagnostics.shared.record(
      "question_answered",
      ["question_id": .string(questionID.uuidString), "source": .string(source)])
    ProbeModel.shared.log([
      "kind": "question_answered", "source": source, "live_session": driver.sessionID != nil,
    ])
    if let continuation = reply {
      reply = nil
      continuation.resume(returning: pending.answer!)
    } else if !busy {
      status = "回答已保存，点继续原任务"
      saveNow()
      if source == "app" { start(restoring: pending) }
    }
    return true
  }
  func submitAnswer() {
    guard let pending = pendingHandoff else { return }
    _ = acceptAnswer(answer, runID: pending.runID, questionID: pending.question.id, source: "app")
  }
  func submitChoice(_ choice: String) {
    guard questionChoices.contains(choice), let pending = pendingHandoff else { return }
    _ = acceptAnswer(choice, runID: pending.runID, questionID: pending.question.id, source: "app")
  }
  func matchesQuestion(runID: UUID, questionID: UUID) -> Bool {
    if runID != self.runID {
      let pending = try? history.load(runID).handoff
      return pending?.question.id == questionID && pending?.answer == nil
    }
    return pendingHandoff?.runID == runID && pendingHandoff?.question.id == questionID
      && pendingHandoff?.answer == nil
  }
  func notificationAction(_ action: QuestionNotificationAction, runID: UUID, questionID: UUID)
    -> Bool
  {
    let candidate = runID == self.runID ? pendingHandoff : (try? history.load(runID).handoff)
    guard let pending = candidate, pending.runID == runID, pending.question.id == questionID
    else { return false }
    switch action {
    case .reply(let text):
      return acceptAnswer(text, runID: runID, questionID: questionID, source: "notification")
    case .choice(let index):
      guard pending.question.choices.indices.contains(index) else { return false }
      return acceptAnswer(
        pending.question.choices[index], runID: runID, questionID: questionID,
        source: "notification")
    case .stop:
      if runID == self.runID && busy { stop(reason: "notification_stop") }
      else if runID == self.runID {
        pendingHandoff = nil; handoffs.remove(); question = nil; canReply = false
        phase = .stopped; status = phase.label; chatUpdatedAt = Date()
        try? persistCurrentChat(); updateHistoryList()
      } else if let chat = try? history.load(runID) {
        var snapshot = chat.record.snapshot; snapshot.phase = .stopped; snapshot.updatedAt = Date()
        do { try history.save(snapshot, context: chat.context, handoff: nil, draft: chat.record.draft) }
        catch { return false }
        updateHistoryList()
      }
      return true
    default: return false
    }
  }
  @discardableResult func newChat() -> Bool {
    guard canSwitchChat else { storageStatus = "请先停止当前任务，再切换聊天。"; return false }
    do {
      try persistCurrentChat()
      try history.select(nil)
      try handoffs.consume()
      try conversations.remove()
      try records.remove()
    } catch {
      storageStatus = "新聊天未能打开：\(error.localizedDescription)"
      return false
    }
    resetCurrentChat()
    updateHistoryList()
    return true
  }
  @discardableResult func openHistory(_ id: UUID) -> Bool {
    guard canSwitchChat else { storageStatus = "请先停止当前任务，再切换聊天。"; return false }
    if id == runID { return true }
    do {
      try persistCurrentChat()
      let chat = try history.load(id)
      // Commit selection first: on relaunch the archive remains authoritative
      // even if refreshing the legacy/current cache files is interrupted.
      try history.select(id)
      applyChat(chat)
      do { try mirrorCurrentFiles(chat) }
      catch { storageStatus = "聊天已打开，但当前记录缓存未能更新。" }
      openRequest = UUID()
      updateHistoryList()
      return true
    } catch { storageStatus = "聊天未能打开：\(error.localizedDescription)"; return false }
  }
  @discardableResult func deleteHistory(_ id: UUID) -> Bool {
    guard canSwitchChat else { return false }
    do {
      try history.delete(id)
      TaskNotifications.shared.clear(runID: id)
      if id == runID {
        resetCurrentChat()
        try handoffs.consume(); try conversations.remove(); try records.remove()
      }
      updateHistoryList()
      return true
    } catch {
      // Deletion is committed by the tombstone, even if file cleanup fails.
      // Never leave a deleted chat active where a later draft can rewrite it.
      if history.isDeleted(id), id == runID { resetCurrentChat() }
      storageStatus = "聊天删除未完全完成：\(error.localizedDescription)"
      updateHistoryList()
      return false
    }
  }
  func refreshHistory() {
    #if DEBUG
      if isInterfacePreview { return }
    #endif
    if canSwitchChat {
      do { try persistCurrentChat() } catch { storageStatus = "历史聊天未能保存：\(error.localizedDescription)" }
    }
    updateHistoryList()
  }
  private func mirrorCurrentFiles(_ chat: LoadedChat) throws {
    if let context = chat.context { try conversations.save(context) } else { try conversations.remove() }
    if let pending = chat.handoff { try handoffs.save(pending) } else { try handoffs.consume() }
    try records.save(chat.record.snapshot)
  }
  private func currentSnapshot() -> TaskSnapshot? {
    guard let runID else { return nil }
    return .init(id: runID, prompt: activePrompt, phase: phase, timeline: timeline, result: result,
      startedAt: startedAt, updatedAt: chatUpdatedAt, model: runModel, conversationRevision: conversationRevision)
  }
  private func persistCurrentChat() throws {
    if runID == nil && !taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      runID = UUID(); startedAt = Date(); chatUpdatedAt = startedAt
    }
    guard runID != nil else { return }
    if taskText != savedDraft { chatUpdatedAt = Date() }
    guard let snapshot = currentSnapshot() else { return }
    try history.save(snapshot, context: savedConversation, handoff: pendingHandoff, draft: taskText)
    try records.save(snapshot)
    try history.select(snapshot.id)
    savedDraft = taskText
  }
  private func updateHistoryList() {
    do {
      var values = try history.summaries()
      if let snapshot = currentSnapshot(), !history.isDeleted(snapshot.id) {
        values.removeAll { $0.id == snapshot.id }
        values.append(ChatHistorySummary(snapshot: snapshot, draft: taskText))
      }
      historyEntries = values.sorted { $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt }
    } catch { storageStatus = "历史列表未能读取：\(error.localizedDescription)" }
  }
  private func scheduleDraftSave() {
    draftSaveOperation?.cancel()
    draftSaveOperation = Task {
      try? await Task.sleep(for: .milliseconds(500))
      guard !Task.isCancelled, !busy else { return }
      draftSaveOperation = nil
      do { try persistCurrentChat() } catch { storageStatus = "草稿未能保存：\(error.localizedDescription)" }
    }
  }
  private func resetCurrentChat() {
    loadingChat = true
    defer { loadingChat = false }
    saveOperation?.cancel()
    saveOperation = nil
    draftSaveOperation?.cancel()
    draftSaveOperation = nil
    savedConversation = nil
    conversationRevision = nil
    pendingHandoff = nil
    question = nil
    canReply = false
    taskText = ""
    activePrompt = ""
    runModel = nil
    result = ""
    timeline = AgentTimeline()
    phase = .idle
    status = "输入要做的事，由你启动"
    runID = nil
    storageStatus = ""
    savedDraft = ""
    chatUpdatedAt = Date()
    turns = 0; calls = 0
    gate = AgentPauseGate(); currentLoop = nil; executor = nil
    wasBackgrounded = false
  }
  private func scheduleSave() {
    guard saveOperation == nil else { return }
    saveOperation = Task {
      try? await Task.sleep(for: .milliseconds(350))
      guard !Task.isCancelled else { return }
      saveOperation = nil
      saveNow()
    }
  }
  private func saveNow() {
    saveOperation?.cancel()
    saveOperation = nil
    guard let runID else { return }
    chatUpdatedAt = Date()
    do {
      try records.save(
        .init(
          id: runID, prompt: activePrompt, phase: phase, timeline: timeline, result: result,
          startedAt: startedAt, updatedAt: chatUpdatedAt, model: runModel,
          conversationRevision: conversationRevision))
    } catch { storageStatus = "记录未能保存；请在离开前复制需要的回答。" }
  }
}
